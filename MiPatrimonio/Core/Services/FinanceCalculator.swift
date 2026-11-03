import Foundation

struct MonthlySummary: Identifiable {
    var id: Date { monthStart }
    let monthStart: Date
    let incomeMinor: Int64
    let expenseMinor: Int64
    var reservedExpenseMinor: Int64 = 0

    var budgetExpenseMinor: Int64 { expenseMinor - reservedExpenseMinor }

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
    // The saved allocation is the funding history, even after the reserve is exhausted.
    static func reservedExpenseAmount(for transaction: FinancialTransaction) -> Int64 {
        guard transaction.type.countsAsExpense, transaction.reservedFundID != nil else { return 0 }
        return Swift.max(0, Swift.min(transaction.reservedAmountMinor ?? 0, transaction.amountMinor))
    }

    static func budgetExpenseAmount(for transaction: FinancialTransaction) -> Int64 {
        guard transaction.type.countsAsExpense else { return 0 }
        return Swift.abs(transaction.amountMinor) - reservedExpenseAmount(for: transaction)
    }

    static func suggestedReservedPaymentAmount(for fund: ReservedFund, transactionAmountMinor: Int64,
                                               transactions: [FinancialTransaction], excluding transactionID: UUID? = nil) -> Int64 {
        Swift.min(Swift.max(0, transactionAmountMinor), remainingReservedAmount(for: fund,
            transactions: transactions, at: .distantFuture, excluding: transactionID))
    }

    static func spentReservedAmount(for fund: ReservedFund, transactions: [FinancialTransaction],
                                    at date: Date = .now, excluding transactionID: UUID? = nil) -> Int64 {
        transactions.filter {
            $0.id != transactionID && $0.reservedFundID == fund.id && $0.type.countsAsExpense
                && $0.date <= date
        }.reduce(Int64.zero) { total, transaction in
            let amount = reservedExpenseAmount(for: transaction)
            let sum = total.addingReportingOverflow(amount)
            return sum.overflow ? Int64.max : sum.partialValue
        }
    }

    static func remainingReservedAmount(for fund: ReservedFund, transactions: [FinancialTransaction],
                                        at date: Date = .now, excluding transactionID: UUID? = nil) -> Int64 {
        Swift.max(0, Swift.max(0, fund.amountMinor) - spentReservedAmount(for: fund, transactions: transactions,
            at: date, excluding: transactionID))
    }

    static func reserveEntries(for fund: ReservedFund, transactions: [FinancialTransaction],
                               excluding transactionID: UUID? = nil) -> [ReservedLedgerEntry] {
        transactions.compactMap { transaction in
            guard transaction.id != transactionID, transaction.reservedFundID == fund.id,
                  transaction.type.countsAsExpense || transaction.type == .transfer,
                  let source = transaction.sourceAccount?.id, let amount = transaction.reservedAmountMinor else { return nil }
            return ReservedLedgerEntry(id: transaction.id, date: transaction.date, source: source,
                destination: transaction.type == .transfer ? transaction.destinationAccount?.id : nil, amount: amount)
        }
    }

    static func reserveHistoryIsValid(fund: ReservedFund, transactions: [FinancialTransaction],
                                      excluding transactionID: UUID? = nil,
                                      adding entries: [ReservedLedgerEntry] = [], funding: Int64? = nil) -> Bool {
        guard let origin = fund.account?.id else { return false }
        return ReservedLedger.balances(origin: origin, funding: funding ?? fund.amountMinor,
            entries: reserveEntries(for: fund, transactions: transactions, excluding: transactionID) + entries) != nil
    }

    static func locatedReservedAmount(for fund: ReservedFund, accountID: UUID,
                                      transactions: [FinancialTransaction], at date: Date = .now,
                                      excluding transactionID: UUID? = nil) -> Int64 {
        guard let origin = fund.account?.id else { return 0 }
        return ReservedLedger.balances(origin: origin, funding: fund.amountMinor,
            entries: reserveEntries(for: fund, transactions: transactions, excluding: transactionID), through: date)?[accountID] ?? 0
    }

