import Foundation

// Standalone protocol fixtures: no credentials, network or personal database.
#if !canImport(Combine)
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
#endif
struct FixtureUser { let id: UUID }
struct FixtureSession { let user: FixtureUser; let accessToken = "fixture.payload.signature" }
@MainActor final class CloudAccountManager {
    var session: FixtureSession?
    init() { session = FixtureSession(user: FixtureUser(id: UUID())) }
    func validSession() async throws -> FixtureSession { session! }
}
final class FinancialAccount {
    let id = UUID()
    var bankIdentityKey: String?
    var isArchived = false
    init(remote: ConnectedBankAccount, server: URL) { bankIdentityKey = PersonalBankingImporter.identity(server: server, accountID: remote.id) }
}
enum FixtureSnapshotSource { case bankAPI }
struct BalanceSnapshot {
    var account: FinancialAccount?
    let source = FixtureSnapshotSource.bankAPI
    let notes = "Saldo contable de Enable Banking"
}
struct FetchDescriptor<Value> {}
@MainActor final class ModelContext {
    var hasChanges = false
    var accounts: [FinancialAccount] = []
    var snapshots: [BalanceSnapshot] = []
    var ledger: [BankingLedgerEntry] = []
    var appliedBanks: [String] = []
    func fetch<Value>(_ descriptor: FetchDescriptor<Value>) throws -> [Value] {
        if Value.self == FinancialAccount.self { return accounts as! [Value] }
        if Value.self == BalanceSnapshot.self { return snapshots as! [Value] }
        preconditionFailure("Unexpected fixture model")
    }
}
@MainActor final class BankingConnectionClient {
    static var available: [ConnectedBankSession] = []
    static var values: [String: [BankingAccountFeed]] = [:]
    static var limitedBank: String?
    static var attempts: [String] = []
    static var manual: [Bool] = []
    static var catalogueFails = false
    static var requestedAccounts: [String] = []
    static var feedDelay: UInt64 = 0
    static var activeReads = 0
    static var maximumReads = 0
    static var connectionReads = 0
    init(configuration: BankingServerConfiguration, live: Bool) {}
    func status() async throws -> BankingServerStatus { .init(mode: "production", liveBankingEnabled: true, accountingImportEnabled: true) }
    func connections() async throws -> [ConnectedBankSession] {
        Self.connectionReads += 1
        return Self.available
    }
    func banks() async throws -> [ConnectedBank] {
        if Self.catalogueFails { throw BankingConnectionError.server("bank_unavailable") }
        return []
    }
    func feeds(_ connections: [ConnectedBankSession], asOf: Date, userInitiated: Bool) async throws -> [BankingAccountFeed] {
        let bank = connections[0].bank
        Self.attempts.append(bank); Self.manual.append(userInitiated)
        let ids = Set(connections.flatMap(\.accounts).map(\.id))
        Self.requestedAccounts += ids.sorted()
        Self.activeReads += 1; Self.maximumReads = max(Self.maximumReads, Self.activeReads)
        defer { Self.activeReads -= 1 }
        if Self.feedDelay > 0 { try await Task.sleep(nanoseconds: Self.feedDelay) }
        if bank == Self.limitedBank { throw BankingConnectionError.accountQuery(bank: bank, lastFour: "0000", reason: .bankRateLimited(retryAfter: 21600)) }
        return (Self.values[bank] ?? []).filter { ids.contains($0.account.id) }
    }
}
enum PersonalBankingImporter {
    struct Result { let inserted: Int; let matched: Int }
    struct ManualBalance { }
    struct BalanceReview { }
    static func identity(server: URL, accountID: String) -> String { server.absoluteString + "|" + accountID }
    @MainActor static func ledger(in context: ModelContext) throws -> [BankingLedgerEntry] { context.ledger }
    @MainActor static func plan(_ feeds: [BankingAccountFeed], server: URL, in context: ModelContext) throws -> PersonalBankingPlan {
        let links = Dictionary(uniqueKeysWithValues: feeds.map { feed in
            (feed.account.id, context.accounts.first { $0.bankIdentityKey == identity(server: server, accountID: feed.account.id) }!.id)
        })
        return try PersonalBankingPlan.build(feeds: feeds, links: links, ledger: context.ledger)
    }
    @MainActor static func apply(_ feeds: [BankingAccountFeed], server: URL,
                                choices: [String: PersonalBankingPlan.Choice] = [:], manualBalances: [UUID: ManualBalance] = [:],
                                reviewedBalances: [BalanceReview]? = nil, ownTransferHints: [String: Set<String>] = [:],
                                in context: ModelContext, observedAt: Date) throws -> Result {
        let plan = try plan(feeds, server: server, in: context)
        let decisions = try plan.resolutions(choices)
        for item in plan.items {
            guard decisions[item.id] == .new else { preconditionFailure("Unexpected fixture match") }
            context.ledger.append(.init(id: UUID(), date: item.date, kind: item.kind, amount: item.amount,
                source: item.source, destination: item.destination, text: item.text, externalID: item.id))
        }
        context.appliedBanks += Set(feeds.map(\.connection.bank)).sorted()
        return Result(inserted: plan.items.count, matched: 0)
    }
}

