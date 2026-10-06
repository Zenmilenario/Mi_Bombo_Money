import Foundation
import SwiftData

// Uses the app's services and models; executed on macOS by test-backup.yml.
@main
struct FinancialLogicCheck {
    private static let calendar = Calendar.autoupdatingCurrent

    @MainActor
    static func main() throws {
        checkBalancesAndHistory()
        checkBudgetRemainders()
        checkReviewedAlerts()
        checkBankIdentity()
        try checkAutomaticTransfers()
        try checkAutomaticCharges()
        try checkCategories()
        try checkCSVImport()
        precondition(MoneyParser.minorUnits(from: "1.234,56 €") == 123_456)
        precondition(MoneyParser.minorUnits(from: "1234.56") == 123_456)
        precondition(MoneyParser.minorUnits(from: "1,234.56") == 123_456)
        precondition(MoneyParser.minorUnits(from: "-12,30") == -1_230)
        precondition(MoneyParser.minorUnits(from: "12,34,56") == nil)
        precondition(MoneyParser.minorUnits(from: "texto 12,34") == nil)
        precondition(MoneyParser.minorUnits(from: "92233720368547758.08") == nil)
        precondition(MoneyParser.minorUnits(from: "-92233720368547758.08") == nil)
        print("Financial checks passed: reservations, transfers, dated history, budget remainders, reviewed alerts, bank identity, automatic subscriptions/income/fees, categories and CSV input.")
    }

    private static func date(_ month: Int, _ day: Int = 1) -> Date {
        calendar.date(from: DateComponents(year: 2024, month: month, day: day, hour: 12))!
    }

    private static func checkBankIdentity() {
        let bank = FinancialInstitution(name: "Mi banco")
        let daily = FinancialAccount(name: "Día a día", type: .checking, institution: bank)
        let savings = FinancialAccount(name: "Ahorro", type: .savings, institution: bank)
        let cash = FinancialAccount(name: "Efectivo", type: .cash)
        precondition(daily.bankDisplayName == "Mi banco")
        precondition(daily.bankAndAccountDisplayName == "Mi banco · Día a día")
        precondition(savings.bankAndAccountDisplayName == "Mi banco · Ahorro",
                     "Accounts at the same bank must remain distinguishable")
        precondition(cash.bankDisplayName == "Efectivo" && cash.bankAndAccountDisplayName == "Efectivo")
        bank.name = "Banco actualizado"
        precondition(daily.bankDisplayName == "Banco actualizado")
    }

    private static func checkReviewedAlerts() {
        let october = "budgets-2026-10"
        let firstIssue = "supermercado:10000:12000"
        var state = DashboardAlertReviewState()
        precondition(!state.isReviewed(id: october, revision: firstIssue))
        state.markReviewed(id: october, revision: firstIssue)
        let restored = DashboardAlertReviewState(serialized: state.serialized)
        precondition(restored.isReviewed(id: october, revision: firstIssue),
                     "A reviewed issue must remain minimized after reopening the app")
        precondition(!restored.isReviewed(id: october, revision: "supermercado:10000:15000"),
                     "Increased spending must bring the alert back")
        precondition(!restored.isReviewed(id: october, revision: "ocio:10000:12000"),
                     "A different over-budget category must be shown even with the same count and amount")
        precondition(!restored.isReviewed(id: "budgets-2026-11", revision: firstIssue),
                     "Acknowledging one month must not minimize the next month's alert")
        precondition(!restored.isReviewed(id: "duplicates", revision: "transaction-1"),
                     "Acknowledging budgets must not hide an unrelated alert")
        precondition(!DashboardAlertReviewState(serialized: "invalid JSON").isReviewed(id: october, revision: firstIssue))
        state.markReviewed(id: "duplicates", revision: "transaction-1")
        let multiple = DashboardAlertReviewState(serialized: state.serialized)
        precondition(multiple.isReviewed(id: october, revision: firstIssue) && multiple.isReviewed(id: "duplicates", revision: "transaction-1"))
    }

