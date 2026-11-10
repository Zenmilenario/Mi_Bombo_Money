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

/// A card payment captured at the till: by the Shortcuts «Transacción» automation after paying with
/// Apple Pay, or dictated to Siri. It waits on this device until the app files it as an expense.
struct CardPayment: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let amountMinor: Int64
    let merchant: String
    let card: String
}

/// Payments captured outside the app, kept on this device until they are filed. Once filed, the expense
/// carries `marker` in its external id until the bank sends the same posting and the import pairs them.
enum CardPaymentInbox {
    static let marker = "applepay:"
    /// How long after the payment the bank posting may still be that payment.
    static let matchWindow: TimeInterval = 7 * 86_400
    /// After this many days without the bank posting, Don Bigotes points the payment out.
    static let overdueAfter: TimeInterval = 5 * 86_400
    static let defaultAccountKey = "cardPaymentDefaultAccount"
    static let cardAccountsKey = "cardPaymentAccountsV1"
    static let seenCardsKey = "cardPaymentSeenCardsV1"
    static var directoryOverride: URL?

    /// Posted when the action adds a payment, so an open app files it at once.
    static let didChange = Notification.Name("CardPaymentInboxDidChange")

    static func isAwaiting(_ externalID: String?) -> Bool { externalID?.hasPrefix(marker) == true }

    /// Card names seen in payments, so each one can be assigned an account in Ajustes.
    static func seenCards(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: seenCardsKey) ?? []
    }
    static func rememberCard(_ card: String, defaults: UserDefaults = .standard) {
        let name = card.trimmingCharacters(in: .whitespacesAndNewlines)
        var cards = seenCards(defaults)
        guard !name.isEmpty, !cards.contains(where: { normalizedCard($0) == normalizedCard(name) }) else { return }
        cards.append(name)
        defaults.set(Array(cards.suffix(12)), forKey: seenCardsKey)
    }
    static func externalID(for payment: CardPayment) -> String { marker + payment.id.uuidString.lowercased() }

    /// Reads what Shortcuts passes as the amount ("4,50 €", "€4.50", "1.234,56"). Only positive amounts.
    static func amount(from raw: String) -> Int64? {
        var text = raw.filter { ("0"..."9").contains($0) || $0 == "," || $0 == "." }
        guard text.contains(where: { ("0"..."9").contains($0) }) else { return nil }
        let comma = text.lastIndex(of: ","), dot = text.lastIndex(of: ".")
        if let comma, let dot {
            // Both separators: the later one marks the decimals, the other groups thousands.
            let decimal: Character = comma > dot ? "," : "."
            text = String(text.compactMap { character -> Character? in
                character == decimal ? "." : (character == "," || character == "." ? nil : character)
            })
        } else if let separator = comma ?? dot {
            // One kind of separator: decimal when at most two digits follow its last use, grouping otherwise.
            let symbol = text[separator]
            let isDecimal = text.distance(from: separator, to: text.endIndex) - 1 <= 2 && text.filter({ $0 == symbol }).count == 1
            text = String(text.compactMap { character -> Character? in
                guard character == symbol else { return character }
                return isDecimal ? "." : nil
            })
        }
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        var cents = value * 100, rounded = Decimal()
        NSDecimalRound(&rounded, &cents, 0, .plain)
        let minor = NSDecimalNumber(decimal: rounded).int64Value
        return minor > 0 ? minor : nil
    }

    static func normalizedCard(_ card: String) -> String {
        card.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The account a card belongs to: the one chosen for that card, otherwise the default one.
    static func account(for card: String, rules: [String: UUID], fallback: UUID?) -> UUID? {
        rules[normalizedCard(card)] ?? fallback
    }

    static func decodeRules(_ stored: String) -> [String: UUID] {
        guard let raw = try? JSONDecoder().decode([String: String].self, from: Data(stored.utf8)) else { return [:] }
        return raw.compactMapValues(UUID.init(uuidString:))
    }
    static func encodeRules(_ rules: [String: UUID]) -> String {
        (try? String(decoding: JSONEncoder().encode(rules.mapValues(\.uuidString)), as: UTF8.self)) ?? ""
    }

    /// Bank holds not already counted as a payment recorded with Apple Pay. Each recorded payment covers at
    /// most one hold of the same amount from the payment day up to `matchWindow` later; undated holds match
    /// by amount alone.
    static func uncoveredHolds(_ holds: [BankingPreview.PendingMovement],
                               awaiting: [(amountMinor: Int64, date: Date)]) -> [BankingPreview.PendingMovement] {
        var open = awaiting
        return holds.filter { hold in
            guard hold.signedAmountMinor < 0 else { return true }
            let day = hold.date.flatMap(dayFormatter.date(from:))
            guard let index = open.firstIndex(where: { payment in
                guard payment.amountMinor == -hold.signedAmountMinor else { return false }
                guard let day else { return true }
                let delay = day.timeIntervalSince(payment.date)
                return delay >= -86_400 && delay <= matchWindow
            }) else { return true }
            open.remove(at: index)
            return false
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static var url: URL? {
        let base = directoryOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("CardPayments", isDirectory: true)
        return base?.appendingPathComponent("inbox.json")
    }

    static func load() -> [CardPayment] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CardPayment].self, from: data)) ?? []
    }

    static func save(_ payments: [CardPayment]) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        guard !payments.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Readable after the first unlock: the automation may run right after paying, before the app opens.
        #if os(iOS)
        try JSONEncoder().encode(payments).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(payments).write(to: url, options: .atomic)
        #endif
        var destination = url, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? destination.setResourceValues(values)
    }

    static func add(_ payment: CardPayment) throws {
        var payments = load()
        guard !payments.contains(where: { $0.id == payment.id }) else { return }
        payments.append(payment)
        try save(payments)
    }

    static func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        try? save(load().filter { !ids.contains($0.id) })
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
