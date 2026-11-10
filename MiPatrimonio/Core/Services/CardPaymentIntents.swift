import AppIntents
import Foundation
import SwiftData

/// Shortcuts and Siri action. In the «Transacción» automation of Shortcuts (it runs after each Apple Pay
/// payment) it receives the amount, merchant and card of the payment. It only writes to this device's
/// inbox: the app files the payment as an expense pending from the bank the next time it opens.
struct RecordCardPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Apuntar pago con tarjeta"
    static let description = IntentDescription(
        "Apunta en Doblón un pago con tarjeta, pendiente del banco hasta que el banco lo envíe. En la automatización «Transacción» de Atajos, apunta cada pago con Apple Pay al momento.")
    static let openAppWhenRun = false

    @Parameter(title: "Importe", description: "El importe pagado, por ejemplo 4,50 €.")
    var amount: String

    @Parameter(title: "Comercio")
    var merchant: String?

    @Parameter(title: "Tarjeta", description: "El nombre de la tarjeta en Wallet. Sirve para elegir la cuenta.")
    var card: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Apuntar \(\.$amount) en \(\.$merchant)") {
            \.$card
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let minor = CardPaymentInbox.amount(from: amount) else {
            throw $amount.needsValueError("¿Cuánto has pagado?")
        }
        let merchantText = (merchant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cardText = (card ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try CardPaymentInbox.add(CardPayment(id: UUID(), date: .now, amountMinor: minor, merchant: merchantText, card: cardText))
        await MainActor.run {
            CardPaymentInbox.rememberCard(cardText)
            NotificationCenter.default.post(name: CardPaymentInbox.didChange, object: nil)
        }
        let formatted = (Decimal(minor) / 100).formatted(.currency(code: "EUR"))
        return .result(dialog: "Apuntado en Doblón: \(formatted). Queda pendiente del banco.")
    }
}

struct DoblonShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordCardPaymentIntent(),
            phrases: [
                "Apuntar un pago en \(.applicationName)",
                "Apunta un pago con tarjeta en \(.applicationName)"
            ],
            shortTitle: "Apuntar pago",
            systemImageName: "creditcard"
        )
    }
}

/// Moves the payments captured by the action into the finances as expenses waiting for the bank.
enum CardPaymentFiler {
    /// Returns how many payments were filed. Payments whose card has no account yet stay in the inbox.
    @MainActor @discardableResult
    static func file(into context: ModelContext, defaults: UserDefaults = .standard) -> Int {
        let pending = CardPaymentInbox.load()
        guard !pending.isEmpty, !context.hasChanges,
              let accounts = try? context.fetch(FetchDescriptor<FinancialAccount>()),
              let rules = try? context.fetch(FetchDescriptor<CategoryRule>()) else { return 0 }
        let cardAccounts = CardPaymentInbox.decodeRules(defaults.string(forKey: CardPaymentInbox.cardAccountsKey) ?? "")
        let fallback = defaults.string(forKey: CardPaymentInbox.defaultAccountKey).flatMap(UUID.init(uuidString:))
        let active = Dictionary(uniqueKeysWithValues: accounts.filter { !$0.isArchived }.map { ($0.id, $0) })
        var filed = Set<UUID>()
        for payment in pending {
            guard let id = CardPaymentInbox.account(for: payment.card, rules: cardAccounts, fallback: fallback),
                  let account = active[id] else { continue }
            let paymentID = payment.id
            // Already filed on an earlier opening whose inbox could not be cleared.
            if let count = try? context.fetchCount(FetchDescriptor<FinancialTransaction>(predicate: #Predicate { $0.id == paymentID })),
               count > 0 {
                filed.insert(payment.id); continue
            }
            let text = payment.merchant.isEmpty ? "Pago con tarjeta" : payment.merchant
            let transaction = FinancialTransaction(
                id: payment.id, date: payment.date, type: .expense, amountMinor: payment.amountMinor,
                descriptionText: text,
                notes: payment.card.isEmpty ? "Apuntado al pagar." : "Apuntado al pagar con \(payment.card).",
                externalID: CardPaymentInbox.externalID(for: payment), sourceAccount: account,
                category: CategoryRuleService.match(description: text, type: .expense, rules: rules)?.category)
            transaction.fingerprint = DuplicateDetectionService.fingerprint(
                date: payment.date, sourceAccountID: account.id, destinationAccountID: nil,
                type: .expense, amountMinor: payment.amountMinor, description: text)
            context.insert(transaction)
            filed.insert(payment.id)
        }
        guard !filed.isEmpty else { return 0 }
        do { try context.save() } catch { context.rollback(); return 0 }
        CardPaymentInbox.remove(filed)
        return filed.count
    }
}
