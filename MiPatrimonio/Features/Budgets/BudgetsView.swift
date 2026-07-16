import Charts
import SwiftData
import SwiftUI

struct BudgetsView: View {
    @AppStorage("hideAmounts") private var hideAmounts = false
    @Query(sort: \FinanceCategory.sortOrder) private var categories: [FinanceCategory]
    @Query(sort: \MonthlyBudget.monthStart, order: .reverse) private var budgets: [MonthlyBudget]
    @Query(sort: \FinancialTransaction.date, order: .reverse) private var transactions: [FinancialTransaction]

    @State private var selectedMonth = Date.now.startOfMonth()
    @State private var selectedCategory: FinanceCategory?

    private var expenseCategories: [FinanceCategory] {
        categories.filter {
            !$0.isArchived && ($0.kind == .expense || $0.kind == .both)
        }
    }

    private var progressItems: [BudgetProgress] {
        FinanceCalculator.budgetProgress(
            for: selectedMonth,
            categories: expenseCategories,
            budgets: budgets,
            transactions: transactions
        )
    }

    private var budgetedItems: [BudgetProgress] {
        progressItems.filter { $0.limitMinor > 0 }
    }

    private var attentionItems: [BudgetProgress] {
        budgetedItems
            .filter { $0.spentMinor > $0.limitMinor || $0.fraction >= 0.85 }
            .sorted { $0.fraction > $1.fraction }
    }

    private var healthyItems: [BudgetProgress] {
        budgetedItems
            .filter { $0.spentMinor <= $0.limitMinor && $0.fraction < 0.85 }
            .sorted { $0.fraction > $1.fraction }
    }

    private var unbudgetedCategories: [FinanceCategory] {
        expenseCategories.filter { item(for: $0).limitMinor == 0 }
    }

    private var totalBudgetMinor: Int64 {
        budgetedItems.reduce(Int64.zero) { $0 + $1.limitMinor }
    }

    private var totalSpentMinor: Int64 {
        budgetedItems.reduce(Int64.zero) { $0 + $1.spentMinor }
    }

    private var unbudgetedSpentMinor: Int64 {
        progressItems
            .filter { $0.limitMinor == 0 }
            .reduce(Int64.zero) { $0 + $1.spentMinor }
    }

    private var totalAvailableMinor: Int64 {
        totalBudgetMinor - totalSpentMinor
    }

    private var totalFraction: Double {
        guard totalBudgetMinor > 0 else { return 0 }
        return Double(totalSpentMinor) / Double(totalBudgetMinor)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    monthSelector
                }

