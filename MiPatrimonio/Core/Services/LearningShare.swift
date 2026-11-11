import CryptoKit
import Foundation

/// What the person taught the models, shared by their devices (CloudBackend/learning-contract.md, version 1).
/// The Android app writes and combines exactly the same document (Tests/Fixtures/shared_learning_cases.json).
struct SharedLearning: Codable, Equatable, Sendable {
    struct Toggle: Codable, Equatable, Sendable { var enabled: Bool; var at: Int64 }
    struct CategoryEntry: Codable, Equatable, Sendable { var signature: String?; var at: Int64 }
    struct OperationEntry: Codable, Equatable, Sendable { var signature: String?; var kind: String?; var at: Int64 }
    struct TermsEntry: Codable, Equatable, Sendable {
        var account: String
        var savebackPercent: Double
        var roundUpMultiplier: Int
        var validFrom: Int64
        var at: Int64
    }
    struct Input: Codable, Equatable, Sendable {
        var text: String
        var amountMinor: Int64
        var isCredit: Bool
        var day: Int
        var weekday: Int
        var month: String
        var accountKey: String
        var savebackPercent: Double?
        var roundUpMultiplier: Int?
    }
    struct Action: Codable, Equatable, Sendable { var type: String; var destinationID: String?; var categoryID: String? }
    struct Example: Codable, Equatable, Sendable { var input: Input; var action: Action }
    struct Prior: Codable, Equatable, Sendable { var example: Example; var signature: String }
    struct CorrectionEntry: Codable, Equatable, Sendable { var example: Example?; var signature: String?; var prior: Prior?; var at: Int64 }
    struct AutomaticEntry: Codable, Equatable, Sendable {
        var before: Action?
        var after: Action?
        var signature: String?
        var fingerprint: String?
        var validated: Int?
        var at: Int64
    }

    var version = 1
    var since: Int64?
    var enabledAt: Int64?
    var automation: Toggle?
    var categories: [String: CategoryEntry] = [:]
    var operations: [String: OperationEntry] = [:]
    var terms: [String: TermsEntry] = [:]
    var corrections: [String: CorrectionEntry] = [:]
    var reviewed: [String: Int64] = [:]
    var automatic: [String: AutomaticEntry] = [:]

    init() { }

    private enum CodingKeys: String, CodingKey {
        case version, since, enabledAt, automation, categories, operations, terms, corrections, reviewed, automatic
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        since = try values.decodeIfPresent(Int64.self, forKey: .since)
        enabledAt = try values.decodeIfPresent(Int64.self, forKey: .enabledAt)
        automation = try values.decodeIfPresent(Toggle.self, forKey: .automation)
        categories = try values.decodeIfPresent([String: CategoryEntry].self, forKey: .categories) ?? [:]
        operations = try values.decodeIfPresent([String: OperationEntry].self, forKey: .operations) ?? [:]
        terms = try values.decodeIfPresent([String: TermsEntry].self, forKey: .terms) ?? [:]
        corrections = try values.decodeIfPresent([String: CorrectionEntry].self, forKey: .corrections) ?? [:]
        reviewed = try values.decodeIfPresent([String: Int64].self, forKey: .reviewed) ?? [:]
        automatic = try values.decodeIfPresent([String: AutomaticEntry].self, forKey: .automatic) ?? [:]
    }
}

