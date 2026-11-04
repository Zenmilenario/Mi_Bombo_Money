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

private struct TransactionCategorySelection: Identifiable {
    let id = UUID()
    let transactionIDs: Set<UUID>
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
    @State private var showOnlyReview = false
    @State private var showingFilters = false
    @State private var isSelecting = false
    @State private var selectedIDs = Set<UUID>()
    @State private var categorySelection: TransactionCategorySelection?
    @State private var selectedTransaction: FinancialTransaction?
    @State private var deletionError: String?

    @State private var showingCSVExporter = false
    @State private var csvExportDocument: TransactionCSVDocument?
    @State private var csvExportMessage: String?

    private var scopedTransactions: [FinancialTransaction] {
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
                transaction.displayDescription,
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

    private var filteredTransactions: [FinancialTransaction] {
        scopedTransactions.filter { !showOnlyReview || !TransactionReviewService.issues(for: $0).isEmpty }
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

    private var reviewCount: Int {
        scopedTransactions.filter { !TransactionReviewService.issues(for: $0).isEmpty }.count
    }

    var body: some View {
        NavigationStack {
            movementContent
            .cloudSyncToolbar()
            .scrollContentBackground(.hidden)
            .background(AppDesign.pageBackground)
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
                                isSelecting.toggle()
                                selectedIDs.removeAll()
                            } label: {
                                Label(isSelecting ? "Terminar selección" : "Seleccionar movimientos", systemImage: "checkmark.circle")
                            }
                            if isSelecting {
                                Button("Categorizar seleccionados (\(selectedIDs.count))") {
                                    categorySelection = TransactionCategorySelection(transactionIDs: selectedIDs)
                                }
                                .disabled(selectedIDs.isEmpty)
                            }
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
                        showOnlyReview: $showOnlyReview,
                        accounts: accounts.filter { !$0.isArchived },
                        categories: categories.filter { !$0.isArchived }
                    )
                }
            }
            .sheet(item: $selectedTransaction) { transaction in
                TransactionDetailView(transaction: transaction)
            }
            .sheet(item: $categorySelection) { selection in
                BulkCategoryView(transactionIDs: selection.transactionIDs) {
                    selectedIDs.removeAll(); isSelecting = false
                }
            }
            .onChange(of: filteredTransactions.map(\.id)) { _, visibleIDs in
                selectedIDs.formIntersection(visibleIDs)
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

    @ViewBuilder
    private var movementContent: some View {
        if transactions.isEmpty {
            ContentUnavailableView(
                "Sin movimientos",
                systemImage: "list.bullet.rectangle",
                description: Text(accounts.allSatisfy(\.isArchived)
                    ? "Primero añade una cuenta desde Cuentas. Después podrás registrar movimientos."
                    : "Añade un movimiento con el botón azul o importa un archivo CSV.")
            )
        } else {
            movementsList
        }
    }

    private var movementsList: some View {
        List {
            if isSelecting { selectionControls }
            Section {
                TransactionPeriodSummaryCard(
                    transactionCount: filteredTransactions.count,
                    incomeMinor: filteredIncomeMinor,
                    expenseMinor: filteredExpenseMinor
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                reviewSummary
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
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

            transactionSections
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var transactionSections: some View {
        if filteredTransactions.isEmpty {
            Section {
                ContentUnavailableView(
                    showOnlyReview && reviewCount == 0 ? "Sin revisiones pendientes" : "Sin resultados",
                    systemImage: showOnlyReview && reviewCount == 0 ? "checkmark.circle" : "line.3.horizontal.decrease.circle",
                    description: Text(showOnlyReview && reviewCount == 0
                        ? "No se detectan duplicados pendientes ni problemas de categoría con los filtros actuales."
                        : "Prueba a cambiar la búsqueda o limpiar los filtros.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        } else {
            ForEach(groupedTransactionDays) { group in
                transactionSection(group)
            }
        }
    }

    private func transactionSection(_ group: TransactionDayGroup) -> some View {
        let heading = group.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        return Section {
            ForEach(group.transactions) { transaction in
                TransactionActionRow(
                    transaction: transaction,
                    isSelecting: isSelecting,
                    isSelected: selectedIDs.contains(transaction.id),
                    onTap: { tapTransaction(transaction) },
                    onCategorize: {
                        categorySelection = TransactionCategorySelection(transactionIDs: Set([transaction.id]))
                    },
                    onDelete: { delete(transaction) }
                )
            }
        } header: {
            Text(heading)
        }
    }

    private func tapTransaction(_ transaction: FinancialTransaction) {
        if !isSelecting {
            selectedTransaction = transaction
        } else if selectedIDs.contains(transaction.id) {
            selectedIDs.remove(transaction.id)
        } else {
            selectedIDs.insert(transaction.id)
        }
    }

    private var selectionControls: some View {
        Section {
            Text("\(selectedIDs.count) movimientos seleccionados").font(.headline)
            HStack {
                Button("Seleccionar resultados") { selectedIDs = Set(filteredTransactions.map(\.id)) }
                Spacer()
                Button("Cancelar") { isSelecting = false; selectedIDs.removeAll() }
            }
            Button {
                categorySelection = TransactionCategorySelection(transactionIDs: selectedIDs)
            } label: {
                Label("Elegir categoría para la selección", systemImage: "tag")
            }
            .disabled(selectedIDs.isEmpty)
        } footer: {
            Text("La selección se limita a los resultados de tu búsqueda y filtros. Al cambiar los filtros se retiran los movimientos que dejan de aparecer.")
        }
    }

    private var reviewAction: TransactionReviewService.FilterAction {
        TransactionReviewService.filterAction(pendingCount: reviewCount, showingOnlyReview: showOnlyReview)
    }

    @ViewBuilder private var reviewSummary: some View {
        if reviewAction == .none {
            reviewSummaryContent
                .accessibilityElement(children: .combine)
        } else {
            Button {
                switch reviewAction {
                case .showPending: showOnlyReview = true
                case .showAll: showOnlyReview = false
                case .none: break
                }
            } label: {
                reviewSummaryContent
            }
            .buttonStyle(.plain)
            .accessibilityHint(showOnlyReview ? "Vuelve a mostrar los movimientos con los filtros actuales"
                : "Muestra posibles duplicados y movimientos sin una categoría compatible")
        }
    }

    private var reviewSummaryContent: some View {
            AdaptiveValueRow {
                HStack(spacing: 12) {
                    Image(systemName: reviewCount == 0 ? "checkmark.circle" : "checklist")
                        .font(.title3).foregroundStyle(reviewCount == 0 ? AppDesign.income : AppDesign.warning)
                        .frame(width: 42, height: 42)
                        .background(AppDesign.tertiaryBackground, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(reviewCount == 0 ? "Todo revisado" : "Por revisar").font(.headline).foregroundStyle(.primary)
                        Text(reviewCount == 0
                            ? (activeFilterCount > 0 || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Sin incidencias con los filtros actuales" : "Sin incidencias en los movimientos registrados")
                            : reviewCount == 1
                            ? "1 movimiento con revisión pendiente" : "\(reviewCount) movimientos con revisión pendiente")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } value: {
                if reviewAction != .none {
                    Label(showOnlyReview ? "Ver todos" : "Ver pendientes", systemImage: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(AppDesign.accent)
                }
            }
            .padding(AppDesign.cardPadding)
            .financeCardSurface()
    }

    private var activeFilterCount: Int {
        [
            selectedAccountID != nil,
            selectedCategoryID != nil,
            selectedType != nil,
            dateFilter != .all,
            showOnlyDuplicates,
            showOnlyReview,
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

                if showOnlyReview {
                    FilterChip(title: "Por revisar", systemImage: "checklist", tint: AppDesign.warning,
                               onRemove: { showOnlyReview = false })
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
        showOnlyReview = false
    }

    private func delete(_ transaction: FinancialTransaction) {
        do {
            if let fundID = transaction.reservedFundID {
                let funds = try modelContext.fetch(FetchDescriptor<ReservedFund>())
                guard let fund = funds.first(where: { $0.id == fundID }),
                      FinanceCalculator.reserveHistoryIsValid(fund: fund, transactions: transactions, excluding: transaction.id) else {
                    deletionError = "Esta transferencia sostiene pagos con reserva. Desvincula o corrige primero esos pagos."; return
                }
            }
            modelContext.delete(transaction)
            try modelContext.save()
        } catch {
            modelContext.rollback()
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

private struct TransactionActionRow: View {
    let transaction: FinancialTransaction
    let isSelecting: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onCategorize: () -> Void
    let onDelete: () -> Void

    private var hint: String {
        isSelecting ? "Selecciona o deselecciona el movimiento" : "Abre el detalle del movimiento"
    }

    private var selectionValue: String {
        guard isSelecting else { return "" }
        return isSelected ? "Seleccionado" : "Sin seleccionar"
    }

    var body: some View {
        Button(action: onTap) {
            rowLabel
        }
        .buttonStyle(.plain)
        .listRowBackground(AppDesign.cardBackground)
        .accessibilityHint(Text(hint))
        .accessibilityValue(Text(selectionValue))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isSelecting {
                Button(action: onCategorize) {
                    Label("Categoría", systemImage: "tag")
                }
                .tint(AppDesign.accent)
            }
        }
        .swipeActions(edge: .trailing) {
            if !isSelecting {
                Button(role: .destructive, action: onDelete) {
                    Label("Eliminar", systemImage: "trash")
                }
            }
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(AppDesign.accent)
                    .accessibilityHidden(true)
            }
            TransactionRow(transaction: transaction)
        }
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
                    Text(transaction.displayDescription)
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
                if let issue = TransactionReviewService.issues(for: transaction).first(where: { $0 != .possibleDuplicate }) {
                    Label(issue.title, systemImage: issue.systemImage)
                        .font(.caption2).foregroundStyle(AppDesign.warning)
                }
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


private struct BulkCategoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialTransaction.date, order: .reverse) private var transactions: [FinancialTransaction]
    @Query(sort: \FinanceCategory.sortOrder) private var categories: [FinanceCategory]
    @Query private var rules: [CategoryRule]
    let transactionIDs: Set<UUID>
    let onSaved: () -> Void
    @State private var searchText = ""
    @State private var categoryID: UUID?
    @State private var rememberRule = false
    @State private var rulePhrase = ""
    @State private var initialized = false
    @State private var errorMessage: String?

    private var selected: [FinancialTransaction] {
        transactions.filter { transactionIDs.contains($0.id) }
    }
    private var compatibleCategories: [FinanceCategory] {
        guard !selected.isEmpty else { return [] }
        return categories.filter { category in
            selected.allSatisfy { CategoryRuleService.supports(category, for: $0.type) }
        }
    }
    private var visibleCategories: [FinanceCategory] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return compatibleCategories.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
    }
    private var chosenCategory: FinanceCategory? {
        compatibleCategories.first { $0.id == categoryID }
    }
    private var learningIssue: String? {
        guard rememberRule, let category = chosenCategory else { return nil }
        return CategoryRuleService.classificationError(transactions: selected, category: category, remembering: rulePhrase)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(selected.count) movimientos seleccionados").font(.headline)
                    if let chosenCategory {
                        LabeledContent("Categoría elegida", value: chosenCategory.name)
                    }
                    if selected.count != transactionIDs.count {
                        Text("La selección ha cambiado o algún movimiento ya no existe. Cierra y vuelve a seleccionarlos.")
                            .foregroundStyle(.red)
                    }
                    DisclosureGroup("Ver movimientos seleccionados") {
                        ForEach(selected) { transaction in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(transaction.displayDescription)
                                Text("\(transaction.type.title) · \(transaction.sourceAccount?.bankAndAccountDisplayName ?? "Sin cuenta")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("La categoría se aplicará a toda esta selección. Los vínculos de reservas y movimientos periódicos se conservan.")
                }
                Section("Categoría") {
                    if compatibleCategories.isEmpty {
                        Text("No hay una categoría compatible con toda la selección. Selecciona movimientos de tipos compatibles o crea una categoría en Ajustes.")
                            .foregroundStyle(.secondary)
                    } else if visibleCategories.isEmpty {
                        Text("No hay categorías con ese nombre.").foregroundStyle(.secondary)
                    }
                    ForEach(visibleCategories) { category in
                        Button {
                            categoryID = category.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: category.systemImage)
                                    .foregroundStyle(Color(hex: category.colorHex))
                                    .frame(width: 32, height: 32)
                                Text(category.name).foregroundStyle(.primary)
                                Spacer()
                                if categoryID == category.id { Image(systemName: "checkmark.circle.fill") }
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(categoryID == category.id ? "Seleccionada" : "")
                    }
                }
                if chosenCategory != nil {
                    Section {
                        Toggle("Recordar para próximos movimientos", isOn: $rememberRule)
                        if rememberRule {
                            TextField("Comercio o frase a reconocer", text: $rulePhrase)
                                .textInputAutocapitalization(.never)
                            if let learningIssue {
                                Text(learningIssue).font(.footnote).foregroundStyle(.red)
                            }
                        }
                    } footer: {
                        Text("La frase debe aparecer en todos los conceptos seleccionados. Se guarda una regla para cada tipo seleccionado. Si esa frase ya tenía una regla para ese tipo, se actualiza su categoría. Puedes clasificar ahora sin guardar ninguna regla.")
                    }
                }
            }
            .navigationTitle(selected.count == 1 ? "Cambiar categoría" : "Categorizar selección")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Buscar categoría")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aplicar (\(selected.count))") { save() }
                        .fontWeight(.semibold)
                        .disabled(chosenCategory == nil || learningIssue != nil || selected.isEmpty
                                  || selected.count != transactionIDs.count)
                }
            }
            .onAppear {
                guard !initialized else { return }
                initialized = true
                if let first = selected.first,
                   Set(selected.map { CategoryRuleService.normalized($0.displayDescription) }).count == 1 {
                    rulePhrase = first.displayDescription
                }
            }
            .alert("No se pudo guardar la categoría", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("Aceptar", role: .cancel) { errorMessage = nil } }
            message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        guard selected.count == transactionIDs.count, !selected.isEmpty, let category = chosenCategory else {
            errorMessage = "Revisa la selección y elige una categoría compatible."; return
        }
        do {
            try CategoryRuleService.classify(transactions: selected, category: category,
                remembering: rememberRule ? rulePhrase : nil, existingRules: rules, in: modelContext)
            TransactionLearning.confirm(selected, in: modelContext)
            onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct TransactionReviewActions: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var transactions: [FinancialTransaction]
    @Query(sort: \FinanceCategory.sortOrder) private var categories: [FinanceCategory]
    @Query private var rules: [CategoryRule]
    @State private var rememberChoice = false
    @State private var learnedCategoryID: UUID?
    @State private var rulePhrase = ""
    @State private var errorMessage: String?
    @State private var transferPartner: FinancialTransaction?
    let transaction: FinancialTransaction
    let reviewAsTransfer: () -> Void

    private var issues: [TransactionReviewIssue] { TransactionReviewService.issues(for: transaction) }
    private var needsCategory: Bool { issues.contains(.missingCategory) || issues.contains(.incompatibleCategory) }
    private var allowedCategories: [FinanceCategory] {
        categories.filter { CategoryRuleService.supports($0, for: transaction.type) }
    }
    private var suggestedRule: CategoryRule? {
        CategoryRuleService.match(description: transaction.descriptionText, type: transaction.type, rules: rules)
    }
    private var similarMovements: [DuplicateCandidate] {
        DuplicateDetectionService.candidates(date: transaction.date,
            sourceAccountID: transaction.sourceAccount?.id, destinationAccountID: transaction.destinationAccount?.id,
            type: transaction.type, amountMinor: transaction.amountMinor, description: transaction.descriptionText,
            existing: transactions, excluding: transaction.id)
    }

    var body: some View {
        SectionCard("Por revisar", subtitle: "Resuelve solo lo que necesita atención") {
            ForEach(issues) { issue in
                Label(issue.title, systemImage: issue.systemImage)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(AppDesign.warning)
            }
            if needsCategory { categoryActions }
            if issues.contains(.possibleDuplicate) { duplicateActions }
        }
        .onAppear { if rulePhrase.isEmpty { rulePhrase = transaction.displayDescription } }
        .task(id: transaction.updatedAt) {
            learnedCategoryID = nil
            guard needsCategory, suggestedRule == nil, !transaction.hasBankTransferConcept else { return }
            let prediction = await TransactionLearning.suggest(transaction.displayDescription,
                type: transaction.type, categories: allowedCategories, in: modelContext)
            if !Task.isCancelled { learnedCategoryID = prediction }
        }
        .alert("No se pudo guardar la revisión", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Aceptar", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("¿Unir los dos apuntes como transferencia propia?", isPresented: Binding(
            get: { transferPartner != nil }, set: { if !$0 { transferPartner = nil } }
        ), titleVisibility: .visible, presenting: transferPartner) { partner in
            Button("Unir como transferencia") {
                do { try PersonalBankingImporter.pairImportedTransfer(transaction, with: partner, in: modelContext) }
                catch { errorMessage = error.localizedDescription }
            }
        } message: { partner in
            let source = transaction.type == .expense ? transaction.sourceAccount : partner.sourceAccount
            let destination = transaction.type == .income ? transaction.sourceAccount : partner.sourceAccount
            Text("\(source?.bankAndAccountDisplayName ?? "") → \(destination?.bankAndAccountDisplayName ?? ""). Se conservarán las dos referencias bancarias.")
        }
    }

    private var categoryActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if transaction.hasBankTransferConcept { transferActions }
            if let rule = suggestedRule, let category = rule.category {
                Button { assign(category, usingExistingRule: true) } label: {
                    Label("Usar \(category.name)", systemImage: category.systemImage)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Text("Sugerida por tu regla «\(rule.phrase)».")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !transaction.hasBankTransferConcept, let category = allowedCategories.first(where: { $0.id == learnedCategoryID }) {
                Button { assign(category, usingExistingRule: true) } label: {
                    Label("Confirmar propuesta de IA: \(category.name)", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            NavigationLink {
                TransactionCategoryPicker(categories: allowedCategories, selection: nil) { category in
                    assign(category)
                }
            } label: {
                Label("Elegir categoría", systemImage: "tag")
                    .frame(minHeight: 44, alignment: .leading)
            }
            .disabled(allowedCategories.isEmpty)
            if allowedCategories.isEmpty {
                Text("Añade una categoría compatible desde Ajustes → Categorías.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if CategoryRuleService.normalized(transaction.descriptionText).count >= 3 {
                Toggle("Recordar esta elección", isOn: $rememberChoice)
                if rememberChoice {
                    TextField("Comercio o frase a reconocer", text: $rulePhrase)
                }
                Text("Puedes acortar la frase al nombre del comercio. La regla se aplicará a próximos movimientos del mismo tipo que contengan esa frase.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var transferActions: some View {
        let partners = transactions.filter { PersonalBankingImporter.canPairImportedTransfer(transaction, with: $0) }
        return VStack(alignment: .leading, spacing: 8) {
            Label("Posible transferencia", systemImage: "arrow.left.arrow.right")
                .font(.subheadline.weight(.semibold))
            if partners.isEmpty {
                Text("Si la otra cuenta también es tuya, comprueba si el otro apunte ya está registrado antes de convertir el movimiento.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Revisar como transferencia propia", action: reviewAsTransfer)
            } else {
                Text("Hay apuntes de signo contrario del mismo importe y día. Une los dos solo si reconoces el traspaso entre tus cuentas.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(partners) { partner in
                    Button { transferPartner = partner } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(partner.sourceAccount?.bankAndAccountDisplayName ?? "Cuenta")
                            Text(partner.displayDescription).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var duplicateActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compara este movimiento con los registros similares antes de decidir.")
                .font(.subheadline)
            ForEach(Array(similarMovements.prefix(3))) { candidate in
                similarRow(candidate.transaction)
            }
            if similarMovements.isEmpty {
                Text("Actualmente no se encuentra una coincidencia clara con los demás movimientos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                commit {
                    transaction.duplicateState = .none
                    transaction.updatedAt = .now
                }
            } label: {
                Label("Conservar: no es un duplicado", systemImage: "checkmark.circle")
            }
            .buttonStyle(.bordered)
                .controlSize(.large)
            Text("Esta opción conserva los movimientos. Si sobra uno, elimínalo desde la lista de Movimientos.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func similarRow(_ other: FinancialTransaction) -> some View {
        AdaptiveValueRow {
            VStack(alignment: .leading, spacing: 4) {
                Text(other.displayDescription).font(.subheadline.weight(.medium))
                Text("\(other.sourceAccount?.bankAndAccountDisplayName ?? "Sin cuenta") · \(other.type.title) · \(other.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } value: {
            PrivacyAmountText(minorUnits: other.type.countsAsExpense ? -other.amountMinor : other.amountMinor,
                              currencyCode: other.sourceAccount?.currencyCode ?? "EUR",
                              font: .subheadline, weight: .semibold, signed: other.type != .transfer)
        }
        .padding(12)
        .background(AppDesign.tertiaryBackground, in: RoundedRectangle(cornerRadius: AppDesign.compactRadius))
    }

    private func assign(_ category: FinanceCategory, usingExistingRule: Bool = false) {
        guard CategoryRuleService.supports(category, for: transaction.type) else {
            errorMessage = "Esta categoría ya no está disponible para este tipo de movimiento."
            return
        }
        do {
            try CategoryRuleService.classify(transactions: [transaction], category: category,
                remembering: rememberChoice && !usingExistingRule ? rulePhrase : nil,
                existingRules: rules, in: modelContext)
            TransactionLearning.confirm([transaction], in: modelContext)
        } catch { errorMessage = error.localizedDescription }
    }

    private func commit(_ update: () -> Void) {
        // Roll back only this review's changes if the final save fails.
        do { try modelContext.save() }
        catch { errorMessage = error.localizedDescription; return }
        update()
        do { try modelContext.save() }
        catch { modelContext.rollback(); errorMessage = error.localizedDescription }
    }
}

private struct TransactionDetailView: View {
    @Query private var reservedFunds: [ReservedFund]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hideAmounts") private var hideAmounts = false

    let transaction: FinancialTransaction

    @State private var showingEdit = false
    @State private var reviewingTransfer = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: AppDesign.sectionSpacing) {
                    summaryCard
                    movementDetails
                    if transaction.displayDescription != transaction.descriptionText {
                        SectionCard("Concepto guardado", subtitle: "Descripción conservada tal como está registrada") {
                            Text(transaction.descriptionText)
                                .font(.subheadline).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if !transaction.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        SectionCard("Notas") {
                            Text(transaction.notes)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if !TransactionReviewService.issues(for: transaction).isEmpty {
                        TransactionReviewActions(transaction: transaction) {
                            reviewingTransfer = true
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(AppDesign.pageBackground)
            .navigationTitle("Detalle del movimiento")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $reviewingTransfer) {
                TransactionFormView(transaction: transaction, asBankTransfer: true)
            }
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

            Text(transaction.displayDescription)
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
                        detailRow(title: transaction.type == .transfer ? "Reserva trasladada" : "Pagado con reserva",
                            value: reservedFunds.first(where: { $0.id == fundID })?.name ?? "Reserva eliminada",
                            systemImage: "lock.open")
                        detailRow(title: "Importe de la reserva", value: hideAmounts ? "••••••" : MoneyFormatter.string(
                            minorUnits: transaction.reservedAmountMinor ?? 0), systemImage: "banknote")
                        detailRow(title: "Cuenta para el presupuesto", value: hideAmounts ? "••••••" : MoneyFormatter.string(
                            minorUnits: FinanceCalculator.budgetExpenseAmount(for: transaction)), systemImage: "chart.pie")
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

struct TransactionCategoryPickerLink: View {
    let categories: [FinanceCategory]
    @Binding var selection: UUID?
    var onSelect: () -> Void = {}

    var body: some View {
        NavigationLink {
            TransactionCategoryPicker(categories: categories, selection: selection) { category in
                selection = category.id
                onSelect()
            }
        } label: {
            LabeledContent("Categoría") {
                if let category = categories.first(where: { $0.id == selection }) {
                    Label(category.name, systemImage: category.systemImage)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Elegir").foregroundStyle(.secondary)
                }
            }
        }
        .disabled(categories.isEmpty)
    }
}

private struct TransactionCategoryPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    let categories: [FinanceCategory]
    let selection: UUID?
    let onSelect: (FinanceCategory) -> Void

    private var matches: [FinanceCategory] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return categories.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            TextField("Buscar categoría", text: $searchText)
                .autocorrectionDisabled()
            let results = matches
            if results.isEmpty {
                Label("No hay categorías con ese nombre.", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            ForEach(results) { category in
                Button {
                    dismiss()
                    onSelect(category)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: category.systemImage)
                            .foregroundStyle(Color(hex: category.colorHex))
                            .frame(width: 28)
                        Text(category.name).foregroundStyle(.primary)
                        Spacer()
                        if selection == category.id {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == category.id ? [.isSelected] : [])
            }
        }
        .navigationTitle("Elegir categoría")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TransactionFiltersView: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedAccountID: UUID?
    @Binding var selectedCategoryID: UUID?
    @Binding var selectedType: TransactionType?
    @Binding var dateFilter: TransactionDateFilter
    @Binding var showOnlyDuplicates: Bool
    @Binding var showOnlyReview: Bool

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
                Toggle("Solo por revisar", isOn: $showOnlyReview)
                Toggle("Solo posibles duplicados", isOn: $showOnlyDuplicates)
            }

            Section {
                Button("Restablecer filtros", role: .destructive) {
                    selectedAccountID = nil
                    selectedCategoryID = nil
                    selectedType = nil
                    dateFilter = .all
                    showOnlyDuplicates = false
                    showOnlyReview = false
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
    private let asBankTransfer: Bool

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
    @State private var reservedAmountIsCustom = false
    @State private var reservedTransferID: UUID?
    @State private var isReconciled: Bool
    @State private var rememberCategoryRule = false
    @State private var rulePhrase = ""
    @State private var categoryChosenManually = false
    @State private var learnedCategoryID: UUID?
    @State private var validationMessage: String?
    @FocusState private var descriptionIsFocused: Bool

    init(transaction: FinancialTransaction? = nil, preferredReservedFund: ReservedFund? = nil,
         preferredType: TransactionType = .expense, preferredSource: FinancialAccount? = nil,
         preferredDestination: FinancialAccount? = nil, preferredDescription: String = "", asBankTransfer: Bool = false) {
        self.transaction = transaction
        self.asBankTransfer = asBankTransfer
        let bankIncoming = asBankTransfer && transaction?.type == .income
        _date = State(initialValue: transaction?.date ?? .now)
        _type = State(initialValue: asBankTransfer ? .transfer : transaction?.type ?? preferredType)
        _sourceAccountID = State(initialValue: bankIncoming ? nil : transaction?.sourceAccount?.id ?? preferredReservedFund?.account?.id ?? preferredSource?.id)
        _destinationAccountID = State(initialValue: bankIncoming ? transaction?.sourceAccount?.id : transaction?.destinationAccount?.id ?? preferredDestination?.id)
        _categoryID = State(initialValue: asBankTransfer ? nil : transaction?.category?.id)
        _descriptionText = State(initialValue: transaction?.descriptionText ?? preferredReservedFund?.name ?? preferredDescription)
        _amountText = State(initialValue: transaction.map {
            String(format: "%.2f", Double($0.amountMinor) / 100)
        } ?? "")
        _notes = State(initialValue: transaction?.notes ?? "")
        _reservedFundID = State(initialValue: transaction?.reservedFundID ?? preferredReservedFund?.id)
        _reservedAmountText = State(initialValue: (transaction?.reservedAmountMinor).map { String(format: "%.2f", Double($0) / 100) } ?? "")
        _reservedAmountIsCustom = State(initialValue: transaction?.reservedFundID != nil && transaction?.reservedAmountMinor != transaction?.amountMinor)
        _isReconciled = State(initialValue: transaction?.isReconciled ?? false)
    }

    private var activeAccounts: [FinancialAccount] {
        accounts.filter { !$0.isArchived }
    }

    private func paymentPlan(for fund: ReservedFund, requested: Int64? = nil) -> FinanceCalculator.ReservedPaymentPlan? {
        guard type.countsAsExpense, let account = activeAccounts.first(where: { $0.id == sourceAccountID }) else { return nil }
        return FinanceCalculator.reservedPaymentPlan(fund: fund, account: account, date: date,
            requested: requested ?? Swift.abs(MoneyParser.minorUnits(from: amountText) ?? 0),
            transactions: existingTransactions, excluding: transaction?.id, preferredTransferID: reservedTransferID)
    }

    private var eligibleReservedFunds: [ReservedFund] {
        if type == .transfer, let destination = activeAccounts.first(where: { $0.id == destinationAccountID }),
           destination.type == .investment || destination.type.isLiability || !destination.includeInNetWorth { return [] }
        guard let source = activeAccounts.first(where: { $0.id == sourceAccountID }),
              source.includeInNetWorth, !source.type.isLiability, source.type != .investment else { return [] }
        return reservedFunds.filter { fund in
            if fund.id == reservedFundID { return true }
            let available = FinanceCalculator.availableReserve(fund: fund, accountID: source.id,
                date: date, destinationID: type == .transfer ? destinationAccountID : nil,
                transactions: existingTransactions, excluding: transaction?.id)
            if available > 0 { return true }
            return type.countsAsExpense && fund.account?.currencyCode == source.currencyCode
                && FinanceCalculator.remainingReservedAmount(for: fund, transactions: existingTransactions,
                    at: .distantFuture, excluding: transaction?.id) > 0
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
                        .disabled(asBankTransfer)
                        .onChange(of: date) { _, _ in updateSuggestedReservedAmount() }
                    Picker("Tipo", selection: $type) {
                        ForEach(TransactionType.allCases) { type in
                            Label(type.title, systemImage: type.systemImage).tag(type)
                        }
                    }
                    .disabled(asBankTransfer)
                    .onChange(of: type) { _, newType in
                        if !newType.countsAsExpense && newType != .transfer { reservedFundID = nil; reservedAmountText = "" }
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
                        .disabled(asBankTransfer)
                        .onChange(of: amountText) { _, _ in
                            updateSuggestedReservedAmount()
                        }
                    TextField("Descripción", text: $descriptionText)
                        .disabled(asBankTransfer)
                        .focused($descriptionIsFocused)
                        .onChange(of: descriptionText) { _, _ in
                            if !categoryChosenManually { applySuggestedCategory() }
                        }

                    sourceAccountPicker

                    if type == .transfer {
                        destinationAccountPicker
                    }

                    categorySuggestion
                    TransactionCategoryPickerLink(categories: allowedCategories, selection: $categoryID) {
                        categoryChosenManually = true
                    }
                }

                reservedFundingSection

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
            .onChange(of: destinationAccountID) { _, _ in updateSuggestedReservedAmount() }
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
            .task(id: type.rawValue + "|" + descriptionText) { await updateLearningSuggestion() }
            .onAppear {
                updateSuggestedReservedAmount()
                if transaction == nil, sourceAccountID == nil {
                    sourceAccountID = existingTransactions
                        .compactMap(\.sourceAccount)
                        .first(where: { recent in activeAccounts.contains(where: { $0.id == recent.id }) })?.id
                        ?? activeAccounts.first?.id
                }
                if transaction == nil || !allowedCategories.contains(where: { $0.id == categoryID }) {
                    if !categoryChosenManually { applySuggestedCategory() }
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

    private var sourceAccountPicker: some View {
        Picker(type == .transfer ? "Cuenta de origen" : "Cuenta", selection: $sourceAccountID) {
            Text("Seleccionar").tag(nil as UUID?)
            ForEach(activeAccounts) { account in
                Label(account.bankAndAccountDisplayName, systemImage: account.bankSystemImage).tag(Optional(account.id))
            }
        }
        .disabled(asBankTransfer && transaction?.type == .expense)
        .onChange(of: sourceAccountID) { _, _ in
            if let fundID = reservedFundID, !eligibleReservedFunds.contains(where: { $0.id == fundID }) {
                reservedFundID = nil
                reservedAmountText = ""
            }
            updateSuggestedReservedAmount()
        }
    }

    private var destinationAccountPicker: some View {
        Picker("Cuenta destino", selection: $destinationAccountID) {
            Text("Seleccionar").tag(nil as UUID?)
            ForEach(activeAccounts.filter { $0.id != sourceAccountID }) { account in
                Label(account.bankAndAccountDisplayName, systemImage: account.bankSystemImage).tag(Optional(account.id))
            }
        }
        .disabled(asBankTransfer && transaction?.type == .income)
    }

    @ViewBuilder
    private var reservedFundingSection: some View {
        if (type.countsAsExpense || type == .transfer) && (!eligibleReservedFunds.isEmpty || reservedFundID != nil) {
            Section {
                Picker(type == .transfer ? "Dinero que trasladas" : "Pagar con", selection: $reservedFundID) {
                    Text("Dinero disponible").tag(nil as UUID?)
                    ForEach(eligibleReservedFunds) { fund in
                        Text(fund.name).tag(Optional(fund.id))
                    }
                }
                .onChange(of: reservedFundID) { _, _ in
                    reservedAmountIsCustom = false
                    reservedTransferID = nil
                    updateSuggestedReservedAmount()
                }
                if let fund = reservedFunds.first(where: { $0.id == reservedFundID }) {
                    LabeledContent("Total sin comprometer") {
                        PrivacyAmountText(minorUnits: FinanceCalculator.remainingReservedAmount(
                            for: fund, transactions: existingTransactions, at: .distantFuture, excluding: transaction?.id))
                    }
                    if let plan = paymentPlan(for: fund), plan.candidateTransfers.count > 1 {
                        Picker("Transferencia de esta reserva", selection: $reservedTransferID) {
                            Text("Elige la transferencia").tag(nil as UUID?)
                            ForEach(plan.candidateTransfers) { transfer in
                                Text("\(transfer.date.formatted(date: .abbreviated, time: .omitted)) · \(transfer.displayDescription) · \(MoneyFormatter.string(minorUnits: transfer.amountMinor))")
                                    .tag(Optional(transfer.id))
                            }
                        }
                        .onChange(of: reservedTransferID) { _, _ in updateSuggestedReservedAmount() }
                    }
                    if type.countsAsExpense, (paymentPlan(for: fund)?.amount ?? 0) == 0,
                       (MoneyParser.minorUnits(from: amountText) ?? 0) != 0 {
                        Text("Esta reserva aún no tiene dinero disponible en la cuenta elegida. Selecciona aquí una transferencia compatible o edita la transferencia con la que llevaste el dinero y elige la reserva en «Dinero que trasladas».")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if reservedAmountIsCustom {
                        TextField("Importe tomado de la reserva", text: $reservedAmountText)
                            .keyboardType(.decimalPad)
                        Button("Usar importe automático") {
                            reservedAmountIsCustom = false
                            updateSuggestedReservedAmount()
                        }
                    } else {
                        LabeledContent("Se toma de la reserva") {
                            PrivacyAmountText(minorUnits: MoneyParser.minorUnits(from: reservedAmountText) ?? 0)
                        }
                        Button("Ajustar importe") { reservedAmountIsCustom = true }
                    }
                    if let plan = paymentPlan(for: fund, requested: MoneyParser.minorUnits(from: reservedAmountText)),
                       let transfer = plan.transfer {
                        Label("Al guardar se vincularán \(MoneyFormatter.string(minorUnits: plan.transferredAmount)) de la transferencia «\(transfer.displayDescription)» a esta reserva. No se creará otro movimiento.",
                              systemImage: "arrow.left.arrow.right")
                            .font(.footnote)
                    }
                    if type.countsAsExpense {
                        LabeledContent("Del presupuesto mensual") {
                            PrivacyAmountText(minorUnits: Swift.max(0,
                                Swift.abs(MoneyParser.minorUnits(from: amountText) ?? 0)
                                    - Swift.max(0, MoneyParser.minorUnits(from: reservedAmountText) ?? 0)))
                        }
                    }
                }
            } header: {
                Label("Origen del dinero", systemImage: "lock.open")
            } footer: {
                Text(type == .transfer ? "La reserva acompaña al dinero hasta la cuenta de destino. No se consume ni cuenta como gasto." : "La parte cubierta por la reserva queda fuera del presupuesto mensual. Si hay una única transferencia compatible en los últimos 35 días, se vincula al guardar. Si hay varias, elige aquí la que corresponde al pago. También puedes vincular la reserva al editar una transferencia en «Dinero que trasladas».")
            }
        }
    }

    private func updateSuggestedReservedAmount() {
        guard !reservedAmountIsCustom else { return }
        guard let fund = reservedFunds.first(where: { $0.id == reservedFundID }) else {
            reservedAmountText = ""
            return
        }
        let requested = Swift.abs(MoneyParser.minorUnits(from: amountText) ?? 0)
        let amount: Int64
        if type == .transfer, let sourceAccountID {
            amount = Swift.min(requested, FinanceCalculator.availableReserve(fund: fund, accountID: sourceAccountID,
                date: date, destinationID: destinationAccountID, transactions: existingTransactions, excluding: transaction?.id))
        } else { amount = paymentPlan(for: fund)?.amount ?? 0 }
        reservedAmountText = String(format: "%.2f", Double(amount) / 100)
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

    private func updateLearningSuggestion() async {
        learnedCategoryID = nil
        guard transaction == nil, type != .transfer,
              !categoryChosenManually, matchedCategoryRule == nil else { return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let prediction = await TransactionLearning.suggest(descriptionText, type: type,
            categories: allowedCategories, in: modelContext)
        if !Task.isCancelled { learnedCategoryID = prediction }
    }

    @ViewBuilder
    private var categorySuggestion: some View {
        if let rule = matchedCategoryRule,
           !categoryChosenManually,
           categoryID == rule.category?.id {
            Label("Sugerida por la regla «\(rule.phrase)»", systemImage: "sparkle.magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !categoryChosenManually, matchedCategoryRule == nil,
                  let category = allowedCategories.first(where: { $0.id == learnedCategoryID }) {
            Button {
                categoryID = category.id
                categoryChosenManually = true
            } label: {
                Label("Usar propuesta de IA: \(category.name)", systemImage: "sparkles")
            }
        }
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
        categoryID = proposedID
    }

    private func save() {
        let cleanDescription = asBankTransfer ? descriptionText : descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
        if asBankTransfer, let transaction {
            let bankSide = transaction.type == .income ? destinationAccount : sourceAccount
            guard transaction.hasBankTransferConcept, type == .transfer, bankSide?.id == transaction.sourceAccount?.id,
                  date == transaction.date, amountMinor == transaction.amountMinor, sourceAccount.currencyCode == destinationAccount?.currencyCode else {
                validationMessage = "Conserva el importe, la fecha y el lado del banco. Elige otra cuenta en la misma moneda para completar la transferencia."
                return
            }
            let otherAccount = transaction.type == .income ? sourceAccount : destinationAccount
            let oppositeType: TransactionType = transaction.type == .income ? .expense : .income
            if existingTransactions.contains(where: { other in
                guard other.id != transaction.id, other.amountMinor == amountMinor,
                      Calendar.current.isDate(other.date, inSameDayAs: date) else { return false }
                if other.type == .transfer {
                    return other.sourceAccount?.id == sourceAccount.id && other.destinationAccount?.id == destinationAccount?.id
                }
                return other.type == oppositeType && other.sourceAccount?.id == otherAccount?.id
            }) {
                validationMessage = "Ya hay un apunte del mismo importe y día en la otra cuenta, o una transferencia registrada. Compruébalo antes de convertir este movimiento."
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

        updateSuggestedReservedAmount()
        let fundingFund = reservedFunds.first { $0.id == reservedFundID }
        var fundingAmount: Int64?
        var transferToLink: FinancialTransaction?
        var transferFunding: Int64 = 0
        if reservedFundID != nil {
            guard let fund = fundingFund, let amount = MoneyParser.minorUnits(from: reservedAmountText) else {
                validationMessage = "Selecciona una reserva e indica qué parte del pago sale de ella."
                return
            }
            let plan = paymentPlan(for: fund, requested: amount)
            transferToLink = plan?.transfer
            transferFunding = plan?.transferredAmount ?? 0
            if transferToLink == nil, let error = FinanceCalculator.reservedPaymentError(fund: fund, amountMinor: amount,
                transactionAmountMinor: Swift.abs(amountMinor), type: type, account: sourceAccount,
                transactions: existingTransactions, excluding: transaction?.id, date: date, destination: destinationAccount) {
                validationMessage = error; return
            }
            guard amount > 0, amount <= Swift.abs(amountMinor) else {
                validationMessage = "El importe reservado debe ser mayor que cero y no superar el movimiento."; return
            }
            fundingAmount = amount
        }

        // Validate both the old and new funds before changing any managed object.
        // Removing/editing a transfer must not strand payments already funded at its destination.
        for fund in reservedFunds where fund.id == fundingFund?.id || fund.id == transaction?.reservedFundID {
            var entries: [ReservedLedgerEntry] = []
            if fund.id == fundingFund?.id, let fundingAmount {
                entries.append(ReservedLedgerEntry(id: transaction?.id ?? UUID(), date: date,
                    source: sourceAccount.id, destination: type == .transfer ? destinationAccount?.id : nil, amount: fundingAmount))
                if let transfer = transferToLink, let source = transfer.sourceAccount?.id {
                    entries.append(ReservedLedgerEntry(id: transfer.id, date: transfer.date, source: source,
                        destination: sourceAccount.id, amount: transferFunding))
                }
            }
            guard FinanceCalculator.reserveHistoryIsValid(fund: fund, transactions: existingTransactions,
                excluding: transaction?.id, adding: entries) else {
                validationMessage = "Este cambio dejaría pagos o transferencias sin dinero reservado en su cuenta. Revisa primero los movimientos vinculados."; return
            }
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

        if let transfer = transferToLink, let fund = fundingFund {
            transfer.reservedFundID = fund.id
            transfer.reservedAmountMinor = transferFunding
            transfer.updatedAt = .now
        }

        let savedTransaction: FinancialTransaction
        let confirmedCategory = rememberCategoryRule ||
            (categoryChosenManually && (transaction == nil || transaction?.category?.id != categoryID))
        if let transaction {
            savedTransaction = transaction
            let previousFingerprint = DuplicateDetectionService.fingerprint(
                date: transaction.date, sourceAccountID: transaction.sourceAccount?.id,
                destinationAccountID: transaction.destinationAccount?.id, type: transaction.type,
                amountMinor: transaction.amountMinor, description: transaction.descriptionText)
            let nextDuplicateState = TransactionReviewService.duplicateStateAfterEdit(
                previous: transaction.duplicateState, previousFingerprint: previousFingerprint,
                newFingerprint: fingerprint, hasCandidates: !candidates.isEmpty)
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
            transaction.duplicateState = nextDuplicateState
            transaction.updatedAt = .now
        } else {
            savedTransaction = FinancialTransaction(
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
            )
            modelContext.insert(savedTransaction)
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
            if confirmedCategory { TransactionLearning.confirm([savedTransaction], in: modelContext) }
            dismiss()
        } catch {
            modelContext.rollback()
            validationMessage = error.localizedDescription
        }
    }
}
