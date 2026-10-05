import Foundation
import SwiftData

enum CategoryRuleService {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func supports(_ category: FinanceCategory, for type: TransactionType) -> Bool {
        guard !category.isArchived else { return false }
        switch type {
        case .income, .interest: return category.kind == .income || category.kind == .both
        case .expense, .fee: return category.kind == .expense || category.kind == .both
        case .transfer: return category.kind == .transfer
        }
    }

    static func match(
        description: String,
        type: TransactionType,
        rules: [CategoryRule]
    ) -> CategoryRule? {
        let text = normalized(description)
        guard !text.isEmpty else { return nil }
        return rules
            .filter { rule in
                let phrase = normalized(rule.phrase)
                guard rule.isActive,
                      rule.transactionType == type,
                      phrase.count >= 3,
                      text.contains(phrase),
                      let category = rule.category else { return false }
                return supports(category, for: type)
            }
            .sorted {
                let leftLength = normalized($0.phrase).count
                let rightLength = normalized($1.phrase).count
                return leftLength == rightLength ? $0.updatedAt > $1.updatedAt : leftLength > rightLength
            }
            .first
    }

    static func remember(
        phrase: String,
        type: TransactionType,
        category: FinanceCategory,
        existing: [CategoryRule],
        in context: ModelContext
    ) {
        let cleanPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized(cleanPhrase).count >= 3 else { return }
        if let rule = existing.first(where: {
            $0.transactionType == type && normalized($0.phrase) == normalized(cleanPhrase)
        }) {
            rule.category = category
            rule.isActive = true
            rule.updatedAt = .now
        } else {
            context.insert(CategoryRule(phrase: cleanPhrase, transactionType: type, category: category))
        }
    }
}
