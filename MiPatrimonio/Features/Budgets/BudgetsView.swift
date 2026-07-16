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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    monthSelector
                }

                if !progressItems.filter({ $0.limitMinor > 0 }).isEmpty {
                    Section("Vista general") {
                        budgetChart
                            .listRowInsets(EdgeInsets())
                            .padding(.vertical)
                    }
                }

                Section("Categorías") {
                    ForEach(expenseCategories) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            BudgetRow(
                                item: item(for: category),
                                category: category
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Las transferencias propias no consumen presupuesto. Los gastos y las comisiones sí se incluyen en su categoría.")
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
    }

    @ViewBuilder
    private var budgetChart: some View {
        if hideAmounts {
            Label("Gráfico oculto por privacidad", systemImage: "eye.slash")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            Chart {
                ForEach(progressItems.filter { $0.limitMinor > 0 }.prefix(7)) { item in
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
        .frame(height: 230)
        .chartLegend(position: .bottom)
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().font(.caption2)
                }
            }
        }
    }

    private func item(for category: FinanceCategory) -> BudgetProgress {
        if let item = progressItems.first(where: { $0.category.id == category.id }) {
            return item
        }
        return BudgetProgress(category: category, limitMinor: 0, spentMinor: 0)
    }

    private func existingBudget(for category: FinanceCategory) -> MonthlyBudget? {
        budgets.first {
            $0.category?.id == category.id
                && Calendar.autoupdatingCurrent.isDate($0.monthStart, equalTo: selectedMonth, toGranularity: .month)
        }
    }
}

private struct BudgetRow: View {
    let item: BudgetProgress
    let category: FinanceCategory
    @AppStorage("hideAmounts") private var hideAmounts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(category.name, systemImage: category.systemImage)
                    .foregroundStyle(.primary)
                Spacer()
                Text(item.statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            if item.limitMinor > 0 {
                ProgressView(value: Swift.min(item.fraction, 1))
                    .tint(statusColor)
                HStack {
                    Text(hidden(MoneyFormatter.string(minorUnits: item.spentMinor)))
                    Spacer()
                    Text("Disponible: \(hidden(MoneyFormatter.string(minorUnits: item.availableMinor)))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Toca para definir un presupuesto mensual")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
