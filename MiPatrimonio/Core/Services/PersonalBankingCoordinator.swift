import Combine
import Foundation
import SwiftData

@MainActor
final class PersonalBankingCoordinator: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message = "Conecta tus bancos para recibir sus movimientos."
    @Published private(set) var errorMessage: String?
    @Published private(set) var connections: [ConnectedBankSession] = []
    @Published private(set) var banks: [ConnectedBank] = []
    @Published private(set) var pendingPlan: PersonalBankingPlan?
    private var pendingFeeds: [BankingAccountFeed] = []
    private var pendingLedger: [UUID: BankingLedgerEntry]?
    private var observedAt: Date?
    private var nextAttempt = Date.distantPast
    private var owner: UUID?

    func savedServer(owner: UUID) -> String { UserDefaults.standard.string(forKey: key(owner)) ?? "" }
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
        nextAttempt = .distantPast
        UserDefaults.standard.removeObject(forKey: key(session.user.id) + "-next")
        try await refresh(account: account)
    }
    func refresh(account: CloudAccountManager) async throws {
        let expectedOwner = account.session?.user.id
        let client = try await client(account: account)
        _ = try await client.status()
        let connections = try await client.connections()
        let banks = try await client.banks()
        guard account.session?.user.id == expectedOwner else { throw CancellationError() }
        self.connections = connections; self.banks = banks; self.owner = expectedOwner
    }
    /// Called serially between cloud synchronization passes; never from a closed or locked app.
    @discardableResult
    func synchronize(account: CloudAccountManager, context: ModelContext, force: Bool = false,
                     mayApply: @MainActor () -> Bool = { true }) async -> Bool {
        guard !busy, let user = account.session?.user.id, !savedServer(owner: user).isEmpty else { return false }
        let persistedNext = UserDefaults.standard.object(forKey: key(user) + "-next") as? Date ?? .distantPast
        if !force && (Date.now < max(nextAttempt, persistedNext) || pendingPlan != nil) { return false }
        guard !context.hasChanges else { return false }
        busy = true; errorMessage = nil; owner = user
        defer { busy = false }
        // Retrying every 15 seconds would turn cloud polling into banking polling.
        nextAttempt = .now.addingTimeInterval(15 * 60)
        UserDefaults.standard.set(nextAttempt, forKey: key(user) + "-next")
        do {
            let client = try await client(account: account)
            _ = try await client.status()
            let available = try await client.connections()
            guard !available.isEmpty else {
                connections = []; pendingPlan = nil; pendingFeeds = []
                message = "No hay permisos bancarios activos. Conecta o renueva tu banco."
                return false
            }
            let accounts = try context.fetch(FetchDescriptor<FinancialAccount>())
            let server = URL(string: savedServer(owner: user))!
            let selected = available.map { connection in
                ConnectedBankSession(id: connection.id, bank: connection.bank, validUntil: connection.validUntil,
                    accounts: connection.accounts.filter { remote in
                        accounts.contains { $0.bankIdentityKey == PersonalBankingImporter.identity(server: server, accountID: remote.id) && !$0.isArchived }
                    })
            }.filter { !$0.accounts.isEmpty }
            guard !selected.isEmpty else {
                connections = available; message = "Hay cuentas nuevas por asociar en Conexión bancaria."
                return false
            }
            let date = Date.now
            let feeds = try await client.feeds(selected, asOf: date)
            let selectedIDs = Set(selected.flatMap(\.accounts).map(\.id))
            let notLinked = Set(available.flatMap(\.accounts).filter { !selectedIDs.contains($0.id) }.compactMap(\.ownershipKey))
            if feeds.contains(where: { feed in feed.movements.contains { $0.counterpartyKey.map { notLinked.contains($0) } == true } }) {
                throw PersonalBankingError.incompleteTransfer
            }
            try Task.checkCancellation()
            guard account.session?.user.id == user, !context.hasChanges, mayApply() else { throw PersonalBankingError.changed }
            let plan = try PersonalBankingImporter.plan(feeds, server: server, in: context)
            connections = available
            let bankSnapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
            let firstImport = plan.balances.contains { balance in
                !bankSnapshots.contains { $0.account?.id == balance.account && $0.source == .bankAPI && $0.notes == "Saldo contable de Enable Banking" }
            }
            if firstImport {
                pendingFeeds = feeds; pendingPlan = plan; observedAt = date
                pendingLedger = Dictionary(uniqueKeysWithValues: try PersonalBankingImporter.ledger(in: context).map { ($0.id, $0) })
                message = "Primera descarga preparada: revisa las cuentas y los movimientos antes de incorporarlos."
                return false
            }
            do { _ = try plan.resolutions([:]) }
            catch PersonalBankingError.needsReview {
                pendingFeeds = feeds; pendingPlan = plan; observedAt = date
                pendingLedger = Dictionary(uniqueKeysWithValues: try PersonalBankingImporter.ledger(in: context).map { ($0.id, $0) })
                message = "Hay movimientos bancarios por revisar antes de incorporarlos."
                return false
            }
            let result = try PersonalBankingImporter.apply(feeds, server: server, in: context, observedAt: date)
            pendingPlan = nil; pendingFeeds = []; observedAt = date
            message = "\(result.inserted) movimientos nuevos · \(result.matched) coincidencias reconocidas."
            nextAttempt = date.addingTimeInterval(6 * 60 * 60)
            UserDefaults.standard.set(nextAttempt, forKey: key(user) + "-next")
            return true
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch { errorMessage = error.localizedDescription }
        return false
    }
    func confirm(choices: [String: PersonalBankingPlan.Choice], account: CloudAccountManager, context: ModelContext) throws {
        guard !busy, let user = account.session?.user.id, user == owner, let observedAt,
              Date.now.timeIntervalSince(observedAt) < 15 * 60, pendingPlan != nil,
              let server = URL(string: savedServer(owner: user)) else { throw PersonalBankingError.changed }
        let current = Dictionary(uniqueKeysWithValues: try PersonalBankingImporter.ledger(in: context).map { ($0.id, $0) })
        guard current == pendingLedger else { throw PersonalBankingError.changed }
        let result = try PersonalBankingImporter.apply(pendingFeeds, server: server, choices: choices, in: context, observedAt: observedAt)
        pendingPlan = nil; pendingFeeds = []; nextAttempt = .now.addingTimeInterval(6 * 60 * 60)
        UserDefaults.standard.set(nextAttempt, forKey: key(user) + "-next")
        message = "\(result.inserted) movimientos nuevos · \(result.matched) coincidencias conservadas."
        errorMessage = nil
    }
    func disconnected() {
        pendingPlan = nil; pendingFeeds = []; pendingLedger = nil; nextAttempt = .distantPast
        if let owner { UserDefaults.standard.removeObject(forKey: key(owner) + "-next") }
    }
}