/// Canonical identifiers and signatures, identical on both apps.
enum LearningCanonical {
    static func id(_ value: UUID) -> String { value.uuidString.lowercased() }
    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    static func hex(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func categorySignature(type: String, categoryID: UUID, description: String) -> String {
        hex([type, id(categoryID), description].joined(separator: "|"))
    }

    static func identity(id transaction: UUID, type: String, amountMinor: Int64, date: Date, description: String,
                         sourceID: UUID?, destinationID: UUID?, sourceCurrency: String?, destinationCurrency: String?,
                         bankEntryKey: String?) -> String {
        hex([id(transaction), type, String(amountMinor), String(ms(date)), description,
             sourceID.map(id) ?? "", destinationID.map(id) ?? "", sourceCurrency ?? "", destinationCurrency ?? "",
             bankEntryKey ?? ""].joined(separator: "|"))
    }

    static func accountKey(accountID: UUID, currency: String) -> String { hex(id(accountID) + "|" + currency) }
}

enum LearningShare {
    /// Per entry the newest change wins (the cloud's on a tie); reviews are joined; the earliest dates are kept.
    static func merge(_ local: SharedLearning, _ remote: SharedLearning) -> SharedLearning {
        func newest<T>(_ left: [String: T], _ right: [String: T], _ at: (T) -> Int64) -> [String: T] {
            var result = left
            for (key, value) in right {
                if let mine = result[key], at(mine) > at(value) { continue }
                result[key] = value
            }
            return result
        }
        func earliest(_ a: Int64?, _ b: Int64?) -> Int64? { [a, b].compactMap { $0 }.min() }
        var result = SharedLearning()
        result.since = earliest(local.since, remote.since)
        result.enabledAt = earliest(local.enabledAt, remote.enabledAt)
        if let theirs = remote.automation, theirs.at >= (local.automation?.at ?? Int64.min) { result.automation = theirs }
        else { result.automation = local.automation ?? remote.automation }
        result.categories = newest(local.categories, remote.categories, \.at)
        result.operations = newest(local.operations, remote.operations, \.at)
        result.terms = newest(local.terms, remote.terms, \.at)
        result.corrections = newest(local.corrections, remote.corrections, \.at)
        result.automatic = newest(local.automatic, remote.automatic, \.at)
        result.reviewed = local.reviewed.merging(remote.reviewed) { min($0, $1) }
        return result
    }

    /// Dates the iPhone's export against the last combined copy (`base`): what did not change keeps its date,
    /// what is new or different gets `now`, and an entry this device could represent (`representable`) and no
    /// longer exports becomes a removal. Entries it cannot represent are kept unchanged.
    static func stamp(_ exported: SharedLearning, base: SharedLearning, now: Int64,
                      representable: (_ section: String, _ key: String) -> Bool) -> SharedLearning {
        func dated<T: Equatable>(_ section: String, _ mine: [String: T], _ previous: [String: T],
                                 at: (T) -> Int64, setAt: (T, Int64) -> T, live: (T) -> Bool, removal: ((Int64) -> T)?) -> [String: T] {
            var result: [String: T] = [:]
            for key in Set(mine.keys).union(previous.keys) {
                let before = previous[key]
                if let value = mine[key] {
                    if let before, setAt(before, 0) == setAt(value, 0) { result[key] = before }
                    else { result[key] = setAt(value, now) }
                } else if let before {
                    if let removal, live(before), representable(section, key) { result[key] = removal(now) }
                    else { result[key] = before }
                }
            }
            return result
        }
        var result = SharedLearning()
        result.since = [exported.since, base.since].compactMap { $0 }.min()
        result.enabledAt = [exported.enabledAt, base.enabledAt].compactMap { $0 }.min()
        if let enabled = exported.automation?.enabled {
            if let previous = base.automation { result.automation = previous.enabled == enabled ? previous : .init(enabled: enabled, at: now) }
            else { result.automation = .init(enabled: enabled, at: enabled ? 0 : now) }
        } else { result.automation = base.automation }
        result.categories = dated("categories", exported.categories, base.categories, at: \.at,
            setAt: { var v = $0; v.at = $1; return v }, live: { $0.signature != nil },
            removal: { .init(signature: nil, at: $0) })
        result.operations = dated("operations", exported.operations, base.operations, at: \.at,
            setAt: { var v = $0; v.at = $1; return v }, live: { $0.signature != nil },
            removal: { .init(signature: nil, kind: nil, at: $0) })
        result.terms = dated("terms", exported.terms, base.terms, at: \.at,
            setAt: { var v = $0; v.at = $1; return v }, live: { _ in true }, removal: nil)
        result.corrections = dated("corrections", exported.corrections, base.corrections, at: \.at,
            setAt: { var v = $0; v.at = $1; return v }, live: { $0.example != nil },
            removal: { .init(example: nil, signature: nil, prior: nil, at: $0) })
        result.automatic = dated("automatic", exported.automatic, base.automatic, at: \.at,
            setAt: { var v = $0; v.at = $1; return v }, live: { $0.after != nil },
            removal: { .init(before: nil, after: nil, signature: nil, fingerprint: nil, validated: nil, at: $0) })
        result.reviewed = exported.reviewed.merging(base.reviewed) { min($0, $1) }
        return result
    }
}
