import Charts
import SwiftData
import SwiftUI

private enum TransactionDateFilter: String, CaseIterable, Identifiable {
    case all
    case thisMonth
    case last30Days
    case thisYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Todas las fechas"
        case .thisMonth: "Este mes"
        case .last30Days: "Últimos 30 días"
        case .thisYear: "Este año"
        }
    }
}

struct TransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialTransaction.date, order: .reverse) private var transactions: [FinancialTransaction]
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]
    @Query(sort: \FinanceCategory.sortOrder) private var categories: [FinanceCategory]

    @State private var searchText = ""
    @State private var selectedAccountID: UUID?
    @State private var selectedCategoryID: UUID?
    @State private var selectedType: TransactionType?
    @State private var dateFilter: TransactionDateFilter = .all
    @State private var showOnlyDuplicates = false
    @State private var showingFilters = false
    @State private var editingTransaction: FinancialTransaction?
    @State private var deletionError: String?

    private var filteredTransactions: [FinancialTransaction] {
        transactions.filter { transaction in
            if let selectedAccountID,
               transaction.sourceAccount?.id != selectedAccountID,
               transaction.destinationAccount?.id != selectedAccountID
            {
                return false
            }

            if let selectedCategoryID,
               transaction.category?.id != selectedCategoryID
            {
                return false
            }

            if let selectedType,
               transaction.type != selectedType
            {
                return false
            }

            if showOnlyDuplicates,
               transaction.duplicateState != .possible
            {
                return false
            }

            if !matchesDateFilter(transaction.date) {
                return false
            }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }

            return [
                transaction.descriptionText,
                transaction.notes,
                transaction.sourceAccount?.name ?? "",
                transaction.destinationAccount?.name ?? "",
                transaction.category?.name ?? "",
                transaction.type.title,
            ].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var groupedDates: [Date] {
        Array(
            Dictionary(grouping: filteredTransactions) {
                Calendar.autoupdatingCurrent.startOfDay(for: $0.date)
            }.keys
        )
        .sorted(by: >)
    }

    private var filteredIncomeMinor: Int64 {
        filteredTransactions
            .filter { $0.type.countsAsIncome }
            .reduce(Int64.zero) { $0 + Swift.abs($1.amountMinor) }
    }

    private var filteredExpenseMinor: Int64 {
        filteredTransactions
            .filter { $0.type.countsAsExpense }
            .reduce(Int64.zero) { $0 + Swift.abs($1.amountMinor) }
    }

    private var duplicateCount: Int {
        transactions.filter { $0.duplicateState == .possible }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    ContentUnavailableView(
                        "Sin movimientos",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Añade un movimiento con el botón azul o importa un archivo CSV.")
                    )
                } else {
                    List {
                        Section {
                            TransactionPeriodSummaryCard(
                                transactionCount: filteredTransactions.count,
                                incomeMinor: filteredIncomeMinor,
                                expenseMinor: filteredExpenseMinor
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }

                        if duplicateCount > 0 && !showOnlyDuplicates {
                            Section {
                                Button {
                                    showOnlyDuplicates = true
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.on.doc.fill")
                                            .foregroundStyle(.orange)
                                            .frame(width: 36, height: 36)
                                            .background(Color.orange.opacity(0.11), in: Circle())

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(
                                                duplicateCount == 1
                                                    ? "Revisar 1 posible duplicado"
                                                    : "Revisar \(duplicateCount) posibles duplicados"
                                            )
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)

                                            Text("Comprueba los movimientos antes de conservarlos.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if activeFilterCount > 0 {
                            Section {
                                activeFilters
                                    .listRowInsets(
                                        EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
                                    )
                            } header: {
                                HStack {
                                    Text("Filtros activos")
                                    Spacer()
                                    Button("Limpiar") {
                                        resetFilters()
                                    }
                                    .font(.caption.weight(.semibold))
                                    .textCase(nil)
                                }
                            }
                        }

                        Section {
                            NavigationLink {
                                SpendingAnalysisView()
                            } label: {
                                Label("Análisis de gastos", systemImage: "chart.bar.xaxis")
                            }
                        }

                        if filteredTransactions.isEmpty {
                            Section {
                                ContentUnavailableView(
                                    "Sin resultados",
                                    systemImage: "line.3.horizontal.decrease.circle",
                                    description: Text("Prueba a cambiar la búsqueda o limpiar los filtros.")
                                )
                                .frame(maxWidth: .infinity, minHeight: 220)
                            }
                        } else {
                            ForEach(groupedDates, id: \.self) { date in
                                Section(
                                    date.formatted(
                                        .dateTime.weekday(.wide).day().month(.wide).year()
                                    )
                                ) {
                                    ForEach(transactions(for: date)) { transaction in
                                        Button {
                                            editingTransaction = transaction
                                        } label: {
                                            TransactionRow(transaction: transaction)
                                        }
                                        .buttonStyle(.plain)
                                        .swipeActions(edge: .leading) {
                                            Button {
                                                editingTransaction = transaction
                                            } label: {
                                                Label("Editar", systemImage: "pencil")
                                            }
                                            .tint(.blue)
                                        }
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                delete(transaction)
                                            } label: {
                                                Label("Eliminar", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Movimientos")
            .searchable(
                text: $searchText,
                prompt: "Buscar descripción, cuenta o categoría"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingFilters = true
                    } label: {
                        Image(
                            systemName: activeFilterCount > 0
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle"
                        )
                    }
                    .accessibilityLabel("Filtros")
                }
            }
            .sheet(isPresented: $showingFilters) {
                NavigationStack {
                    TransactionFiltersView(
                        selectedAccountID: $selectedAccountID,
                        selectedCategoryID: $selectedCategoryID,
                        selectedType: $selectedType,
                        dateFilter: $dateFilter,
                        showOnlyDuplicates: $showOnlyDuplicates,
                        accounts: accounts.filter { !$0.isArchived },
                        categories: categories.filter { !$0.isArchived }
                    )
                }
            }
            .sheet(item: $editingTransaction) { transaction in
                TransactionFormView(transaction: transaction)
            }
            .alert(
                "No se pudo eliminar",
                isPresented: Binding(
                    get: { deletionError != nil },
                    set: { isPresented in
                        if !isPresented {
                            deletionError = nil
                        }
                    }
                )
            ) {
                Button("Aceptar", role: .cancel) {
                    deletionError = nil
                }
            } message: {
                Text(deletionError ?? "Error desconocido")
            }
        }
    }

    private var activeFilterCount: Int {
        [
            selectedAccountID != nil,
            selectedCategoryID != nil,
            selectedType != nil,
            dateFilter != .all,
            showOnlyDuplicates,
        ]
        .filter { $0 }
        .count
    }

    private var activeFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let selectedAccountID,
                   let account = accounts.first(where: { $0.id == selectedAccountID })
                {
                    FilterChip(
                        title: account.name,
                        systemImage: "building.columns",
                        onRemove: { self.selectedAccountID = nil }
                    )
                }

                if let selectedCategoryID,
                   let category = categories.first(where: { $0.id == selectedCategoryID })
                {
                    FilterChip(
                        title: category.name,
                        systemImage: category.systemImage,
                        tint: Color(hex: category.colorHex),
                        onRemove: { self.selectedCategoryID = nil }
                    )
                }

                if let selectedType {
                    FilterChip(
                        title: selectedType.title,
                        systemImage: selectedType.systemImage,
                        onRemove: { self.selectedType = nil }
                    )
                }

                if dateFilter != .all {
                    FilterChip(
                        title: dateFilter.title,
                        systemImage: "calendar",
                        onRemove: { dateFilter = .all }
                    )
                }

                if showOnlyDuplicates {
                    FilterChip(
                        title: "Posibles duplicados",
                        systemImage: "doc.on.doc",
                        tint: .orange,
                        onRemove: { showOnlyDuplicates = false }
                    )
                }
            }
        }
    }

    private func transactions(for date: Date) -> [FinancialTransaction] {
        filteredTransactions.filter {
            Calendar.autoupdatingCurrent.isDate($0.date, inSameDayAs: date)
        }
    }

    private func matchesDateFilter(_ date: Date) -> Bool {
        let calendar = Calendar.autoupdatingCurrent

        switch dateFilter {
        case .all:
            return true
        case .thisMonth:
            return calendar.isDate(date, equalTo: .now, toGranularity: .month)
                && calendar.isDate(date, equalTo: .now, toGranularity: .year)
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
            return date >= start && date <= .now
        case .thisYear:
            return calendar.isDate(date, equalTo: .now, toGranularity: .year)
        }
    }

    private func resetFilters() {
        selectedAccountID = nil
        selectedCategoryID = nil
        selectedType = nil
        dateFilter = .all
        showOnlyDuplicates = false
    }

    private func delete(_ transaction: FinancialTransaction) {
        modelContext.delete(transaction)
        do {
            try modelContext.save()
        } catch {
            deletionError = error.localizedDescription
        }
    }
}

private struct TransactionPeriodSummaryCard: View {
    let transactionCount: Int
    let incomeMinor: Int64
    let expenseMinor: Int64

    private var netMinor: Int64 {
        incomeMinor - expenseMinor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Resumen del periodo")
                    .font(.headline)
                Spacer()
                Text("\(transactionCount) movimientos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                FinancialSummaryTile(
                    title: "Ingresos",
                    minorUnits: incomeMinor,
                    tint: .green
                )

                Divider()

                FinancialSummaryTile(
                    title: "Gastos",
                    minorUnits: expenseMinor,
                    tint: .red
                )
            }
            .frame(minHeight: 54)

            Divider()

            HStack {
                Label("Balance del periodo", systemImage: "equal.circle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                PrivacyAmountText(
                    minorUnits: netMinor,
                    font: .headline,
                    weight: .semibold,
                    signed: true
                )
                .foregroundStyle(netMinor >= 0 ? .blue : .red)
            }
        }
        .padding(AppDesign.cardPadding)
        .background(
            AppDesign.cardBackground,
            in: RoundedRectangle(cornerRadius: AppDesign.cardRadius, style: .continuous)
        )
    }
}

private struct TransactionRow: View {
    let transaction: FinancialTransaction
    @AppStorage("hideAmounts") private var hideAmounts = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transaction.category?.systemImage ?? transaction.type.systemImage)
                .foregroundStyle(Color(hex: transaction.category?.colorHex ?? "#4D7C8A"))
                .frame(width: 38, height: 38)
                .background(Color.secondary.opacity(0.09), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(transaction.descriptionText)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    if transaction.duplicateState == .possible {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Posible duplicado")
                    }
                }

                HStack(spacing: 6) {
                    Text(accountSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if transaction.type == .transfer {
                        StatusPill(
                            text: "Transferencia",
                            systemImage: "arrow.left.arrow.right",
                            tint: .blue
                        )
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(displayAmount)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(amountColor)

                Text(transaction.category?.name ?? transaction.type.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var accountSubtitle: String {
        if transaction.type == .transfer {
            return "\(transaction.sourceAccount?.name ?? "Sin origen") → \(transaction.destinationAccount?.name ?? "Sin destino")"
        }
        return transaction.sourceAccount?.name ?? "Sin cuenta"
    }

    private var displayAmount: String {
        guard !hideAmounts else { return "••••••" }

        let base = MoneyFormatter.string(
            minorUnits: transaction.amountMinor,
            currencyCode: transaction.sourceAccount?.currencyCode ?? "EUR"
        )

        switch transaction.type {
        case .income, .interest:
            return "+\(base)"
        case .expense, .fee:
            return "−\(base)"
        case .transfer:
            return base
        }
    }

    private var amountColor: Color {
        switch transaction.type {
        case .income, .interest: .green
        case .expense, .fee: .primary
        case .transfer: .blue
        }
    }
}

private struct TransactionFiltersView: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedAccountID: UUID?
    @Binding var selectedCategoryID: UUID?
    @Binding var selectedType: TransactionType?
    @Binding var dateFilter: TransactionDateFilter
    @Binding var showOnlyDuplicates: Bool

    let accounts: [FinancialAccount]
    let categories: [FinanceCategory]

    var body: some View {
        Form {
            Section("Periodo") {
                Picker("Fecha", selection: $dateFilter) {
                    ForEach(TransactionDateFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            }

            Section("Clasificación") {
                Picker("Cuenta", selection: $selectedAccountID) {
                    Text("Todas").tag(nil as UUID?)
                    ForEach(accounts) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }

                Picker("Categoría", selection: $selectedCategoryID) {
                    Text("Todas").tag(nil as UUID?)
                    ForEach(categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }

                Picker("Tipo", selection: $selectedType) {
                    Text("Todos").tag(nil as TransactionType?)
                    ForEach(TransactionType.allCases) { type in
                        Text(type.title).tag(Optional(type))
                    }
                }
            }

            Section("Revisión") {
                Toggle("Solo posibles duplicados", isOn: $showOnlyDuplicates)
            }

            Section {
                Button("Restablecer filtros", role: .destructive) {
                    selectedAccountID = nil
                    selectedCategoryID = nil
                    selectedType = nil
                    dateFilter = .all
                    showOnlyDuplicates = false
                }
            }
        }
        .navigationTitle("Filtros")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Hecho") {
                    dismiss()
                }
            }
        }
    }
}

private struct SpendingAnalysisView: View {
    @Query(sort: \FinanceCategory.sortOrder) private var categories: [FinanceCategory]
    @Query(sort: \FinancialTransaction.date, order: .reverse) private var transactions: [FinancialTransaction]

    @AppStorage("hideAmounts") private var hideAmounts = false
    @State private var selectedMonth = Date.now.startOfMonth()

    private var summary: MonthlySummary {
        FinanceCalculator.monthlySummary(
            for: selectedMonth,
            transactions: transactions
        )
    }

    private var spending: [CategorySpend] {
        FinanceCalculator.spendingByCategory(
            for: selectedMonth,
            categories: categories,
            transactions: transactions
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: AppDesign.sectionSpacing) {
                monthSelector

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ],
                    spacing: 12
                ) {
                    MetricCard(
                        title: "Gastos",
                        value: hidden(MoneyFormatter.string(minorUnits: summary.expenseMinor)),
                        systemImage: "arrow.up",
                        tint: .red
                    )

                    MetricCard(
                        title: "Categorías activas",
                        value: "\(spending.count)",
                        systemImage: "tag",
                        tint: .blue
                    )
                }

                SectionCard(
                    "Gastos por categoría",
                    subtitle: "Ordenados de mayor a menor"
                ) {
                    if hideAmounts {
                        Label("Gráfico oculto por privacidad", systemImage: "eye.slash")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if spending.isEmpty {
                        Text("No hay gastos en el mes seleccionado.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        Chart(spending.prefix(8)) { item in
                            BarMark(
                                x: .value("Gasto", Double(item.spentMinor) / 100),
                                y: .value("Categoría", item.category.name)
                            )
                            .foregroundStyle(Color(hex: item.category.colorHex))
                            .cornerRadius(5)
                        }
                        .frame(height: CGFloat(Swift.max(220, spending.prefix(8).count * 42)))
                        .chartXAxis {
                            AxisMarks { value in
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
                        .accessibilityLabel("Gastos por categoría")
                        .accessibilityValue(
                            spending.first.map {
                                "La categoría con más gasto es \($0.category.name), con \(MoneyFormatter.string(minorUnits: $0.spentMinor))."
                            } ?? "Sin datos"
                        )
                    }
                }

                if !spending.isEmpty {
                    SectionCard("Detalle") {
                        VStack(spacing: 0) {
                            ForEach(Array(spending.enumerated()), id: \.element.id) { index, item in
                                HStack(spacing: 12) {
                                    Image(systemName: item.category.systemImage)
                                        .foregroundStyle(Color(hex: item.category.colorHex))
                                        .frame(width: 34, height: 34)
                                        .background(
                                            Color(hex: item.category.colorHex).opacity(0.11),
                                            in: Circle()
                                        )

                                    Text(item.category.name)
                                        .font(.subheadline.weight(.medium))

                                    Spacer()

                                    PrivacyAmountText(
                                        minorUnits: item.spentMinor,
                                        font: .subheadline,
                                        weight: .semibold
                                    )
                                }
                                .padding(.vertical, 10)

                                if index < spending.count - 1 {
                                    Divider()
                                        .padding(.leading, 46)
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
        .navigationTitle("Análisis de gastos")
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

    private func hidden(_ value: String) -> String {
        hideAmounts ? "••••••" : value
    }
}

struct TransactionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]
    @Query(sort: \FinanceCategory.sortOrder) private var categories: [FinanceCategory]
    @Query(sort: \FinancialTransaction.date, order: .reverse) private var existingTransactions: [FinancialTransaction]

    private let transaction: FinancialTransaction?

    @State private var date: Date
    @State private var type: TransactionType
    @State private var sourceAccountID: UUID?
    @State private var destinationAccountID: UUID?
    @State private var categoryID: UUID?
    @State private var descriptionText: String
    @State private var amountText: String
    @State private var notes: String
    @State private var isReconciled: Bool
    @State private var validationMessage: String?

    init(transaction: FinancialTransaction? = nil) {
        self.transaction = transaction
        _date = State(initialValue: transaction?.date ?? .now)
        _type = State(initialValue: transaction?.type ?? .expense)
        _sourceAccountID = State(initialValue: transaction?.sourceAccount?.id)
        _destinationAccountID = State(initialValue: transaction?.destinationAccount?.id)
        _categoryID = State(initialValue: transaction?.category?.id)
        _descriptionText = State(initialValue: transaction?.descriptionText ?? "")
        _amountText = State(initialValue: transaction.map {
            String(format: "%.2f", Double($0.amountMinor) / 100)
        } ?? "")
        _notes = State(initialValue: transaction?.notes ?? "")
        _isReconciled = State(initialValue: transaction?.isReconciled ?? false)
    }

    private var activeAccounts: [FinancialAccount] {
        accounts.filter { !$0.isArchived }
    }

    private var allowedCategories: [FinanceCategory] {
        categories.filter { category in
            guard !category.isArchived else { return false }
            switch type {
            case .income, .interest:
                return category.kind == .income || category.kind == .both
            case .expense, .fee:
                return category.kind == .expense || category.kind == .both
            case .transfer:
                return category.kind == .transfer
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Movimiento") {
                    DatePicker("Fecha", selection: $date, displayedComponents: [.date])
                    Picker("Tipo", selection: $type) {
                        ForEach(TransactionType.allCases) { type in
                            Label(type.title, systemImage: type.systemImage).tag(type)
                        }
                    }
                    .onChange(of: type) { _, newType in
                        if newType == .transfer {
                            categoryID = categories.first(where: { $0.kind == .transfer })?.id
                        } else {
                            destinationAccountID = nil
                            if !allowedCategories.contains(where: { $0.id == categoryID }) {
                                categoryID = nil
                            }
                        }
                    }

                    Picker("Cuenta", selection: $sourceAccountID) {
                        Text("Seleccionar").tag(nil as UUID?)
                        ForEach(activeAccounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }

                    if type == .transfer {
                        Picker("Cuenta destino", selection: $destinationAccountID) {
                            Text("Seleccionar").tag(nil as UUID?)
                            ForEach(activeAccounts.filter { $0.id != sourceAccountID }) { account in
                                Text(account.name).tag(Optional(account.id))
                            }
                        }
                    }

                    Picker("Categoría", selection: $categoryID) {
                        Text("Sin categoría").tag(nil as UUID?)
                        ForEach(allowedCategories) { category in
                            Label(category.name, systemImage: category.systemImage)
                                .tag(Optional(category.id))
                        }
                    }
                }

                Section("Detalle") {
                    TextField("Descripción", text: $descriptionText)
                    TextField("Importe", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notas", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                    Toggle("Conciliado", isOn: $isReconciled)
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(transaction == nil ? "Nuevo movimiento" : "Editar movimiento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        guard let amountMinor = MoneyParser.minorUnits(from: amountText), amountMinor != 0 else {
            validationMessage = "Introduce un importe válido mayor que cero."
            return
        }
        guard let sourceAccount = activeAccounts.first(where: { $0.id == sourceAccountID }) else {
            validationMessage = "Selecciona una cuenta."
            return
        }
        let destinationAccount = activeAccounts.first(where: { $0.id == destinationAccountID })
        if type == .transfer {
            guard let destinationAccount, destinationAccount.id != sourceAccount.id else {
                validationMessage = "Selecciona una cuenta de destino diferente."
                return
            }
        }

        let category = categories.first(where: { $0.id == categoryID })
        let cleanDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDescription.isEmpty else {
            validationMessage = "Añade una descripción."
            return
        }

        let fingerprint = DuplicateDetectionService.fingerprint(
            date: date,
            sourceAccountID: sourceAccount.id,
            destinationAccountID: type == .transfer ? destinationAccount?.id : nil,
            type: type,
            amountMinor: amountMinor,
            description: cleanDescription
        )
        let candidates = DuplicateDetectionService.candidates(
            date: date,
            sourceAccountID: sourceAccount.id,
            destinationAccountID: type == .transfer ? destinationAccount?.id : nil,
            type: type,
            amountMinor: amountMinor,
            description: cleanDescription,
            existing: existingTransactions,
            excluding: transaction?.id
        )

        if let transaction {
            transaction.date = date
            transaction.type = type
            transaction.amountMinor = Swift.abs(amountMinor)
            transaction.sourceAccount = sourceAccount
            transaction.destinationAccount = type == .transfer ? destinationAccount : nil
            transaction.category = category
            transaction.descriptionText = cleanDescription
            transaction.notes = notes
            transaction.isReconciled = isReconciled
            transaction.fingerprint = fingerprint
            transaction.duplicateState = candidates.isEmpty ? .none : .possible
            transaction.updatedAt = .now
        } else {
            modelContext.insert(FinancialTransaction(
                date: date,
                type: type,
                amountMinor: amountMinor,
                descriptionText: cleanDescription,
                notes: notes,
                isReconciled: isReconciled,
                fingerprint: fingerprint,
                duplicateState: candidates.isEmpty ? .none : .possible,
                sourceAccount: sourceAccount,
                destinationAccount: type == .transfer ? destinationAccount : nil,
                category: category
            ))
        }

        sourceAccount.lastUpdatedAt = .now
        sourceAccount.updatedAt = .now
        if let destinationAccount {
            destinationAccount.lastUpdatedAt = .now
            destinationAccount.updatedAt = .now
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
