import CryptoKit
import Foundation

struct DuplicateCandidate: Identifiable {
    var id: UUID { transaction.id }
    let transaction: FinancialTransaction
    let score: Double
}

enum DuplicateDetectionService {
    static func fingerprint(
        date: Date,
        sourceAccountID: UUID?,
        destinationAccountID: UUID?,
        type: TransactionType,
        amountMinor: Int64,
        description: String
    ) -> String {
        let dateString = ISO8601DateFormatter.dayOnly.string(from: date)
        let normalizedDescription = normalize(description)
        let payload = [
            dateString,
            sourceAccountID?.uuidString ?? "none",
            destinationAccountID?.uuidString ?? "none",
            type.rawValue,
            String(Swift.abs(amountMinor)),
            normalizedDescription,
        ].joined(separator: "|")

        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func candidates(
        date: Date,
        sourceAccountID: UUID?,
        destinationAccountID: UUID?,
        type: TransactionType,
        amountMinor: Int64,
        description: String,
        existing: [FinancialTransaction],
        excluding transactionID: UUID? = nil
    ) -> [DuplicateCandidate] {
        let normalizedDescription = normalize(description)
        let targetAmount = Swift.abs(amountMinor)
        let targetFingerprint = fingerprint(
            date: date,
            sourceAccountID: sourceAccountID,
            destinationAccountID: destinationAccountID,
            type: type,
            amountMinor: targetAmount,
            description: description
        )

        return existing.compactMap { transaction in
            guard transaction.id != transactionID else { return nil }
            guard transaction.sourceAccount?.id == sourceAccountID else { return nil }
            guard transaction.destinationAccount?.id == destinationAccountID else { return nil }
            guard Swift.abs(transaction.amountMinor) == targetAmount else { return nil }

            if !transaction.fingerprint.isEmpty && transaction.fingerprint == targetFingerprint {
                return DuplicateCandidate(transaction: transaction, score: 1)
            }

            let days = Swift.abs(Calendar.autoupdatingCurrent.dateComponents(
                [.day],
                from: Calendar.autoupdatingCurrent.startOfDay(for: transaction.date),
                to: Calendar.autoupdatingCurrent.startOfDay(for: date)
            ).day ?? 99)
            guard days <= 1 else { return nil }

            let textScore = similarity(normalizedDescription, normalize(transaction.descriptionText))
            let typeScore = transaction.type == type ? 0.15 : 0
            let dateScore = days == 0 ? 0.25 : 0.12
            let score = Swift.min(1, 0.45 + typeScore + dateScore + (0.4 * textScore))
            return score >= 0.72 ? DuplicateCandidate(transaction: transaction, score: score) : nil
        }
        .sorted { $0.score > $1.score }
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .filter { $0.count > 1 }
            .joined(separator: " ")
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs, !lhs.isEmpty { return 1 }
        let left = Set(lhs.split(separator: " ").map(String.init))
        let right = Set(rhs.split(separator: " ").map(String.init))
        guard !left.isEmpty || !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }
}

private extension ISO8601DateFormatter {
    static let dayOnly: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}
