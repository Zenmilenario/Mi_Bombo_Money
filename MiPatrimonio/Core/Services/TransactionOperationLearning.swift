import CryptoKit
import Foundation
import SwiftData

/// Confirmations belong to a financial profile, never to a global model.
@MainActor
enum TransactionOperationLearning {
    static let didChange = Notification.Name("TransactionOperationLearning.didChange")
    enum LearningError: Error { case unavailable }
    private struct Record: Codable {
        let signature: String
        let kind: TransactionOperationKind
    }
    private struct History: Codable {
        var records: [UUID: Record] = [:]
        var terms: [UUID: [TransactionOperationModel.CardTerms]] = [:]
        init() { }
        private enum CodingKeys: String, CodingKey { case records, terms }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            records = try values.decodeIfPresent([UUID: Record].self, forKey: .records) ?? [:]
            terms = try values.decodeIfPresent([UUID: [TransactionOperationModel.CardTerms]].self, forKey: .terms) ?? [:]
        }
    }
    struct Review {
        let confirmed: TransactionOperationKind?
        let prediction: TransactionOperationModel.Prediction?
    }
    private struct Training: Equatable, Sendable {
        let location: URL
        let examples: [TransactionOperationModel.Example]
    }
    private static var training: Training?
    private static var job: Task<TransactionOperationModel?, Never>?

    private static func location(in context: ModelContext) -> URL? {
        guard let configuration = context.container.configurations.first,
              ["LocalFinance", "CloudFinance"].contains(configuration.name) else { return nil }
        return configuration.url.appendingPathExtension("operation-learning-v1.json")
    }
    private static func read(_ url: URL) throws -> History {
        guard FileManager.default.fileExists(atPath: url.path) else { return History() }
        return try JSONDecoder().decode(History.self, from: Data(contentsOf: url))
    }
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func input(_ transaction: FinancialTransaction, terms: TransactionOperationModel.CardTerms? = nil) -> TransactionOperationModel.Input? {
        guard let account = transaction.sourceAccount, transaction.bankEntryKey != nil,
              !account.isArchived, account.type != .investment, !account.type.isLiability,
              transaction.duplicateState != .possible,
              [.expense, .income, .transfer].contains(transaction.type) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        // Provider booking dates are parsed as UTC; travel must not change the training label.
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: transaction.date)
        return .init(text: transaction.descriptionText, amountMinor: transaction.amountMinor,
                     isCredit: transaction.type.countsAsIncome, day: components.day ?? 0,
                     weekday: components.weekday ?? 0,
                     month: "\(components.year ?? 0)-\(components.month ?? 0)",
                     accountKey: hash(account.id.uuidString + "|" + account.currencyCode),
                     savebackPercent: terms?.savebackPercent, roundUpMultiplier: terms?.roundUpMultiplier)
    }
    private static func signature(_ transaction: FinancialTransaction) -> String {
        hash([transaction.id.uuidString, transaction.typeRaw, String(transaction.amountMinor),
              String(transaction.date.timeIntervalSince1970), transaction.descriptionText,
              transaction.sourceAccount?.id.uuidString ?? "", transaction.destinationAccount?.id.uuidString ?? "",
              transaction.sourceAccount?.currencyCode ?? "", transaction.destinationAccount?.currencyCode ?? "",
              transaction.bankEntryKey ?? ""].joined(separator: "|"))
    }
    static func supports(_ transaction: FinancialTransaction) -> Bool { input(transaction)?.valid == true }

    static func specializedIDs(in transactions: [FinancialTransaction], context: ModelContext) throws -> Set<UUID> {
        guard let location = location(in: context) else { return [] }
        let history = try read(location)
        return Set(transactions.compactMap { row in
            guard row.modelContext === context, supports(row), let record = history.records[row.id],
                  record.kind != .ordinary, record.signature == signature(row) else { return nil }
            return row.id
        })
    }

    private static func applicableTerms(_ history: History, transaction: FinancialTransaction) -> TransactionOperationModel.CardTerms? {
        guard let accountID = transaction.sourceAccount?.id else { return nil }
        return history.terms[accountID, default: []].filter { $0.valid && $0.validFrom <= transaction.date }
            .max { $0.validFrom < $1.validFrom }
    }
    static func terms(for transaction: FinancialTransaction, in context: ModelContext) throws -> TransactionOperationModel.CardTerms? {
        guard transaction.modelContext === context, let location = location(in: context) else { return nil }
        return applicableTerms(try read(location), transaction: transaction)
    }
    static func saveTerms(_ terms: TransactionOperationModel.CardTerms, transaction: FinancialTransaction, in context: ModelContext) throws {
        guard terms.valid, !context.hasChanges, transaction.modelContext === context,
              supports(transaction), let accountID = transaction.sourceAccount?.id,
              let location = location(in: context) else { throw LearningError.unavailable }
        var history = try read(location)
        history.terms[accountID, default: []].removeAll { $0.validFrom == terms.validFrom }
        history.terms[accountID, default: []].append(terms)
        try write(history, at: location)
    }

    static func review(_ transaction: FinancialTransaction, in context: ModelContext) async throws -> Review {
        guard transaction.modelContext === context, let location = location(in: context) else {
            return Review(confirmed: nil, prediction: nil)
        }
        let history = try read(location)
        guard let current = input(transaction, terms: applicableTerms(history, transaction: transaction)) else {
            return Review(confirmed: nil, prediction: nil)
        }
        if let record = history.records[transaction.id], record.signature == signature(transaction) {
            return Review(confirmed: record.kind, prediction: nil)
        }
        let transactions = try context.fetch(FetchDescriptor<FinancialTransaction>())
        let examples = transactions.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { row -> TransactionOperationModel.Example? in
            guard let record = history.records[row.id], record.signature == signature(row),
                  let value = input(row, terms: applicableTerms(history, transaction: row)) else { return nil }
            return .init(input: value, kind: record.kind, confirmed: true)
        }
        let next = Training(location: location, examples: Array(examples.prefix(700)))
        if training != next || job == nil {
            job?.cancel()
            training = next
            job = Task.detached(priority: .utility) { TransactionOperationModel.train(next.examples) }
        }
        let revision = signature(transaction)
        let model = await job?.value
        guard !Task.isCancelled, training == next, signature(transaction) == revision else {
            return Review(confirmed: nil, prediction: nil)
        }
        return Review(confirmed: nil, prediction: model?.predict(current))
    }

    /// Only an explicit decision becomes a label. No ledger mutation or bank call occurs here.
    static func confirm(_ kind: TransactionOperationKind?, transaction: FinancialTransaction,
                        in context: ModelContext) throws {
        guard !context.hasChanges, transaction.modelContext === context, let location = location(in: context) else {
            throw LearningError.unavailable
        }
        var history = try read(location)
        guard let value = input(transaction, terms: applicableTerms(history, transaction: transaction)), value.valid else {
            throw LearningError.unavailable
        }
        if let kind {
            history.records[transaction.id] = Record(signature: signature(transaction), kind: kind)
        } else { history.records.removeValue(forKey: transaction.id) }
        try write(history, at: location)
    }

    private static func write(_ history: History, at location: URL) throws {
        let data = try JSONEncoder().encode(history)
        try data.write(to: location, options: [.atomic, .completeFileProtection])
        var destination = location, attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try destination.setResourceValues(attributes)
        training = nil
        job?.cancel()
        job = nil
        NotificationCenter.default.post(name: didChange, object: location)
    }
}