                Section {
                    BudgetOverviewCard(
                        budgetMinor: totalBudgetMinor,
                        spentMinor: totalSpentMinor,
                        availableMinor: totalAvailableMinor,
                        unbudgetedSpentMinor: unbudgetedSpentMinor,
                        fraction: totalFraction,
                        pacingText: budgetPacingText
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if !budgetedItems.isEmpty {
                    Section {
                        NavigationLink {
                            BudgetAnalysisView(initialMonth: selectedMonth)
                        } label: {
                            Label("Análisis: presupuesto frente a gasto", systemImage: "chart.bar.xaxis")
                        }
                    }
                }

                if !attentionItems.isEmpty {
                    Section("Necesitan atención") {
                        ForEach(attentionItems) { item in
                            budgetButton(item)
                        }
                    }
                }

                if !healthyItems.isEmpty {
                    Section("Dentro del presupuesto") {
                        ForEach(healthyItems) { item in
                            budgetButton(item)
                        }
                    }
                }

                if !unbudgetedCategories.isEmpty {
                    Section {
                        ForEach(unbudgetedCategories) { category in
                            budgetButton(item(for: category))
                        }
                    } header: {
                        Text("Sin presupuesto")
                    } footer: {
                        Text("Toca una categoría para definir su límite mensual.")
                    }
                }

                Section {
                    Text("Las transferencias entre tus propias cuentas no consumen presupuesto. Los gastos y las comisiones sí se incluyen en su categoría.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Presupuestos")
            .sheet(item: $selectedCategory) { category in
                BudgetEditorView(
                    category: category,
                    month: selectedMonth,
                    existingBudget: existingBudget(for: category)
                )
            }
        }
    }

    private var monthSelector: some View {
        HStack {
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
                Text("Presupuesto mensual")
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

    private func budgetButton(_ item: BudgetProgress) -> some View {
        Button {
            selectedCategory = item.category
        } label: {
            BudgetRow(item: item, category: item.category)
        }
        .buttonStyle(.plain)
    }

    private var budgetPacingText: String {
        guard totalBudgetMinor > 0 else {
            return "Define límites para empezar a controlar el mes"
        }

        let currentMonth = Date.now.startOfMonth()
        let calendar = Calendar.autoupdatingCurrent

        if selectedMonth > currentMonth {
            return "Presupuesto preparado para un mes futuro"
        }

        if selectedMonth < currentMonth {
            if totalAvailableMinor >= 0 {
                return "Cerraste el mes por debajo del presupuesto"
            }
            return "Cerraste el mes por encima del presupuesto"
        }

        let day = calendar.component(.day, from: .now)
        let daysInMonth = calendar.range(of: .day, in: .month, for: .now)?.count ?? 30
        let expectedFraction = Double(day) / Double(daysInMonth)
        let expectedSpend = Int64((Double(totalBudgetMinor) * expectedFraction).rounded())
        let difference = expectedSpend - totalSpentMinor

        if difference >= 0 {
            return "Vas \(hidden(MoneyFormatter.string(minorUnits: difference))) por debajo del ritmo previsto"
        }
        return "Vas \(hidden(MoneyFormatter.string(minorUnits: Swift.abs(difference)))) por encima del ritmo previsto"
    }

    private func item(for category: FinanceCategory) -> BudgetProgress {
        if let item = progressItems.first(where: { $0.category.id == category.id }) {
            return item
        }
        return BudgetProgress(
            category: category,
            limitMinor: 0,
            spentMinor: 0
        )
    }

    private func existingBudget(for category: FinanceCategory) -> MonthlyBudget? {
        budgets.first {
            $0.category?.id == category.id
                && Calendar.autoupdatingCurrent.isDate(
                    $0.monthStart,
                    equalTo: selectedMonth,
                    toGranularity: .month
                )
        }
    }

    private func hidden(_ value: String) -> String {
        hideAmounts ? "••••••" : value
    }
}

private struct BudgetOverviewCard: View {
    let budgetMinor: Int64
    let spentMinor: Int64
    let availableMinor: Int64
    let unbudgetedSpentMinor: Int64
    let fraction: Double
    let pacingText: String

    private var tint: Color {
        if fraction > 1 { return .red }
        if fraction >= 0.85 { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Vista general")
                    .font(.headline)
                Spacer()
                StatusPill(
                    text: statusText,
                    systemImage: statusImage,
                    tint: tint
                )
            }

            if budgetMinor > 0 {
                HStack(spacing: 14) {
                    FinancialSummaryTile(
                        title: "Presupuestado",
                        minorUnits: budgetMinor,
                        tint: .primary
                    )

                    Divider()

                    FinancialSummaryTile(
                        title: "Gastado",
                        minorUnits: spentMinor,
                        tint: fraction > 1 ? .red : .primary
                    )
                }
                .frame(minHeight: 54)

                Divider()

                HStack {
                    Text("Disponible")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    PrivacyAmountText(
                        minorUnits: availableMinor,
                        font: .headline,
                        weight: .semibold,
                        signed: true
                    )
                    .foregroundStyle(availableMinor >= 0 ? .green : .red)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Swift.min(fraction, 1))
                        .tint(tint)

                    HStack(alignment: .firstTextBaseline) {
                        Text(pacingText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                    }
                }

                if unbudgetedSpentMinor > 0 {
                    Label {
                        HStack(spacing: 4) {
                            Text("Gasto sin presupuesto:")
                            PrivacyAmountText(
                                minorUnits: unbudgetedSpentMinor,
                                font: .caption,
                                weight: .semibold
                            )
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "chart.pie")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    Text("Aún no has definido límites para este mes.")
                        .font(.subheadline.weight(.semibold))
                    Text("Toca cualquier categoría para crear su presupuesto mensual.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(AppDesign.cardPadding)
        .background(
            AppDesign.cardBackground,
            in: RoundedRectangle(cornerRadius: AppDesign.cardRadius, style: .continuous)
        )
    }

    private var statusText: String {
        guard budgetMinor > 0 else { return "Sin configurar" }
        if fraction > 1 { return "Superado" }
        if fraction >= 0.85 { return "Cerca del límite" }
        return "En control"
    }

    private var statusImage: String {
        guard budgetMinor > 0 else { return "plus.circle" }
        if fraction > 1 { return "exclamationmark.triangle.fill" }
        if fraction >= 0.85 { return "exclamationmark.circle.fill" }
        return "checkmark.circle.fill"
    }
}

private struct BudgetRow: View {
    let item: BudgetProgress
    let category: FinanceCategory

    @AppStorage("hideAmounts") private var hideAmounts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: category.systemImage)
                    .foregroundStyle(Color(hex: category.colorHex))
                    .frame(width: 34, height: 34)
                    .background(Color(hex: category.colorHex).opacity(0.11), in: Circle())

                Text(category.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                StatusPill(
                    text: item.statusText,
                    tint: statusColor
                )
            }

            if item.limitMinor > 0 {
                ProgressView(value: Swift.min(item.fraction, 1))
                    .tint(statusColor)

                HStack {
                    Text("Gastado: \(hidden(MoneyFormatter.string(minorUnits: item.spentMinor)))")
                    Spacer()
                    Text("Disponible: \(hidden(MoneyFormatter.string(minorUnits: item.availableMinor)))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(
                    item.spentMinor > 0
                        ? "Has gastado \(hidden(MoneyFormatter.string(minorUnits: item.spentMinor))) sin definir un límite"
                        : "Toca para definir un presupuesto mensual"
                )
                .font(.caption)
                .foregroundStyle(item.spentMinor > 0 ? Color.orange : Color.secondary)
            }
        }
        .padding(.vertical, 5)
    }

    private var statusColor: Color {
        if item.limitMinor == 0 { return .secondary }
        if item.spentMinor > item.limitMinor { return .red }
        if item.fraction >= 0.85 { return .orange }
        return Color(hex: category.colorHex)
    }

    private func hidden(_ value: String) -> String {
        hideAmounts ? "••••••" : value
    }
}

private struct BudgetAnalysisView: View {
    @Query(sort: \FinanceCategory.sortOrder) private var categories: [FinanceCategory]
    @Query(sort: \MonthlyBudget.monthStart, order: .reverse) private var budgets: [MonthlyBudget]
    @Query(sort: \FinancialTransaction.date, order: .reverse) private var transactions: [FinancialTransaction]

    @AppStorage("hideAmounts") private var hideAmounts = false
    @State private var selectedMonth: Date

    init(initialMonth: Date) {
        _selectedMonth = State(initialValue: initialMonth.startOfMonth())
    }

    private var expenseCategories: [FinanceCategory] {
        categories.filter {
            !$0.isArchived && ($0.kind == .expense || $0.kind == .both)
        }
    }

    private var items: [BudgetProgress] {
        FinanceCalculator.budgetProgress(
            for: selectedMonth,
            categories: expenseCategories,
            budgets: budgets,
            transactions: transactions
        )
        .filter { $0.limitMinor > 0 }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: AppDesign.sectionSpacing) {
                monthSelector

                SectionCard(
                    "Presupuesto frente a gasto real",
                    subtitle: "Compara lo planificado con lo que realmente has gastado"
                ) {
                    if hideAmounts {
                        Label("Gráfico oculto por privacidad", systemImage: "eye.slash")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 190)
                    } else if items.isEmpty {
                        Text("No hay presupuestos para el mes seleccionado.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        Chart {
                            ForEach(items.prefix(7)) { item in
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
                        .frame(height: 250)
                        .chartLegend(position: .bottom)
                        .chartXAxis {
                            AxisMarks { _ in
                                AxisValueLabel()
                                    .font(.caption2)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Presupuesto frente a gasto real")
                        .accessibilityValue(accessibilitySummary)
                    }
                }

                if !items.isEmpty {
                    SectionCard("Comparativa por categoría") {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Label(item.category.name, systemImage: item.category.systemImage)
                                            .font(.subheadline.weight(.medium))
                                        Spacer()
                                        PrivacyAmountText(
                                            minorUnits: item.availableMinor,
                                            font: .subheadline,
                                            weight: .semibold,
                                            signed: true
                                        )
                                        .foregroundStyle(item.availableMinor >= 0 ? .green : .red)
                                    }

                                    ProgressView(value: Swift.min(item.fraction, 1))
                                        .tint(item.spentMinor > item.limitMinor ? .red : Color(hex: item.category.colorHex))
                                }
                                .padding(.vertical, 10)

                                if index < items.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(AppDesign.pageBackground)
        .navigationTitle("Análisis de presupuesto")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var monthSelector: some View {
        HStack {
            Button {
                selectedMonth = selectedMonth.addingMonths(-1).startOfMonth()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Mes anterior")

            Spacer()

            Text(selectedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)

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

    private var accessibilitySummary: String {
        guard let highest = items.max(by: { $0.fraction < $1.fraction }) else {
            return "Sin datos"
        }
        return "La categoría con mayor uso del presupuesto es \(highest.category.name), con \(highest.fraction.formatted(.percent.precision(.fractionLength(0))))."
    }
}

private struct BudgetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let category: FinanceCategory
    let month: Date
    let existingBudget: MonthlyBudget?

    @State private var limitText: String
    @State private var notes: String
    @State private var errorMessage: String?

    init(category: FinanceCategory, month: Date, existingBudget: MonthlyBudget?) {
        self.category = category
        self.month = month
        self.existingBudget = existingBudget
        _limitText = State(initialValue: existingBudget.map {
            String(format: "%.2f", Double($0.limitMinor) / 100)
        } ?? "")
        _notes = State(initialValue: existingBudget?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Categoría", value: category.name)
                    LabeledContent("Mes", value: month.formatted(.dateTime.month(.wide).year()))
                }

                Section("Presupuesto") {
                    TextField("Límite mensual", text: $limitText)
                        .keyboardType(.decimalPad)
                    TextField("Notas", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                if existingBudget != nil {
                    Section {
                        Button("Eliminar presupuesto", role: .destructive) {
                            deleteBudget()
                        }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Presupuesto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
                }
            }
        }
    }

    private func save() {
        guard let limit = MoneyParser.minorUnits(from: limitText), limit >= 0 else {
            errorMessage = "Introduce un límite válido."
            return
        }

        if let existingBudget {
            existingBudget.limitMinor = limit
            existingBudget.notes = notes
            existingBudget.monthStart = month.startOfMonth()
            existingBudget.updatedAt = .now
        } else {
            modelContext.insert(MonthlyBudget(
                monthStart: month.startOfMonth(),
                limitMinor: limit,
                notes: notes,
                category: category
            ))
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteBudget() {
        guard let existingBudget else { return }
        modelContext.delete(existingBudget)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
