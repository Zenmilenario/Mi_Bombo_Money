import Foundation

struct BankingMovementCommit: Sendable {
    static let notification = Notification.Name("BankingMovementCommit.saved")
    let storeURL: URL
    let transactionIDs: Set<UUID>

    static func publish(storeURL: URL?, transactionIDs: Set<UUID>) {
        guard let storeURL, !transactionIDs.isEmpty else { return }
        NotificationCenter.default.post(name: notification,
            object: Self(storeURL: storeURL, transactionIDs: transactionIDs))
    }
}

struct BankingServerStatus: Decodable { let mode: String; let liveBankingEnabled: Bool; let accountingImportEnabled: Bool }
struct BankingAccountFeed {
    let connection: ConnectedBankSession
    let account: ConnectedBankAccount
    let balances: [BankingPreview.Balance]
    let movements: [BankingPreview.Movement]
    var pendingMovements: [BankingPreview.PendingMovement]? = nil
    var ignoredStatuses: [String: Int]? = nil
}

struct BankingAccountActivity: Codable {
    let observedAt: Date
    let currency: String
    let bookedBalance: Int64?
    let availableBalance: Int64?
    let pendingMovements: [BankingPreview.PendingMovement]?
    /// The latest booked postings the bank sent in this query, newest first. A diagnostic for
    /// "did the bank send it?"; kept on the device only. Absent in activity saved by older versions.
    var recentMovements: [RecentMovement]? = nil
    /// How many booked postings the bank sent in this query.
    var receivedCount: Int? = nil
    /// Entries sent with a status the app does not import (cancelled, informative, none…), by status.
    var ignoredStatuses: [String: Int]? = nil

    struct RecentMovement: Codable, Equatable {
        let bookingDate: String
        let signedAmountMinor: Int64
        let currency: String
        let description: String
    }

    /// Sum of the provisional amounts (holds are negative). They are not in the ledger yet.
    var pendingTotal: Int64 { (pendingMovements ?? []).reduce(0) { $0 + $1.signedAmountMinor } }
    /// Only the charges held (negative): pending credits are not money available yet.
    var heldTotal: Int64 { (pendingMovements ?? []).reduce(0) { $0 + min(0, $1.signedAmountMinor) } }

    init(feed: BankingAccountFeed, observedAt: Date) {
        self.observedAt = observedAt
        currency = feed.account.currency
        let balances = feed.balances.filter { $0.currency == feed.account.currency }
        func balance(preferred: String, fallback: String) -> Int64? {
            let preferredRows = balances.filter { $0.type == preferred }
            let rows = preferredRows.isEmpty ? balances.filter { $0.type == fallback } : preferredRows
            let amounts = Set(rows.map(\.amountMinor))
            return amounts.count == 1 ? amounts.first : nil
        }
        recentMovements = feed.movements
            .sorted { $0.bookingDate == $1.bookingDate ? ($0.id ?? "") > ($1.id ?? "") : $0.bookingDate > $1.bookingDate }
            .prefix(8)
            .map { RecentMovement(bookingDate: $0.bookingDate, signedAmountMinor: $0.signedAmountMinor,
                                  currency: $0.currency, description: $0.description) }
        receivedCount = feed.movements.count
        ignoredStatuses = feed.ignoredStatuses
        bookedBalance = balance(preferred: "ITBD", fallback: "CLBD")
        availableBalance = balance(preferred: "ITAV", fallback: "CLAV")
        if let pending = feed.pendingMovements {
            var seenIDs = Set(feed.movements.compactMap(\.id))
            pendingMovements = pending.filter { row in
                row.currency == feed.account.currency && ["HOLD", "PDNG"].contains(row.status)
                    && (row.id.map { seenIDs.insert($0).inserted } ?? true)
            }.sorted { ($0.date ?? "") > ($1.date ?? "") }
        } else {
            pendingMovements = nil
        }
    }
}
/// Last bank activity per linked account, kept on this device only: outside accounting, cloud and backups.
/// Holds stay visible after reopening the app until the next download replaces them.
enum BankingActivityStore {
    static var directoryOverride: URL?
    static let maximumAge: TimeInterval = 7 * 86_400

    private static func url(owner: UUID) -> URL? {
        let base = directoryOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("BankingActivity", isDirectory: true)
        return base?.appendingPathComponent(owner.uuidString.lowercased() + ".json")
    }
    static func load(owner: UUID, now: Date = .now) -> [String: BankingAccountActivity] {
        guard let url = url(owner: owner), let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([String: BankingAccountActivity].self, from: data) else { return [:] }
        return saved.filter { now.timeIntervalSince($0.value.observedAt) < maximumAge }
    }
    static func save(_ activity: [String: BankingAccountActivity], owner: UUID) {
        guard let url = url(owner: owner) else { return }
        guard !activity.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try JSONEncoder().encode(activity).write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try JSONEncoder().encode(activity).write(to: url, options: .atomic)
            #endif
            var destination = url, values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? destination.setResourceValues(values)
        } catch {
            // Losing this cache only hides holds until the next download; accounting is unaffected.
        }
    }
}

struct ConnectedBank: Decodable, Identifiable {
    let name: String
    let country: String
    let beta: Bool
    var id: String { "\(country):\(name)" }
}
struct ConnectedBankAccount: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let currency: String
    let lastFour: String
    let ownershipKey: String?
    let testRole: String?
    init(id: String, name: String, currency: String, lastFour: String, ownershipKey: String? = nil, testRole: String? = nil) {
        self.id = id; self.name = name; self.currency = currency; self.lastFour = lastFour
        self.ownershipKey = ownershipKey; self.testRole = testRole
    }
}
struct ConnectedBankSession: Decodable, Identifiable {
    let id: String
    let bank: String
    let validUntil: String
    let accounts: [ConnectedBankAccount]
    let testScenario: String?
    init(id: String, bank: String, validUntil: String, accounts: [ConnectedBankAccount], testScenario: String? = nil) {
        self.id = id; self.bank = bank; self.validUntil = validUntil; self.accounts = accounts; self.testScenario = testScenario
    }
}
struct BankingAuthorizationStart: Decodable { let id: String; let authorizationURL: URL }
struct BankingPreview: Decodable {
    struct Balance: Decodable { let amountMinor: Int64; let currency: String; let type: String }
    struct Movement: Decodable, Identifiable {
        let id: String?
        let bookingDate: String
        let signedAmountMinor: Int64
        let currency: String
        let description: String
        let counterpartyKey: String?
        let transferKey: String?
        init(id: String?, bookingDate: String, signedAmountMinor: Int64, currency: String, description: String,
             counterpartyKey: String? = nil, transferKey: String? = nil) {
            self.id = id; self.bookingDate = bookingDate; self.signedAmountMinor = signedAmountMinor
            self.currency = currency; self.description = description; self.counterpartyKey = counterpartyKey; self.transferKey = transferKey
        }
    }
    struct PendingMovement: Codable {
        let id: String?
        let date: String?
        let signedAmountMinor: Int64
        let currency: String
        let description: String
        let status: String
    }
    let balances: [Balance]
    let transactions: [Movement]
    let pendingTransactions: [PendingMovement]?
    /// Entries the bank sent with a status the app does not import, counted by status (diagnostic only).
    let ignoredStatuses: [String: Int]?
    let continuation: String?

    init(balances: [Balance], transactions: [Movement], continuation: String?) {
        self.balances = balances
        self.transactions = transactions
        self.continuation = continuation
        pendingTransactions = nil
        ignoredStatuses = nil
    }
}