    private static func checkBalancesAndHistory() {
        let cash = FinancialAccount(name: "Corriente", type: .checking, openingBalanceMinor: 100_000, openingDate: date(1))
        let investment = FinancialAccount(name: "Valores", type: .investment, openingBalanceMinor: 20_000, openingDate: date(1))
        let expense = FinancialTransaction(date: date(1, 5), type: .expense, amountMinor: 7_500, descriptionText: "Compra", sourceAccount: cash)
        let transfer = FinancialTransaction(date: date(1, 10), type: .transfer, amountMinor: 10_000, descriptionText: "Aportación", sourceAccount: cash, destinationAccount: investment)
        let transactions = [expense, transfer]
        let reservation = ReservedFund(name: "Máster", amountMinor: 60_000, account: cash)

        precondition(FinanceCalculator.balance(of: cash, at: date(1, 15), transactions: transactions) == 82_500)
        precondition(FinanceCalculator.balance(of: investment, at: date(1, 15), transactions: transactions) == 30_000)
        precondition(FinanceCalculator.netWorth(accounts: [cash, investment], transactions: transactions, at: date(1, 15)) == 112_500)
        precondition(FinanceCalculator.spendableCash(accounts: [cash, investment], funds: [reservation], transactions: transactions) == 22_500,
                     "Reserved funds and investments must be excluded from spendable cash")
        let summary = FinanceCalculator.monthlySummary(for: date(1), transactions: transactions, calendar: calendar)
        precondition(summary.expenseMinor == 7_500 && summary.incomeMinor == 0,
                     "An internal transfer must not be counted as spending or income")

        let futureIncome = FinancialTransaction(date: date(1, 25), type: .income, amountMinor: 25_000, descriptionText: "Ingreso futuro", sourceAccount: cash)
        let futureSnapshot = BalanceSnapshot(date: date(1, 28), balanceMinor: 900_000, account: investment)
        let history = FinanceCalculator.netWorthHistory(
            endingAt: date(1, 15), months: 2, accounts: [cash, investment],
            transactions: transactions + [futureIncome], snapshots: [futureSnapshot], calendar: calendar
        )
        precondition(history.count == 2 && history.first?.valueMinor == 0)
        precondition(history.last?.valueMinor == 112_500,
                     "The current chart point must exclude future transactions and valuations")

        let snapshot = BalanceSnapshot(date: date(1, 7), balanceMinor: 80_000, account: cash)
        precondition(FinanceCalculator.balance(of: cash, at: date(1, 15), transactions: transactions, snapshots: [snapshot]) == 70_000,
                     "A valuation must replace the previous balance and apply only subsequent movements")
    }

    private static func checkBudgetRemainders() {
        let category = FinanceCategory(name: "Supermercado", kind: .expense)
        let account = FinancialAccount(name: "Corriente", type: .checking)
        let expense = FinancialTransaction(date: date(1, 10), type: .expense, amountMinor: 6_000, descriptionText: "Compra", sourceAccount: account, category: category)
        let plan = RecurringBudget(startMonth: date(1).startOfMonth(), baseLimitMinor: 10_000, remainderChoice: .carryForward, category: category)

        func limit(for month: Date, asOf: Date, overrides: [MonthlyBudget] = []) -> BudgetLimitDetails {
            FinanceCalculator.budgetLimit(for: category, month: month, budgets: overrides, recurringBudgets: [plan], transactions: [expense], calendar: calendar, asOf: asOf)
        }

        let carried = limit(for: date(2), asOf: date(2, 15))
        precondition(carried.limitMinor == 14_000 && carried.carriedInMinor == 4_000 && carried.isRecurring)
        let notYetClosed = limit(for: date(2), asOf: date(1, 15))
        precondition(notYetClosed.limitMinor == 10_000 && notYetClosed.carriedInMinor == 0,
                     "An open month's remainder must not be carried forward yet")
        let override = MonthlyBudget(monthStart: date(2).startOfMonth(), limitMinor: 8_000, category: category)
        let overridden = limit(for: date(2), asOf: date(2, 15), overrides: [override])
        precondition(overridden.limitMinor == 8_000 && overridden.carriedInMinor == 0)
        plan.remainderChoice = .save
        let saved = limit(for: date(2), asOf: date(2, 15))
        precondition(saved.limitMinor == 10_000 && saved.carriedInMinor == 0)
        plan.endMonth = date(2).startOfMonth()
        precondition(limit(for: date(2), asOf: date(2, 15)).limitMinor == 0)
    }

