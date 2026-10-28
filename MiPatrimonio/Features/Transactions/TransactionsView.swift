import Charts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private struct TransactionCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CSVImportError.unreadableFile
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = Data(text.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}

private struct TransactionDayGroup: Identifiable {
    var id: Date { date }
    let date: Date
    let transactions: [FinancialTransaction]
}

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
    @State private var selectedTransaction: FinancialTransaction?
    @State private var deletionError: String?

    @State private var showingCSVExporter = false
    @State private var csvExportDocument: TransactionCSVDocument?
    @State private var csvExportMessage: String?

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
                transaction.sourceAccount?.institution?.name ?? "",
                transaction.destinationAccount?.institution?.name ?? "",
                transaction.category?.name ?? "",
                transaction.type.title,
            ].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var groupedTransactionDays: [TransactionDayGroup] {
        let grouped = Dictionary(grouping: filteredTransactions) {
            Calendar.autoupdatingCurrent.startOfDay(for: $0.date)
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { TransactionDayGroup(date: $0.key, transactions: $0.value) }
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
                        description: Text(accounts.allSatisfy(\.isArchived)
                            ? "Primero añade una cuenta desde Cuentas. Después podrás registrar movimientos."
                            : "Añade un movimiento con el botón azul o importa un archivo CSV.")
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
                            ForEach(groupedTransactionDays) { group in
                                Section(
                                    group.date.formatted(
                                        .dateTime.weekday(.wide).day().month(.wide).year()
                                    )
                                ) {
                                    ForEach(group.transactions) { transaction in
                                        Button {
                                            selectedTransaction = transaction
                                        } label: {
                                            TransactionRow(transaction: transaction)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityHint("Abre el detalle del movimiento")
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
                    HStack(spacing: 12) {
                        Menu {
                            Button {
                                exportCSV()
                            } label: {
                                Label("Exportar a CSV", systemImage: "square.and.arrow.up")
                            }
                            .disabled(filteredTransactions.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Más opciones")

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
            }
            .fileExporter(
                isPresented: $showingCSVExporter,
                document: csvExportDocument,
                contentType: .commaSeparatedText,
                defaultFilename: csvFileName
            ) { result in
                csvExportDocument = nil
                switch result {
                case .success:
                    csvExportMessage = "Movimientos exportados a CSV correctamente."
                case .failure(let error):
                    csvExportMessage = error.localizedDescription
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
            .sheet(item: $selectedTransaction) { transaction in
                TransactionDetailView(transaction: transaction)
            }
            .alert(
                "Exportar movimientos",
                isPresented: Binding(
                    get: { csvExportMessage != nil },
                    set: { if !$0 { csvExportMessage = nil } }
                )
            ) {
                Button("Aceptar", role: .cancel) {
                    csvExportMessage = nil
                }
            } message: {
                Text(csvExportMessage ?? "")
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
                        title: account.bankAndAccountDisplayName,
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

    private var csvFileName: String {
        let day = String(ISO8601DateFormatter().string(from: .now).prefix(10))
        return "MiPatrimonio-movimientos-\(day)"
    }

    private func exportCSV() {
        let csv = CSVExportService.generateCSV(from: filteredTransactions)
        csvExportDocument = TransactionCSVDocument(text: csv)
        showingCSVExporter = true
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

            AdaptiveSummaryPair(
                firstTitle: "Ingresos",
                firstAmount: incomeMinor,
                firstTint: .green,
                secondTitle: "Gastos",
                secondAmount: expenseMinor,
                secondTint: .red
            )

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

                Text(accountSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(displayAmount)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(amountColor)

                if transaction.type != .transfer {
                    Text(transaction.category?.name ?? transaction.type.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(transaction.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var accountSubtitle: String {
        if transaction.type == .transfer {
            return "\(transaction.sourceAccount?.bankAndAccountDisplayName ?? "Sin origen") → \(transaction.destinationAccount?.bankAndAccountDisplayName ?? "Sin destino")"
        }
        return transaction.sourceAccount?.bankAndAccountDisplayName ?? "Sin cuenta"
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


private struct TransactionDetailView: View {
    @Query private var reservedFunds: [ReservedFund]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hideAmounts") private var hideAmounts = false

    let transaction: FinancialTransaction

    @State private var showingEdit = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: AppDesign.sectionSpacing) {
                    summaryCard
                    movementDetails

                    if !transaction.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        SectionCard("Notas") {
                            Text(transaction.notes)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if transaction.duplicateState == .possible {
                        SectionCard("Revisión pendiente") {
                            Label(
                                "Este movimiento se parece a otro y podría estar duplicado.",
                                systemImage: "doc.on.doc.fill"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(AppDesign.pageBackground)
            .navigationTitle("Detalle del movimiento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingEdit = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Editar movimiento")
                }
            }
            .sheet(isPresented: $showingEdit) {
                TransactionFormView(transaction: transaction)
            }
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 14) {
            Image(systemName: transaction.category?.systemImage ?? transaction.type.systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(accentColor)
                .frame(width: 56, height: 56)
                .background(accentColor.opacity(0.12), in: Circle())

            Text(transaction.descriptionText)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(displayAmount)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(amountColor)
                .minimumScaleFactor(0.75)
                .lineLimit(1)

            Text(transaction.type.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.10), in: Capsule())
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            AppDesign.cardBackground,
            in: RoundedRectangle(cornerRadius: AppDesign.heroRadius, style: .continuous)
        )
    }

    private var movementDetails: some View {
        SectionCard("Información") {
            VStack(spacing: 0) {
                detailRow(
                    title: "Fecha",
                    value: transaction.date.formatted(date: .long, time: .shortened),
                    systemImage: "calendar"
                )

                Divider().padding(.leading, 38)

                if transaction.type == .transfer {
                    detailRow(
                        title: "Cuenta de origen",
                        value: transaction.sourceAccount?.bankAndAccountDisplayName ?? "Sin cuenta",
                        systemImage: "arrow.up.right.circle"
                    )

                    Divider().padding(.leading, 38)

                    detailRow(
                        title: "Cuenta de destino",
                        value: transaction.destinationAccount?.bankAndAccountDisplayName ?? "Sin cuenta",
                        systemImage: "arrow.down.left.circle"
                    )
                } else {
                    detailRow(
                        title: "Cuenta",
                        value: transaction.sourceAccount?.bankAndAccountDisplayName ?? "Sin cuenta",
                        systemImage: "building.columns"
                    )

                    if let fundID = transaction.reservedFundID {
                        Divider().padding(.leading, 38)
                        detailRow(title: "Pagado con reserva",
                            value: reservedFunds.first(where: { $0.id == fundID })?.name ?? "Reserva eliminada",
                            systemImage: "lock.open")
                        detailRow(title: "Importe de la reserva", value: hideAmounts ? "••••••" : MoneyFormatter.string(
                            minorUnits: transaction.reservedAmountMinor ?? 0), systemImage: "banknote")
                    }
                    if let category = transaction.category {
                        Divider().padding(.leading, 38)

                        detailRow(
                            title: "Categoría",
                            value: category.name,
                            systemImage: category.systemImage
                        )
                    }
                }
            }
        }
    }

    private func detailRow(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(accentColor)
                .frame(width: 26)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 12)
    }

    private var accentColor: Color {
        Color(hex: transaction.category?.colorHex ?? "#237F98")
    }

    private var displayAmount: String {
        guard !hideAmounts else { return "••••••" }

        let base = MoneyFormatter.string(
            minorUnits: transaction.amountMinor,
            currencyCode: transaction.sourceAccount?.currencyCode
                ?? transaction.destinationAccount?.currencyCode
                ?? "EUR"
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
                        Label(account.bankAndAccountDisplayName, systemImage: account.bankSystemImage).tag(Optional(account.id))
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
                    columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
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
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)

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
            .frame(maxWidth: AppDesign.readableContentWidth)
            .frame(maxWidth: .infinity)
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
    @Query private var reservedFunds: [ReservedFund]
    @Query(sort: \CategoryRule.updatedAt, order: .reverse) private var categoryRules: [CategoryRule]
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
    @State private var reservedFundID: UUID?
    @State private var reservedAmountText: String
    @State private var isReconciled: Bool
    @State private var rememberCategoryRule = false
    @State private var rulePhrase = ""
    @State private var categoryChosenManually = false
    @State private var automaticCategoryID: UUID?
    @State private var validationMessage: String?
    @FocusState private var descriptionIsFocused: Bool

    init(transaction: FinancialTransaction? = nil, preferredReservedFund: ReservedFund? = nil) {
        self.transaction = transaction
        _date = State(initialValue: transaction?.date ?? .now)
        _type = State(initialValue: transaction?.type ?? .expense)
        _sourceAccountID = State(initialValue: transaction?.sourceAccount?.id ?? preferredReservedFund?.account?.id)
        _destinationAccountID = State(initialValue: transaction?.destinationAccount?.id)
        _categoryID = State(initialValue: transaction?.category?.id)
        _descriptionText = State(initialValue: transaction?.descriptionText ?? "")
        _amountText = State(initialValue: transaction.map {
            String(format: "%.2f", Double($0.amountMinor) / 100)
        } ?? "")
        _notes = State(initialValue: transaction?.notes ?? "")
        _reservedFundID = State(initialValue: transaction?.reservedFundID ?? preferredReservedFund?.id)
        _reservedAmountText = State(initialValue: (transaction?.reservedAmountMinor).map { String(format: "%.2f", Double($0) / 100) } ?? "")
        _isReconciled = State(initialValue: transaction?.isReconciled ?? false)
    }

    private var activeAccounts: [FinancialAccount] {
        accounts.filter { !$0.isArchived }
    }

    private var eligibleReservedFunds: [ReservedFund] {
        reservedFunds.filter { fund in
            fund.account?.id == sourceAccountID && (fund.id == reservedFundID || FinanceCalculator.remainingReservedAmount(
                for: fund, transactions: existingTransactions, at: .distantFuture, excluding: transaction?.id) > 0)
        }
    }

    private var allowedCategories: [FinanceCategory] {
        categories.filter { category in
            let isCurrentArchivedCategory = category.isArchived
                && category.id == transaction?.category?.id
                && transaction?.type == type
            guard !category.isArchived || isCurrentArchivedCategory else { return false }
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
                        if !newType.countsAsExpense { reservedFundID = nil; reservedAmountText = "" }
                        categoryChosenManually = false
                        if newType == .transfer {
                            applySuggestedCategory()
                        } else {
                            destinationAccountID = nil
                            applySuggestedCategory()
                        }
                    }

                    TextField("Importe", text: $amountText)
                        .keyboardType(.decimalPad)
                        .onChange(of: amountText) { oldValue, newValue in
                            if reservedFundID != nil && (reservedAmountText.isEmpty || reservedAmountText == oldValue) {
                                reservedAmountText = newValue
                            }
                        }
                    TextField("Descripción", text: $descriptionText)
                        .focused($descriptionIsFocused)
                        .onChange(of: descriptionText) { _, _ in
                            if !categoryChosenManually { applySuggestedCategory() }
                        }

                    Picker("Cuenta", selection: $sourceAccountID) {
                        Text("Seleccionar").tag(nil as UUID?)
                        ForEach(activeAccounts) { account in
                            Label(account.bankAndAccountDisplayName, systemImage: account.bankSystemImage).tag(Optional(account.id))
                        }
                    }

                    .onChange(of: sourceAccountID) { _, newID in
                        if let fundID = reservedFundID, reservedFunds.first(where: { $0.id == fundID })?.account?.id != newID {
                            reservedFundID = nil; reservedAmountText = ""
                        }
                    }

                    if type == .transfer {
                        Picker("Cuenta destino", selection: $destinationAccountID) {
                            Text("Seleccionar").tag(nil as UUID?)
                            ForEach(activeAccounts.filter { $0.id != sourceAccountID }) { account in
                                Label(account.bankAndAccountDisplayName, systemImage: account.bankSystemImage).tag(Optional(account.id))
                            }
                        }
                    }

                    Picker("Categoría", selection: $categoryID) {
                        ForEach(allowedCategories) { category in
                            Label(category.name, systemImage: category.systemImage)
                                .tag(Optional(category.id))
                        }
                    }
                    .onChange(of: categoryID) { _, newID in
                        if newID != automaticCategoryID { categoryChosenManually = true }
                    }

                    if let rule = matchedCategoryRule,
                       !categoryChosenManually,
                       categoryID == rule.category?.id {
                        Label("Sugerida por la regla «\(rule.phrase)»", systemImage: "sparkle.magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if type.countsAsExpense && (!eligibleReservedFunds.isEmpty || reservedFundID != nil) {
                    Section {
                        Picker("Pagar con", selection: $reservedFundID) {
                            Text("Dinero disponible").tag(nil as UUID?)
                            ForEach(eligibleReservedFunds) { fund in
                                Text(fund.name).tag(Optional(fund.id))
                            }
                        }
                        .onChange(of: reservedFundID) { _, newID in
                            reservedAmountText = newID == nil ? "" : amountText
                        }
                        if let fund = reservedFunds.first(where: { $0.id == reservedFundID }) {
                            LabeledContent("Disponible en la reserva") {
                                PrivacyAmountText(minorUnits: FinanceCalculator.remainingReservedAmount(
                                    for: fund, transactions: existingTransactions, at: .distantFuture, excluding: transaction?.id))
                            }
                            TextField("Importe tomado de la reserva", text: $reservedAmountText)
                                .keyboardType(.decimalPad)
                        }
                    } header: {
                        Label("Origen del dinero", systemImage: "lock.open")
                    } footer: {
                        Text("La parte pagada con esta reserva reduce la reserva y el saldo de su cuenta. Solo el resto del pago reduce el dinero disponible.")
                    }
                }

                Section("Detalle") {
                    TextField("Notas", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                    Toggle("Conciliado", isOn: $isReconciled)
                }

                if type != .transfer {
                    Section {
                        Toggle("Recordar esta categoría para esta descripción", isOn: $rememberCategoryRule)
                        if rememberCategoryRule {
                            TextField("Frase a reconocer (opcional)", text: $rulePhrase)
                                .textInputAutocapitalization(.sentences)
                        }
                    } footer: {
                        Text("Deja la frase vacía para usar toda la descripción, o escribe una parte estable como el nombre del comercio.")
                    }
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
            .alert("Revisa el movimiento", isPresented: Binding(
                get: { validationMessage != nil },
                set: { if !$0 { validationMessage = nil } }
            )) {
                Button("Aceptar", role: .cancel) {
                    if descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        descriptionIsFocused = true
                    }
                }
            } message: {
                Text(validationMessage ?? "")
            }
            .onAppear {
                if transaction == nil, sourceAccountID == nil {
                    sourceAccountID = existingTransactions
                        .compactMap(\.sourceAccount)
                        .first(where: { recent in activeAccounts.contains(where: { $0.id == recent.id }) })?.id
                        ?? activeAccounts.first?.id
                }
                if transaction == nil || !allowedCategories.contains(where: { $0.id == categoryID }) {
                    applySuggestedCategory()
                } else {
                    categoryChosenManually = true
                }
            }
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

    private func preferredCategory(for transactionType: TransactionType) -> FinanceCategory? {
        let preferredName: String
        switch transactionType {
        case .expense: preferredName = "Otros gastos"
        case .fee: preferredName = "Impuestos y comisiones"
        case .income: preferredName = "Otros ingresos"
        case .interest: preferredName = "Intereses"
        case .transfer: preferredName = "Transferencias"
        }
        return allowedCategories.first(where: { $0.name == preferredName })
    }

    private var matchedCategoryRule: CategoryRule? {
        CategoryRuleService.match(
            description: descriptionText,
            type: type,
            rules: categoryRules
        )
    }

    private func applySuggestedCategory() {
        let proposedID = matchedCategoryRule?.category?.id ?? preferredCategory(for: type)?.id
        automaticCategoryID = proposedID
        categoryID = proposedID
    }

    private func save() {
        let cleanDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDescription.isEmpty else {
            validationMessage = "Añade una descripción para reconocer el movimiento, por ejemplo «Compra del supermercado»."
            return
        }
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
        if type != .transfer {
            guard let category, allowedCategories.contains(where: { $0.id == category.id }) else {
                validationMessage = "Selecciona una categoría para clasificar el movimiento."
                return
            }
        }
        let phraseToRemember = rulePhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? cleanDescription : rulePhrase
        if rememberCategoryRule && CategoryRuleService.normalized(phraseToRemember).count < 3 {
            validationMessage = "Escribe una frase de al menos tres caracteres para la regla."
            return
        }

        let fundingFund = reservedFunds.first { $0.id == reservedFundID }
        var fundingAmount: Int64?
        if reservedFundID != nil {
            guard let fund = fundingFund, let amount = MoneyParser.minorUnits(from: reservedAmountText) else {
                validationMessage = "Selecciona una reserva e indica qué parte del pago sale de ella."
                return
            }
            if let error = FinanceCalculator.reservedPaymentError(fund: fund, amountMinor: amount,
                transactionAmountMinor: Swift.abs(amountMinor), type: type, account: sourceAccount,
                transactions: existingTransactions, excluding: transaction?.id) {
                validationMessage = error; return
            }
            fundingAmount = amount
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
            transaction.reservedFundID = fundingFund?.id
            transaction.reservedAmountMinor = fundingAmount
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
                reservedFundID: fundingFund?.id, reservedAmountMinor: fundingAmount,
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

        if rememberCategoryRule, let category, type != .transfer {
            CategoryRuleService.remember(
                phrase: phraseToRemember, type: type,
                category: category, existing: categoryRules,
                in: modelContext
            )
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            validationMessage = error.localizedDescription
        }
    }
}
