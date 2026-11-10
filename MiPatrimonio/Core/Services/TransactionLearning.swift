import CryptoKit
import Foundation
import SwiftData

@MainActor
enum TransactionLearning {
    private struct History: Codable {
        var since: Date = .now
        var confirmations: [UUID: String] = [:]
    }

    private struct Training: Equatable, Sendable {
        let scope: URL
        let expenses: [TransactionCategoryModel.Example]
        let income: [TransactionCategoryModel.Example]
    }

    struct Models: Sendable {
        let expenses: TransactionCategoryModel?
        let income: TransactionCategoryModel?
    }

    private static var training: Training?
    private static var job: Task<Models, Never>?

    private static func location(in context: ModelContext) -> URL? {
        guard let config = context.container.configurations.first,
              config.name == "LocalFinance" || config.name == "CloudFinance" else { return nil }
        return config.url.appendingPathExtension("category-learning-v1.json")
    }

    private static func save(_ history: History, at url: URL) throws {
        let data = try JSONEncoder().encode(history)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        var destination = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? destination.setResourceValues(values)
    }

    private static func history(at url: URL) throws -> History {
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(History.self, from: Data(contentsOf: url))
        }
        let history = History()
        try save(history, at: url)
        return history
    }

    private static func signature(_ transaction: FinancialTransaction, category: FinanceCategory) -> String {
        let value = [transaction.type.rawValue, category.id.uuidString, transaction.descriptionText].joined(separator: "|")
        return StableDigest.hex(value)
    }

    /// Record only after the financial save has succeeded.
    static func confirm(_ transactions: [FinancialTransaction], in context: ModelContext, recordCorrection: Bool = true) {
        if recordCorrection { try? TransactionOperationLearning.rememberCategoryReviews(transactions, in: context) }
        guard !transactions.isEmpty, let url = location(in: context),
              var history = try? history(at: url) else { return }
        for transaction in transactions {
            guard transaction.type != .transfer, let category = transaction.category,
                  CategoryRuleService.supports(category, for: transaction.type) else {
                history.confirmations.removeValue(forKey: transaction.id)
                continue
            }
            history.confirmations[transaction.id] = signature(transaction, category: category)
        }
        if (try? save(history, at: url)) != nil {
            Task { _ = await models(in: context) }
        }
    }

    static func models(in context: ModelContext) async -> Models? {
        guard let url = location(in: context), let history = try? history(at: url),
              let categories = try? context.fetch(FetchDescriptor<FinanceCategory>()),
              let transactions = try? context.fetch(FetchDescriptor<FinancialTransaction>()),
              let specialized = try? TransactionOperationLearning.specializedIDs(in: transactions, context: context),
              let rules = try? context.fetch(FetchDescriptor<CategoryRule>()) else { return nil }
        let categoryTransactions = transactions.filter { !specialized.contains($0.id) }
        let input = Training(scope: url,
            expenses: examples(for: .expense, categories: categories, transactions: categoryTransactions, rules: rules, history: history),
            income: examples(for: .income, categories: categories, transactions: categoryTransactions, rules: rules, history: history))
        if training == input, let job {
            let result = await job.value
            return training == input ? result : nil
        }
        job?.cancel()
        let next = Task.detached(priority: .utility) {
            Models(expenses: TransactionCategoryModel.train(input.expenses),
                   income: TransactionCategoryModel.train(input.income))
        }
        training = input
        job = next
        let result = await next.value
        return training == input ? result : nil
    }

    static func suggest(_ text: String, type: TransactionType, categories: [FinanceCategory],
                        in context: ModelContext) async -> UUID? {
        guard type != .transfer, TransactionCategoryModel.tokens(text).count > 0,
              let models = await models(in: context), !Task.isCancelled else { return nil }
        let model = type.countsAsIncome ? models.income : models.expenses
        let allowed = Set(categories.filter { CategoryRuleService.supports($0, for: type) }.map(\.id))
        return model?.predict(text, allowed: allowed)?.categoryID
    }

    private static func examples(for type: TransactionType, categories: [FinanceCategory],
                                 transactions: [FinancialTransaction], rules: [CategoryRule],
                                 history: History) -> [TransactionCategoryModel.Example] {
        let active = categories.filter { CategoryRuleService.supports($0, for: type) }
        let grouped = Dictionary(grouping: active) { CategoryRuleService.normalized($0.name) }
        var examples = TransactionCategoryModel.syntheticExamples.flatMap { entry -> [TransactionCategoryModel.Example] in
            let (name, texts) = entry
            guard let matches = grouped[CategoryRuleService.normalized(name)],
                  matches.count == 1, let category = matches.first else { return [] }
            return texts.map { .init(text: $0, categoryID: category.id, weight: 1) }
        }
        let ordered = transactions.sorted { left, right in
            let leftConfirmed = history.confirmations[left.id] != nil
            let rightConfirmed = history.confirmations[right.id] != nil
            if leftConfirmed != rightConfirmed { return leftConfirmed }
            if left.date != right.date { return left.date > right.date }
            return left.id.uuidString < right.id.uuidString
        }
        var seen: [UUID: Set<String>] = [:]
        var historicalCount: [UUID: Int] = [:]
        for transaction in ordered {
            if examples.count >= 700 { break }
            guard transaction.type != .transfer, transaction.type.countsAsIncome == type.countsAsIncome,
                  transaction.duplicateState != .possible, let category = transaction.category,
                  CategoryRuleService.supports(category, for: type),
                  CategoryRuleService.supports(category, for: transaction.type) else { continue }
            let saved = history.confirmations[transaction.id]
            let confirmed = saved.map { $0 == signature(transaction, category: category) } ?? false
            if !confirmed {
                let name = CategoryRuleService.normalized(category.name)
                guard saved == nil, transaction.updatedAt < history.since,
                      transaction.recurringMovementID == nil, name != "otros gastos", name != "otros ingresos",
                      historicalCount[category.id, default: 0] < 35,
                      CategoryRuleService.match(description: transaction.descriptionText,
                        type: transaction.type, rules: rules) == nil else { continue }
            }
            let text = transaction.displayDescription
            let tokens = TransactionCategoryModel.tokens(text)
            guard !tokens.isEmpty, seen[category.id, default: []].insert(tokens.joined(separator: " ")).inserted else { continue }
            examples.append(.init(text: text, categoryID: category.id, weight: confirmed ? 5 : 0.55))
            if !confirmed { historicalCount[category.id, default: 0] += 1 }
        }
        return examples
    }
}