    @MainActor
    private static func checkAutomaticTransfers() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let cash = FinancialAccount(name: "Origen", type: .checking, openingBalanceMinor: 100_000, openingDate: date(1))
        let investment = FinancialAccount(name: "Valores", type: .investment, openingDate: date(1))
        let movement = RecurringMovement(name: "Aportación", type: .transfer, amountMinor: 10_000, descriptionText: "Inversión", frequency: .monthly, nextDueDate: date(1, 5), postsAutomatically: true, sourceAccount: cash, destinationAccount: investment)
        context.insert(cash)
        context.insert(investment)
        context.insert(movement)
        try context.save()

        let posted = try RecurringMovementService.postDueMovements(in: context, through: date(3, 10))
        let repeated = try RecurringMovementService.postDueMovements(in: context, through: date(3, 10))
        precondition(posted == 3 && repeated == 0, "Reopening the app must not duplicate automatic transfers")
        let transactions = try context.fetch(FetchDescriptor<FinancialTransaction>())
        precondition(transactions.count == 3 && transactions.allSatisfy { $0.recurringMovementID == movement.id })
        precondition(FinanceCalculator.balance(of: cash, at: date(3, 10), transactions: transactions) == 70_000)
        precondition(FinanceCalculator.balance(of: investment, at: date(3, 10), transactions: transactions) == 30_000)
        precondition(FinanceCalculator.netWorth(accounts: [cash, investment], transactions: transactions, at: date(3, 10)) == 100_000)
        precondition(calendar.isDate(movement.nextDueDate, inSameDayAs: date(4, 5)))
    }

    @MainActor
    private static func checkAutomaticCharges() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let cash = FinancialAccount(name: "Corriente", type: .checking, openingBalanceMinor: 100_000, openingDate: date(1))
        let subscriptions = FinanceCategory(name: "Suscripciones", kind: .expense)
        let fees = FinanceCategory(name: "Comisiones", kind: .expense)
        let salary = FinanceCategory(name: "Nómina", kind: .income)
        context.insert(cash)
        for category in [subscriptions, fees, salary] { context.insert(category) }
        let subscription = RecurringMovement(name: "Streaming", type: .expense, amountMinor: 1_500, descriptionText: "Streaming", frequency: .monthly, nextDueDate: date(1, 5), isSubscription: true, postsAutomatically: true, sourceAccount: cash, category: subscriptions)
        let income = RecurringMovement(name: "Nómina", type: .income, amountMinor: 20_000, descriptionText: "Nómina", frequency: .monthly, nextDueDate: date(1, 6), postsAutomatically: true, sourceAccount: cash, category: salary)
        let fee = RecurringMovement(name: "Comisión", type: .fee, amountMinor: 200, descriptionText: "Comisión", frequency: .monthly, nextDueDate: date(1, 7), endDate: date(2, 7), postsAutomatically: true, sourceAccount: cash, category: fees)
        let manual = RecurringMovement(name: "Manual", type: .expense, amountMinor: 3_000, descriptionText: "Manual", frequency: .monthly, nextDueDate: date(1, 8), postsAutomatically: false, sourceAccount: cash, category: subscriptions)
        let paused = RecurringMovement(name: "Pausado", type: .expense, amountMinor: 3_000, descriptionText: "Pausado", frequency: .monthly, nextDueDate: date(1, 8), isActive: false, postsAutomatically: true, sourceAccount: cash, category: subscriptions)
        let future = RecurringMovement(name: "Futuro", type: .expense, amountMinor: 3_000, descriptionText: "Futuro", frequency: .monthly, nextDueDate: date(4, 8), postsAutomatically: true, sourceAccount: cash, category: subscriptions)
        let invalidCategory = RecurringMovement(name: "Categoría incompatible", type: .expense, amountMinor: 3_000, descriptionText: "No registrar", frequency: .monthly, nextDueDate: date(1, 8), postsAutomatically: true, sourceAccount: cash, category: salary)
        for rule in [subscription, income, fee, manual, paused, future, invalidCategory] { context.insert(rule) }
        try context.save()

        let posted = try RecurringMovementService.postDueMovements(in: context, through: date(3, 10))
        let repeated = try RecurringMovementService.postDueMovements(in: context, through: date(3, 10))
        precondition(posted == 8 && repeated == 0, "Due subscriptions, income and fees must post once; paused, manual and future rules must not post")
        subscription.nextDueDate = date(1, 5)
        try context.save()
        let replayed = try RecurringMovementService.postDueMovements(in: context, through: date(3, 10))
        precondition(replayed == 0 && calendar.isDate(subscription.nextDueDate, inSameDayAs: date(4, 5)),
                     "Moving a rule's due date back must not recreate charges already recorded for that rule and day")
        let transactions = try context.fetch(FetchDescriptor<FinancialTransaction>())
        precondition(transactions.allSatisfy { $0.destinationAccount == nil })
        precondition(transactions.filter { $0.recurringMovementID == subscription.id }.count == 3)
        precondition(transactions.filter { $0.recurringMovementID == fee.id }.count == 2 && !fee.isActive,
                     "The final scheduled charge is included but dates after the end date are not")
        precondition(FinanceCalculator.balance(of: cash, at: date(3, 10), transactions: transactions) == 155_100)
        let january = FinanceCalculator.monthlySummary(for: date(1), transactions: transactions, calendar: calendar)
        precondition(january.incomeMinor == 20_000 && january.expenseMinor == 1_700)
        let budget = MonthlyBudget(monthStart: date(1).startOfMonth(), limitMinor: 2_000, category: subscriptions)
        let progress = FinanceCalculator.budgetProgress(for: date(1), categories: [subscriptions], budgets: [budget], transactions: transactions, calendar: calendar)
        precondition(progress.first?.spentMinor == 1_500, "An automatic subscription must consume its category budget")
    }

    @MainActor
    private static func checkCategories() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try CategoryDefaultsService.restoreMissing(in: context)
        let first = try context.fetch(FetchDescriptor<FinanceCategory>())
        precondition(!first.isEmpty && first.allSatisfy { !$0.systemImage.isEmpty })
        precondition(first.contains { $0.kind == .expense } && first.contains { $0.kind == .income } && first.contains { $0.kind == .transfer })
        try CategoryDefaultsService.restoreMissing(in: context)
        let second = try context.fetch(FetchDescriptor<FinanceCategory>())
        precondition(second.count == first.count, "Restoring common categories must not duplicate them")

        let supermarket = first.first { $0.name == "Supermercado" }!
        let general = CategoryRule(phrase: "Mercadona", transactionType: .expense, category: supermarket)
        let specific = CategoryRule(phrase: "Mercadona online", transactionType: .expense, category: supermarket)
        precondition(CategoryRuleService.match(description: "MERCADONA ÓNLINE Madrid", type: .expense, rules: [general, specific])?.id == specific.id)
        precondition(CategoryRuleService.match(description: "Mercadona", type: .income, rules: [general]) == nil)
        supermarket.isArchived = true
        precondition(CategoryRuleService.match(description: "Mercadona", type: .expense, rules: [general]) == nil)
    }

    @MainActor
    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            FinancialInstitution.self, FinancialAccount.self, PaymentCard.self,
            ReservedFund.self, FinanceCategory.self, FinancialTransaction.self,
            CategoryRule.self, MonthlyBudget.self, RecurringBudget.self,
            SavingsGoal.self, RecurringMovement.self, BalanceSnapshot.self, ImportBatch.self,
        ])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private static func checkCSVImport() throws {
        let minimal = try CSVImportService.parse(url: URL(fileURLWithPath: "Samples/plantilla_csv_minima.csv"))
        precondition(minimal.drafts.count == 2 && minimal.warnings.isEmpty)
        precondition(minimal.drafts[0].type == .expense && minimal.drafts[0].amountMinor == 1_250)
        precondition(minimal.drafts[1].type == .income && minimal.drafts[1].amountMinor == 12_500)
        let full = try CSVImportService.parse(url: URL(fileURLWithPath: "Samples/ejemplo_importacion.csv"))
        precondition(full.drafts.count == 4 && full.warnings.isEmpty)
        precondition(full.drafts[0].type == .transfer && full.drafts[0].destinationAccountName == "Bankinter - Nómina")
        precondition(full.drafts[2].type == .expense && full.drafts[2].amountMinor == 4_280)

        let mixed = try CSVImportService.parse(text: "Fecha;Concepto;Importe\n16/07/2026;Importe mal escrito;12,34,56\n17/07/2026;Compra válida;-12,50\n")
        precondition(mixed.drafts.count == 1 && mixed.warnings.count == 1,
                     "Malformed amounts must be rejected instead of importing a numeric prefix")
    }
}
