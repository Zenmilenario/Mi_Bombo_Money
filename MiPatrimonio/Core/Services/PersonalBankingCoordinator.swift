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
    @Published private var accountActivity: [String: BankingAccountActivity] = [:] {
        didSet { if let owner { BankingActivityStore.save(accountActivity, owner: owner) } }
    }
    /// Holds saved by a previous launch, shown before this session's first bank query.
    private var restoredActivity: (owner: UUID, value: [String: BankingAccountActivity])?
    private var pendingFeeds: [BankingAccountFeed] = []
    private var pendingLedger: [UUID: BankingLedgerEntry]?
    private var observedAt: Date?
    private struct Download {
        let feeds: [BankingAccountFeed]
        let knownAccounts: [ConnectedBankAccount]
        let server: URL
        let observedAt: Date
    }
    private var waitingDownload: Download?
    private static let reviewLifetime: TimeInterval = 15 * 60
    @Published private(set) var bankStatus: [String: BankingBankSyncStatus] = [:]
    private var schedules: [String: BankingBankSchedule] = [:]
    private var pendingDeferred: [String: Int] = [:]
    private var pendingHints: [String: Set<String>] = [:]
    private var owner: UUID?

    func activity(for user: UUID?) -> [String: BankingAccountActivity] {
        guard let user else { return [:] }
        if user == owner { return accountActivity }
        if restoredActivity?.owner != user { restoredActivity = (user, BankingActivityStore.load(owner: user)) }
        return restoredActivity?.value ?? [:]
    }
    /// Adopts the holds saved on this device when the coordinator starts serving this owner.
    private func adoptOwner(_ user: UUID) {
        guard owner != user else { return }
        owner = user
        accountActivity = BankingActivityStore.load(owner: user)
        restoredActivity = nil
    }

    func nextAutomaticRefresh(for bank: String) -> Date? {
        schedules[bank]?.automaticDate
    }

    func savedServer(owner: UUID) -> String {
        let saved = UserDefaults.standard.string(forKey: key(owner))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? "https://" + BankingConnectionPolicy.personalServerHost : saved
    }
    private func key(_ owner: UUID) -> String { "banking-live-origin-v1-" + owner.uuidString.lowercased() }
    private func discoveryDate(for owner: UUID) -> Date {
        UserDefaults.standard.object(forKey: key(owner) + "-next-discovery-v1") as? Date ?? .distantPast
    }
    private func scheduleDiscovery(for owner: UUID, at date: Date) {
        UserDefaults.standard.set(date, forKey: key(owner) + "-next-discovery-v1")
    }
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
        if configuration.serverURL != URL(string: savedServer(owner: session.user.id)) {
            accountActivity = [:]
            waitingDownload = nil
            clearReview()
        }
        UserDefaults.standard.set(configuration.serverURL.absoluteString, forKey: key(session.user.id))
        try await refresh(account: account)
    }
    func refresh(account: CloudAccountManager) async throws {
        let expectedOwner = account.session?.user.id
        let client = try await client(account: account)
        _ = try await client.status()
        let connections = try await client.connections()
        guard account.session?.user.id == expectedOwner else { throw CancellationError() }
        if self.owner != expectedOwner {
            bankStatus = [:]
            waitingDownload = nil
            clearReview()
            if let expectedOwner { adoptOwner(expectedOwner) } else { owner = nil; accountActivity = [:] }
        }
        self.connections = connections
        if let expectedOwner, let server = URL(string: savedServer(owner: expectedOwner)) {
            keepActivity(for: connections, server: server)
        }
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
                bankStatus[bank] = BankingBankSyncStatus(summary: "Hay una descarga anterior sin incorporar. La revisión se recuperará en la próxima consulta.")
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

    private func keepActivity(for connections: [ConnectedBankSession], server: URL) {
        let active = Set(connections.flatMap(\.accounts).map { PersonalBankingImporter.identity(server: server, accountID: $0.id) })
        accountActivity = accountActivity.filter { active.contains($0.key) }
    }
    private func imported(_ feeds: [BankingAccountFeed], deferred: [String: Int], keptEdits: [String: String] = [:]) {
        for bank in Set(feeds.map(\.connection.bank)) {
            schedules[bank, default: BankingBankSchedule()].lastImportedAt = .now
            schedules[bank, default: BankingBankSchedule()].awaitingReview = false
            let summary = ["Descarga incorporada a tus finanzas.", keptEdits[bank]].compactMap { $0 }.joined(separator: " ")
            bankStatus[bank] = BankingBankSyncStatus(summary: summary, deferredTransfers: deferred[bank, default: 0])
        }
        if let owner { saveSchedules(user: owner) }
    }
    /// Called serially between cloud synchronization passes; never from a closed or locked app.
    @discardableResult
    func synchronize(account: CloudAccountManager, context: ModelContext, force: Bool = false,
                     onlyBank: String? = nil, mayApply: @MainActor () -> Bool = { true }) async -> Bool {
        guard !busy, !Task.isCancelled, let user = account.session?.user.id else { return false }
        if owner != user {
            bankStatus = [:]
            waitingDownload = nil
            clearReview()
            adoptOwner(user)
        }
        let now = Date.now
        if let observedAt, now.timeIntervalSince(observedAt) >= Self.reviewLifetime {
            for bank in Set(pendingFeeds.map(\.connection.bank)) {
                bankStatus[bank]?.summary = "La revisión ha caducado y se recuperará en la próxima consulta."
            }
            clearReview()
            message = "La revisión ha caducado. Se preparará otra al actualizar el banco."
        }
        if pendingPlan != nil {
            if force { message = "Revisa e incorpora la descarga pendiente, o descártala, antes de solicitar otra." }
            return false
        }
        guard !context.hasChanges, mayApply() else {
            if force { message = "Hay cambios locales pendientes de guardar. Finaliza el formulario antes de actualizar el banco." }
            return false
        }
        if let received = waitingDownload {
            waitingDownload = nil
            if now.timeIntervalSince(received.observedAt) < Self.reviewLifetime {
                return incorporate(received, user: user, context: context)
            }
            message = "La descarga anterior ha caducado. Se actualizará cuando le toque al banco."
        }
        if !force && now < discoveryDate(for: user) { return false }
        busy = true; errorMessage = nil
        message = "Consultando cada banco por separado…"
        defer { busy = false }
        // Reserve the next discovery before issuing any request, including on a cold start.
        scheduleDiscovery(for: user, at: now.addingTimeInterval(15 * 60))
        do {
            let client = try await client(account: account)
            _ = try await client.status()
            let available = try await client.connections()
            guard account.session?.user.id == user else { throw CancellationError() }
            connections = available
            let server = URL(string: savedServer(owner: user))!
            keepActivity(for: available, server: server)
            guard !available.isEmpty else {
                message = "No hay permisos bancarios activos. Conecta o renueva tu banco."
                return false
            }
            loadSchedules(user: user, banks: Set(available.map(\.bank)))
            let accounts = try context.fetch(FetchDescriptor<FinancialAccount>())
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
                if let next = linked.map({ schedules[$0.bank, default: BankingBankSchedule()].automaticDate }).min() {
                    scheduleDiscovery(for: user, at: next)
                }
                return false
            }
            let outcomes = try await PersonalBankingDownloadBatch.load(selected) { group in
                let bank = group[0].bank
                self.schedules[bank, default: BankingBankSchedule()].started(at: .now)
                self.saveSchedules(user: user)
                return try await client.feeds(group, asOf: date, userInitiated: force)
            }
            guard account.session?.user.id == user else { throw CancellationError() }
            var downloaded: [BankingAccountFeed] = []
            for outcome in outcomes {
                switch outcome {
                case .downloaded(let bank, let feeds):
                    schedules[bank, default: BankingBankSchedule()].downloaded(at: .now)
                    bankStatus[bank] = BankingBankSyncStatus(summary: "\(feeds.reduce(0) { $0 + $1.movements.count }) movimientos recibidos; pendientes de incorporar.")
                    downloaded += feeds
                    for feed in feeds {
                        let identity = PersonalBankingImporter.identity(server: server, accountID: feed.account.id)
                        accountActivity[identity] = BankingAccountActivity(feed: feed, observedAt: date)
                    }
                case .failed(let bank, let error):
                    let delay = (error as? BankingConnectionError)?.retryDelay
                    schedules[bank, default: BankingBankSchedule()].failed(at: .now, retryAfter: delay, userInitiated: force)
                    bankStatus[bank] = BankingBankSyncStatus(summary: "No se ha completado la descarga de este banco.",
                        errorMessage: error.localizedDescription, retryAt: schedules[bank]?.blockedUntil,
                        retryIsAutomatic: !force)
                }
            }
            saveSchedules(user: user)
            if let next = linked.map({ schedules[$0.bank, default: BankingBankSchedule()].automaticDate }).min() {
                scheduleDiscovery(for: user, at: next)
            }
            guard !downloaded.isEmpty else {
                message = "No se ha incorporado ninguna descarga. Revisa el estado de cada banco; tus datos guardados se conservan."
                return false
            }
            let received = Download(feeds: downloaded, knownAccounts: available.flatMap(\.accounts), server: server, observedAt: date)
            if Task.isCancelled || context.hasChanges || !mayApply() {
                waitingDownload = received
                message = "Descarga recibida. Se incorporará cuando la app pueda guardar los cambios."
                return false
            }
            return incorporate(received, user: user, context: context)
        } catch is CancellationError { message = "Consulta cancelada. Tus datos guardados se conservan." }
        catch let error as URLError where error.code == .cancelled { message = "Consulta cancelada. Tus datos guardados se conservan." }
        catch {
            message = "No se ha completado la consulta bancaria."
            errorMessage = error.localizedDescription
        }
        return false
    }

    private func incorporate(_ download: Download, user: UUID, context: ModelContext) -> Bool {
        var excluded: [String: Error] = [:]
        do {
            // A problem in one bank's own feed must not hold back the others. Selecting again
            // defers own transfers whose peer bank was excluded; they are never imported as expenses.
            var remaining = download.feeds
            // Trade Republic sends no counterparty or reference: legs that name it are joined by amount and date.
            let referenceLessAccounts = Set(connections.filter { $0.bank == "Trade Republic" }.flatMap(\.accounts).map(\.id))
            var prepared: (selection: PersonalBankingDownloadSelection, plan: PersonalBankingPlan)?
            while prepared == nil {
                let candidate = try PersonalBankingDownloadSelection.prepare(remaining, knownAccounts: download.knownAccounts,
                    referenceLessAccounts: referenceLessAccounts)
                do {
                    prepared = (candidate, try PersonalBankingImporter.plan(candidate.feeds, server: download.server, in: context))
                } catch let error as PersonalBankingError {
                    guard let bank = error.bank, remaining.contains(where: { $0.connection.bank != bank }) else { throw error }
                    excluded[bank] = error
                    remaining.removeAll { $0.connection.bank == bank }
                }
            }
            guard let ready = prepared else { return false }
            let selection = ready.selection
            let plan = ready.plan
            let feeds = selection.feeds
            for (bank, count) in selection.deferredByBank { bankStatus[bank]?.deferredTransfers = count }
            reportExcluded(excluded)
            let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
            let firstImport = plan.balances.contains { balance in
                !snapshots.contains { $0.account?.id == balance.account && $0.source == .bankAPI && $0.notes == "Saldo contable de Enable Banking" }
            }
            var needsReview = firstImport || plan.requiresReferenceReview || plan.requiresBalanceReview
            do { _ = try plan.resolutions([:]) }
            catch PersonalBankingError.needsReview { needsReview = true }
            let names = Set(feeds.map(\.connection.bank)).sorted().joined(separator: ", ")
            if needsReview {
                for bank in Set(feeds.map(\.connection.bank)) {
                    schedules[bank, default: BankingBankSchedule()].awaitingReview = true
                }
                let ledger = try PersonalBankingImporter.ledger(in: context)
                saveSchedules(user: user)
                pendingFeeds = feeds; pendingPlan = plan; observedAt = download.observedAt; pendingDeferred = selection.deferredByBank
                pendingHints = selection.ownTransferHints
                pendingLedger = Dictionary(uniqueKeysWithValues: ledger.map { ($0.id, $0) })
                message = "Descarga preparada de \(names): revisa e incorpora los movimientos. El estado de los demás bancos se muestra por separado."
                errorMessage = excludedDescription(excluded)
                return false
            }
            let result = try PersonalBankingImporter.apply(feeds, server: download.server, ownTransferHints: selection.ownTransferHints,
                in: context, observedAt: download.observedAt)
            imported(feeds, deferred: selection.deferredByBank, keptEdits: plan.keptEditsSummary())
            message = "\(names): \(result.inserted) movimientos nuevos · \(result.matched) coincidencias reconocidas."
            errorMessage = excludedDescription(excluded)
            return true
        } catch {
            for bank in Set(download.feeds.map(\.connection.bank)) where excluded[bank] == nil {
                bankStatus[bank]?.summary = "Descarga recibida, pero no se ha podido incorporar."
                bankStatus[bank]?.errorMessage = error.localizedDescription
            }
            reportExcluded(excluded)
            message = "No se ha incorporado esta descarga. Tus datos guardados se conservan."
            errorMessage = [excludedDescription(excluded), error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
        }
        return false
    }
    private func reportExcluded(_ excluded: [String: Error]) {
        for (bank, error) in excluded {
            bankStatus[bank] = BankingBankSyncStatus(summary: "Descarga recibida, pero no se ha podido incorporar.",
                errorMessage: error.localizedDescription, deferredTransfers: bankStatus[bank]?.deferredTransfers ?? 0)
        }
    }
    private func excludedDescription(_ excluded: [String: Error]) -> String? {
        excluded.isEmpty ? nil : excluded.keys.sorted().compactMap { excluded[$0]?.localizedDescription }.joined(separator: "\n")
    }
    func confirm(choices: [String: PersonalBankingPlan.Choice], manualBalances: [UUID: PersonalBankingImporter.ManualBalance] = [:],
                 reviewedBalances: [PersonalBankingImporter.BalanceReview] = [], account: CloudAccountManager, context: ModelContext) throws {
        guard !busy, let user = account.session?.user.id, user == owner, let observedAt,
              Date.now.timeIntervalSince(observedAt) < Self.reviewLifetime, pendingPlan != nil,
              let server = URL(string: savedServer(owner: user)) else { throw PersonalBankingError.changed }
        let current = Dictionary(uniqueKeysWithValues: try PersonalBankingImporter.ledger(in: context).map { ($0.id, $0) })
        guard current == pendingLedger else { throw PersonalBankingError.changed }
        let result = try PersonalBankingImporter.apply(pendingFeeds, server: server, choices: choices,
            manualBalances: manualBalances, reviewedBalances: reviewedBalances, ownTransferHints: pendingHints,
            in: context, observedAt: observedAt)
        imported(pendingFeeds, deferred: pendingDeferred, keptEdits: pendingPlan?.keptEditsSummary() ?? [:])
        clearReview()
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
        clearReview()
        message = "No se ha incorporado la descarga descartada. Tus datos guardados se conservan."
    }
    private func clearReview() {
        pendingPlan = nil; pendingFeeds = []; pendingLedger = nil; observedAt = nil; pendingDeferred = [:]; pendingHints = [:]
    }
    func disconnected() {
        accountActivity = [:]
        waitingDownload = nil
        clearReview()
        if let owner { scheduleDiscovery(for: owner, at: .distantPast) }
        errorMessage = nil
        message = "Las conexiones han cambiado. Actualiza los movimientos para preparar la descarga."
    }
}
