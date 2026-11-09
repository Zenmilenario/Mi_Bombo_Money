import Charts
import SwiftData
import SwiftUI

private enum NetWorthRange: String, CaseIterable, Identifiable {
    case threeMonths
    case sixMonths
    case oneYear
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .threeMonths: "3 M"
        case .sixMonths: "6 M"
        case .oneYear: "1 A"
        case .all: "Todo"
        }
    }

    var fixedMonthCount: Int? {
        switch self {
        case .threeMonths: 3
        case .sixMonths: 6
        case .oneYear: 12
        case .all: nil
        }
    }
}

private enum DashboardDestination {
    case transactions
    case accounts
    case budgets
    case settings
}

private struct DashboardAlertItem: Identifiable {
    let id: String
    let revision: String
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let destination: DashboardDestination
    let priority: Int
}

struct DashboardView: View {
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]
    @Query(sort: \FinancialTransaction.date, order: .reverse) private var transactions: [FinancialTransaction]
    @Query(sort: \FinanceCategory.sortOrder) private var categories: [FinanceCategory]
    @Query(sort: \MonthlyBudget.monthStart, order: .reverse) private var budgets: [MonthlyBudget]
    @Query(sort: \RecurringBudget.startMonth, order: .reverse) private var recurringBudgets: [RecurringBudget]
    @Query(sort: \BalanceSnapshot.date) private var snapshots: [BalanceSnapshot]
    @Query(sort: \RecurringMovement.nextDueDate) private var recurringMovements: [RecurringMovement]
    @Query(sort: \SavingsGoal.createdAt, order: .reverse) private var goals: [SavingsGoal]
    @Query private var reservedFunds: [ReservedFund]

    @AppStorage("hideAmounts") private var hideAmounts = false
    @Environment(\.bankAccountActivity) private var bankActivity
    @AppStorage("dashboardReviewedAlertsV1") private var reviewedAlertsJSON = ""

    @Binding var selectedMonth: Date
    @State private var chartRange: NetWorthRange = .oneYear
    @State private var selectedGoal: SavingsGoal?
    @State private var expandedReviewedAlertIDs: Set<String> = []
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 220

    let onOpenTransactions: () -> Void
    let onOpenAccounts: () -> Void
    let onOpenBudgets: () -> Void
    let onOpenSettings: () -> Void
    let onAddMovement: () -> Void

    private var activeAccounts: [FinancialAccount] {
        accounts.filter { !$0.isArchived }
    }

    private var monthSummary: MonthlySummary {
        FinanceCalculator.monthlySummary(
            for: selectedMonth,
            transactions: transactions
        )
    }

    private var currentNetWorth: Int64 {
        FinanceCalculator.netWorth(
            accounts: activeAccounts,
            transactions: transactions,
            snapshots: snapshots,
            at: .now
        )
    }

    private var spendableCash: Int64 {
        FinanceCalculator.spendableCash(
            accounts: activeAccounts,
            funds: reservedFunds,
            transactions: transactions,
            snapshots: snapshots
        )
    }

    /// Charges the bank has already held on spendable accounts but not booked yet (negative).
    private var heldMinor: Int64 {
        activeAccounts
            .filter { $0.includeInNetWorth && $0.type != .investment && !$0.type.isLiability }
            .compactMap { $0.bankIdentityKey.flatMap { bankActivity[$0] }?.heldTotal }
            .reduce(0, +)
    }

    private var reservedCash: Int64 {
        activeAccounts
            .filter { $0.includeInNetWorth && !$0.type.isLiability && $0.type != .investment }
            .reduce(Int64.zero) { $0 + FinanceCalculator.reservedAmount(for: $1, funds: reservedFunds, transactions: transactions) }
    }

    private var investmentContributionsThisMonth: Int64 {
        accounts.filter { $0.type == .investment }.reduce(Int64.zero) {
            $0 + FinanceCalculator.investmentFlows(for: $1, month: selectedMonth,
                transactions: transactions).contributedMinor
        }
    }

    private var hasInvestmentContributions: Bool {
        investmentContributionsThisMonth > 0 || recurringMovements.contains {
            $0.type == .transfer && $0.destinationAccount?.type == .investment
        }
    }

    private var previousMonthNetWorth: Int64 {
        let currentMonthStart = Date.now.startOfMonth()
        let previousMonthEnd = Calendar.autoupdatingCurrent.date(
            byAdding: .second,
            value: -1,
            to: currentMonthStart
        ) ?? currentMonthStart

        return FinanceCalculator.netWorth(
            accounts: activeAccounts,
            transactions: transactions,
            snapshots: snapshots,
            at: previousMonthEnd
        )
    }

    private var currentMonthChange: Int64 {
        currentNetWorth - previousMonthNetWorth
    }

    private var currentMonthChangeRate: Double? {
        guard previousMonthNetWorth != 0 else { return nil }
        return Double(currentMonthChange) / Double(Swift.abs(previousMonthNetWorth))
    }

    private var budgetItems: [BudgetProgress] {
        FinanceCalculator.budgetProgress(
            for: selectedMonth,
            categories: categories,
            budgets: budgets,
            recurringBudgets: recurringBudgets,
            transactions: transactions
        )
    }

    private var budgetedItems: [BudgetProgress] {
        budgetItems.filter { $0.limitMinor > 0 }
    }

    private var totalBudgetMinor: Int64 {
        budgetedItems.reduce(Int64.zero) { $0 + $1.limitMinor }
    }

    private var totalBudgetSpentMinor: Int64 {
        budgetedItems.reduce(Int64.zero) { $0 + $1.spentMinor }
    }

    private var totalBudgetAvailableMinor: Int64 {
        totalBudgetMinor - totalBudgetSpentMinor
    }

    private var totalBudgetFraction: Double {
        guard totalBudgetMinor > 0 else { return 0 }
        return Double(totalBudgetSpentMinor) / Double(totalBudgetMinor)
    }

    private var chartMonthCount: Int {
        if let fixed = chartRange.fixedMonthCount {
            return fixed
        }

        let earliestDate = activeAccounts.map(\.openingDate).min() ?? Date.now
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.month],
            from: earliestDate.startOfMonth(),
            to: Date.now.startOfMonth()
        )
        return Swift.max(3, (components.month ?? 11) + 1)
    }

    private var netWorthHistory: [NetWorthPoint] {
        FinanceCalculator.netWorthHistory(
            endingAt: .now,
            months: chartMonthCount,
            accounts: activeAccounts,
            transactions: transactions,
            snapshots: snapshots
        )
    }

    private var netWorthChartYDomain: ClosedRange<Double> {
        let values = netWorthHistory.map { Double($0.valueMinor) / 100 }
        guard let minimum = values.min(), let maximum = values.max() else {
            return 0...1
        }

        let spread = maximum - minimum
        let reference = Swift.max(
            Swift.max(Swift.abs(minimum), Swift.abs(maximum)),
            100
        )
        let padding = Swift.max(Swift.max(spread * 0.12, reference * 0.05), 50)

        return (minimum - padding)...(maximum + padding)
    }

    private var duplicateTransactions: [FinancialTransaction] {
        transactions.filter { $0.duplicateState == .possible }
    }

    private var dueRecurringMovements: [RecurringMovement] {
        recurringMovements.filter { movement in
            guard movement.isActive else { return false }
            guard movement.nextDueDate <= Date.now.endOfMonth() else { return false }
            guard let endDate = movement.endDate else { return true }
            return endDate >= .now
        }
    }

    private var staleAccounts: [FinancialAccount] {
        let limit = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: -30,
            to: .now
        ) ?? .now
        return activeAccounts.filter { $0.lastUpdatedAt < limit }
    }

    private var overBudgetItems: [BudgetProgress] {
        budgetedItems.filter { $0.spentMinor > $0.limitMinor }
    }

    private var alertItems: [DashboardAlertItem] {
        var items: [DashboardAlertItem] = []
        let exceededBudgets = overBudgetItems
        let duplicates = duplicateTransactions
        let stale = staleAccounts
        let upcoming = dueRecurringMovements
        let overBudgetCount = exceededBudgets.count
        let duplicateCount = duplicates.count
        let staleAccountCount = stale.count
        let dueRecurringCount = upcoming.count

        if overBudgetCount > 0 {
            items.append(DashboardAlertItem(
                id: "budgets-\(selectedMonth.startOfMonth().timeIntervalSinceReferenceDate)",
                revision: exceededBudgets.map { "\($0.id.uuidString):\($0.limitMinor):\($0.spentMinor)" }.sorted().joined(separator: "|"),
                title: overBudgetCount == 1
                    ? "Has superado 1 presupuesto"
                    : "Has superado \(overBudgetCount) presupuestos",
                detail: "Revisa las categorías que necesitan atención.",
                systemImage: "exclamationmark.triangle.fill",
                tint: AppDesign.expense,
                destination: .budgets,
                priority: 0
            ))
        }

        if duplicateCount > 0 {
            items.append(DashboardAlertItem(
                id: "duplicates",
                revision: duplicates.map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.sorted().joined(separator: "|"),
                title: duplicateCount == 1
                    ? "Hay 1 posible movimiento duplicado"
                    : "Hay \(duplicateCount) posibles movimientos duplicados",
                detail: "Comprueba los registros antes de conservarlos.",
                systemImage: "doc.on.doc.fill",
                tint: AppDesign.warning,
                destination: .transactions,
                priority: 1
            ))
        }

        if staleAccountCount > 0 {
            items.append(DashboardAlertItem(
                id: "staleAccounts",
                revision: stale.map { "\($0.id.uuidString):\($0.lastUpdatedAt.timeIntervalSinceReferenceDate)" }.sorted().joined(separator: "|"),
                title: staleAccountCount == 1
                    ? "1 cuenta lleva más de 30 días sin actualizarse"
                    : "\(staleAccountCount) cuentas llevan más de 30 días sin actualizarse",
                detail: "Actualiza el saldo para mantener fiable el patrimonio.",
                systemImage: "clock.badge.exclamationmark.fill",
                tint: AppDesign.warning,
                destination: .accounts,
                priority: 2
            ))
        }

        if dueRecurringCount > 0 {
            items.append(DashboardAlertItem(
                id: "recurring",
                revision: upcoming.map { "\($0.id.uuidString):\($0.nextDueDate.timeIntervalSinceReferenceDate):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.sorted().joined(separator: "|"),
                title: dueRecurringCount == 1
                    ? "Tienes 1 movimiento recurrente próximo"
                    : "Tienes \(dueRecurringCount) movimientos recurrentes próximos",
                detail: "Consulta las próximas suscripciones y cargos.",
                systemImage: "calendar.badge.clock",
                tint: AppDesign.savings,
                destination: .settings,
                priority: 3
            ))
        }

        return items.sorted { $0.priority < $1.priority }
    }

    private func isReviewed(_ item: DashboardAlertItem) -> Bool {
        DashboardAlertReviewState(serialized: reviewedAlertsJSON).isReviewed(id: item.id, revision: item.revision)
    }

    private func minimize(_ item: DashboardAlertItem) {
        var state = DashboardAlertReviewState(serialized: reviewedAlertsJSON)
        state.markReviewed(id: item.id, revision: item.revision)
        withAnimation(.easeInOut(duration: 0.2)) {
            reviewedAlertsJSON = state.serialized
            expandedReviewedAlertIDs.remove(item.id)
        }
    }

    private var primaryGoal: SavingsGoal? {
        let incompleteGoals = goals.filter { goalProgress($0) < 1 }
        return incompleteGoals.max { goalProgress($0) < goalProgress($1) } ?? goals.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: AppDesign.sectionSpacing) {
                    welcomeHeader
                    if activeAccounts.isEmpty {
                        ContentUnavailableView {
                            Label("Empieza con tus datos", systemImage: "building.columns")
                        } description: {
                            Text("Añade tu primera cuenta o efectivo. Después podrás registrar movimientos y presupuestos.")
                        } actions: {
                            Button("Añadir mi primera cuenta", action: onOpenAccounts)
                                .buttonStyle(.borderedProminent)
                                .tint(AppDesign.actionFill)
                        }
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        if !alertPresentation.expanded.isEmpty {
                            alertsSection
                        }
                        AdaptiveCardGrid(spacing: AppDesign.sectionSpacing, packsColumns: true) {
                            netWorthCard
                            monthlyOverview
                            monthPaceCard
                            monthCalendarCard
                            budgetsSection
                            netWorthChart
                            primaryGoalSection
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .cloudSyncToolbar()
            .scrollContentBackground(.hidden)
            .background(AppDesign.pageBackground)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !activeAccounts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onAddMovement) {
                            Label("Añadir movimiento", systemImage: "plus")
                        }
                        .accessibilityLabel("Añadir movimiento")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            hideAmounts.toggle()
                        }
                    } label: {
                        Image(systemName: hideAmounts ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(hideAmounts ? "Mostrar importes" : "Ocultar importes")
                }
            }
            .sheet(item: $selectedGoal) { goal in
                GoalDetailView(goal: goal)
            }
        }
    }

    private var monthlyOverview: some View {
        VStack(spacing: 16) {
            monthSelector
            monthlyMetrics
        }
        .padding(AppDesign.cardPadding)
        .financeCardSurface()
    }

    private var welcomeHeader: some View {
        AdaptiveValueRow {
            VStack(alignment: .leading, spacing: 5) {
                Text(greeting)
                    .font(.largeTitle.bold())
                Text("Tu dinero, de un vistazo")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } value: {
            if alertPresentation.expanded.isEmpty && !alertPresentation.minimized.isEmpty {
                minimizedAlertsStrip(items: alertPresentation.minimized)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greeting: String {
        switch Calendar.autoupdatingCurrent.component(.hour, from: .now) {
        case 6..<12: return "Buenos días"
        case 12..<21: return "Buenas tardes"
        default: return "Buenas noches"
        }
    }

    private var availableMinor: Int64 { spendableCash + heldMinor }

    private var investedMinor: Int64 {
        activeAccounts
            .filter { $0.includeInNetWorth && $0.type == .investment }
            .reduce(Int64.zero) { $0 + FinanceCalculator.balance(of: $1, transactions: transactions, snapshots: snapshots) }
    }

    private var isCurrentMonth: Bool {
        Calendar.autoupdatingCurrent.isDate(selectedMonth, equalTo: .now, toGranularity: .month)
    }

    /// Days of the month still ahead, today included.
    private var daysLeftInMonth: Int {
        let calendar = Calendar.autoupdatingCurrent
        let days = calendar.range(of: .day, in: .month, for: .now)?.count ?? 30
        return max(1, days - calendar.component(.day, from: .now) + 1)
    }

    /// What the month's budget still allows per remaining day. A fact about the budget, not advice.
    private var dailyMarginMinor: Int64? {
        guard isCurrentMonth, totalBudgetMinor > 0 else { return nil }
        return max(0, totalBudgetAvailableMinor) / Int64(daysLeftInMonth)
    }

    private var netWorthCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            AdaptiveValueRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text(heldMinor == 0 ? "Disponible para usar" : "Disponible tras retenciones")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    PrivacyAmountText(minorUnits: availableMinor, font: .system(size: 42, weight: .bold, design: .rounded), weight: .bold)
                        .foregroundStyle(availableMinor >= 0 ? Color.primary : AppDesign.expense)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    if heldMinor != 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "hourglass")
                            PrivacyAmountText(minorUnits: heldMinor, font: .caption, weight: .semibold, signed: true)
                            Text("ya retenido por el banco")
                        }
                        .font(.caption)
                        .foregroundStyle(AppDesign.warning)
                        .accessibilityElement(children: .combine)
                    }
                }
            } value: {
                if let margin = dailyMarginMinor {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tu margen de hoy").font(.caption.weight(.semibold)).foregroundStyle(AppDesign.accent)
                        PrivacyAmountText(minorUnits: margin, font: .title2, weight: .bold)
                        Text(daysLeftInMonth == 1 ? "Último día del presupuesto" : "Para \(daysLeftInMonth) días de presupuesto")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(minWidth: 160, alignment: .leading)
                    .background(AppDesign.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: AppDesign.compactRadius + 4, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
            }

            moneyBreakdown

            Divider().overlay(Color.primary.opacity(0.08))

            ViewThatFits(in: .horizontal) {
                HStack {
                    netWorthLine
                    Spacer()
                    changeLine
                }
                VStack(alignment: .leading, spacing: 6) {
                    netWorthLine
                    changeLine
                }
            }
            .font(.footnote)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .financeCardSurface(radius: AppDesign.heroRadius)
    }

    private var netWorthLine: some View {
        HStack(spacing: 4) {
            Text("Patrimonio total").foregroundStyle(.secondary)
            PrivacyAmountText(minorUnits: currentNetWorth, font: .footnote, weight: .semibold)
        }
    }

    private var changeLine: some View {
        HStack(spacing: 4) {
            Image(systemName: currentMonthChange >= 0 ? "arrow.up.right" : "arrow.down.right")
            Text(hideAmounts ? "•••••• este mes" : changeSummaryText)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(changeTint)
    }

    /// How the money splits: available, reserved, held by the bank and invested.
    private var moneyBreakdown: some View {
        let parts: [(String, Int64, Color)] = [
            ("Disponible", max(0, availableMinor), AppDesign.accent),
            ("Reservado", max(0, reservedCash), AppDesign.savings),
            ("Retenido", abs(heldMinor), AppDesign.warning),
            ("Inversión", max(0, investedMinor), AppDesign.investment)
        ]
        let total = max(1, parts.reduce(Int64.zero) { $0 + $1.1 })
        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                let visible = parts.filter { $0.1 > 0 }
                let gaps = CGFloat(max(0, visible.count - 1)) * 3
                HStack(spacing: 3) {
                    ForEach(visible.indices, id: \.self) { index in
                        let part = visible[index]
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(part.2)
                            .frame(width: max(4, (proxy.size.width - gaps) * CGFloat(part.1) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
            .accessibilityHidden(true)

            AdaptiveCardGrid(minimumColumnWidth: 120, maximumColumns: 4, spacing: 10) {
                ForEach(parts.indices, id: \.self) { index in
                    let part = parts[index]
                    Button {
                        if part.0 == "Reservado" { onOpenAccounts() } else if part.0 == "Retenido" { onOpenTransactions() } else { onOpenAccounts() }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(part.2).frame(width: 8, height: 8)
                                Text(part.0).font(.caption).foregroundStyle(.secondary)
                            }
                            PrivacyAmountText(minorUnits: part.1, font: .subheadline, weight: .semibold)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Spending pace against the month's budget, with a straight-line projection.
    @ViewBuilder private var monthPaceCard: some View {
        if isCurrentMonth && totalBudgetMinor > 0 {
            let calendar = Calendar.autoupdatingCurrent
            let days = calendar.range(of: .day, in: .month, for: .now)?.count ?? 30
            let today = calendar.component(.day, from: .now)
            let expected = totalBudgetMinor * Int64(today) / Int64(days)
            let difference = expected - totalBudgetSpentMinor
            let projection = totalBudgetSpentMinor * Int64(days) / Int64(max(1, today))
            SectionCard("Ritmo del mes", subtitle: "Día \(today) de \(days)") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        PrivacyAmountText(minorUnits: totalBudgetSpentMinor, font: .title2, weight: .bold)
                        Text("de").foregroundStyle(.secondary)
                        PrivacyAmountText(minorUnits: totalBudgetMinor, font: .subheadline, weight: .semibold)
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        let spentFraction = min(1, Double(totalBudgetSpentMinor) / Double(totalBudgetMinor))
                        let expectedFraction = min(1, Double(expected) / Double(totalBudgetMinor))
                        ZStack(alignment: .leading) {
                            Capsule().fill(AppDesign.tertiaryBackground)
                            Capsule().fill(difference >= 0 ? AppDesign.accent : AppDesign.expense)
                                .frame(width: max(6, width * spentFraction))
                            Rectangle().fill(Color.primary.opacity(0.55))
                                .frame(width: 2, height: 18)
                                .offset(x: width * expectedFraction - 1)
                        }
                    }
                    .frame(height: 12)
                    .accessibilityHidden(true)
                    AdaptiveCardGrid(minimumColumnWidth: 140, maximumColumns: 2, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(difference >= 0 ? "Por debajo del ritmo" : "Por encima del ritmo")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(difference >= 0 ? AppDesign.income : AppDesign.expense)
                            PrivacyAmountText(minorUnits: abs(difference), font: .subheadline, weight: .bold)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((difference >= 0 ? AppDesign.incomeSurface : AppDesign.expenseSurface),
                                    in: RoundedRectangle(cornerRadius: AppDesign.compactRadius, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("A este paso, a fin de mes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            PrivacyAmountText(minorUnits: projection, font: .subheadline, weight: .bold)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppDesign.tertiaryBackground, in: RoundedRectangle(cornerRadius: AppDesign.compactRadius, style: .continuous))
                    }
                    Text("La marca indica lo que correspondería gastar hasta hoy si el presupuesto se repartiera por igual.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Spending per day of the selected month as a small calendar.
    private var monthCalendarCard: some View {
        let calendar = Calendar.autoupdatingCurrent
        let monthStart = selectedMonth.startOfMonth()
        let days = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        // Monday-first offset of the 1st.
        let leading = (calendar.component(.weekday, from: monthStart) + 5) % 7
        var spend = [Int: Int64]()
        for transaction in transactions where transaction.type.countsAsExpense
            && calendar.isDate(transaction.date, equalTo: monthStart, toGranularity: .month) {
            spend[calendar.component(.day, from: transaction.date), default: 0] += abs(transaction.amountMinor)
        }
        let maximum = max(1, spend.values.max() ?? 1)
        let todayDay = isCurrentMonth ? calendar.component(.day, from: .now) : (selectedMonth > .now ? 0 : days + 1)
        let busiest = spend.max { $0.value < $1.value }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
        return SectionCard("Tu mes, día a día", subtitle: "Gasto de cada día") {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(["L", "M", "X", "J", "V", "S", "D"], id: \.self) { initial in
                        Text(initial).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(0..<leading, id: \.self) { index in
                        Color.clear.frame(height: 30).id("lead-\(index)")
                    }
                    ForEach(1...days, id: \.self) { day in
                        let amount = spend[day] ?? 0
                        let level = amount == 0 ? 0.0 : 0.22 + 0.78 * Double(amount) / Double(maximum)
                        let future = day > todayDay
                        Text("\(day)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(level > 0.6 ? Color.white : (future ? Color.secondary.opacity(0.6) : Color.primary))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background((level == 0 ? AppDesign.tertiaryBackground : AppDesign.accent.opacity(level)),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay {
                                if day == todayDay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(AppDesign.accent, lineWidth: 2)
                                }
                            }
                            .accessibilityLabel(hideAmounts ? "Día \(day)" : "Día \(day): \(MoneyFormatter.string(minorUnits: amount))")
                    }
                }
                if let busiest, !hideAmounts {
                    Text("El día con más gasto fue el \(busiest.key): \(MoneyFormatter.string(minorUnits: busiest.value)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var monthSelector: some View {
        HStack(spacing: 14) {
            Button {
                selectedMonth = selectedMonth.addingMonths(-1).startOfMonth()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Mes anterior")

            Spacer()

            VStack(spacing: 2) {
                Text("Resumen mensual")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(selectedMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer()

            Button {
                selectedMonth = selectedMonth.addingMonths(1).startOfMonth()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Mes siguiente")
        }
    }

    private var monthlyMetrics: some View {
        VStack(spacing: 12) {
            AdaptiveCardGrid(minimumColumnWidth: 145, maximumColumns: hasInvestmentContributions ? 2 : 3, spacing: 12) {
                MetricCard(
                    title: "Ingresos",
                    value: hidden(MoneyFormatter.string(minorUnits: monthSummary.incomeMinor)),
                    systemImage: "arrow.down",
                    tint: AppDesign.income,
                    usesTintedBackground: true
                )

                MetricCard(
                    title: "Gastos totales",
                    value: hidden(MoneyFormatter.string(minorUnits: monthSummary.expenseMinor)),
                    systemImage: "arrow.up",
                    tint: AppDesign.expense,
                    usesTintedBackground: true
                )

                MetricCard(
                    title: "Ahorro neto",
                    value: hidden(MoneyFormatter.string(minorUnits: monthSummary.netSavingsMinor)),
                    systemImage: "banknote",
                    tint: monthSummary.netSavingsMinor >= 0 ? AppDesign.savings : AppDesign.expense,
                    valueColor: monthSummary.netSavingsMinor >= 0 ? .primary : AppDesign.expense,
                    usesTintedBackground: true
                )

                if hasInvestmentContributions {
                    MetricCard(
                        title: "Aportado a inversión",
                        value: hidden(MoneyFormatter.string(minorUnits: investmentContributionsThisMonth)),
                        systemImage: "chart.line.uptrend.xyaxis",
                        tint: AppDesign.investment,
                        usesTintedBackground: true
                    )
                }

            }
            if monthSummary.reservedExpenseMinor > 0 {
                VStack(spacing: 6) {
                    LabeledContent("Gasto para presupuesto", value: hidden(MoneyFormatter.string(minorUnits: monthSummary.budgetExpenseMinor)))
                    LabeledContent("Pagado con reservas", value: hidden(MoneyFormatter.string(minorUnits: monthSummary.reservedExpenseMinor)))
                    Text("Los pagos con dinero reservado quedan fuera del presupuesto mensual.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    savingsRateLabel
                    Spacer()
                    Button("Ver movimientos", action: onOpenTransactions)
                }
                VStack(alignment: .leading, spacing: 8) {
                    savingsRateLabel
                    Button("Ver movimientos", action: onOpenTransactions)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
    }

    private var savingsRateLabel: some View {
        Label(
            hideAmounts ? "Tasa de ahorro: ••••" : "Tasa de ahorro: \(MoneyFormatter.percent(monthSummary.savingsRate))",
            systemImage: "gauge.with.dots.needle.50percent"
        )
        .foregroundStyle(.secondary)
    }

    private var alertPresentation: (expanded: [DashboardAlertItem], minimized: [DashboardAlertItem]) {
        let items = alertItems
        let state = DashboardAlertReviewState(serialized: reviewedAlertsJSON)
        let expanded = items.filter { !state.isReviewed(id: $0.id, revision: $0.revision) || expandedReviewedAlertIDs.contains($0.id) }
        let minimized = items.filter { state.isReviewed(id: $0.id, revision: $0.revision) && !expandedReviewedAlertIDs.contains($0.id) }
        return (expanded, minimized)
    }

    @ViewBuilder
    private var alertsSection: some View {
        let expanded = alertPresentation.expanded
        let minimized = alertPresentation.minimized
        if !expanded.isEmpty {
            SectionCard("Necesita tu atención", subtitle: "Puedes minimizar los avisos que ya has revisado") {
                VStack(spacing: 0) {
                    ForEach(Array(expanded.enumerated()), id: \.element.id) { index, item in
                        alertRow(item)
                        if index < expanded.count - 1 {
                            Divider()
                        }
                    }
                }
                if !minimized.isEmpty {
                    Divider()
                    minimizedAlertsStrip(items: minimized)
                }
            }
        }
    }

    private func alertRow(_ item: DashboardAlertItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                open(item.destination)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(item.tint)
                        .frame(width: 38, height: 38)
                        .background(item.tint.opacity(0.11), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                minimize(item)
            } label: {
                Label(isReviewed(item) ? "Volver a minimizar" : "Revisado · minimizar", systemImage: "checkmark.circle")
                    .font(.caption.weight(.semibold))
                    .padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
            .tint(item.tint)
            .accessibilityHint("El aviso sigue activo y quedará visible como un icono")
        }
        .padding(.vertical, 12)
    }

    private func minimizedAlertsStrip(items: [DashboardAlertItem]) -> some View {
        HStack(spacing: 8) {
            Text("Revisados")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            _ = expandedReviewedAlertIDs.insert(item.id)
                        }
                    } label: {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(item.tint)
                            .frame(width: 44, height: 44)
                            .background(item.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AppDesign.compactRadius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.title). Revisado, sigue activo")
                    .accessibilityHint("Desplegar el aviso para leerlo o volver a revisarlo")
                    .help(item.title)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .financeCardSurface()
    }

    private var budgetsSection: some View {
        SectionCard(
            "Presupuesto del mes",
            subtitle: selectedMonth.formatted(.dateTime.month(.wide).year()),
            actionTitle: "Ver detalle",
            action: onOpenBudgets
        ) {
            if totalBudgetMinor <= 0 {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Todavía no has definido presupuestos para este mes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Crear presupuestos") {
                        onOpenBudgets()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    AdaptiveSummaryPair(
                        firstTitle: "Gastado",
                        firstAmount: totalBudgetSpentMinor,
                        firstTint: totalBudgetFraction > 1 ? AppDesign.expense : .primary,
                        secondTitle: "Disponible",
                        secondAmount: totalBudgetAvailableMinor,
                        secondTint: totalBudgetAvailableMinor >= 0 ? AppDesign.income : AppDesign.expense
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Swift.min(totalBudgetFraction, 1))
                            .tint(budgetOverallTint)

                        HStack {
                            Text(budgetPacingText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(totalBudgetFraction, format: .percent.precision(.fractionLength(0)))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(budgetOverallTint)
                        }
                    }

                }
            }
        }
    }

    private var netWorthChart: some View {
        SectionCard(
            "Evolución del patrimonio",
            subtitle: "Comprueba la tendencia, no solo el saldo actual"
        ) {
            VStack(spacing: 14) {
                Picker("Periodo", selection: $chartRange) {
                    ForEach(NetWorthRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)

                if hideAmounts {
                    privacyChartPlaceholder
                } else if netWorthHistory.isEmpty {
                    Text("No hay datos suficientes para mostrar la evolución.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    Chart(netWorthHistory) { point in
                        AreaMark(
                            x: .value("Mes", point.date),
                            y: .value("Patrimonio", Double(point.valueMinor) / 100)
                        )
                        .foregroundStyle(
                            .linearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.26),
                                    Color.accentColor.opacity(0.01),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("Mes", point.date),
                            y: .value("Patrimonio", Double(point.valueMinor) / 100)
                        )
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                        .interpolationMethod(.monotone)
                    }
                    .frame(height: chartHeight)
                    .chartXScale(
                        range: .plotDimension(startPadding: 10, endPadding: 10)
                    )
                    .chartYScale(domain: netWorthChartYDomain)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.month(.abbreviated))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(
                                        number,
                                        format: .currency(code: "EUR")
                                            .precision(.fractionLength(0))
                                    )
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Evolución del patrimonio")
                    .accessibilityValue(chartAccessibilityValue)
                }
            }
        }
    }

    @ViewBuilder
    private var primaryGoalSection: some View {
        if let goal = primaryGoal {
            SectionCard(
                "Objetivo destacado",
                subtitle: "Tu próximo hito financiero",
                actionTitle: "Ver detalle",
                action: { selectedGoal = goal }
            ) {
                let current = goalCurrentAmount(goal)
                let target = Swift.max(0, goal.targetAmountMinor)
                let fraction = goalProgress(goal)

                Button {
                    selectedGoal = goal
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: fraction >= 1 ? "checkmark.seal.fill" : "target")
                                .font(.title3)
                                .foregroundStyle(Color(hex: goal.colorHex))
                                .frame(width: 42, height: 42)
                                .background(
                                    Color(hex: goal.colorHex).opacity(0.11),
                                    in: Circle()
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                Text(goal.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(goalStatusText(current: current, target: target))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                                .font(.headline)
                                .foregroundStyle(Color(hex: goal.colorHex))

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }

                        ProgressView(value: fraction)
                            .tint(Color(hex: goal.colorHex))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Abre el detalle del objetivo")
            }
        }
    }

    private var privacyChartPlaceholder: some View {
        Label("Gráfico oculto por privacidad", systemImage: "eye.slash")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
            .accessibilityLabel("Datos del gráfico ocultos")
    }

    private var changeSummaryText: String {
        let amount = MoneyFormatter.string(minorUnits: Swift.abs(currentMonthChange))
        let sign = currentMonthChange >= 0 ? "+" : "−"
        let rate = currentMonthChangeRate.map {
            $0.formatted(.percent.precision(.fractionLength(1)))
        }

        if let rate {
            return "\(sign)\(amount) este mes · \(rate)"
        }
        return "\(sign)\(amount) este mes"
    }

    private var changeTint: Color {
        if currentMonthChange > 0 { return AppDesign.income }
        if currentMonthChange < 0 { return AppDesign.expense }
        return .secondary
    }

    private var budgetOverallTint: Color {
        if totalBudgetFraction > 1 { return AppDesign.expense }
        if totalBudgetFraction >= 0.85 { return AppDesign.warning }
        return AppDesign.accent
    }

    private var budgetPacingText: String {
        guard totalBudgetMinor > 0 else { return "Sin presupuesto definido" }

        let calendar = Calendar.autoupdatingCurrent
        let currentMonth = Date.now.startOfMonth()

        if selectedMonth > currentMonth {
            return "Presupuesto planificado"
        }

        if selectedMonth < currentMonth {
            if totalBudgetAvailableMinor >= 0 {
                return "Cerraste el mes por debajo del presupuesto"
            }
            return "Cerraste el mes por encima del presupuesto"
        }

        let day = calendar.component(.day, from: .now)
        let range = calendar.range(of: .day, in: .month, for: .now)
        let daysInMonth = range?.count ?? 30
        let expectedFraction = Double(day) / Double(daysInMonth)
        let expectedSpend = Int64((Double(totalBudgetMinor) * expectedFraction).rounded())
        let difference = expectedSpend - totalBudgetSpentMinor

        if difference >= 0 {
            return "Vas \(hidden(MoneyFormatter.string(minorUnits: difference))) por debajo del ritmo"
        }
        return "Vas \(hidden(MoneyFormatter.string(minorUnits: Swift.abs(difference)))) por encima del ritmo"
    }

    private var chartAccessibilityValue: String {
        guard let first = netWorthHistory.first, let last = netWorthHistory.last else {
            return "Sin datos"
        }
        let change = last.valueMinor - first.valueMinor
        let direction = change >= 0 ? "aumentó" : "disminuyó"
        return "El patrimonio \(direction) \(MoneyFormatter.string(minorUnits: Swift.abs(change))) en el periodo seleccionado."
    }

    private func open(_ destination: DashboardDestination) {
        switch destination {
        case .transactions: onOpenTransactions()
        case .accounts: onOpenAccounts()
        case .budgets: onOpenBudgets()
        case .settings: onOpenSettings()
        }
    }

    private func goalCurrentAmount(_ goal: SavingsGoal) -> Int64 {
        guard let account = goal.linkedAccount else {
            return Swift.max(0, goal.currentAmountMinor)
        }
        return Swift.max(
            0,
            FinanceCalculator.balance(
                of: account,
                transactions: transactions,
                snapshots: snapshots
            )
        )
    }

    private func goalProgress(_ goal: SavingsGoal) -> Double {
        let target = Swift.max(0, goal.targetAmountMinor)
        guard target > 0 else { return 0 }
        return Swift.min(1, Double(goalCurrentAmount(goal)) / Double(target))
    }

    private func goalStatusText(current: Int64, target: Int64) -> String {
        guard target > 0 else { return "Define una cantidad objetivo" }
        let remaining = Swift.max(0, target - current)
        if remaining == 0 { return "Objetivo completado" }
        return "Faltan \(hidden(MoneyFormatter.string(minorUnits: remaining)))"
    }

    private func hidden(_ value: String) -> String {
        hideAmounts ? "••••••" : value
    }
}
