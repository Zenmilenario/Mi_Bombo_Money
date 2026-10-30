import Combine
import Foundation
import SwiftData

@MainActor
final class CloudSyncCoordinator: ObservableObject {
    @Published private(set) var container: ModelContainer?
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var needsMigrationChoice = false
    @Published private(set) var status = "Conectando…"
    @Published private(set) var lastSync: Date?
    @Published private(set) var automaticPauseReason: String?
    @Published var errorMessage: String?
    @Published private(set) var conflict: CloudMergeConflict?
    @Published private(set) var viewGeneration = UUID()
    private var ownerID: UUID?
    private var baseline: CloudSnapshot?
    private var directory: URL?
    private var localMigration: FinanceBackup?
    private var pendingRemote: CloudSnapshot?
    private var pendingLocal: CloudJSON?
    private var pendingBase: CloudJSON?

    func setAutomaticPauseReason(_ reason: String?) {
        if automaticPauseReason != reason { automaticPauseReason = reason }
    }

    var migrationRecordCount: Int { localMigration?.totalRecords ?? 0 }
    var conflictDescriptions: [String] {
        guard let conflict else { return [] }
        return conflict.records.map { key in
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return key }
            let record = (try? CloudDocument.indexed(pendingLocal ?? .object([:]), entity: parts[0])[parts[1]]) ??
                (try? CloudDocument.indexed(pendingRemote?.document ?? .object([:]), entity: parts[0])[parts[1]])
            return record?.object["name"]?.string ?? record?.object["descriptionText"]?.string ?? record?.object["phrase"]?.string ?? "Registro de \(parts[0])"
        }
    }

    func open(account: CloudAccountManager) async {
        guard container == nil, !busy, let user = account.session?.user else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            ownerID = user.id
            directory = try PersistenceController.cloudDirectory(ownerID: user.id)
            container = try PersistenceController.makeCloudContainer(ownerID: user.id)
            if let directory, FileManager.default.fileExists(atPath: directory.appendingPathComponent("SyncState.enc").path) {
                let encrypted = try Data(contentsOf: directory.appendingPathComponent("SyncState.enc"))
                baseline = try JSONDecoder().decode(CloudSnapshot.self, from: LocalEncryptionService.decrypt(encrypted))
                ready = true; status = "Datos de este dispositivo"
                return
            }
            let cached = try CloudBackupAdapter.document(in: container!.mainContext)
            let remote = try await account.snapshot()
            try requireIdentity(account)
            if CloudDocument.financialRecordCount(cached) > 0 {
                // A crash may leave a valid cache before its first baseline was written.
                // Establish an empty baseline and review overlapping edits instead of replacing it.
                baseline = CloudSnapshot(workspaceID: remote.workspaceID, revision: remote.revision,
                                         document: CloudDocument.normalized(.object([:])))
                ready = true; status = "Recuperando cambios de este dispositivo"
                return
            }
            if CloudDocument.financialRecordCount(remote.document) == 0 {
                let original = try BackupService.capture(in: PersistenceController.shared.mainContext)
                let source = try JSONDecoder().decode(CloudJSON.self, from: BackupService.encode(original))
                if CloudDocument.financialRecordCount(source) > 0 {
                    localMigration = original
                    pendingRemote = remote
                    needsMigrationChoice = true
                    status = "Elige cómo empezar"
                    return
                }
            }
            try finish(remote, preserving: nil)
            if remote.document.object["categories"]?.array.isEmpty != false, let container {
                try CategoryDefaultsService.restoreMissing(in: container.mainContext, stableIDs: true)
            }
            ready = true
        } catch {
            errorMessage = error.localizedDescription
            status = "Pendiente de conexión"
        }
    }

    func chooseMigration(copyLocal: Bool, account: CloudAccountManager) async {
        guard !busy, let remote = pendingRemote else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let fresh = try await account.snapshot(workspace: remote.workspaceID)
            try requireIdentity(account)
            var result = fresh
            if copyLocal, let localMigration {
                guard CloudDocument.financialRecordCount(fresh.document) == 0 else {
                    throw CloudTransportError.requestRejected("Otro dispositivo ya tiene datos en esta cuenta. Elige empezar sin copiar para abrirlos; tus datos locales siguen guardados aparte.")
                }
                let document = try JSONDecoder().decode(CloudJSON.self, from: BackupService.encode(localMigration))
                result = try await account.save(workspace: fresh.workspaceID, revision: fresh.revision, document: document)
                try requireIdentity(account)
            }
            try finish(result, preserving: nil)
            if result.document.object["categories"]?.array.isEmpty != false, let container {
                try CategoryDefaultsService.restoreMissing(in: container.mainContext, stableIDs: true)
            }
            localMigration = nil; pendingRemote = nil; needsMigrationChoice = false; ready = true
        } catch { errorMessage = error.localizedDescription }
    }

    func synchronize(account: CloudAccountManager, preferLocal: Bool? = nil) async {
        guard ready, !busy, let container, let baseline, account.session?.user.id == ownerID,
              !account.needsSignIn, conflict == nil || preferLocal != nil else { return }
        busy = true; errorMessage = nil; status = "Sincronizando…"
        defer { busy = false }
        do {
            // Read the cloud under its workspace lock, then capture any edits made while awaiting it.
            let remote = try await account.snapshot(workspace: baseline.workspaceID)
            try requireIdentity(account)
            try container.mainContext.save()
            let local = try CloudBackupAdapter.document(in: container.mainContext)
            let merged: CloudJSON
            do {
                if let preferLocal, pendingRemote?.revision == remote.revision {
                    merged = try CloudDocument.resolving(base: baseline.document, local: local, remote: remote.document, preferLocal: preferLocal)
                } else {
                    merged = try CloudDocument.merge(base: baseline.document, local: local, remote: remote.document)
                }
            } catch let issue as CloudMergeConflict {
                conflict = issue; pendingRemote = remote; pendingLocal = local; pendingBase = baseline.document
                status = "Cambios por revisar"
                throw issue
            }
            // Validate the merged graph before transmitting anything, including deletions and reserves.
            _ = try CloudBackupAdapter.backup(from: merged)
            let result: CloudSnapshot
            if try CloudDocument.same(merged, remote.document) { result = remote }
            else {
                result = try await account.save(workspace: remote.workspaceID, revision: remote.revision, document: merged)
                try requireIdentity(account)
            }
            // A user may save another form while the network write is in flight.
            let latest = try CloudBackupAdapter.document(in: container.mainContext)
            let finalLocal: CloudJSON
            do { finalLocal = try CloudDocument.merge(base: local, local: latest, remote: result.document) }
            catch let issue as CloudMergeConflict {
                pendingRemote = result; pendingLocal = latest; pendingBase = baseline.document
                throw issue
            }
            try finish(result, preserving: finalLocal)
            conflict = nil; pendingRemote = nil; pendingLocal = nil; pendingBase = nil
        } catch is CancellationError {
            status = "Guardado en este dispositivo"
            errorMessage = nil
        } catch let issue as CloudMergeConflict {
            conflict = issue
            status = "Cambios por revisar"
            errorMessage = issue.localizedDescription
        } catch {
            status = "Guardado en este dispositivo"
            errorMessage = error.localizedDescription
        }
    }

    private func requireIdentity(_ account: CloudAccountManager) throws {
        guard account.session?.user.id == ownerID else { throw CancellationError() }
    }
    private func finish(_ remote: CloudSnapshot, preserving localDocument: CloudJSON?) throws {
        guard let container, let directory else { throw CloudTransportError.invalidData }
        let current = try CloudBackupAdapter.document(in: container.mainContext)
        let incoming = localDocument ?? remote.document
        let backup = try CloudBackupAdapter.backup(from: incoming)
        if try !CloudDocument.same(current, incoming) {
            // Keep one encrypted pre-merge recovery copy, outside Git and scoped to this user.
            try LocalEncryptionService.encrypt(BackupService.encode(BackupService.capture(in: container.mainContext)))
                .write(to: directory.appendingPathComponent("BeforeLastSync.enc"), options: [.atomic, .completeFileProtection])
            var removed = false
            for entity in CloudDocument.entities {
                let before = Set(try CloudDocument.indexed(current, entity: entity).keys)
                let after = Set(try CloudDocument.indexed(incoming, entity: entity).keys)
                if !before.subtracting(after).isEmpty { removed = true }
            }
            try CloudBackupAdapter.apply(backup, in: container.mainContext)
            if removed { viewGeneration = UUID() }
        }
        let encoded = try JSONEncoder().encode(remote)
        try LocalEncryptionService.encrypt(encoded).write(to: directory.appendingPathComponent("SyncState.enc"), options: [.atomic, .completeFileProtection])
        baseline = remote
        lastSync = .now
        status = (try CloudDocument.same(incoming, remote.document)) ? "Al día" : "Cambios pendientes de subir"
    }

    func retryOpening(account: CloudAccountManager) async {
        guard !busy else { return }
        container = nil; ready = false
        await open(account: account)
    }
}