@main struct PersonalBankingCoordinatorCheck {
    static let server = URL(string: "https://" + BankingConnectionPolicy.personalServerHost)!
    static let day = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-86400)).prefix(10)
    static func feed(bank: String, id: String, other: String? = nil) -> BankingAccountFeed {
        let remote = ConnectedBankAccount(id: id, name: "Synthetic", currency: "EUR", lastFour: "0000", ownershipKey: id)
        var rows: [BankingPreview.Movement] = bank == "BBVA" ? [.init(id: "purchase", bookingDate: String(day), signedAmountMinor: -750,
            currency: "EUR", description: "Synthetic purchase")] : []
        if let other { rows.append(.init(id: "transfer-" + id, bookingDate: String(day), signedAmountMinor: bank == "BBVA" ? 5000 : -5000,
            currency: "EUR", description: "Synthetic transfer", counterpartyKey: other, transferKey: "pair")) }
        return .init(connection: .init(id: UUID().uuidString, bank: bank, validUntil: "2099-01-01", accounts: [remote]), account: remote,
            balances: [.init(amountMinor: 10000, currency: "EUR", type: "CLBD")], movements: rows)
    }
    @MainActor static func main() async throws {
        let activityDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mibombo-activity-" + UUID().uuidString, isDirectory: true)
        BankingActivityStore.directoryOverride = activityDirectory
        defer { try? FileManager.default.removeItem(at: activityDirectory) }
        var bbva = feed(bank: "BBVA", id: "bbva", other: "bankinter")
        bbva.pendingMovements = [.init(id: nil, date: String(day), signedAmountMinor: -1250,
            currency: "EUR", description: "Fictitious hold", status: "HOLD")]
        let bankinter = feed(bank: "Bankinter", id: "bankinter", other: "bbva")
        BankingConnectionClient.available = [bbva.connection, bankinter.connection]
        BankingConnectionClient.values = ["BBVA": [bbva], "Bankinter": [bankinter]]
        BankingConnectionClient.limitedBank = "Bankinter"
        let account = CloudAccountManager()
        let storage = "banking-live-origin-v1-" + account.session!.user.id.uuidString.lowercased()
        let context = ModelContext()
        context.accounts = [bbva, bankinter].map { FinancialAccount(remote: $0.account, server: server) }
        context.snapshots = context.accounts.map { BalanceSnapshot(account: $0) }
        defer { for suffix in ["", "-bank-schedules-v2", "-blocked-until", "-next", "-next-discovery-v1"] { UserDefaults.standard.removeObject(forKey: storage + suffix) } }
        let coordinator = PersonalBankingCoordinator()
        try await coordinator.configure(server: server.absoluteString, account: account)
        let changed = await coordinator.synchronize(account: account, context: context, force: true)
        precondition(changed && context.appliedBanks == ["BBVA"])
        precondition(context.ledger.count == 1 && context.ledger[0].kind == "expense")
        let bankKey = context.accounts[0].bankIdentityKey!
        let owner = account.session!.user.id
        precondition(coordinator.activity(for: owner)[bankKey]?.pendingMovements?.count == 1)
        precondition(coordinator.activity(for: owner)[bankKey]?.pendingTotal == -1250)
        precondition(coordinator.activity(for: UUID()).isEmpty)
        // A later launch shows the saved holds before contacting the bank, only to the same owner.
        let relaunched = PersonalBankingCoordinator()
        precondition(relaunched.activity(for: owner)[bankKey]?.pendingMovements?.first?.description == "Fictitious hold")
        precondition(relaunched.activity(for: UUID()).isEmpty, "Holds are never shown to another user")
        let expired = BankingActivityStore.load(owner: owner, now: Date.now.addingTimeInterval(BankingActivityStore.maximumAge + 60))
        precondition(expired.isEmpty, "Old holds are dropped instead of being shown as current")
        precondition(coordinator.bankStatus["BBVA"]?.deferredTransfers == 1)
        precondition(coordinator.bankStatus["Bankinter"]?.retryAt != nil)
        precondition(BankingConnectionClient.manual.allSatisfy { $0 })
        let beforeAutomatic = BankingConnectionClient.attempts
        _ = await coordinator.synchronize(account: account, context: context)
        precondition(BankingConnectionClient.attempts == beforeAutomatic, "Cloud polling must not become repeated bank polling")

        let beforeReopens = BankingConnectionClient.connectionReads
        for _ in 0..<10 {
            let coldStart = PersonalBankingCoordinator()
            _ = await coldStart.synchronize(account: account, context: context)
        }
        precondition(BankingConnectionClient.connectionReads == beforeReopens && BankingConnectionClient.attempts == beforeAutomatic,
                     "Rapid cold starts must use the saved deadline before contacting the server or bank")

        let reopened = PersonalBankingCoordinator()
        try await reopened.configure(server: server.absoluteString, account: account)
        BankingConnectionClient.attempts = []
        _ = await reopened.synchronize(account: account, context: context, force: true, onlyBank: "Bankinter")
        precondition(BankingConnectionClient.attempts.isEmpty, "A blocked bank must not be queried after restarting")
        _ = await reopened.synchronize(account: account, context: context, force: true, onlyBank: "BBVA")
        precondition(BankingConnectionClient.attempts == ["BBVA"] && context.ledger.count == 1)
        bbva.pendingMovements = []
        BankingConnectionClient.values["BBVA"] = [bbva]
        _ = await reopened.synchronize(account: account, context: context, force: true, onlyBank: "BBVA")
        precondition(reopened.activity(for: owner)[bankKey]?.pendingMovements?.isEmpty == true,
                     "A fresh download replaces provisional entries for that account")

        // The first successful bank download still needs explicit confirmation.
        context.snapshots = []; context.ledger = []; BankingConnectionClient.attempts = []
        let beforeReview = await reopened.synchronize(account: account, context: context, force: true, onlyBank: "BBVA")
        precondition(!beforeReview && reopened.pendingPlan?.items.count == 1 && context.ledger.isEmpty)
        let beforeBlocked = BankingConnectionClient.attempts
        _ = await reopened.synchronize(account: account, context: context, force: true, onlyBank: "Bankinter")
        precondition(reopened.pendingPlan?.items.count == 1 && BankingConnectionClient.attempts == beforeBlocked,
            "Trying another bank must never erase the first bank's unconfirmed download")
        reopened.discardPending()
        precondition(reopened.pendingPlan == nil && context.ledger.isEmpty, "Discarding a preview must not delete or import financial data")
        _ = await reopened.synchronize(account: account, context: context, force: true, onlyBank: "BBVA")
        try reopened.confirm(choices: [:], account: account, context: context)
        precondition(context.ledger.count == 1)

        // A legacy wait stays automatic; an explicit online query still reaches the bank.
        let savedSchedule = UserDefaults.standard.data(forKey: storage + "-bank-schedules-v2")!
        UserDefaults.standard.removeObject(forKey: storage + "-bank-schedules-v2")
        UserDefaults.standard.set(Date.now.addingTimeInterval(3600), forKey: storage + "-blocked-until")
        let migrated = PersonalBankingCoordinator()
        try await migrated.configure(server: server.absoluteString, account: account)
        BankingConnectionClient.attempts = []
        _ = await migrated.synchronize(account: account, context: context, force: true, onlyBank: "BBVA")
        precondition(BankingConnectionClient.attempts == ["BBVA"])
        precondition(migrated.pendingPlan != nil, "A legacy global wait must not leave both banks looking disconnected")
        precondition(UserDefaults.standard.object(forKey: storage + "-blocked-until") == nil)

        // Once the other bank can be read, the held transfer is recovered exactly once.
        var restored = try JSONDecoder().decode([String: BankingBankSchedule].self, from: savedSchedule)
        restored["Bankinter"] = BankingBankSchedule()
        UserDefaults.standard.set(try JSONEncoder().encode(restored), forKey: storage + "-bank-schedules-v2")
        BankingConnectionClient.limitedBank = nil
        let recovered = PersonalBankingCoordinator()
        try await recovered.configure(server: server.absoluteString, account: account)
        context.snapshots = context.accounts.map { BalanceSnapshot(account: $0) }
        _ = await recovered.synchronize(account: account, context: context, force: true)
        precondition(context.ledger.count == 2 && context.ledger.filter { $0.kind == "transfer" }.count == 1)
        _ = await recovered.synchronize(account: account, context: context, force: true)
        precondition(context.ledger.count == 2, "Recovering the bank must not repeat its peer's purchase or the transfer")
        // Opening the first install needs no hidden manual server configuration.
        let freshAccount = CloudAccountManager()
        let freshStorage = "banking-live-origin-v1-" + freshAccount.session!.user.id.uuidString.lowercased()
        defer { for suffix in ["", "-bank-schedules-v2", "-next-discovery-v1"] { UserDefaults.standard.removeObject(forKey: freshStorage + suffix) } }
        let freshContext = ModelContext()
        freshContext.accounts = [FinancialAccount(remote: bbva.account, server: server)]
        let optional = ConnectedBankAccount(id: "optional-investment-cash", name: "Synthetic optional", currency: "EUR", lastFour: "0000")
        BankingConnectionClient.available = [.init(id: bbva.connection.id, bank: "BBVA", validUntil: "2099-01-01", accounts: [bbva.account, optional]), bankinter.connection]
        BankingConnectionClient.attempts = []; BankingConnectionClient.requestedAccounts = []
        BankingConnectionClient.manual = []; BankingConnectionClient.catalogueFails = true
        let fresh = PersonalBankingCoordinator()
        precondition(fresh.savedServer(owner: freshAccount.session!.user.id) == server.absoluteString)
        try await fresh.connectionCompleted(bank: "BBVA", account: freshAccount, context: freshContext)
        precondition(BankingConnectionClient.attempts == ["BBVA"] && BankingConnectionClient.manual == [true])
        precondition(BankingConnectionClient.requestedAccounts == [bbva.account.id], "An optional unlinked investment cash account must not be queried")
        precondition(fresh.pendingPlan?.items.count == 1 && fresh.catalogueErrorMessage != nil,
            "Authorization/link completion must prepare a visible download even if the bank catalogue is unavailable")
        precondition(freshContext.ledger.isEmpty, "Preparing the first download must not import without confirmation")
        try fresh.confirm(choices: [:], account: freshAccount, context: freshContext)
        let statusAfterRestart = PersonalBankingCoordinator()
        try await statusAfterRestart.refresh(account: freshAccount)
        precondition(statusAfterRestart.bankStatus["BBVA"]?.summary.contains("Última incorporación") == true)
        // The authorization callback cannot race an automatic download and lose its preview.
        fresh.discardPending()
        freshContext.ledger = []; BankingConnectionClient.feedDelay = 150_000_000
        UserDefaults.standard.removeObject(forKey: freshStorage + "-bank-schedules-v2")
        UserDefaults.standard.removeObject(forKey: freshStorage + "-next-discovery-v1")
        let racing = PersonalBankingCoordinator()
        let auto = Task { await racing.synchronize(account: freshAccount, context: freshContext, onlyBank: "BBVA") }
        try await Task.sleep(nanoseconds: 20_000_000)
        try await racing.connectionCompleted(bank: "BBVA", account: freshAccount, context: freshContext)
        _ = await auto.value
        precondition(racing.pendingPlan?.items.count == 1 && BankingConnectionClient.maximumReads == 1)

        // An editor opened while the download was in flight must not waste the bank read.
        freshContext.snapshots = freshContext.accounts.map { BalanceSnapshot(account: $0) }
        BankingConnectionClient.feedDelay = 0
        UserDefaults.standard.removeObject(forKey: freshStorage + "-bank-schedules-v2")
        UserDefaults.standard.removeObject(forKey: freshStorage + "-next-discovery-v1")
        let waiting = PersonalBankingCoordinator()
        let beforeWaiting = BankingConnectionClient.attempts.count
        var safetyChecks = 0
        let staged = await waiting.synchronize(account: freshAccount, context: freshContext, onlyBank: "BBVA") {
            safetyChecks += 1
            return safetyChecks == 1
        }
        precondition(!staged && freshContext.ledger.isEmpty && BankingConnectionClient.attempts.count == beforeWaiting + 1)
        let resumed = await waiting.synchronize(account: freshAccount, context: freshContext)
        precondition(resumed && freshContext.ledger.count == 1 && BankingConnectionClient.attempts.count == beforeWaiting + 1,
                     "Closing an editor must import the complete saved download without a second bank request")
        // A movement edited locally in one bank must not hold back another bank's download.
        let isolatedAccount = CloudAccountManager()
        let isolatedStorage = "banking-live-origin-v1-" + isolatedAccount.session!.user.id.uuidString.lowercased()
        defer { for suffix in ["", "-bank-schedules-v2", "-next-discovery-v1"] { UserDefaults.standard.removeObject(forKey: isolatedStorage + suffix) } }
        let isolatedBBVA = feed(bank: "BBVA", id: "iso-bbva")
        let sabadellRemote = ConnectedBankAccount(id: "iso-sabadell", name: "Synthetic", currency: "EUR", lastFour: "0000", ownershipKey: "iso-sabadell")
        let sabadell = BankingAccountFeed(connection: .init(id: UUID().uuidString, bank: "Sabadell", validUntil: "2099-01-01", accounts: [sabadellRemote]),
            account: sabadellRemote, balances: [.init(amountMinor: 20000, currency: "EUR", type: "CLBD")],
            movements: [.init(id: "salary", bookingDate: String(day), signedAmountMinor: 120000, currency: "EUR", description: "Synthetic salary")])
        let isolatedContext = ModelContext()
        isolatedContext.accounts = [isolatedBBVA, sabadell].map { FinancialAccount(remote: $0.account, server: server) }
        isolatedContext.snapshots = isolatedContext.accounts.map { BalanceSnapshot(account: $0) }
        isolatedContext.ledger = [.init(id: UUID(), date: .now, kind: "expense", amount: 999, source: isolatedContext.accounts[0].id,
            destination: nil, text: "Synthetic purchase edited by the user", externalID: "enable-entry:test:iso-bbva:purchase")]
        BankingConnectionClient.available = [isolatedBBVA.connection, sabadell.connection]
        BankingConnectionClient.values = ["BBVA": [isolatedBBVA], "Sabadell": [sabadell]]
        BankingConnectionClient.limitedBank = nil; BankingConnectionClient.feedDelay = 0
        let isolated = PersonalBankingCoordinator()
        try await isolated.configure(server: server.absoluteString, account: isolatedAccount)
        let isolatedApplied = await isolated.synchronize(account: isolatedAccount, context: isolatedContext, force: true)
        precondition(isolatedApplied && isolatedContext.appliedBanks == ["BBVA", "Sabadell"],
            "A movement the user edited no longer holds back its own bank or another one")
        precondition(isolatedContext.ledger.count == 2 && isolatedContext.ledger.contains { $0.amount == 120000 })
        precondition(isolatedContext.ledger.contains { $0.amount == 999 }, "The user's edited movement is preserved")
        precondition(isolated.bankStatus["Sabadell"]?.summary == "Descarga incorporada a tus finanzas.")
        precondition(isolated.bankStatus["BBVA"]?.summary.contains("Se conserva tu versión") == true
            && isolated.bankStatus["BBVA"]?.errorMessage == nil, "The kept edit is reported, not treated as an error")
        let onlyEdited = await isolated.synchronize(account: isolatedAccount, context: isolatedContext, force: true, onlyBank: "BBVA")
        precondition(onlyEdited && isolatedContext.ledger.count == 2 && isolatedContext.ledger.contains { $0.amount == 999 },
            "A single bank with an edited movement is incorporated without overwriting the user's version")
        print("Banking coordinator passed: independent banks, reopen limits, deferred application, first-download review and transfer recovery.")
    }
}
