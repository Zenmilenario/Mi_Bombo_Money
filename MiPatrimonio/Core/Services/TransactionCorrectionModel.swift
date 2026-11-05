import Foundation

/// Supervised nearest-neighbour classification of complete user corrections.
/// There are no merchant rules or personal amounts. Only explicit human decisions are examples.
struct TransactionCorrectionModel: Sendable {
    struct Action: Codable, Hashable, Sendable {
        let type: String
        let destinationID: UUID?
        let categoryID: UUID?
    }
    struct Example: Codable, Equatable, Sendable {
        let input: TransactionOperationModel.Input
        let action: Action
    }
    struct Decision: Sendable {
        let action: Action
        let confirmedExamples: Int
        let validatedPredictions: Int
    }
    private let examples: [Example]
    private struct ValidationKey: Hashable, Sendable {
        let account: String
        let isCredit: Bool
        let action: Action
    }
    private let validated: [ValidationKey: Int]

    private static func month(_ value: String) -> Int? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]) else { return nil }
        return parts[0] * 12 + parts[1]
    }
    static func train(_ input: [Example]) -> Self? {
        let valid = input.filter { $0.input.valid && month($0.input.month) != nil }
        let groups = Dictionary(grouping: valid, by: \.input)
        let rows = groups.values.flatMap { values in
            // Keep contradictory labels as competing evidence, rather than hiding ambiguity.
            Dictionary(grouping: values, by: \.action).values.compactMap(\.first)
        }.sorted {
            let left = $0.input, right = $1.input
            return "\(left.accountKey)|\(left.month)|\(left.day)|\(left.amountMinor)|\(left.text)"
                < "\(right.accountKey)|\(right.month)|\(right.day)|\(right.amountMinor)|\(right.text)"
        }
        guard rows.count >= 9 else { return nil }
        var successes: [ValidationKey: Int] = [:]
        var failures: Set<ValidationKey> = []
        // Rolling temporal evaluation: each label is predicted using strictly earlier months.
        // Same-day duplicates and screenshots of the same event cannot inflate support.
        for row in rows {
            if Task.isCancelled { return nil }
            let earlier = rows.filter { (month($0.input.month) ?? 0) < (month(row.input.month) ?? 0) }
            guard let prediction = vote(row.input, examples: earlier) else { continue }
            let key = ValidationKey(account: row.input.accountKey, isCredit: row.input.isCredit, action: prediction)
            if prediction == row.action { successes[key, default: 0] += 1 }
            else { failures.insert(key) }
        }
        return Self(examples: rows, validated: successes.filter { !failures.contains($0.key) })
    }

    func automaticDecision(_ input: TransactionOperationModel.Input) -> Decision? {
        guard input.valid, let inputMonth = Self.month(input.month),
              let action = Self.vote(input, examples: examples) else { return nil }
        let key = ValidationKey(account: input.accountKey, isCredit: input.isCredit, action: action)
        guard validated[key, default: 0] >= 3 else { return nil }
        let related = examples.filter { $0.input.accountKey == input.accountKey && $0.input.isCredit == input.isCredit }
        guard let newest = related.compactMap({ Self.month($0.input.month) }).max(), inputMonth >= newest else { return nil }
        let supporting = related.filter { $0.action == action }
        guard supporting.count >= 6, related.filter({ $0.action != action }).count >= 3,
              Set(supporting.compactMap { Self.month($0.input.month) }).count >= 2 else { return nil }
        return Decision(action: action, confirmedExamples: supporting.count, validatedPredictions: validated[key, default: 0])
    }

    private static func vote(_ input: TransactionOperationModel.Input, examples: [Example]) -> Action? {
        let peers = examples.filter { $0.input.accountKey == input.accountKey && $0.input.isCredit == input.isCredit && $0.input != input }
        guard peers.count >= 6 else { return nil }
        let ranked = peers.map { ($0, distance(input, $0.input)) }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.input.month < $1.0.input.month
        }
        let nearest = Array(ranked.prefix(3))
        guard let action = nearest.first?.0.action, nearest.allSatisfy({ $0.0.action == action }),
              let worst = nearest.last?.1, worst <= 0.18,
              let competing = ranked.first(where: { $0.0.action != action }), competing.1 >= worst + 0.08 else { return nil }
        return action
    }

    private static func distance(_ left: TransactionOperationModel.Input, _ right: TransactionOperationModel.Input) -> Double {
        let amount = min(1, abs(log1p(Double(left.amountMinor) / 100) - log1p(Double(right.amountMinor) / 100)) / 4)
        let difference = abs(left.day - right.day)
        let day = Double(min(difference, 31 - difference)) / 15.5
        let weekday = left.weekday == right.weekday ? 0.0 : 1.0
        if !left.hasDescription && !right.hasDescription { return amount * 0.65 + day * 0.25 + weekday * 0.1 }
        guard left.hasDescription == right.hasDescription else { return 1 }
        let a = Set(left.words), b = Set(right.words)
        let union = a.union(b).count
        let text = union == 0 ? 1 : 1 - Double(a.intersection(b).count) / Double(union)
        return text * 0.7 + amount * 0.15 + day * 0.1 + weekday * 0.05
    }
}
