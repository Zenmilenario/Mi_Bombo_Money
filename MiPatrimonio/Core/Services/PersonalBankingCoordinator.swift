#if canImport(Combine)
import Combine
#endif
import Foundation
#if canImport(SwiftData)
import SwiftData
#endif

@MainActor
final class PersonalBankingCoordinator: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message = "Conecta tus bancos para recibir sus movimientos."
    @Published private(set) var errorMessage: String?
    @Published private(set) var connections: [ConnectedBankSession] = []
    @Published private(set) var banks: [ConnectedBank] = []
    @Published private(set) var pendingPlan: PersonalBankingPlan?
    @Published private(set) var catalogueErrorMessage: String?
    private var pendingFeeds: [BankingAccountFeed] = []
    private var pendingLedger: [UUID: BankingLedgerEntry]?
    private var observedAt: Date?
    @Published private(set) var bankStatus: [String: BankingBankSyncStatus] = [:]
    private var schedules: [String: BankingBankSchedule] = [:]
    private var nextDiscoveryAttempt = Date.distantPast
    private var pendingDeferred: [String: Int] = [:]
    private var owner: UUID?

    func savedServer(owner: UUID) -> String {
        let saved = UserDefaults.standard.string(forKey: key(owner))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? "https://" + BankingConnectionPolicy.personalServerHost : saved
    }
    private func key(_ owner: UUID) -> String { "banking-live-origin-v1-" + owner.uuidString.lowercased() }
    func client(account: CloudAccountManager, override: String? = nil) async throws -> BankingConnectionClient {
        let session = try await account.validSession()
        let configuration = try BankingServerConfiguration.cloud(url: override ?? savedServer(owner: session.user.id), accessToken: session.accessToken)
        return BankingConnectionClient(configuration: configuration, live: true)
    }
    func configure(server: String, account: CloudAccountManager) async throws {
        let session = try await account.validSession()
        let configuration = try BankingServerConfiguration.cloud(url: server, accessToken: session.accessToken)
        _ = try await BankingConnectionClient(configuration: configuration, live: true).status()
        guard account.session?.user.id == session.user.id else { throw CancellationError() }
        UserDefaults.standard.set(configuration.serverURL.absoluteString, forKey: key(session.user.id))
        nextDiscoveryAttempt = .distantPast
        try await refresh(account: account)
    }
    func refresh(account: CloudAccountManager) async throws {
        let expectedOwner = account.session?.user.id
        let client = try await client(account: account)
        _ = try await client.status()
        let connections = try await client.connections()
        guard account.session?.user.id == expectedOwner else { throw CancellationError() }
        if self.owner != expectedOwner { bankStatus = [:] }
        self.connections = connections; self.owner = expectedOwner
        if let expectedOwner { loadSchedules(user: expectedOwner, banks: Set(connections.map(\.bank))) }
        // Catalogue availability must not hide existing connections or block their reads.
        do {
            let availableBanks = try await client.banks()
            guard account.session?.user.id == expectedOwner else { throw CancellationError() }
            banks = availableBanks; catalogueErrorMessage = nil
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw error }
        catch { catalogueErrorMessage = "No se ha podido cargar el catálogo de bancos. Las conexiones existentes se pueden seguir actualizando." }
    }
    /// Called by the UI after authorization or after the account-link sheet has closed.
    func connectionCompleted(bank: String, account: CloudAccountManager, context: ModelContext) async throws {
        for _ in 0..<600 {
            if !busy { break }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !busy else {
            message = "Ya hay una consulta bancaria en curso. Espera a que termine para ver su revisión."
            return
        }
        // Reserve the coordinator while metadata loads so the automatic loop cannot
        // consume the user's explicit action in the middle of the callback.
        busy = true
        do { try await refresh(account: account) }
        catch { busy = false; throw error }
        busy = false
        nextDiscoveryAttempt = .distantPast
        _ = await synchronize(account: account, context: context, force: true, onlyBank: bank)
    }
    private func loadSchedules(user: UUID, banks: Set<String>) {
        let storageKey = key(user) + "-bank-schedules-v2"
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([String: BankingBankSchedule].self, from: data) {
            schedules = saved
        } else {
            schedules = [:]
            // The old version stored no bank identity with its cooldown. Preserve that
            // existing wait once; guessing a bank would risk bypassing its restriction.
            if let old = UserDefaults.standard.object(forKey: key(user) + "-blocked-until") as? Date, old > .now {
                for bank in banks { schedules[bank] = BankingBankSchedule(nextAttempt: old, blockedUntil: old) }
            }
            if !banks.isEmpty {
                saveSchedules(user: user)
                UserDefaults.standard.removeObject(forKey: key(user) + "-blocked-until")
                UserDefaults.standard.removeObject(forKey: key(user) + "-next")
            }
        }
        for bank in banks {
            if let until = schedules[bank]?.blockedUntil, until > .now {
                let automaticOnly = schedules[bank]?.manualBlockedUntil.map { $0 <= .now } ?? true
                bankStatus[bank] = BankingBankSyncStatus(summary: automaticOnly
                    ? "La actualización automática está en espera. Puedes solicitar una comprobación manual."
                    : "El banco ha limitado también las consultas manuales.",
                    errorMessage: bankStatus[bank]?.errorMessage, retryAt: until,
                    retryIsAutomatic: automaticOnly)
            } else if schedules[bank]?.awaitingReview == true && pendingPlan == nil {
                bankStatus[bank] = BankingBankSyncStatus(summary: "Hay una descarga anterior sin incorporar. Actualiza este banco para recuperar la revisión.")
            } else if bankStatus[bank] == nil {
                let imported = schedules[bank]?.lastImportedAt
                bankStatus[bank] = BankingBankSyncStatus(summary: imported.map {
                    "Última incorporación: \($0.formatted(date: .abbreviated, time: .shortened))."
                } ?? "Cuenta conectada; pendiente de comprobar la descarga.")
            }
        }
    }
    private func saveSchedules(user: UUID) {
        if let data = try? JSONEncoder().encode(schedules) {
            UserDefaults.standard.set(data, forKey: key(user) + "-bank-schedules-v2")
        }
    }
    private func imported(_ feeds: [BankingAccountFeed], deferred: [String: Int]) {
        for bank in Set(feeds.map(\.connection.bank)) {
            schedules[bank, default: BankingBankSchedule()].lastImportedAt = .now
            schedules[bank, default: BankingBankSchedule()].awaitingReview = false
            bankStatus[bank] = BankingBankSyncStatus(summary: "Descarga incorporada a tus finanzas.",
                deferredTransfers: deferred[bank, default: 0])
        }
        if let owner { saveSchedules(user: owner) }
    }
    /// Called serially between cloud synchronization passes; never from a closed or locked app.
    @discardableResult
    func synchronize(account: CloudAccountManager, context: ModelContext, force: Bool = false,
                     onlyBank: String? = nil, mayApply: @MainActor () -> Bool = { true }) async -> Bool {
        guard !busy, let user = account.session?.user.id, !savedServer(owner: user).isEmpty else { return false }
        if pendingPlan != nil {
            if force { message = "Revisa e incorpora la descarga pendiente, o descártala, antes de solicitar otra." }
            return false
        }
        if !force && Date.now < nextDiscoveryAttempt { return false }
        guard !context.hasChanges else {
            if force { message = "Hay cambios locales pendientes de guardar. Finaliza el formulario antes de actualizar el banco." }
            return false
        }
        busy = true; errorMessage = nil; owner = user
        pendingPlan = nil; pendingFeeds = []; pendingLedger = nil; observedAt = nil; pendingDeferred = [:]
        message = "Consultando cada banco por separado…"
        defer { busy = false }
        nextDiscoveryAttempt = .now.addingTimeInterval(15 * 60)
        var downloaded: [BankingAccountFeed] = []
        do {
            let client = try await client(account: account)
            _ = try await client.status()
            let available = try await client.connections()
            guard account.session?.user.id == user else { throw CancellationError() }
            connections = available
            guard !available.isEmpty else {
                message = "No hay permisos bancarios activos. Conecta o renueva tu banco."
                return false
            }
            loadSchedules(user: user, banks: Set(available.map(\.bank)))
            let accounts = try context.fetch(FetchDescriptor<FinancialAccount>())
            let server = URL(string: savedServer(owner: user))!
            let linked = available.map { connection in
                ConnectedBankSession(id: connection.id, bank: connection.bank, validUntil: connection.validUntil,
                    accounts: connection.accounts.filter { remote in
                        accounts.contains { $0.bankIdentityKey == PersonalBankingImporter.identity(server: server, accountID: remote.id) && !$0.isArchived }
                    })
            }.filter { !$0.accounts.isEmpty }
            let requested = linked.filter { onlyBank == nil || $0.bank == onlyBank }
            guard !requested.isEmpty else {
                message = "Asocia una cuenta del banco con una cuenta de la app para descargar sus movimientos."
                return false
            }
            let date = Date.now
            let selected = requested.filter { schedules[$0.bank, default: BankingBankSchedule()].allows(force: force, at: date) }
            guard !selected.isEmpty else {
                message = "Los bancos seleccionados están en espera. Consulta el estado de cada banco; los demás mantienen su propio plazo."
                nextDiscoveryAttempt = requested.map { schedules[$0.bank, default: BankingBankSchedule()].automaticDate }.min() ?? nextDiscoveryAttempt
                return false
            }
            let outcomes = try await PersonalBankingDownloadBatch.load(selected) { group in
                let bank = group[0].bank
                self.schedules[bank, default: BankingBankSchedule()].started(at: date)
                self.saveSchedules(user: user)
                return try await client.feeds(group, asOf: date, userInitiated: force)
            }
            for outcome in outcomes {
                switch outcome {
                case .downloaded(let bank, let feeds):
                    schedules[bank, default: BankingBankSchedule()].downloaded(at: date)
                    bankStatus[bank] = BankingBankSyncStatus(summary: "\(feeds.reduce(0) { $0 + $1.movements.count }) movimientos recibidos; pendientes de incorporar.")
                    downloaded += feeds
                case .failed(let bank, let error):
                    let delay = (error as? BankingConnectionError)?.retryDelay
                    schedules[bank, default: BankingBankSchedule()].failed(at: .now, retryAfter: delay, userInitiated: force)
                    bankStatus[bank] = BankingBankSyncStatus(summary: "No se ha completado la descarga de este banco.",
                        errorMessage: error.localizedDescription, retryAt: schedules[bank]?.blockedUntil,
                        retryIsAutomatic: !force)
                }
            }
            saveSchedules(user: user)
            nextDiscoveryAttempt = linked.map { schedules[$0.bank, default: BankingBankSchedule()].automaticDate }.min() ?? nextDiscoveryAttempt
            guard !downloaded.isEmpty else {
                message = "No se ha incorporado ninguna descarga. Revisa el estado de cada banco; tus datos guardados se conservan."
                return false
            }
            let selection = try PersonalBankingDownloadSelection.prepare(downloaded, knownAccounts: available.flatMap(\.accounts))
            let feeds = selection.feeds
            for (bank, count) in selection.deferredByBank { bankStatus[bank]?.deferredTransfers = count }
            try Task.checkCancellation()
            guard account.session?.user.id == user, !context.hasChanges, mayApply() else { throw PersonalBankingError.changed }
            let plan = try PersonalBankingImporter.plan(feeds, server: server, in: context)
            let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
            let firstImport = plan.balances.contains { balance in
                !snapshots.contains { $0.account?.id == balance.account && $0.source == .bankAPI && $0.notes == "Saldo contable de Enable Banking" }
            }
            var needsReview = firstImport || plan.requiresReferenceReview
            do { _ = try plan.resolutions([:]) }
            catch PersonalBankingError.needsReview { needsReview = true }
            let names = Set(feeds.map(\.connection.bank)).sorted().joined(separator: ", ")
            if needsReview {
                for bank in Set(feeds.map(\.connection.bank)) {
                    schedules[bank, default: BankingBankSchedule()].awaitingReview = true
                }
                saveSchedules(user: user)
                pendingFeeds = feeds; pendingPlan = plan; observedAt = date; pendingDeferred = selection.deferredByBank
                pendingLedger = Dictionary(uniqueKeysWithValues: try PersonalBankingImporter.ledger(in: context).map { ($0.id, $0) })
                message = "Descarga preparada de \(names): revisa e incorpora los movimientos. El estado de los demás bancos se muestra por separado."
                return false
            }
            let result = try PersonalBankingImporter.apply(feeds, server: server, in: context, observedAt: date)
            imported(feeds, deferred: selection.deferredByBank)
            message = "\(names): \(result.inserted) movimientos nuevos · \(result.matched) coincidencias reconocidas."
            return true
        } catch is CancellationError { message = "Consulta cancelada. Tus datos guardados se conservan." }
        catch let error as URLError where error.code == .cancelled { message = "Consulta cancelada. Tus datos guardados se conservan." }
        catch {
            for bank in Set(downloaded.map(\.connection.bank)) {
                bankStatus[bank]?.summary = "Descarga recibida, pero no se ha podido incorporar."
            }
            message = "No se ha incorporado esta descarga. Tus datos guardados se conservan."
            errorMessage = error.localizedDescription
        }
        return false
    }
    func confirm(choices: [String: PersonalBankingPlan.Choice], account: CloudAccountManager, context: ModelContext) throws {
        guard !busy, let user = account.session?.user.id, user == owner, let observedAt,
              Date.now.timeIntervalSince(observedAt) < 15 * 60, pendingPlan != nil,
              let server = URL(string: savedServer(owner: user)) else { throw PersonalBankingError.changed }
        let current = Dictionary(uniqueKeysWithValues: try PersonalBankingImporter.ledger(in: context).map { ($0.id, $0) })
        guard current == pendingLedger else { throw PersonalBankingError.changed }
        let result = try PersonalBankingImporter.apply(pendingFeeds, server: server, choices: choices, in: context, observedAt: observedAt)
        imported(pendingFeeds, deferred: pendingDeferred)
        pendingPlan = nil; pendingFeeds = []; pendingDeferred = [:]
        message = "\(result.inserted) movimientos nuevos · \(result.matched) coincidencias conservadas."
        errorMessage = nil
    }
    func discardPending() {
        guard !busy else { return }
        for bank in Set(pendingFeeds.map(\.connection.bank)) {
            bankStatus[bank]?.summary = "Descarga descartada sin incorporar. Puedes solicitar una nueva."
            schedules[bank, default: BankingBankSchedule()].awaitingReview = false
        }
        if let owner { saveSchedules(user: owner) }
        pendingPlan = nil; pendingFeeds = []; pendingLedger = nil; observedAt = nil; pendingDeferred = [:]
        message = "No se ha incorporado la descarga descartada. Tus datos guardados se conservan."
    }
    func disconnected() {
        pendingPlan = nil; pendingFeeds = []; pendingLedger = nil; observedAt = nil; pendingDeferred = [:]; nextDiscoveryAttempt = .distantPast
        errorMessage = nil
        message = "Las conexiones han cambiado. Actualiza los movimientos para preparar la descarga."
    }
}
