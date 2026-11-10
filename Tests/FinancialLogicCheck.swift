import Foundation
import SwiftData

// Uses the app's services and models; executed on macOS by test-backup.yml.
@main
struct FinancialLogicCheck {
    private static let calendar = Calendar.autoupdatingCurrent

    @MainActor
    static func main() throws {
        checkBalancesAndHistory()
        checkInvestmentFlows()
        checkReadableDescriptions()
        try checkBulkClassification()
        checkReservedPayments()
        checkReservedTransfers()
        checkReservedBudgets()
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

        let sampleTx = FinancialTransaction(
            date: date(2, 14),
            type: .expense,
            amountMinor: 2_550,
            descriptionText: "Cena; San Valentín",
            notes: "Con amigos", sourceAccount: nil
        )
        let exportedCSV = CSVExportService.generateCSV(from: [sampleTx])
        precondition(exportedCSV.contains("2024-02-14") && exportedCSV.contains("Gasto") && exportedCSV.contains("25,50") && exportedCSV.contains("\"Cena; San Valentín\""),
                     "CSV export must correctly format date, type, amount with European comma, and escape delimiters")

        checkBalanceIndex()
        print("Financial checks passed: reservations, transfers, dated history, budget remainders, reviewed alerts, bank identity, automatic subscriptions/income/fees, categories, CSV input and CSV export.")
    }

    private static func date(_ month: Int, _ day: Int = 1) -> Date {
        calendar.date(from: DateComponents(year: 2024, month: month, day: day, hour: 12))!
    }

    /// The balance index used by the screens gives exactly the scanned balance, and its cache is rebuilt
    /// after every save (here, `invalidate()`).
    private static func checkBalanceIndex() {
        let current = FinancialAccount(name: "Corriente ficticia", type: .checking, openingBalanceMinor: 50_000, openingDate: date(1, 10))
        let savings = FinancialAccount(name: "Ahorro ficticio", type: .savings, openingBalanceMinor: 0, openingDate: date(1))
        let investing = FinancialAccount(name: "Inversión ficticia", type: .investment, openingDate: date(2))
        var transactions: [FinancialTransaction] = []
        let kinds: [TransactionType] = [.expense, .income, .transfer, .fee, .interest, .transfer]
        for index in 0..<60 {
            let kind = kinds[index % kinds.count]
            let source = [current, savings, investing][index % 3]
            let destination = kind == .transfer ? [savings, investing, current, source][index % 4] : nil
            transactions.append(FinancialTransaction(date: date(1 + index % 6, 1 + index % 27), type: kind,
                amountMinor: Int64(100 + index * 37), descriptionText: "Movimiento ficticio \(index)",
                sourceAccount: source, destinationAccount: destination))
        }
        // Same date as the opening and as a snapshot: the edges of each rule.
        transactions.append(FinancialTransaction(date: date(1, 10), type: .expense, amountMinor: 999, descriptionText: "Borde",
            sourceAccount: current))
        let snapshots = [BalanceSnapshot(date: date(3, 15), balanceMinor: 12_345, account: savings),
                         BalanceSnapshot(date: date(5, 2), balanceMinor: 20_000, account: savings),
                         BalanceSnapshot(date: date(4, 1), balanceMinor: 7_000, account: investing)]
        transactions.append(FinancialTransaction(date: date(3, 15), type: .income, amountMinor: 555, descriptionText: "Mismo día",
            sourceAccount: savings))
        let index = AccountBalanceIndex(transactions: transactions, snapshots: snapshots)
        let dates = [date(1), date(1, 10), date(2, 14), date(3, 15), date(4, 20), date(5, 2), date(7), Date.distantPast]
        for account in [current, savings, investing] {
            for when in dates {
                let scanned = FinanceCalculator.scannedBalance(of: account, at: when, transactions: transactions, snapshots: snapshots)
                precondition(index.balance(of: account, at: when) == scanned, "Index and scan must agree")
            }
        }
        BalanceIndexCache.enable()
        defer { BalanceIndexCache.disable() }
        let before = FinanceCalculator.balance(of: current, transactions: transactions, snapshots: snapshots)
        precondition(before == FinanceCalculator.scannedBalance(of: current, transactions: transactions, snapshots: snapshots))
        transactions[0].amountMinor += 1_000
        BalanceIndexCache.invalidate()
        let after = FinanceCalculator.balance(of: current, transactions: transactions, snapshots: snapshots)
        precondition(after == FinanceCalculator.scannedBalance(of: current, transactions: transactions, snapshots: snapshots),
                     "After a save the index is rebuilt with the new amount")
        let subset = Array(transactions.prefix(10))
        precondition(FinanceCalculator.balance(of: current, transactions: subset)
            == FinanceCalculator.scannedBalance(of: current, transactions: subset), "Another array never reuses the index")
        let history = FinanceCalculator.netWorthHistory(endingAt: date(6), months: 6, accounts: [current, savings, investing],
            transactions: transactions, snapshots: snapshots, calendar: calendar)
        let expected = history.map { point -> Int64 in
            let end = Swift.min(point.date.endOfMonth(calendar: calendar), date(6))
            return [current, savings, investing].reduce(Int64.zero) {
                $0 + FinanceCalculator.scannedBalance(of: $1, at: end, transactions: transactions, snapshots: snapshots)
            }
        }
        precondition(history.map(\.valueMinor) == expected, "Net worth history keeps its values")
    }

