import Foundation

struct MonthlySummary: Identifiable {
    var id: Date { monthStart }
    let monthStart: Date
    let incomeMinor: Int64
    let expenseMinor: Int64

    var netSavingsMinor: Int64 { incomeMinor - expenseMinor }
    var savingsRate: Double? {
        guard incomeMinor > 0 else { return nil }
        return Double(netSavingsMinor) / Double(incomeMinor)
    }
}

struct CategorySpend: Identifiable {
    var id: UUID { category.id }
    let category: FinanceCategory
    let spentMinor: Int64
}

struct BudgetProgress: Identifiable {
    var id: UUID { category.id }
    let category: FinanceCategory
    let limitMinor: Int64
    let spentMinor: Int64

    var availableMinor: Int64 { limitMinor - spentMinor }
    var fraction: Double {
        guard limitMinor > 0 else { return 0 }
        return Double(spentMinor) / Double(limitMinor)
    }

    var statusText: String {
        guard limitMinor > 0 else { return "Sin presupuesto" }
        if spentMinor > limitMinor { return "Superado" }
        if fraction >= 0.85 { return "Cerca del límite" }
        return "Dentro"
    }
}

struct NetWorthPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let valueMinor: Int64
}

enum FinanceCalculator {
    static func effect(of transaction: FinancialTransaction, on account: FinancialAccount) -> Int64 {
        let amount = Swift.abs(transaction.amountMinor)
        let isSource = transaction.sourceAccount?.id == account.id
        let isDestination = transaction.destinationAccount?.id == account.id

        switch transaction.type {
        case .income, .interest:
            return isSource ? amount : 0
        case .expense, .fee:
            return isSource ? -amount : 0
        case .transfer:
            if isSource { return -amount }
            if isDestination { return amount }
            return 0
        }
    }

    static func balance(
        of account: FinancialAccount,
        at date: Date = .now,
        transactions: [FinancialTransaction],
        snapshots: [BalanceSnapshot] = []
    ) -> Int64 {
        let accountSnapshots = snapshots
            .filter { $0.account?.id == account.id && $0.date <= date }
            .sorted { $0.date > $1.date }

        if let latestSnapshot = accountSnapshots.first {
            let subsequentEffects = transactions
                .filter { $0.date > latestSnapshot.date && $0.date <= date }
                .reduce(Int64.zero) { partial, transaction in
                    partial + effect(of: transaction, on: account)
                }
            return latestSnapshot.balanceMinor + subsequentEffects
        }

        guard account.openingDate <= date else { return 0 }
        let effects = transactions
            .filter { $0.date >= account.openingDate && $0.date <= date }
            .reduce(Int64.zero) { partial, transaction in
                partial + effect(of: transaction, on: account)
            }
        return account.openingBalanceMinor + effects
    }

    static func netWorth(
        accounts: [FinancialAccount],
        transactions: [FinancialTransaction],
        snapshots: [BalanceSnapshot] = [],
        at date: Date = .now
    ) -> Int64 {
        accounts
            .filter { !$0.isArchived && $0.includeInNetWorth }
            .reduce(Int64.zero) { partial, account in
                partial + balance(of: account, at: date, transactions: transactions, snapshots: snapshots)
            }
    }

    static func monthlySummary(
        for month: Date,
        transactions: [FinancialTransaction],
        calendar: Calendar = .autoupdatingCurrent
    ) -> MonthlySummary {
        let start = month.startOfMonth(calendar: calendar)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        let monthTransactions = transactions.filter { $0.date >= start && $0.date < end }

        let income = monthTransactions
            .filter { $0.type.countsAsIncome }
            .reduce(Int64.zero) { $0 + Swift.abs($1.amountMinor) }
        let expense = monthTransactions
            .filter { $0.type.countsAsExpense }
            .reduce(Int64.zero) { $0 + Swift.abs($1.amountMinor) }

        return MonthlySummary(monthStart: start, incomeMinor: income, expenseMinor: expense)
    }