    // Maximum new allocation that leaves every later reserved payment/transfer covered.
    static func availableReserve(fund: ReservedFund, accountID: UUID, date: Date,
                                 destinationID: UUID? = nil, transactions: [FinancialTransaction],
                                 excluding transactionID: UUID? = nil) -> Int64 {
        var low: Int64 = 0
        var high = remainingReservedAmount(for: fund, transactions: transactions,
            at: .distantFuture, excluding: transactionID)
        while low < high {
            let middle = low + (high - low) / 2 + 1
            let entry = ReservedLedgerEntry(id: UUID(), date: date, source: accountID,
                                            destination: destinationID, amount: middle)
            if reserveHistoryIsValid(fund: fund, transactions: transactions, excluding: transactionID, adding: [entry]) {
                low = middle
            } else { high = middle - 1 }
        }
        return low
    }

    struct ReservedPaymentPlan {
        let amount: Int64
        let transfer: FinancialTransaction?
        let transferredAmount: Int64
        var candidateTransfers: [FinancialTransaction] = []
    }

    static func reservedPaymentPlan(fund: ReservedFund, account: FinancialAccount, date: Date,
                                    requested: Int64, transactions: [FinancialTransaction],
                                    excluding transactionID: UUID? = nil, preferredTransferID: UUID? = nil) -> ReservedPaymentPlan {
        let desired = Swift.min(Swift.max(0, requested), remainingReservedAmount(for: fund,
            transactions: transactions, at: .distantFuture, excluding: transactionID))
        let direct = Swift.min(desired, availableReserve(fund: fund, accountID: account.id,
            date: date, transactions: transactions, excluding: transactionID))
        guard desired > direct else { return ReservedPaymentPlan(amount: direct, transfer: nil, transferredAmount: 0) }
        let needed = desired - direct
        let candidates = transactions.filter { transfer in
            guard transfer.id != transactionID, transfer.type == .transfer,
                  transfer.reservedFundID == nil, transfer.reservedAmountMinor == nil,
                  transfer.destinationAccount?.id == account.id,
                  let source = transfer.sourceAccount, source.id != account.id,
                  source.currencyCode == account.currencyCode,
                  source.includeInNetWorth, !source.isArchived, !source.type.isLiability, source.type != .investment,
                  transfer.date <= date, transfer.date >= date.addingTimeInterval(-35 * 86_400),
                  transfer.amountMinor >= needed else { return false }
            let move = ReservedLedgerEntry(id: transfer.id, date: transfer.date, source: source.id,
                                           destination: account.id, amount: needed)
            let payment = ReservedLedgerEntry(id: UUID(), date: date, source: account.id,
                                              destination: nil, amount: desired)
            return reserveHistoryIsValid(fund: fund, transactions: transactions, excluding: transactionID, adding: [move, payment])
        }
        let chosen = preferredTransferID.flatMap { id in candidates.first { $0.id == id } }
            ?? (candidates.count == 1 ? candidates.first : nil)
        guard let chosen else {
            return ReservedPaymentPlan(amount: direct, transfer: nil, transferredAmount: 0, candidateTransfers: candidates)
        }
        return ReservedPaymentPlan(amount: desired, transfer: chosen, transferredAmount: needed, candidateTransfers: candidates)
    }