    private static func checkReservedPayments() {
        let account = FinancialAccount(name: "Corriente", type: .checking, openingBalanceMinor: 100_000, openingDate: date(1))
        let other = FinancialAccount(name: "Otra", type: .checking, openingBalanceMinor: 100_000, openingDate: date(1))
        let fund = ReservedFund(name: "Máster", amountMinor: 60_000, account: account)
        let otherFund = ReservedFund(name: "Vacaciones", amountMinor: 10_000, account: account)
        let payment = FinancialTransaction(date: date(1, 5), type: .expense, amountMinor: 20_000,
            descriptionText: "Matrícula", reservedFundID: fund.id, reservedAmountMinor: 20_000, sourceAccount: account)
        precondition(FinanceCalculator.remainingReservedAmount(for: fund, transactions: [payment]) == 40_000)
        precondition(FinanceCalculator.balance(of: account, transactions: [payment]) == 80_000)
        precondition(FinanceCalculator.spendableCash(accounts: [account], funds: [fund], transactions: [payment]) == 40_000,
            "Paying from a reserve must leave free cash unchanged")
        precondition(FinanceCalculator.remainingReservedAmount(for: otherFund, transactions: [payment]) == 10_000)
        precondition(FinanceCalculator.monthlySummary(for: date(1), transactions: [payment]).expenseMinor == 20_000,
            "Reserved payments still count as actual expenses")
        payment.amountMinor = 30_000 // 200 from reserve + 100 from free cash
        precondition(FinanceCalculator.spendableCash(accounts: [account], funds: [fund], transactions: [payment]) == 30_000)
        payment.reservedAmountMinor = 10_000
        precondition(FinanceCalculator.spendableCash(accounts: [account], funds: [fund], transactions: [payment]) == 20_000)
        precondition(FinanceCalculator.remainingReservedAmount(for: fund, transactions: []) == 60_000,
            "Deleting a payment must release its allocation automatically")
        precondition(FinanceCalculator.reservedPaymentError(fund: fund, amountMinor: 55_000, transactionAmountMinor: 55_000,
            type: .expense, account: account, transactions: [payment], excluding: payment.id) == nil,
            "Editing must release the old allocation before validating")
        precondition(FinanceCalculator.reservedPaymentError(fund: fund, amountMinor: 55_000, transactionAmountMinor: 55_000,
            type: .expense, account: account, transactions: [payment]) != nil)
        precondition(FinanceCalculator.reservedPaymentError(fund: fund, amountMinor: 1_000, transactionAmountMinor: 1_000,
            type: .expense, account: other, transactions: []) != nil)
        precondition(FinanceCalculator.reservedPaymentError(fund: fund, amountMinor: 2_000, transactionAmountMinor: 1_000,
            type: .expense, account: account, transactions: []) != nil)
        payment.date = .now.addingTimeInterval(2 * 86_400)
        precondition(FinanceCalculator.remainingReservedAmount(for: fund, transactions: [payment]) == 60_000,
            "A future payment must not release reserved money today")
        precondition(FinanceCalculator.remainingReservedAmount(for: fund, transactions: [payment], at: .distantFuture) == 50_000)
        payment.date = date(1, 5); payment.reservedFundID = nil; payment.reservedAmountMinor = nil
        precondition(FinanceCalculator.spendableCash(accounts: [account], funds: [fund], transactions: [payment]) == 10_000,
            "Ordinary expenses must keep reducing free cash")
    }