    static func monthlySummaries(
        endingAt month: Date,
        count: Int,
        transactions: [FinancialTransaction],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MonthlySummary] {
        let endMonth = month.startOfMonth(calendar: calendar)
        return (0..<Swift.max(0, count)).reversed().map { offset in
            let target = calendar.date(byAdding: .month, value: -offset, to: endMonth) ?? endMonth
            return monthlySummary(for: target, transactions: transactions, calendar: calendar)
        }
    }

    static func spendingByCategory(
        for month: Date,
        categories: [FinanceCategory],
        transactions: [FinancialTransaction],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [CategorySpend] {
        let start = month.startOfMonth(calendar: calendar)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        let expenseTransactions = transactions.filter {
            $0.date >= start && $0.date < end && $0.type.countsAsExpense
        }

        return categories
            .filter { !$0.isArchived && ($0.kind == .expense || $0.kind == .both) }
            .map { category in
                let spent = expenseTransactions
                    .filter { $0.category?.id == category.id }
                    .reduce(Int64.zero) { $0 + Swift.abs($1.amountMinor) }
                return CategorySpend(category: category, spentMinor: spent)
            }
            .filter { $0.spentMinor > 0 }
            .sorted { $0.spentMinor > $1.spentMinor }
    }

    static func budgetProgress(
        for month: Date,
        categories: [FinanceCategory],
        budgets: [MonthlyBudget],
        transactions: [FinancialTransaction],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [BudgetProgress] {
        let monthStart = month.startOfMonth(calendar: calendar)
        let spend = Dictionary(uniqueKeysWithValues: spendingByCategory(
            for: monthStart,
            categories: categories,
            transactions: transactions,
            calendar: calendar
        ).map { ($0.category.id, $0.spentMinor) })

        let monthBudgets = budgets.filter {
            calendar.isDate($0.monthStart, equalTo: monthStart, toGranularity: .month)
        }
        let budgetPairs: [(UUID, Int64)] = monthBudgets.compactMap { budget in
            guard let categoryID = budget.category?.id else { return nil }
            return (categoryID, budget.limitMinor)
        }
        let budgetByCategory = Dictionary(uniqueKeysWithValues: budgetPairs)

        return categories
            .filter { !$0.isArchived && ($0.kind == .expense || $0.kind == .both) }
            .map { category in
                BudgetProgress(
                    category: category,
                    limitMinor: budgetByCategory[category.id] ?? 0,
                    spentMinor: spend[category.id] ?? 0
                )
            }
            .filter { $0.limitMinor > 0 || $0.spentMinor > 0 }
            .sorted {
                if $0.fraction == $1.fraction { return $0.category.sortOrder < $1.category.sortOrder }
                return $0.fraction > $1.fraction
            }
    }

    static func netWorthHistory(
        endingAt month: Date,
        months: Int,
        accounts: [FinancialAccount],
        transactions: [FinancialTransaction],
        snapshots: [BalanceSnapshot],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [NetWorthPoint] {
        let endMonth = month.startOfMonth(calendar: calendar)
        return (0..<Swift.max(0, months)).reversed().map { offset in
            let monthStart = calendar.date(byAdding: .month, value: -offset, to: endMonth) ?? endMonth
            let monthEnd = monthStart.endOfMonth(calendar: calendar)
            return NetWorthPoint(
                date: monthStart,
                valueMinor: netWorth(
                    accounts: accounts,
                    transactions: transactions,
                    snapshots: snapshots,
                    at: monthEnd
                )
            )
        }
    }

    static func estimatedAnnualInterestMinor(
        account: FinancialAccount,
        transactions: [FinancialTransaction],
        snapshots: [BalanceSnapshot] = []
    ) -> Int64 {
        let currentBalance = balance(of: account, transactions: transactions, snapshots: snapshots)
        guard currentBalance != 0, account.annualInterestRate != 0 else { return 0 }
        let estimate = Int64((Double(Swift.abs(currentBalance)) * account.annualInterestRate).rounded())
        return account.type.isLiability ? -Swift.abs(estimate) : estimate
    }
}