    static func reservedPaymentError(fund: ReservedFund, amountMinor: Int64, transactionAmountMinor: Int64,
                                     type: TransactionType, account: FinancialAccount,
                                     transactions: [FinancialTransaction], excluding transactionID: UUID? = nil,
                                     date: Date = .now, destination: FinancialAccount? = nil) -> String? {
        guard type.countsAsExpense || type == .transfer,
              account.includeInNetWorth, !account.isArchived, !account.type.isLiability, account.type != .investment else {
            return "Selecciona una cuenta de efectivo para pagar o trasladar una reserva."
        }
        if type == .transfer {
            guard let destination, destination.id != account.id,
                  destination.currencyCode == account.currencyCode, destination.includeInNetWorth,
                  !destination.isArchived, !destination.type.isLiability, destination.type != .investment else {
                return "La reserva solo puede trasladarse entre cuentas de efectivo de la misma moneda."
            }
        }
        guard amountMinor > 0, amountMinor <= transactionAmountMinor else {
            return "El importe de la reserva debe ser mayor que cero y no superar el movimiento."
        }
        let entry = ReservedLedgerEntry(id: transactionID ?? UUID(), date: date, source: account.id,
            destination: type == .transfer ? destination?.id : nil, amount: amountMinor)
        guard reserveHistoryIsValid(fund: fund, transactions: transactions, excluding: transactionID, adding: [entry]) else {
            return "No hay suficiente dinero de esta reserva en la cuenta y fecha elegidas. Vincula la reserva a la transferencia que llevó el dinero a esta cuenta, o revisa sus pagos posteriores."
        }
        return nil
    }

    static func reservedAmount(for account: FinancialAccount, funds: [ReservedFund],
                               transactions: [FinancialTransaction] = []) -> Int64 {
        funds.reduce(Int64.zero) { $0 + locatedReservedAmount(for: $1, accountID: account.id, transactions: transactions) }
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
                    - reservedAmount(for: account, funds: funds, transactions: transactions)
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

        let reservedExpense = monthTransactions.reduce(Int64.zero) { $0 + reservedExpenseAmount(for: $1) }
        return MonthlySummary(monthStart: start, incomeMinor: income, expenseMinor: expense,
                              reservedExpenseMinor: reservedExpense)
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
        excludingReservedPayments: Bool = false,
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
                    .reduce(Int64.zero) { $0 + (excludingReservedPayments ? budgetExpenseAmount(for: $1) : Swift.abs($1.amountMinor)) }
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
            excludingReservedPayments: true,
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
                result[transaction.date.startOfMonth(calendar: calendar), default: 0] += budgetExpenseAmount(for: transaction)
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
        let activeAccounts = accounts.filter { !$0.isArchived && $0.includeInNetWorth }
        guard !activeAccounts.isEmpty else {
            return (0..<Swift.max(0, months)).reversed().map { offset in
                let monthStart = calendar.date(byAdding: .month, value: -offset, to: endMonth) ?? endMonth
                return NetWorthPoint(date: monthStart, valueMinor: 0)
            }
        }

        // Pre-index transactions and snapshots by account ID to avoid repeated O(M*A*N) full scans
        var txByAccount: [UUID: [FinancialTransaction]] = [:]
        for tx in transactions {
            if let src = tx.sourceAccount?.id {
                txByAccount[src, default: []].append(tx)
            }
            if let dest = tx.destinationAccount?.id, dest != tx.sourceAccount?.id {
                txByAccount[dest, default: []].append(tx)
            }
        }
        var snapsByAccount: [UUID: [BalanceSnapshot]] = [:]
        for snap in snapshots {
            if let accId = snap.account?.id {
                snapsByAccount[accId, default: []].append(snap)
            }
        }

        return (0..<Swift.max(0, months)).reversed().map { offset in
            let monthStart = calendar.date(byAdding: .month, value: -offset, to: endMonth) ?? endMonth
            let monthEnd = monthStart.endOfMonth(calendar: calendar)
            let evaluationDate = Swift.min(monthEnd, month)

            let total = activeAccounts.reduce(Int64.zero) { partial, account in
                let accTx = txByAccount[account.id] ?? []
                let accSnaps = snapsByAccount[account.id] ?? []
                return partial + balance(of: account, at: evaluationDate, transactions: accTx, snapshots: accSnaps)
            }

            return NetWorthPoint(date: monthStart, valueMinor: total)
        }
    }

    static func hasMixedCurrencies(accounts: [FinancialAccount], primaryCurrency: String = "EUR") -> Bool {
        accounts.contains { !$0.isArchived && $0.includeInNetWorth && $0.currencyCode != primaryCurrency }
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
