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
    @Query(sort: \BalanceSnapshot.date) private var snapshots: [BalanceSnapshot]
    @Query(sort: \RecurringMovement.nextDueDate) private var recurringMovements: [RecurringMovement]
    @Query(sort: \SavingsGoal.createdAt, order: .reverse) private var goals: [SavingsGoal]

    @AppStorage("hideAmounts") private var hideAmounts = false

    @State private var selectedMonth = Date.now.startOfMonth()
    @State private var chartRange: NetWorthRange = .oneYear

    let onOpenTransactions: () -> Void
    let onOpenAccounts: () -> Void
    let onOpenBudgets: () -> Void
    let onOpenSettings: () -> Void

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

    private var annualInterestEstimate: Int64 {
        activeAccounts.reduce(Int64.zero) { partial, account in
            partial + FinanceCalculator.estimatedAnnualInterestMinor(
                account: account,
                transactions: transactions,
                snapshots: snapshots
            )
        }
    }

    private var latestAccountUpdate: Date? {
        activeAccounts.map(\.lastUpdatedAt).max()
    }

    private var budgetItems: [BudgetProgress] {
        FinanceCalculator.budgetProgress(
            for: selectedMonth,
            categories: categories,
            budgets: budgets,
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

    private var attentionBudgetItems: [BudgetProgress] {
        budgetedItems
            .sorted { left, right in
                if left.fraction == right.fraction {
                    return left.spentMinor > right.spentMinor
                }
                return left.fraction > right.fraction
            }
            .prefix(3)
            .map { $0 }
    }

    private var chartMonthCount: Int {
        if let fixed = chartRange.fixedMonthCount {
            return fixed
        }

        let earliestDate = activeAccounts.map(\.openingDate).min() ?? selectedMonth
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.month],
            from: earliestDate.startOfMonth(),
            to: selectedMonth.startOfMonth()
        )
        return Swift.max(3, (components.month ?? 11) + 1)
    }

    private var netWorthHistory: [NetWorthPoint] {
        FinanceCalculator.netWorthHistory(
            endingAt: selectedMonth,
            months: chartMonthCount,
            accounts: activeAccounts,
            transactions: transactions,
            snapshots: snapshots
        )
    }

    private var duplicateCount: Int {
        transactions.filter { $0.duplicateState == .possible }.count
    }

    private var dueRecurringCount: Int {
        recurringMovements.filter { movement in
            guard movement.isActive else { return false }
            guard movement.nextDueDate <= Date.now.endOfMonth() else { return false }
            guard let endDate = movement.endDate else { return true }
            return endDate >= .now
        }.count
    }

    private var staleAccountCount: Int {
        let limit = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: -30,
            to: .now
        ) ?? .now
        return activeAccounts.filter { $0.lastUpdatedAt < limit }.count
    }

    private var overBudgetCount: Int {
        budgetedItems.filter { $0.spentMinor > $0.limitMinor }.count
    }

    private var alertItems: [DashboardAlertItem] {
        var items: [DashboardAlertItem] = []

        if overBudgetCount > 0 {
            items.append(DashboardAlertItem(
                id: "budgets",
                title: overBudgetCount == 1
                    ? "Has superado 1 presupuesto"
                    : "Has superado \(overBudgetCount) presupuestos",
                detail: "Revisa las categorías que necesitan atención.",
                systemImage: "exclamationmark.triangle.fill",
                tint: .red,
                destination: .budgets,
                priority: 0
            ))
        }

        if duplicateCount > 0 {
            items.append(DashboardAlertItem(
                id: "duplicates",
                title: duplicateCount == 1
                    ? "Hay 1 posible movimiento duplicado"
                    : "Hay \(duplicateCount) posibles movimientos duplicados",
                detail: "Comprueba los registros antes de conservarlos.",
                systemImage: "doc.on.doc.fill",
                tint: .orange,
                destination: .transactions,
                priority: 1
            ))
        }

        if staleAccountCount > 0 {
            items.append(DashboardAlertItem(
                id: "staleAccounts",
                title: staleAccountCount == 1
                    ? "1 cuenta lleva más de 30 días sin actualizarse"
                    : "\(staleAccountCount) cuentas llevan más de 30 días sin actualizarse",
                detail: "Actualiza el saldo para mantener fiable el patrimonio.",
                systemImage: "clock.badge.exclamationmark.fill",
                tint: .orange,
                destination: .accounts,
                priority: 2
            ))
        }

        if dueRecurringCount > 0 {
            items.append(DashboardAlertItem(
                id: "recurring",
                title: dueRecurringCount == 1
                    ? "Tienes 1 movimiento recurrente próximo"
                    : "Tienes \(dueRecurringCount) movimientos recurrentes próximos",
                detail: "Consulta las próximas suscripciones y cargos.",
                systemImage: "calendar.badge.clock",
                tint: .blue,
                destination: .settings,
                priority: 3
            ))
        }

        return items.sorted { $0.priority < $1.priority }.prefix(3).map { $0 }
    }

    private var primaryGoal: SavingsGoal? {
        let incompleteGoals = goals.filter { goalProgress($0) < 1 }
        return incompleteGoals.max { goalProgress($0) < goalProgress($1) } ?? goals.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: AppDesign.sectionSpacing) {
                    netWorthCard
                    monthSelector
                    monthlyMetrics
                    alertsSection
                    accountsSection
                    budgetsSection
                    netWorthChart
                    primaryGoalSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 104)
            }
            .background(AppDesign.pageBackground)
            .navigationTitle("Inicio")
            .toolbar {
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
        }
    }

    private var netWorthCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label("Patrimonio total", systemImage: "sum")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(lastUpdateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            PrivacyAmountText(
                minorUnits: currentNetWorth,
                font: .system(size: 38, weight: .bold, design: .rounded),
                weight: .bold
            )
            .minimumScaleFactor(0.72)
            .lineLimit(1)

            HStack(spacing: 8) {
                Image(systemName: currentMonthChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.weight(.bold))

                if hideAmounts {
                    Text("•••••• este mes")
                } else {
                    Text(changeSummaryText)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(changeTint)

            Divider()
                .overlay(Color.primary.opacity(0.08))

            HStack {
                Label("Interés anual estimado", systemImage: "percent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                PrivacyAmountText(
                    minorUnits: annualInterestEstimate,
                    font: .subheadline,
                    weight: .semibold
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.24),
                    Color.accentColor.opacity(0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: AppDesign.heroRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
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
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ],
            spacing: 12
        ) {
            MetricCard(
                title: "Ingresos",
                value: hidden(MoneyFormatter.string(minorUnits: monthSummary.incomeMinor)),
                systemImage: "arrow.down",
                tint: .green
            )

            MetricCard(
                title: "Gastos",
                value: hidden(MoneyFormatter.string(minorUnits: monthSummary.expenseMinor)),
                systemImage: "arrow.up",
                tint: .red
            )

            MetricCard(
                title: "Ahorro neto",
                value: hidden(MoneyFormatter.string(minorUnits: monthSummary.netSavingsMinor)),
                systemImage: "banknote",
                tint: monthSummary.netSavingsMinor >= 0 ? .blue : .red,
                valueColor: monthSummary.netSavingsMinor >= 0 ? .primary : .red
            )

            MetricCard(
                title: "Tasa de ahorro",
                value: hideAmounts ? "••••" : MoneyFormatter.percent(monthSummary.savingsRate),
                systemImage: "gauge.with.dots.needle.50percent",
                tint: .orange
            )
        }
    }

    @ViewBuilder
    private var alertsSection: some View {
        if !alertItems.isEmpty {
            SectionCard("Necesita tu atención", subtitle: "Mostramos primero lo más importante") {
                VStack(spacing: 0) {
                    ForEach(Array(alertItems.enumerated()), id: \.element.id) { index, item in
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
                                        .multilineTextAlignment(.leading)
                                    Text(item.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }

                                Spacer(minLength: 8)

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < alertItems.count - 1 {
                            Divider()
                                .padding(.leading, 50)
                        }
                    }
                }
            }
        }
    }

    private var accountsSection: some View {
        SectionCard(
            "Tus cuentas",
            subtitle: activeAccounts.isEmpty ? nil : "Saldos consolidados",
            actionTitle: activeAccounts.isEmpty ? nil : "Ver todas",
            action: activeAccounts.isEmpty ? nil : onOpenAccounts
        ) {
            if activeAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Añade tu primera cuenta para empezar a calcular tu patrimonio.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Añadir una cuenta") {
                        onOpenAccounts()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(activeAccounts.prefix(4).enumerated()), id: \.element.id) { index, account in
                        HStack(spacing: 12) {
                            Image(systemName: account.type.systemImage)
                                .foregroundStyle(Color(hex: account.institution?.colorHex ?? "#1F6B7A"))
                                .frame(width: 38, height: 38)
                                .background(Color.secondary.opacity(0.09), in: Circle())

                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.name)
                                    .font(.subheadline.weight(.semibold))
                                HStack(spacing: 6) {
                                    Text(account.institution?.name ?? account.type.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    if isStale(account) {
                                        StatusPill(
                                            text: "Sin actualizar",
                                            systemImage: "clock",
                                            tint: .orange
                                        )
                                    }
                                }
                            }

                            Spacer(minLength: 8)

                            PrivacyAmountText(
                                minorUnits: FinanceCalculator.balance(
                                    of: account,
                                    transactions: transactions,
                                    snapshots: snapshots
                                ),
                                currencyCode: account.currencyCode,
                                font: .subheadline,
                                weight: .semibold
                            )
                        }
                        .padding(.vertical, 10)

                        if index < Swift.min(activeAccounts.count, 4) - 1 {
                            Divider()
                                .padding(.leading, 50)
                        }
                    }
                }
            }
        }
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
                    HStack(spacing: 16) {
                        FinancialSummaryTile(
                            title: "Gastado",
                            minorUnits: totalBudgetSpentMinor,
                            tint: totalBudgetFraction > 1 ? .red : .primary
                        )

                        Divider()

                        FinancialSummaryTile(
                            title: "Disponible",
                            minorUnits: totalBudgetAvailableMinor,
                            tint: totalBudgetAvailableMinor >= 0 ? .green : .red
                        )
                    }
                    .frame(minHeight: 54)

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

                    if !attentionBudgetItems.isEmpty {
                        Divider()

                        VStack(spacing: 12) {
                            ForEach(attentionBudgetItems) { item in
                                budgetAttentionRow(item)
                            }
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

                        LineMark(
                            x: .value("Mes", point.date),
                            y: .value("Patrimonio", Double(point.valueMinor) / 100)
                        )
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                        .interpolationMethod(.catmullRom)
                    }
                    .frame(height: 220)
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
                actionTitle: "Ver objetivos",
                action: onOpenSettings
            ) {
                let current = goalCurrentAmount(goal)
                let target = Swift.max(0, goal.targetAmountMinor)
                let fraction = goalProgress(goal)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: fraction >= 1 ? "checkmark.seal.fill" : "target")
                            .font(.title3)
                            .foregroundStyle(Color(hex: goal.colorHex))
                            .frame(width: 42, height: 42)
                            .background(Color(hex: goal.colorHex).opacity(0.11), in: Circle())

                        VStack(alignment: .leading, spacing: 3) {
                            Text(goal.name)
                                .font(.subheadline.weight(.semibold))
                            Text(goalStatusText(current: current, target: target))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.headline)
                            .foregroundStyle(Color(hex: goal.colorHex))
                    }

                    ProgressView(value: fraction)
                        .tint(Color(hex: goal.colorHex))
                }
            }
        }
    }

    private func budgetAttentionRow(_ item: BudgetProgress) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(item.category.name, systemImage: item.category.systemImage)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer()

                StatusPill(
                    text: item.statusText,
                    tint: budgetTint(item)
                )
            }

            ProgressView(value: Swift.min(item.fraction, 1))
                .tint(budgetTint(item))

            HStack {
                Text(hidden(MoneyFormatter.string(minorUnits: item.spentMinor)))
                Spacer()
                Text("de \(hidden(MoneyFormatter.string(minorUnits: item.limitMinor)))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var privacyChartPlaceholder: some View {
        Label("Gráfico oculto por privacidad", systemImage: "eye.slash")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
            .accessibilityLabel("Datos del gráfico ocultos")
    }

    private var lastUpdateText: String {
        guard let latestAccountUpdate else { return "Sin actualizar" }
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(latestAccountUpdate) {
            return "Hoy, \(latestAccountUpdate.formatted(.dateTime.hour().minute()))"
        }
        if calendar.isDateInYesterday(latestAccountUpdate) {
            return "Ayer"
        }
        return latestAccountUpdate.formatted(.dateTime.day().month(.abbreviated))
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
        if currentMonthChange > 0 { return .green }
        if currentMonthChange < 0 { return .red }
        return .secondary
    }

    private var budgetOverallTint: Color {
        if totalBudgetFraction > 1 { return .red }
        if totalBudgetFraction >= 0.85 { return .orange }
        return .accentColor
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

    private func isStale(_ account: FinancialAccount) -> Bool {
        let limit = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: -30,
            to: .now
        ) ?? .now
        return account.lastUpdatedAt < limit
    }

    private func budgetTint(_ item: BudgetProgress) -> Color {
        if item.spentMinor > item.limitMinor { return .red }
        if item.fraction >= 0.85 { return .orange }
        return Color(hex: item.category.colorHex)
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
