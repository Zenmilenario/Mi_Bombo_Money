import Foundation
import SwiftData

enum CategoryRuleService {
    enum ClassificationError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): message }
        }
    }

    static func classificationError(transactions: [FinancialTransaction], category: FinanceCategory,
                                    remembering phrase: String? = nil) -> String? {
        guard !transactions.isEmpty else { return "Selecciona al menos un movimiento." }
        guard Set(transactions.map(\.id)).count == transactions.count else {
            return "La selección contiene movimientos repetidos. Vuelve a seleccionarlos."
        }
        guard transactions.allSatisfy({ supports(category, for: $0.type) }) else {
            return "Elige una categoría compatible con todos los movimientos seleccionados."
        }
        if let phrase {
            let normalizedPhrase = normalized(phrase)
            guard normalizedPhrase.count >= 3 else { return "Escribe una frase de al menos tres caracteres para recordarla." }
            guard transactions.allSatisfy({ normalized($0.descriptionText).contains(normalizedPhrase) }) else {
                return "La frase debe aparecer en todos los conceptos seleccionados. Puedes categorizar juntos sin guardar una regla."
            }
        }
        return nil
    }

    @MainActor
    static func classify(transactions: [FinancialTransaction], category: FinanceCategory,
                         remembering phrase: String? = nil, existingRules: [CategoryRule],
                         in context: ModelContext) throws {
        if let error = classificationError(transactions: transactions, category: category, remembering: phrase) {
            throw ClassificationError.invalid(error)
        }
        // Flush unrelated edits first, then commit the category and optional rules together.
        try context.save()
        for transaction in transactions {
            transaction.category = category
            transaction.updatedAt = .now
        }
        if let phrase {
            for type in Set(transactions.map { $0.type.rawValue }).sorted().compactMap(TransactionType.init(rawValue:)) {
                remember(phrase: phrase, type: type, category: category, existing: existingRules, in: context)
            }
        }
        do { try context.save() }
        catch { context.rollback(); throw error }
    }

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
