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
    var carriedInMinor: Int64 = 0
    var isRecurring: Bool = false

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

struct BudgetLimitDetails {
    let limitMinor: Int64
    let carriedInMinor: Int64
    let isRecurring: Bool
}

struct NetWorthPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let valueMinor: Int64
}

enum FinanceCalculator {
    static func reservedAmount(for account: FinancialAccount, funds: [ReservedFund]) -> Int64 {
        funds
            .filter { $0.account?.id == account.id }
            .reduce(Int64.zero) { $0 + Swift.max(0, $1.amountMinor) }
    }

    static func spendableCash(
        accounts: [FinancialAccount],
        funds: [ReservedFund],
        transactions: [FinancialTransaction],
        snapshots: [BalanceSnapshot] = []
    ) -> Int64 {
        accounts
            .filter { !$0.isArchived && $0.includeInNetWorth && $0.type != .investment && !$0.type.isLiability }
            .reduce(Int64.zero) { partial, account in
                partial + balance(of: account, transactions: transactions, snapshots: snapshots)
                    - reservedAmount(for: account, funds: funds)
            }
    }

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
        recurringBudgets: [RecurringBudget] = [],
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

        return categories
            .filter { !$0.isArchived && ($0.kind == .expense || $0.kind == .both) }
            .map { category in
                let details = budgetLimit(
                    for: category, month: monthStart, budgets: budgets,
                    recurringBudgets: recurringBudgets, transactions: transactions,
                    calendar: calendar
                )
                return BudgetProgress(
                    category: category,
                    limitMinor: details.limitMinor,
                    spentMinor: spend[category.id] ?? 0,
                    carriedInMinor: details.carriedInMinor,
                    isRecurring: details.isRecurring
                )
            }
            .filter { $0.limitMinor > 0 || $0.spentMinor > 0 }
            .sorted {
                if $0.fraction == $1.fraction { return $0.category.sortOrder < $1.category.sortOrder }
                return $0.fraction > $1.fraction
            }
    }

    static func activeRecurringBudget(
        for category: FinanceCategory,
        month: Date,
        recurringBudgets: [RecurringBudget],
        calendar: Calendar = .autoupdatingCurrent
    ) -> RecurringBudget? {
        let target = month.startOfMonth(calendar: calendar)
        return recurringBudgets
            .filter {
                guard $0.category?.id == category.id else { return false }
                let start = $0.startMonth.startOfMonth(calendar: calendar)
                let end = $0.endMonth?.startOfMonth(calendar: calendar)
                return start <= target && (end.map { target < $0 } ?? true)
            }
            .max { $0.startMonth < $1.startMonth }
    }

    static func budgetLimit(
        for category: FinanceCategory,
        month: Date,
        budgets: [MonthlyBudget],
        recurringBudgets: [RecurringBudget],
        transactions: [FinancialTransaction],
        calendar: Calendar = .autoupdatingCurrent,
        asOf: Date = .now
    ) -> BudgetLimitDetails {
        let target = month.startOfMonth(calendar: calendar)
        let currentRealMonth = asOf.startOfMonth(calendar: calendar)
        let categoryPlans = recurringBudgets.filter {
            $0.category?.id == category.id && $0.startMonth.startOfMonth(calendar: calendar) <= target
        }
        let categoryBudgets = budgets.filter { $0.category?.id == category.id }
        let firstMonth = categoryPlans.map { $0.startMonth.startOfMonth(calendar: calendar) }.min() ?? target
        let spentByMonth = transactions
            .filter { $0.category?.id == category.id && $0.type.countsAsExpense && $0.date < target.addingMonths(1, calendar: calendar) }
            .reduce(into: [Date: Int64]()) { result, transaction in
                result[transaction.date.startOfMonth(calendar: calendar), default: 0] += Swift.abs(transaction.amountMinor)
            }

        var current = firstMonth
        var previousLimit: Int64 = 0
        var previousSpent: Int64 = 0
        var previousHadPlan = false
        var previousMonth: Date?
        var previousChoice: BudgetRemainderChoice?

        while current <= target {
            let plan = activeRecurringBudget(
                for: category, month: current,
                recurringBudgets: categoryPlans, calendar: calendar
            )
            let override = categoryBudgets.first {
                calendar.isDate($0.monthStart, equalTo: current, toGranularity: .month)
            }
            let carry = plan != nil
                && previousChoice == .carryForward
                && previousHadPlan
                && previousMonth.map({ $0 < currentRealMonth }) == true
                ? Swift.max(0, previousLimit - previousSpent) : 0
            let base = override?.limitMinor ?? plan?.baseLimitMinor ?? 0
            let limit: Int64
            if override != nil {
                limit = base
            } else {
                let sum = base.addingReportingOverflow(carry)
                limit = sum.overflow ? Int64.max : sum.partialValue
            }

            if current == target {
                return BudgetLimitDetails(
                    limitMinor: limit,
                    carriedInMinor: override == nil ? carry : 0,
                    isRecurring: plan != nil
                )
            }
            previousLimit = limit
            previousSpent = spentByMonth[current] ?? 0
            previousHadPlan = plan != nil
            previousMonth = current
            previousChoice = plan?.remainderChoice
            guard let next = calendar.date(byAdding: .month, value: 1, to: current), next > current else {
                break
            }
            current = next
        }
        return BudgetLimitDetails(limitMinor: 0, carriedInMinor: 0, isRecurring: false)
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
                    // The last point must agree with the balance at the requested date,
                    // rather than include future transactions or valuations in that month.
                    at: Swift.min(monthEnd, month)
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