    private static func checkReservedTransfers() {
        let origin = FinancialAccount(name: "Ahorro", type: .savings, openingBalanceMinor: 100_000, openingDate: date(1))
        let destination = FinancialAccount(name: "Cobros", type: .checking, openingBalanceMinor: 10_000, openingDate: date(1))
        let third = FinancialAccount(name: "Otra", type: .checking, openingDate: date(1))
        let fund = ReservedFund(name: "Formación", amountMinor: 60_000, account: origin)
        let move = FinancialTransaction(date: date(1, 4), type: .transfer, amountMinor: 20_000,
            descriptionText: "Traspaso", reservedFundID: fund.id, reservedAmountMinor: 20_000,
            sourceAccount: origin, destinationAccount: destination)
        let payment = FinancialTransaction(date: date(1, 5), type: .expense, amountMinor: 20_000,
            descriptionText: "Escuela", reservedFundID: fund.id, reservedAmountMinor: 20_000, sourceAccount: destination)
        let entries = [payment, move] // Query ordering must not affect the calculation.
        precondition(FinanceCalculator.reserveHistoryIsValid(fund: fund, transactions: entries))
        precondition(FinanceCalculator.locatedReservedAmount(for: fund, accountID: origin.id, transactions: [move]) == 40_000)
        precondition(FinanceCalculator.locatedReservedAmount(for: fund, accountID: destination.id, transactions: [move]) == 20_000)
        precondition(FinanceCalculator.remainingReservedAmount(for: fund, transactions: [move]) == 60_000)
        precondition(FinanceCalculator.remainingReservedAmount(for: fund, transactions: entries) == 40_000)
        precondition(FinanceCalculator.spendableCash(accounts: [origin, destination], funds: [fund], transactions: entries) == 50_000,
            "Relocating then spending a reserve leaves free cash unchanged")
        precondition(FinanceCalculator.monthlySummary(for: date(1), transactions: entries).budgetExpenseMinor == 0)
        precondition(FinanceCalculator.monthlySummary(for: date(1), transactions: entries).expenseMinor == 20_000)
        precondition(!FinanceCalculator.reserveHistoryIsValid(fund: fund, transactions: [payment]))
        precondition(!FinanceCalculator.reserveHistoryIsValid(fund: fund, transactions: entries, excluding: move.id),
            "Deleting the funding transfer must be rejected")
        precondition(!FinanceCalculator.reserveHistoryIsValid(fund: fund, transactions: entries, funding: 10_000))
        payment.amountMinor = 25_000
        precondition(FinanceCalculator.budgetExpenseAmount(for: payment) == 5_000)
        precondition(FinanceCalculator.spendableCash(accounts: [origin, destination], funds: [fund], transactions: entries) == 45_000)
        payment.date = date(1, 3)
        precondition(!FinanceCalculator.reserveHistoryIsValid(fund: fund, transactions: entries), "Later transfers cannot fund earlier payments")
        payment.date = date(1, 5)
        move.reservedFundID = nil; move.reservedAmountMinor = nil
        let plan = FinanceCalculator.reservedPaymentPlan(fund: fund, account: destination, date: payment.date,
            requested: 20_000, transactions: entries, excluding: payment.id)
        precondition(plan.amount == 20_000 && plan.transfer?.id == move.id && plan.transferredAmount == 20_000)
        precondition(move.reservedFundID == nil, "Preparing a plan must not mutate existing movements")
        let ambiguous = FinancialTransaction(date: date(1, 4), type: .transfer, amountMinor: 20_000,
            descriptionText: "Otro traspaso", sourceAccount: origin, destinationAccount: destination)
        precondition(FinanceCalculator.reservedPaymentPlan(fund: fund, account: destination, date: payment.date,
            requested: 20_000, transactions: [move, ambiguous]).transfer == nil, "Ambiguous transfers require an explicit choice")
        let chosen = FinanceCalculator.reservedPaymentPlan(fund: fund, account: destination, date: payment.date,
            requested: 20_000, transactions: [move, ambiguous], preferredTransferID: ambiguous.id)
        precondition(chosen.transfer?.id == ambiguous.id && chosen.candidateTransfers.count == 2)
        let hop = FinancialTransaction(date: move.date, type: .transfer, amountMinor: 20_000, descriptionText: "Segundo tramo",
            reservedFundID: fund.id, reservedAmountMinor: 20_000, sourceAccount: destination, destinationAccount: third)
        move.reservedFundID = fund.id; move.reservedAmountMinor = 20_000
        precondition(FinanceCalculator.reserveHistoryIsValid(fund: fund, transactions: [hop, move]), "Same-instant transfer chains must retain provenance")
        precondition(!FinanceCalculator.reserveHistoryIsValid(fund: fund, transactions: [hop]), "An unfunded transfer cannot invent money")
        move.date = .now.addingTimeInterval(86_400)
        precondition(FinanceCalculator.locatedReservedAmount(for: fund, accountID: destination.id, transactions: [move]) == 0,
            "A future transfer must not relocate the reserve today")
        precondition(FinanceCalculator.reservedPaymentError(fund: fund, amountMinor: 20_000, transactionAmountMinor: 20_000,
            type: .expense, account: origin, transactions: [move], date: move.date.addingTimeInterval(-1)) == nil)
        precondition(FinanceCalculator.reservedPaymentError(fund: fund, amountMinor: 50_000, transactionAmountMinor: 50_000,
            type: .expense, account: origin, transactions: [move], date: move.date.addingTimeInterval(-1)) != nil,
            "Future transfers also commit reserved money")
    }

