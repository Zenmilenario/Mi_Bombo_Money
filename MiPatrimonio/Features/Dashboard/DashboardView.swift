import Charts
import SwiftData
import SwiftUI

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

    private var activeAccounts: [FinancialAccount] {
        accounts.filter { !$0.isArchived }
    }

    private var monthSummary: MonthlySummary {
        FinanceCalculator.monthlySummary(for: selectedMonth, transactions: transactions)
    }

    private var totalNetWorth: Int64 {
        FinanceCalculator.netWorth(
            accounts: activeAccounts,
            transactions: transactions,
            snapshots: snapshots,
            at: .now
        )
    }

    private var budgetItems: [BudgetProgress] {
        FinanceCalculator.budgetProgress(
            for: selectedMonth,
            categories: categories,
            budgets: budgets,
            transactions: transactions
        )
    }

    private var categorySpending: [CategorySpend] {
        FinanceCalculator.spendingByCategory(
            for: selectedMonth,
            categories: categories,
            transactions: transactions
        )
    }

    private var netWorthHistory: [NetWorthPoint] {
        FinanceCalculator.netWorthHistory(
            endingAt: selectedMonth,
            months: 12,
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
            guard movement.isActive, movement.nextDueDate <= Date.now.endOfMonth() else { return false }
            guard let endDate = movement.endDate else { return true }
            return endDate >= .now
        }.count
    }

    private var staleAccountCount: Int {
        let limit = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -30, to: .now) ?? .now
        return activeAccounts.filter { $0.lastUpdatedAt < limit }.count
    }

    private var overBudgetCount: Int {
        budgetItems.filter { $0.limitMinor > 0 && $0.spentMinor > $0.limitMinor }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 18) {
                    netWorthCard
                    monthSelector
                    monthlyMetrics
                    alertsSection
                    accountsSection
                    budgetsSection
                    goalsSection
                    netWorthChart
                    categoryChart
                    budgetChart
                }
                .padding()
                .padding(.bottom, 86)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Inicio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation { hideAmounts.toggle() }
                    } label: {
                        Image(systemName: hideAmounts ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(hideAmounts ? "Mostrar importes" : "Ocultar importes")
                }
            }
        }
    }

    private var netWorthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Patrimonio total", systemImage: "sum")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Actualizado hoy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PrivacyAmountText(
                minorUnits: totalNetWorth,
                font: .system(size: 38, weight: .bold, design: .rounded),
                weight: .bold
            )

            let annualInterest = activeAccounts.reduce(Int64.zero) { partial, account in
                partial + FinanceCalculator.estimatedAnnualInterestMinor(
                    account: account,
                    transactions: transactions,
                    snapshots: snapshots
                )
            }
            HStack {
                Label("Interés anual estimado", systemImage: "percent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                PrivacyAmountText(minorUnits: annualInterest, font: .subheadline, weight: .semibold)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }

    private var monthSelector: some View {
        HStack {
            Button {
                selectedMonth = selectedMonth.addingMonths(-1).startOfMonth()
            } label: {
                Image(systemName: "chevron.left")
            }

            Spacer()
            Text(selectedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
            Spacer()

            Button {
                selectedMonth = selectedMonth.addingMonths(1).startOfMonth()
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .buttonStyle(.bordered)
    }

    private var monthlyMetrics: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                MetricCard(
                    title: "Ingresos",
                    value: hidden(MoneyFormatter.string(minorUnits: monthSummary.incomeMinor)),
                    systemImage: "arrow.down.circle",
                    tint: .green
                )
                MetricCard(
                    title: "Gastos",
                    value: hidden(MoneyFormatter.string(minorUnits: monthSummary.expenseMinor)),
                    systemImage: "arrow.up.circle",
                    tint: .red
                )
                MetricCard(
                    title: "Ahorro neto",
                    value: hidden(MoneyFormatter.string(minorUnits: monthSummary.netSavingsMinor)),
                    systemImage: "banknote",
                    tint: .blue
                )
                MetricCard(
                    title: "Tasa de ahorro",
                    value: hideAmounts ? "••••" : MoneyFormatter.percent(monthSummary.savingsRate),
                    systemImage: "gauge.with.dots.needle.50percent",
                    tint: .orange
                )
            }
        }
    }

    @ViewBuilder
    private var alertsSection: some View {
        let possibleItems: [(String, String, Color)?] = [
            duplicateCount > 0 ? ("\(duplicateCount) posible(s) duplicado(s)", "doc.on.doc", .orange) : nil,
            overBudgetCount > 0 ? ("\(overBudgetCount) presupuesto(s) superado(s)", "exclamationmark.triangle", .red) : nil,
            dueRecurringCount > 0 ? ("\(dueRecurringCount) movimiento(s) periódico(s) próximo(s)", "calendar.badge.clock", .blue) : nil,
            staleAccountCount > 0 ? ("\(staleAccountCount) cuenta(s) sin actualizar en 30 días", "clock.badge.exclamationmark", .orange) : nil,
        ]
        let alertItems = possibleItems.compactMap { $0 }

        if !alertItems.isEmpty {
            SectionCard("Avisos importantes") {
                VStack(spacing: 12) {
                    ForEach(Array(alertItems.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Image(systemName: item.1)
                                .foregroundStyle(item.2)
                                .frame(width: 24)
                            Text(item.0)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private var accountsSection: some View {
        SectionCard("Saldo por cuenta") {
            if activeAccounts.isEmpty {
                Text("Añade tu primera cuenta desde la pestaña Cuentas.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(activeAccounts.enumerated()), id: \.offset) { index, account in
                        HStack(spacing: 12) {
                            Image(systemName: account.type.systemImage)
                                .foregroundStyle(Color(hex: account.institution?.colorHex ?? "#1F6B7A"))
                                .frame(width: 34, height: 34)
                                .background(Color.secondary.opacity(0.09), in: Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                    .font(.subheadline.weight(.semibold))
                                Text(account.institution?.name ?? account.type.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
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
                        .padding(.vertical, 9)
                        if index < activeAccounts.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private var budgetsSection: some View {
        SectionCard("Estado de presupuestos") {
            if budgetItems.isEmpty {
                Text("Todavía no hay presupuestos para este mes.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 14) {
                    ForEach(budgetItems.prefix(5)) { item in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(item.category.name)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(item.statusText)
                                    .font(.caption)
                                    .foregroundStyle(item.spentMinor > item.limitMinor ? Color.red : Color.secondary)
                            }
                            ProgressView(value: Swift.min(item.fraction, 1))
                                .tint(item.spentMinor > item.limitMinor ? .red : Color(hex: item.category.colorHex))
                            HStack {
                                Text(hidden(MoneyFormatter.string(minorUnits: item.spentMinor)))
                                Spacer()
                                Text("de \(hidden(MoneyFormatter.string(minorUnits: item.limitMinor)))")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var goalsSection: some View {
        SectionCard("Objetivos de ahorro") {
            if goals.isEmpty {
                Text("Crea objetivos desde Ajustes para seguir tu progreso.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 14) {
                    ForEach(goals.prefix(3)) { goal in
                        let current = goalCurrentAmount(goal)
                        let target = Swift.max(0, goal.targetAmountMinor)
                        let fraction = target > 0 ? Swift.min(1, Double(current) / Double(target)) : 0

                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Label(goal.name, systemImage: fraction >= 1 ? "checkmark.seal.fill" : "target")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color(hex: goal.colorHex))
                                Spacer()
                                Text(fraction, format: .percent.precision(.fractionLength(0)))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: fraction)
                                .tint(Color(hex: goal.colorHex))
                            HStack {
                                PrivacyAmountText(minorUnits: current, font: .caption, weight: .semibold)
                                Spacer()
                                Text("de")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                PrivacyAmountText(minorUnits: target, font: .caption, weight: .semibold)
                            }
                        }
                    }
                }
            }
        }
    }

    private func goalCurrentAmount(_ goal: SavingsGoal) -> Int64 {
        guard let account = goal.linkedAccount else {
            return Swift.max(0, goal.currentAmountMinor)
        }
        return Swift.max(0, FinanceCalculator.balance(
            of: account,
            transactions: transactions,
            snapshots: snapshots
        ))
    }

    private var netWorthChart: some View {
        SectionCard("Evolución del patrimonio") {
            if hideAmounts {
                privacyChartPlaceholder
            } else if netWorthHistory.isEmpty {
                Text("No hay datos suficientes.")
                    .foregroundStyle(.secondary)
            } else {
                Chart(netWorthHistory) { point in
                    AreaMark(
                        x: .value("Mes", point.date),
                        y: .value("Patrimonio", Double(point.valueMinor) / 100)
                    )
                    .foregroundStyle(.linearGradient(
                        colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))

                    LineMark(
                        x: .value("Mes", point.date),
                        y: .value("Patrimonio", Double(point.valueMinor) / 100)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                }
                .frame(height: 220)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(number, format: .currency(code: "EUR").notation(.compactName))
                            }
                        }
                    }
                }
            }
        }
    }

    private var categoryChart: some View {
        SectionCard("Gastos por categoría") {
            if hideAmounts {
                privacyChartPlaceholder
            } else if categorySpending.isEmpty {
                Text("No hay gastos en el mes seleccionado.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                Chart(categorySpending.prefix(8)) { item in
                    BarMark(
                        x: .value("Gasto", Double(item.spentMinor) / 100),
                        y: .value("Categoría", item.category.name)
                    )
                    .foregroundStyle(Color(hex: item.category.colorHex))
                    .cornerRadius(5)
                }
                .frame(height: CGFloat(Swift.max(220, categorySpending.prefix(8).count * 38)))
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(number, format: .currency(code: "EUR").notation(.compactName))
                            }
                        }
                    }
                }
            }
        }
    }

    private var budgetChart: some View {
        SectionCard("Presupuesto frente a gasto real") {
            if hideAmounts {
                privacyChartPlaceholder
            } else if budgetItems.filter({ $0.limitMinor > 0 }).isEmpty {
                Text("Crea presupuestos para comparar lo planificado con el gasto real.")
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(budgetItems.filter { $0.limitMinor > 0 }.prefix(6)) { item in
                        BarMark(
                            x: .value("Categoría", item.category.name),
                            y: .value("Importe", Double(item.limitMinor) / 100)
                        )
                        .foregroundStyle(by: .value("Serie", "Presupuesto"))
                        .position(by: .value("Serie", "Presupuesto"))

                        BarMark(
                            x: .value("Categoría", item.category.name),
                            y: .value("Importe", Double(item.spentMinor) / 100)
                        )
                        .foregroundStyle(by: .value("Serie", "Gasto real"))
                        .position(by: .value("Serie", "Gasto real"))
                    }
                }
                .frame(height: 240)
                .chartLegend(position: .bottom)
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine()
                        AxisValueLabel().font(.caption2)
                    }
                }
            }
        }
    }

    private var privacyChartPlaceholder: some View {
        Label("Gráfico oculto por privacidad", systemImage: "eye.slash")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .accessibilityLabel("Datos del gráfico ocultos")
    }

    private func hidden(_ value: String) -> String {
        hideAmounts ? "••••••" : value
    }
}