    private static func checkReservedBudgets() {
        let account = FinancialAccount(name: "Corriente", type: .checking, openingBalanceMinor: 100_000, openingDate: date(1))
        let fund = ReservedFund(name: "Objetivo", amountMinor: 60_000, account: account)
        let category = FinanceCategory(name: "Formación", kind: .expense)
        let payment = FinancialTransaction(date: date(1, 5), type: .expense, amountMinor: 20_000,
            descriptionText: "Pago previsto", reservedFundID: fund.id, reservedAmountMinor: 20_000,
            sourceAccount: account, category: category)
        let mixed = FinancialTransaction(date: date(1, 6), type: .expense, amountMinor: 30_000,
            descriptionText: "Pago mixto", reservedFundID: fund.id, reservedAmountMinor: 20_000,
            sourceAccount: account, category: category)
        let ordinary = FinancialTransaction(date: date(1, 7), type: .expense, amountMinor: 5_000,
            descriptionText: "Pago ordinario", sourceAccount: account, category: category)
        let transactions = [payment, mixed, ordinary]
        let budget = MonthlyBudget(monthStart: date(1).startOfMonth(), limitMinor: 15_000, category: category)
        func progress(_ payments: [FinancialTransaction]) -> BudgetProgress {
            FinanceCalculator.budgetProgress(for: date(1), categories: [category], budgets: [budget], transactions: payments)[0]
        }
        precondition(progress([payment]).spentMinor == 0 && progress([payment]).fraction == 0,
                     "A fully reserved payment must not consume budget or raise a budget alert")
        precondition(progress([mixed]).spentMinor == 10_000,
                     "Only the unreserved part of a mixed payment consumes budget")
        precondition(progress(transactions).spentMinor == 15_000 && progress(transactions).fraction == 1)
        precondition(progress([ordinary]).spentMinor == 5_000,
                     "Ordinary spending still consumes budget and deleting a payment releases its contribution")
        let summary = FinanceCalculator.monthlySummary(for: date(1), transactions: transactions)
        precondition(summary.expenseMinor == 55_000 && summary.reservedExpenseMinor == 40_000 && summary.budgetExpenseMinor == 15_000)
        precondition(summary.netSavingsMinor == -55_000,
                     "Actual expenses and net savings must include payments made from earlier savings")
        precondition(FinanceCalculator.spendingByCategory(for: date(1), categories: [category], transactions: transactions)[0].spentMinor == 55_000,
                     "Expense analysis must retain the real category totals")
        let plan = RecurringBudget(startMonth: date(1).startOfMonth(), baseLimitMinor: 50_000,
            remainderChoice: .carryForward, category: category)
        let carried = FinanceCalculator.budgetLimit(for: category, month: date(2), budgets: [], recurringBudgets: [plan],
            transactions: transactions, asOf: date(2, 15))
        precondition(carried.carriedInMinor == 35_000 && carried.limitMinor == 85_000,
                     "Budget rollover must use the same reserved-payment exclusion")
        // The budgets screen reads every category's spending in one pass: same limits as one by one.
        let viaProgress = FinanceCalculator.budgetProgress(for: date(2), categories: [category], budgets: [],
            recurringBudgets: [plan], transactions: transactions)
        let oneByOne = FinanceCalculator.budgetLimit(for: category, month: date(2), budgets: [], recurringBudgets: [plan],
            transactions: transactions)
        precondition(viaProgress.first?.limitMinor == oneByOne.limitMinor && viaProgress.first?.carriedInMinor == oneByOne.carriedInMinor
            && viaProgress.first?.isRecurring == oneByOne.isRecurring, "Budget progress keeps the same limits and rollover")
        let fee = FinancialTransaction(date: date(1, 8), type: .fee, amountMinor: 500,
            descriptionText: "Comisión prevista", reservedFundID: fund.id, reservedAmountMinor: 500,
            sourceAccount: account, category: category)
        precondition(FinanceCalculator.budgetExpenseAmount(for: fee) == 0)
        fee.type = .income
        precondition(FinanceCalculator.reservedExpenseAmount(for: fee) == 0 && FinanceCalculator.budgetExpenseAmount(for: fee) == 0)

        // What a new payment can still take from the reserve, counting committed (future) payments.
        func reserveLeft(_ items: [FinancialTransaction], excluding id: UUID? = nil) -> Int64 {
            FinanceCalculator.remainingReservedAmount(for: fund, transactions: items, at: .distantFuture, excluding: id)
        }
        precondition(min(30_000, reserveLeft(transactions)) == 20_000)
        precondition(min(10_000, reserveLeft(transactions)) == 10_000)
        precondition(min(30_000, reserveLeft(transactions, excluding: payment.id)) == 30_000, "Editing releases the previous allocation")
        let future = FinancialTransaction(date: .now.addingTimeInterval(86_400), type: .expense, amountMinor: 15_000,
            descriptionText: "Pago comprometido", reservedFundID: fund.id, reservedAmountMinor: 15_000, sourceAccount: account)
        precondition(min(30_000, reserveLeft(transactions + [future])) == 5_000, "Suggested funding must respect future commitments")
        fund.amountMinor = 40_000
        precondition(progress(transactions).spentMinor == 15_000,
                     "Exhausting a reserve must not change the funding history of its earlier payments")
        mixed.reservedAmountMinor = 10_000
        precondition(progress(transactions).spentMinor == 25_000 && progress(transactions).fraction > 1,
                     "Editing a payment must immediately update budget alerts")
        mixed.reservedAmountMinor = 90_000
        precondition(FinanceCalculator.budgetExpenseAmount(for: mixed) == 0, "Invalid allocations cannot create negative budget spending")
        mixed.reservedFundID = nil
        precondition(FinanceCalculator.budgetExpenseAmount(for: mixed) == 30_000, "An unlinked amount is not reserved funding")
        mixed.date = date(2, 6)
        precondition(progress(transactions).spentMinor == 5_000, "Only payments in the selected month affect its budget")
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

    private static func checkInvestmentFlows() {
        let cash = FinancialAccount(name: "Efectivo", type: .checking, openingBalanceMinor: 100_000, openingDate: date(1))
        let portfolio = FinancialAccount(name: "Cartera", type: .investment, openingBalanceMinor: 20_000, openingDate: date(1))
        let otherPortfolio = FinancialAccount(name: "Otra cartera", type: .investment, openingDate: date(1))
        let contribution = FinancialTransaction(date: date(1, 3), type: .transfer, amountMinor: 10_000,
            descriptionText: "Aportación", sourceAccount: cash, destinationAccount: portfolio)
        let withdrawal = FinancialTransaction(date: date(1, 4), type: .transfer, amountMinor: 2_000,
            descriptionText: "Retirada", sourceAccount: portfolio, destinationAccount: cash)
        let betweenPortfolios = FinancialTransaction(date: date(1, 5), type: .transfer, amountMinor: 1_000,
            descriptionText: "Entre carteras", sourceAccount: portfolio, destinationAccount: otherPortfolio)
        let income = FinancialTransaction(date: date(1, 6), type: .interest, amountMinor: 500,
            descriptionText: "Intereses cobrados", sourceAccount: cash)
        let future = FinancialTransaction(date: date(1, 20), type: .transfer, amountMinor: 50_000,
            descriptionText: "Aportación futura", sourceAccount: cash, destinationAccount: portfolio)
        let entries = [contribution, withdrawal, betweenPortfolios, income, future]
        let flows = FinanceCalculator.investmentFlows(for: portfolio, month: date(1), transactions: entries, at: date(1, 10))
        precondition(flows.contributedMinor == 10_000 && flows.withdrawnMinor == 2_000 && flows.netMinor == 8_000)
        precondition(FinanceCalculator.investmentFlows(for: cash, month: date(1), transactions: entries).netMinor == 0)
        precondition(FinanceCalculator.investmentFlows(for: portfolio, month: date(2), transactions: entries).netMinor == 0)
        precondition(FinanceCalculator.netWorth(accounts: [cash, portfolio, otherPortfolio], transactions: entries, at: date(1, 10)) == 120_500)
        let summary = FinanceCalculator.monthlySummary(for: date(1), transactions: entries)
        precondition(summary.incomeMinor == 500 && summary.expenseMinor == 0,
            "Only received interest is income; contributions and withdrawals must not inflate income or expense")
        let reinvestment = FinancialTransaction(date: date(1, 7), type: .transfer, amountMinor: 500,
            descriptionText: "Reinversión de intereses cobrados", sourceAccount: cash, destinationAccount: portfolio)
        let withReinvestment = entries + [reinvestment]
        precondition(FinanceCalculator.netWorth(accounts: [cash, portfolio, otherPortfolio], transactions: withReinvestment, at: date(1, 10)) == 120_500)
        precondition(FinanceCalculator.monthlySummary(for: date(1), transactions: withReinvestment).incomeMinor == 500,
            "Reinvesting received interest must not record that income a second time")
        precondition(FinanceCalculator.investmentFlows(for: portfolio, month: date(1), transactions: withReinvestment,
            at: date(1, 10)).contributedMinor == 10_500)
        let valuation = BalanceSnapshot(date: date(1, 8), balanceMinor: 28_500, account: portfolio)
        precondition(FinanceCalculator.balance(of: portfolio, at: date(1, 10), transactions: entries, snapshots: [valuation]) == 28_500,
            "A new portfolio valuation replaces the previous amount instead of adding it again")
        precondition(FinanceCalculator.investmentFlows(for: portfolio, month: date(1), transactions: entries, at: date(1, 10)).netMinor == 8_000,
            "Valuation changes must not be confused with contributed capital")
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
        let expectedIDs = Set((1...3).map { RecurringMovementService.occurrenceID(ruleID: movement.id, scheduledDate: date($0, 5)) })
        precondition(Set(transactions.map(\.id)) == expectedIDs,
                     "The same scheduled occurrence must have the same UUID on every device")
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
        let existingProfile = try makeContainer()
        let existingContext = existingProfile.mainContext
        let customCash = FinanceCategory(name: "INGRESO DE EFECTIVO", kind: .income, isArchived: true)
        existingContext.insert(customCash)
        precondition(CategoryDefaultsService.hasMissingCashCategories(in: [customCash]))
        try CategoryDefaultsService.restoreMissingCashCategories(in: existingContext, stableIDs: true)
        try CategoryDefaultsService.restoreMissingCashCategories(in: existingContext, stableIDs: true)
        let cashCategories = try existingContext.fetch(FetchDescriptor<FinanceCategory>())
        precondition(cashCategories.count == 2 && cashCategories.contains { $0.id == customCash.id && $0.isArchived })
        precondition(cashCategories.contains { $0.name == "Retirada de efectivo" && $0.kind == .expense })
        precondition(!CategoryDefaultsService.hasMissingCashCategories(in: cashCategories))

        let container = try makeContainer()
        let context = container.mainContext
        try CategoryDefaultsService.restoreMissing(in: context)
        let first = try context.fetch(FetchDescriptor<FinanceCategory>())
        precondition(!first.isEmpty && first.allSatisfy { !$0.systemImage.isEmpty })
        precondition(first.contains { $0.kind == .expense } && first.contains { $0.kind == .income } && first.contains { $0.kind == .transfer })
        precondition(first.contains { $0.name == "Ingreso de efectivo" && $0.kind == .income })
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

    private static func checkReadableDescriptions() {
        for (raw, expected) in [
            ("/TXT/D|MERCADO FICTICIO", "MERCADO FICTICIO"),
            ("/TXT/H|PAGO BIZUM DE PRUEBA", "PAGO BIZUM DE PRUEBA"),
            ("  /txt/d|COMERCIO  CON\nESPACIOS  ", "COMERCIO CON ESPACIOS"),
            ("/TXT/D|PAYPAL *SAMPLE/ORDER", "PAYPAL *SAMPLE/ORDER"),
            ("/TXT/D|TRANS INM/ Persona Ficticia", "Transferencia inmediata · Persona Ficticia"),
            ("/TXT/H|TRANSFERENCIA RECIBIDA: Prueba", "Transferencia · Prueba"),
            ("PAGO CON TARJETA DE SERVICIOS VARIOS // PAGO CON TARJETA // TIENDA FICTICIA* ABC123", "TIENDA FICTICIA* ABC123"),
            ("PAGO CON TARJETA // COMERCIO // PEDIDO", "PAGO CON TARJETA // COMERCIO // PEDIDO"),
            ("/TXT/Z|CODIGO DESCONOCIDO", "/TXT/Z|CODIGO DESCONOCIDO"),
            ("/OTRO/D|CODIGO DESCONOCIDO", "/OTRO/D|CODIGO DESCONOCIDO"),
            ("Compra /TXT/D| interna", "Compra /TXT/D| interna"),
            ("/TXT/D|   ", "/TXT/D|   ")
        ] {
            precondition(TransactionPresentation.title(raw, isBanking: true) == expected)
            precondition(TransactionPresentation.title(raw, isBanking: false) == raw,
                "A manually entered or CSV concept must not be rewritten by display cleaning")
        }
        // List titles only: readable bank operations, never applied to manual or CSV concepts.
        for (raw, expected) in [
            ("/TXT/D|MERCADO FICTICIO", "Mercado Ficticio"),
            ("ADEUDO A SU CARGO // PAGO DE ADEUDO DIRECTO SEPA // N 2026000000000001 COLEGIO FICTICIO DEL NORTE, S.L.",
             "Recibo · Colegio Ficticio del Norte, S.L."),
            ("RET. EFECTIVO A DEBITO CON TARJ. EN CAJERO. AUT. // OTROS // 0000", "Retirada de efectivo"),
            ("PAGO CON TARJETA // TIENDA FICTICIA* ABC123", "Tienda Ficticia* ABC123"),
            ("/TXT/D|TRANS INM/ Persona Ficticia", "Transferencia inmediata · Persona Ficticia"),
            ("Comercio Mixto 12", "Comercio Mixto 12"),
            ("Movimiento bancario", "Movimiento bancario"),
            // Pending card holds: marker, glued date and reference are dropped.
            ("/TXT/SUSCRIPCION FICTICIA* SUB09/11/26|20261116", "Suscripcion Ficticia* Sub"),
            ("/TXT/COMEDOR CAMPUS NORTE07/11/26|20261114", "Comedor Campus Norte"),
            ("ABC", "ABC")
        ] {
            precondition(TransactionPresentation.listTitle(raw, isBanking: true) == expected,
                "List title for \(raw): \(TransactionPresentation.listTitle(raw, isBanking: true))")
        }
        precondition(TransactionPresentation.listTitle("MERCADO FICTICIO", isBanking: false) == "MERCADO FICTICIO",
            "A concept the user typed is shown exactly as written")
        // Saying of the day: stable for a day, changes with the day and when tapped, never empty.
        var madrid = Calendar(identifier: .gregorian); madrid.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let morning = madrid.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 8))!
        let evening = madrid.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 22))!
        let tomorrow = madrid.date(byAdding: .day, value: 1, to: morning)!
        precondition(DailyQuote.of(morning, calendar: madrid) == DailyQuote.of(evening, calendar: madrid))
        precondition(DailyQuote.of(morning, calendar: madrid) != DailyQuote.of(tomorrow, calendar: madrid))
        precondition(DailyQuote.of(morning, offset: 1, calendar: madrid) == DailyQuote.of(tomorrow, calendar: madrid))
        precondition(DailyQuote.all.allSatisfy { !$0.text.isEmpty && ($0.kind != .quote || $0.author != nil) },
            "Every quote names its author")
        // Don Bigotes: a dismissed note stays hidden; three dismissals of one kind mute that kind.
        var memory = CompanionMemory()
        precondition(memory.shows(id: "review:1", kind: "review"))
        memory.dismiss(id: "review:1", kind: "review")
        precondition(!memory.shows(id: "review:1", kind: "review") && memory.shows(id: "review:2", kind: "review"))
        memory.dismiss(id: "review:1", kind: "review")
        precondition(memory.dismissalsByKind["review"] == 1, "Dismissing the same note twice counts once")
        memory.dismiss(id: "review:2", kind: "review"); memory.dismiss(id: "review:3", kind: "review")
        precondition(memory.isMuted("review") && !memory.shows(id: "review:4", kind: "review") && memory.shows(id: "holds:1", kind: "holds"))
        let restored = CompanionMemory(serialized: memory.serialized)
        precondition(restored == memory && CompanionMemory(serialized: "") == CompanionMemory())
        memory.forget(except: ["review:3"])
        precondition(memory.dismissed == ["review:3"] && memory.isMuted("review"), "Forgetting old notes keeps what was muted")
        // «Ver» leaves a one-off focus request for the destination screen.
        let request = CompanionFocus.request(.holds, at: morning)
        precondition(CompanionFocus.parse(CompanionFocus.request(.bankReview)) == .bankReview)
        precondition(CompanionFocus.parse(CompanionFocus.request(.awaitingBank)) == .awaitingBank
            && CompanionFocus.parse(CompanionFocus.request(.cardPayments)) == .cardPayments)
        // The memo behind Movimientos and Don Bigotes: same inputs, no recomputation; new inputs, a fresh result.
        let memo = ViewMemo<Int, String>()
        var computed = 0
        let firstValue = memo.value(for: 1) { computed += 1; return "uno" }
        let sameValue = memo.value(for: 1) { computed += 1; return "otro" }
        precondition(firstValue == "uno" && sameValue == "uno" && computed == 1, "Unchanged inputs reuse the result")
        let nextValue = memo.value(for: 2) { computed += 1; return "dos" }
        precondition(nextValue == "dos" && computed == 2, "Changed inputs recompute")
        let backValue = memo.value(for: 1) { computed += 1; return "uno de nuevo" }
        precondition(backValue == "uno de nuevo" && computed == 3, "Only the last result is kept")
        precondition(CompanionFocus.parse(request) == .holds && CompanionFocus.parse("") == nil && CompanionFocus.parse("otro|1") == nil)
        precondition(CompanionFocus.request(.holds, at: morning) != CompanionFocus.request(.holds, at: evening),
            "Tapping the same note again is still a new request")
        // Usage hours: every hour is usual until enough openings; then only the person's own hours.
        var usage = UsageHours()
        precondition(usage.isUsual(madrid.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 3))!, calendar: madrid))
        for day in 1...12 {
            usage.record(madrid.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 21, minute: 10))!, calendar: madrid)
            usage.record(madrid.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 21, minute: 20))!, calendar: madrid)
        }
        precondition(usage.total == 12, "Openings within half an hour count once")
        precondition(usage.isUsual(madrid.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 22))!, calendar: madrid))
        precondition(!usage.isUsual(madrid.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 9))!, calendar: madrid))
        precondition(UsageHours(serialized: usage.serialized) == usage)
        // Stored fingerprints and generated ids depend on these exact bytes.
        precondition(StableDigest.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        precondition(StableDigest.hex(Data("abc".utf8)) == StableDigest.hex("abc"))
        precondition(StableDigest.uuid("abc").uuidString == "BA7816BF-8F01-CFEA-4141-40DE5DAE2223")
        precondition(TransactionPresentation.indicatesTransfer("/TXT/D|TRANS INM/ Persona Ficticia"))
        precondition(!TransactionPresentation.indicatesTransfer("/TXT/Z|TRANS INM/ Persona Ficticia"))
        precondition(!TransactionPresentation.indicatesTransfer("/TXT/H|PAGO BIZUM DE PRUEBA"))
        precondition(!TransactionPresentation.indicatesTransfer("COMPRA TRANS INM/ PRUEBA"))
        let raw = "/TXT/D|MERCADO FICTICIO"
        let transaction = FinancialTransaction(date: date(1), type: .expense, amountMinor: 1250,
            descriptionText: raw, fingerprint: "stable", bankEntryKey: "synthetic-bank-key", sourceAccount: nil)
        precondition(transaction.displayDescription == "MERCADO FICTICIO")
        precondition(transaction.descriptionText == raw && transaction.bankEntryKey == "synthetic-bank-key"
                     && transaction.fingerprint == "stable")
        transaction.bankEntryKey = nil
        precondition(transaction.displayDescription == raw)
        transaction.externalID = "bank-test:synthetic"
        precondition(transaction.displayDescription == "MERCADO FICTICIO")
    }

    @MainActor
    private static func checkBulkClassification() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = FinancialAccount(name: "Cuenta ficticia", type: .checking)
        let category = FinanceCategory(name: "Alimentación", kind: .expense)
        let incompatible = FinanceCategory(name: "Ingresos", kind: .income)
        let fund = ReservedFund(name: "Objetivo ficticio", amountMinor: 5000, account: account)
        let payment = FinancialTransaction(date: date(1, 5), type: .expense, amountMinor: 1500,
            descriptionText: "/TXT/D|MERCADO FICTICIO", fingerprint: "unchanged", duplicateState: .confirmed,
            bankEntryKey: "synthetic-payment", recurringMovementID: UUID(), reservedFundID: fund.id,
            reservedAmountMinor: 1000, sourceAccount: account)
        let fee = FinancialTransaction(date: date(1, 6), type: .fee, amountMinor: 100,
            descriptionText: "MERCADO FICTICIO COMISION", bankEntryKey: "synthetic-fee", sourceAccount: account)
        context.insert(account); context.insert(category); context.insert(incompatible); context.insert(fund)
        context.insert(payment); context.insert(fee)
        try context.save()
        let savedID = payment.id, recurringID = payment.recurringMovementID
        do {
            try CategoryRuleService.classify(transactions: [payment, fee], category: incompatible,
                existingRules: [], in: context)
            preconditionFailure("A mixed batch must reject an incompatible category before applying anything")
        } catch is CategoryRuleService.ClassificationError { }
        precondition(payment.category == nil && fee.category == nil)
        precondition(CategoryRuleService.classificationError(transactions: [], category: category) != nil)
        precondition(CategoryRuleService.classificationError(transactions: [payment, payment], category: category) != nil)
        precondition(CategoryRuleService.classificationError(transactions: [payment, fee], category: category,
            remembering: "Otro comercio") != nil)
        precondition(CategoryRuleService.classificationError(transactions: [payment], category: category, remembering: "ab") != nil)
        #if canImport(CryptoKit)
        let beforeFingerprint = DuplicateDetectionService.fingerprint(date: payment.date,
            sourceAccountID: payment.sourceAccount?.id, destinationAccountID: payment.destinationAccount?.id,
            type: payment.type, amountMinor: payment.amountMinor, description: payment.descriptionText)
        #endif
        try CategoryRuleService.classify(transactions: [payment, fee], category: category,
            remembering: "Mercado ficticio", existingRules: [], in: context)
        #if canImport(CryptoKit)
        precondition(beforeFingerprint == DuplicateDetectionService.fingerprint(date: payment.date,
            sourceAccountID: payment.sourceAccount?.id, destinationAccountID: payment.destinationAccount?.id,
            type: payment.type, amountMinor: payment.amountMinor, description: payment.descriptionText))
        #endif
        precondition(payment.category?.id == category.id && fee.category?.id == category.id)
        precondition(payment.id == savedID && payment.amountMinor == 1500 && payment.date == date(1, 5)
            && payment.reservedFundID == fund.id && payment.reservedAmountMinor == 1000
            && payment.recurringMovementID == recurringID && payment.sourceAccount?.id == account.id
            && payment.bankEntryKey == "synthetic-payment" && payment.fingerprint == "unchanged"
            && payment.duplicateState == .confirmed && payment.descriptionText == "/TXT/D|MERCADO FICTICIO",
            "Bulk classification must preserve financial data, raw text, duplicate decisions and banking identity")
        let rules = try context.fetch(FetchDescriptor<CategoryRule>())
        precondition(rules.count == 2)
        precondition(CategoryRuleService.match(description: "/TXT/D|MERCADO FICTICIO OTRO DIA", type: .expense, rules: rules)?.category?.id == category.id)
        precondition(CategoryRuleService.match(description: "MERCADO FICTICIO", type: .income, rules: rules) == nil)
        precondition(CategoryRuleService.match(description: "OTRO COMERCIO", type: .expense, rules: rules) == nil)
        try CategoryRuleService.classify(transactions: [payment, fee], category: category,
            remembering: "MERCADO FICTICIO", existingRules: rules, in: context)
        let updatedRules = try context.fetch(FetchDescriptor<CategoryRule>())
        precondition(updatedRules.count == 2,
            "Remembering the same phrase again must update the existing rules instead of duplicating them")
        category.isArchived = true
        precondition(CategoryRuleService.classificationError(transactions: [payment, fee], category: category) != nil)
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
        let account = FinancialAccount(name: "Corriente", type: .checking)
        let exported = FinancialTransaction(date: date(1, 5), type: .expense, amountMinor: 12_345,
            descriptionText: "Compra; con \"comillas\"", notes: "=1+1", externalID: "bank-reference", sourceAccount: account)
        let csv = CSVExportService.generateCSV(from: [exported])
        let parsed = try CSVImportService.parse(text: csv)
        precondition(parsed.drafts.count == 1 && parsed.drafts[0].amountMinor == 12_345)
        precondition(parsed.drafts[0].description == exported.descriptionText)
        precondition(parsed.drafts[0].externalID == "bank-reference")
        precondition(parsed.drafts[0].notes == "'=1+1", "CSV text must not become a spreadsheet formula")
        for newline in ["\n", "\r\n", "\r"] {
            let input = [
                "Fecha;Concepto;Importe",
                "16/07/2026;\"Compra; con \"\"comillas\"\"\";-12,50",
                "17/07/2026;\"Nota en dos" + newline + "líneas\";125,00",
                "",
            ].joined(separator: newline)
            let result = try CSVImportService.parse(text: input)
            precondition(result.drafts.count == 2 && result.warnings.isEmpty,
                         "CSV rows must accept LF, CRLF and CR line endings")
            precondition(result.drafts[0].description == "Compra; con \"comillas\"")
            precondition(result.drafts[0].signedAmountMinor == -1_250)
            precondition(result.drafts[1].description == "Nota en dos" + newline + "líneas",
                         "Quoted fields must preserve embedded line endings")
            precondition(result.drafts[1].signedAmountMinor == 12_500)
        }
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
