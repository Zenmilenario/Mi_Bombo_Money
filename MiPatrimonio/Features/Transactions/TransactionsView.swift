import Charts
import Combine
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

private enum TransactionDateFilter: String, CaseIterable, Identifiable, Equatable {
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

/// A provisional charge or credit the bank reported but has not booked yet. Never part of accounting.
struct BankHold: Identifiable {
    let id: String
    let account: FinancialAccount
    let movement: BankingPreview.PendingMovement
    let observedAt: Date

    var title: String { TransactionPresentation.listTitle(movement.description, isBanking: true) }
    var dateText: String? { movement.date.map(PersonalBankingError.displayDate) }

    /// Holds of active linked accounts, newest first. A hold already recorded as an Apple Pay payment
    /// waiting for the bank is left out: that money is already counted as an expense.
    static func all(accounts: [FinancialAccount], activity: [String: BankingAccountActivity],
                    transactions: [FinancialTransaction]) -> [BankHold] {
        accounts.filter { !$0.isArchived }.flatMap { account -> [BankHold] in
            guard let key = account.bankIdentityKey, let entry = activity[key] else { return [] }
            return uncovered(entry, account: account, transactions: transactions).enumerated().map { index, movement in
                BankHold(id: "\(key)#\(index)", account: account, movement: movement, observedAt: entry.observedAt)
            }
        }
        .sorted { lhs, rhs in
            let left = lhs.movement.date ?? "", right = rhs.movement.date ?? ""
            return left == right ? lhs.id < rhs.id : left > right
        }
    }

    static func uncovered(_ entry: BankingAccountActivity, account: FinancialAccount,
                          transactions: [FinancialTransaction]) -> [BankingPreview.PendingMovement] {
        guard let pending = entry.pendingMovements, !pending.isEmpty else { return [] }
        let awaiting = transactions
            .filter { $0.sourceAccount?.id == account.id && $0.bankEntryKey == nil && CardPaymentInbox.isAwaiting($0.externalID) }
            .map { (amountMinor: $0.amountMinor, date: $0.date) }
        return CardPaymentInbox.uncoveredHolds(pending, awaiting: awaiting)
    }

    /// Charges held for this account and not yet counted as a recorded payment (zero or negative).
    static func heldMinor(_ entry: BankingAccountActivity?, account: FinancialAccount,
                          transactions: [FinancialTransaction]) -> Int64 {
        guard let entry else { return 0 }
        return uncovered(entry, account: account, transactions: transactions).reduce(0) { $0 + min(0, $1.signedAmountMinor) }
    }
}

struct TransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.isCloudWorkspace) private var isCloudWorkspace
    @Environment(\.bankAccountActivity) private var bankActivity
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var inspectedID: UUID?
    @AppStorage("companionFocus") private var companionFocus = ""
    @State private var highlightedHolds = false
    @State private var highlightedID: UUID?
    @State private var showingBankReview = false
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
    @State private var bankDeletionCandidate: FinancialTransaction?
    @State private var pendingBankMerge: (duplicate: FinancialTransaction, kept: FinancialTransaction)?
    @State private var pendingOwnTransfer: (debit: FinancialTransaction, credit: FinancialTransaction)?
    @State private var mergeError: String?

    @State private var showingCSVExporter = false
    @State private var csvExportDocument: TransactionCSVDocument?
    @State private var csvExportMessage: String?
    /// Bumped on every save and whenever the stored movements change: the cached list is then rebuilt.
    @State private var dataVersion = 0
    @State private var listMemo = ViewMemo<ListKey, ListData>()

    private struct ListKey: Equatable {
        let count: Int, version: Int, day: Date
        let account: UUID?, category: UUID?, type: TransactionType?, dateFilter: TransactionDateFilter
        let duplicates: Bool, review: Bool, search: String
    }
    private struct ListData {
        let scoped: [FinancialTransaction]
        let filtered: [FinancialTransaction]
        let reviewCount: Int
        let groups: [TransactionDayGroup]
    }

    /// The list, its review count and its days, computed once per change instead of once per use.
    private var listData: ListData {
        let key = ListKey(count: transactions.count, version: dataVersion, day: Calendar.current.startOfDay(for: .now),
                          account: selectedAccountID, category: selectedCategoryID, type: selectedType, dateFilter: dateFilter,
                          duplicates: showOnlyDuplicates, review: showOnlyReview, search: searchText)
        return listMemo.value(for: key) {
            let scoped = computeScopedTransactions()
            let pending = scoped.filter { !TransactionReviewService.issues(for: $0).isEmpty }
            let filtered = showOnlyReview ? pending : scoped
            let groups = Dictionary(grouping: filtered) { Calendar.autoupdatingCurrent.startOfDay(for: $0.date) }
                .sorted { $0.key > $1.key }
                .map { TransactionDayGroup(date: $0.key, transactions: $0.value) }
            return ListData(scoped: scoped, filtered: filtered, reviewCount: pending.count, groups: groups)
        }
    }

    private var scopedTransactions: [FinancialTransaction] { listData.scoped }

    private func computeScopedTransactions() -> [FinancialTransaction] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return transactions.filter { transaction in
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

    private var filteredTransactions: [FinancialTransaction] { listData.filtered }

    private var groupedTransactionDays: [TransactionDayGroup] { listData.groups }

    /// With no period chosen the summary describes the current month, not the whole history.
    private var summaryTransactions: [FinancialTransaction] {
        guard dateFilter == .all else { return filteredTransactions }
        let calendar = Calendar.autoupdatingCurrent
        return filteredTransactions.filter { calendar.isDate($0.date, equalTo: .now, toGranularity: .month) }
    }

    private var summaryTitle: String {
        dateFilter == .all ? Date.now.formatted(.dateTime.month(.wide).year()).capitalized : dateFilter.title
    }

    /// Holds follow the account, type and search filters. Filters that only make sense for recorded
    /// movements (category, review, duplicates) hide them. They are current, so any date filter keeps them.
    private var visibleHolds: [BankHold] {
        guard selectedCategoryID == nil, !showOnlyDuplicates, !showOnlyReview else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return BankHold.all(accounts: accounts, activity: bankActivity, transactions: transactions).filter { hold in
            if let selectedAccountID, hold.account.id != selectedAccountID { return false }
            if let selectedType {
                guard selectedType == .expense || selectedType == .income,
                      (selectedType == .income) == (hold.movement.signedAmountMinor > 0) else { return false }
            }
            guard !query.isEmpty else { return true }
            return [hold.movement.description, hold.title, hold.account.bankAndAccountDisplayName]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var reviewCount: Int { listData.reviewCount }

    /// iPad: list on the left, the chosen movement on the right. iPhone: list and a sheet for the detail.
    var body: some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                listStack
                    .frame(minWidth: 380, idealWidth: 520, maxWidth: 600)
                Rectangle().fill(AppDesign.cardOutline).frame(width: 1).ignoresSafeArea()
                inspector
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(AppDesign.pageBackground)
        } else {
            listStack
        }
    }

    @ViewBuilder private var inspector: some View {
        if let id = inspectedID, let transaction = transactions.first(where: { $0.id == id }) {
            TransactionDetailView(transaction: transaction, onMergeBankEntry: { kept in
                pendingBankMerge = (transaction, kept)
                inspectedID = nil
                performPendingBankMerge()
            }, onPairOwnTransfer: { debit, credit in
                pendingOwnTransfer = (debit, credit)
                inspectedID = nil
                performPendingBankMerge()
            }, onClose: { inspectedID = nil })
            .id(transaction.id)
        } else {
            VStack(spacing: 14) {
                DonBigotesMark(awake: false, size: 64)
                Text("Elige un movimiento").font(.title3.weight(.semibold))
                Text("Su detalle aparecerá aquí, sin tapar la lista.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var listStack: some View {
        NavigationStack {
            movementContent
            .cloudSyncToolbar()
            .scrollContentBackground(.hidden)
            .background(AppDesign.pageBackground)
            .navigationTitle("Movimientos")
            // Don Bigotes' «Ver» on a download waiting for review opens it here, as the review button in the toolbar does.
            .navigationDestination(isPresented: $showingBankReview) { PersonalBankConnectionsView() }
            .searchable(
                text: $searchText,
                prompt: "Buscar descripción, cuenta o categoría"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if isCloudWorkspace { BankDownloadReviewLink() }
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
            .sheet(item: $selectedTransaction, onDismiss: performPendingBankMerge) { transaction in
                // The detail closes before the duplicate is deleted, so it never renders a removed movement.
                TransactionDetailView(transaction: transaction, onMergeBankEntry: { kept in
                    pendingBankMerge = (transaction, kept)
                    selectedTransaction = nil
                }, onPairOwnTransfer: { debit, credit in
                    pendingOwnTransfer = (debit, credit)
                    selectedTransaction = nil
                })
            }
            .sheet(item: $categorySelection) { selection in
                BulkCategoryView(transactionIDs: selection.transactionIDs) {
                    selectedIDs.removeAll(); isSelecting = false
                }
            }
            .onChange(of: filteredTransactions.map(\.id)) { _, visibleIDs in
                selectedIDs.formIntersection(visibleIDs)
            }
            .onChange(of: transactions) { _, _ in dataVersion &+= 1 }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: RunLoop.main)) { _ in dataVersion &+= 1 }
            .alert(
                "Exportar movimientos",
                isPresented: Binding(isPresent: $csvExportMessage)
            ) {
                Button("Aceptar", role: .cancel) {
                    csvExportMessage = nil
                }
            } message: {
                Text(csvExportMessage ?? "")
            }
            .alert(
                "No se pudo eliminar",
                isPresented: Binding(isPresent: $deletionError)
            ) {
                Button("Aceptar", role: .cancel) {
                    deletionError = nil
                }
            } message: {
                Text(deletionError ?? "Error desconocido")
            }
            .confirmationDialog(
                "Este movimiento viene de tu banco",
                isPresented: showingBankDeletion,
                titleVisibility: .visible,
                presenting: bankDeletionCandidate
            ) { transaction in
                Button("Eliminar de todos modos", role: .destructive) {
                    bankDeletionCandidate = nil
                    delete(transaction)
                }
                Button("Cancelar", role: .cancel) { bankDeletionCandidate = nil }
            } message: { _ in
                Text("Si lo eliminas, volverá en la próxima descarga del banco. Si duplica otro movimiento, ábrelo y elige «Unir con este movimiento»: se conserva el tuyo y el banco no lo repetirá.")
            }
            .alert(
                "No se pudieron unir los movimientos",
                isPresented: showingMergeError
            ) {
                Button("Aceptar", role: .cancel) { mergeError = nil }
            } message: {
                Text(mergeError ?? "")
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
      ScrollViewReader { proxy in
        List {
          // Rows without their own background take the card colour, never the system grey.
          Group {
            if isSelecting { selectionControls }
            Section {
                TransactionPeriodSummaryCard(
                    title: summaryTitle,
                    transactionCount: summaryTransactions.count,
                    incomeMinor: summaryTransactions.filter { $0.type.countsAsIncome }.reduce(Int64.zero) { $0 + Swift.abs($1.amountMinor) },
                    expenseMinor: summaryTransactions.filter { $0.type.countsAsExpense }.reduce(Int64.zero) { $0 + Swift.abs($1.amountMinor) }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                quickFilters
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
                InvestmentContributionShortcut()
                NavigationLink {
                    SpendingAnalysisView()
                } label: {
                    Label("Análisis de gastos", systemImage: "chart.bar.xaxis")
                }
            }

            let holds = visibleHolds
            if !holds.isEmpty { BankHoldsSection(holds: holds, highlighted: highlightedHolds) }

            transactionSections
          }
          .listRowBackground(AppDesign.cardBackground)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .onAppear { followCompanion(proxy) }
        .onChange(of: companionFocus) { _, _ in followCompanion(proxy) }
      }
    }

    /// Don Bigotes pointed here: show what he meant, scroll to it and highlight it for a moment.
    private func followCompanion(_ proxy: ScrollViewProxy) {
        guard let focus = CompanionFocus.parse(companionFocus), [.holds, .review, .bankReview, .awaitingBank].contains(focus) else { return }
        companionFocus = ""
        if focus == .bankReview {
            showingBankReview = true
            return
        }
        resetFilters()
        searchText = ""
        if focus == .review { showOnlyReview = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.easeInOut(duration: 0.35)) {
                if focus == .holds, let first = visibleHolds.first {
                    highlightedHolds = true
                    proxy.scrollTo(first.id, anchor: .top)
                } else if focus == .review, let first = filteredTransactions.first {
                    highlightedID = first.id
                    proxy.scrollTo(first.id, anchor: .center)
                } else if focus == .awaitingBank, let oldest = filteredTransactions
                    .filter({ $0.bankEntryKey == nil && CardPaymentInbox.isAwaiting($0.externalID) })
                    .min(by: { $0.date < $1.date }) {
                    highlightedID = oldest.id
                    proxy.scrollTo(oldest.id, anchor: .center)
                }
            }
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeOut(duration: 0.6)) {
                highlightedHolds = false
                highlightedID = nil
            }
        }
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
        let calendar = Calendar.autoupdatingCurrent
        let heading = calendar.isDate(group.date, equalTo: .now, toGranularity: .year)
            ? group.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            : group.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        let net = group.transactions.reduce(Int64.zero) { total, transaction in
            if transaction.type.countsAsIncome { return total + transaction.amountMinor }
            if transaction.type.countsAsExpense { return total - transaction.amountMinor }
            return total
        }
        return Section {
            ForEach(group.transactions) { transaction in
                TransactionActionRow(
                    transaction: transaction,
                    isSelecting: isSelecting,
                    isSelected: selectedIDs.contains(transaction.id),
                    highlighted: highlightedID == transaction.id,
                    onTap: { tapTransaction(transaction) },
                    onCategorize: {
                        categorySelection = TransactionCategorySelection(transactionIDs: Set([transaction.id]))
                    },
                    onDelete: { requestDelete(transaction) }
                )
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(heading)
                Spacer()
                if net != 0 {
                    PrivacyAmountText(minorUnits: net, font: .caption, weight: .semibold, signed: true)
                        .foregroundStyle(net > 0 ? AppDesign.income : .secondary)
                        .accessibilityLabel("Resultado del día")
                }
            }
        }
    }

    private func tapTransaction(_ transaction: FinancialTransaction) {
        if !isSelecting {
            if horizontalSizeClass == .regular { inspectedID = transaction.id } else { selectedTransaction = transaction }
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

    private var quickFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                quickChip("Todo", active: selectedType == nil && !showOnlyReview) { selectedType = nil; showOnlyReview = false }
                quickChip("Gastos", active: selectedType == .expense && !showOnlyReview) { selectedType = .expense; showOnlyReview = false }
                quickChip("Ingresos", active: selectedType == .income && !showOnlyReview) { selectedType = .income; showOnlyReview = false }
                quickChip("Transferencias", active: selectedType == .transfer && !showOnlyReview) { selectedType = .transfer; showOnlyReview = false }
                if reviewCount > 0 || showOnlyReview {
                    quickChip("Por revisar · \(reviewCount)", active: showOnlyReview, tint: AppDesign.warning) {
                        selectedType = nil; showOnlyReview = true
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func quickChip(_ title: String, active: Bool, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(active ? AppDesign.pageBackground : tint)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(active ? Color.primary : AppDesign.cardBackground, in: Capsule())
                .overlay { Capsule().strokeBorder(AppDesign.cardOutline, lineWidth: active ? 0 : 1) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
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
            HStack(spacing: 12) {
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
                Spacer(minLength: 8)
                if reviewAction != .none {
                    HStack(spacing: 4) {
                        Text(showOnlyReview ? "Ver todos" : "Ver pendientes")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(AppDesign.accent)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
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
                        tint: AppDesign.warning,
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

    private var showingBankDeletion: Binding<Bool> {
        Binding(isPresent: $bankDeletionCandidate)
    }

    private var showingMergeError: Binding<Bool> {
        Binding(isPresent: $mergeError)
    }

    private func requestDelete(_ transaction: FinancialTransaction) {
        if isCloudWorkspace && transaction.bankEntryKey != nil {
            bankDeletionCandidate = transaction
        } else {
            delete(transaction)
        }
    }

    private func performPendingBankMerge() {
        if let pair = pendingOwnTransfer {
            pendingOwnTransfer = nil
            do { try PersonalBankingImporter.pairOwnTransfer(pair.debit, with: pair.credit, in: modelContext) }
            catch { mergeError = error.localizedDescription }
        }
        guard let merge = pendingBankMerge else { return }
        pendingBankMerge = nil
        do { try PersonalBankingImporter.mergeBankEntry(merge.duplicate, into: merge.kept, in: modelContext) }
        catch { mergeError = error.localizedDescription }
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

private struct BankDownloadReviewLink: View {
    @EnvironmentObject private var banking: PersonalBankingCoordinator

    var body: some View {
        if banking.pendingPlan != nil {
            NavigationLink {
                PersonalBankConnectionsView()
            } label: {
                Label("Revisar descarga bancaria", systemImage: "tray.and.arrow.down.fill")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Revisar descarga bancaria")
        }
    }
}

private struct TransactionPeriodSummaryCard: View {
    let title: String
    let transactionCount: Int
    let incomeMinor: Int64
    let expenseMinor: Int64

    private var netMinor: Int64 {
        incomeMinor - expenseMinor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(transactionCount == 1 ? "1 movimiento" : "\(transactionCount) movimientos")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { tiles }
                VStack(spacing: 8) { tiles }
            }
        }
        .padding(AppDesign.cardPadding)
        .financeCardSurface()
    }

    @ViewBuilder private var tiles: some View {
        SemanticMetricTile(title: "Ingresos", minorUnits: incomeMinor, systemImage: "arrow.down.left",
                           tint: AppDesign.income, surface: AppDesign.incomeSurface)
        SemanticMetricTile(title: "Gastos", minorUnits: expenseMinor, systemImage: "arrow.up.right",
                           tint: AppDesign.expense, surface: AppDesign.expenseSurface)
        SemanticMetricTile(title: "Balance", minorUnits: netMinor, systemImage: "equal",
                           tint: netMinor >= 0 ? AppDesign.savings : AppDesign.expense,
                           surface: netMinor >= 0 ? AppDesign.savingsSurface : AppDesign.expenseSurface, signed: true)
    }
}

/// Bank holds shown above the movements: they already reduce the money available at the bank.
private struct BankHoldsSection: View {
    let holds: [BankHold]
    var highlighted = false

    private var total: Int64 { holds.reduce(0) { $0 + $1.movement.signedAmountMinor } }
    private var consulted: String {
        holds.map(\.observedAt).max()?.formatted(date: .abbreviated, time: .shortened) ?? ""
    }

    var body: some View {
        Section {
            ForEach(holds) { hold in
                HStack(spacing: 12) {
                    RowGlyph(systemImage: "hourglass", tint: AppDesign.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hold.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text([hold.account.bankAndAccountDisplayName, hold.dateText].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        PrivacyAmountText(minorUnits: hold.movement.signedAmountMinor,
                                          currencyCode: hold.movement.currency,
                                          font: .subheadline, weight: .semibold, signed: true)
                        StatusPill(text: hold.movement.status == "HOLD" ? "Retenido" : "Pendiente", tint: AppDesign.warning)
                    }
                }
                .padding(.vertical, 2)
                .listRowBackground(highlighted ? AppDesign.warning.opacity(0.28) : AppDesign.warningSurface)
                .id(hold.id)
                .accessibilityElement(children: .combine)
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Label("Pendientes del banco", systemImage: "hourglass")
                Spacer()
                PrivacyAmountText(minorUnits: total, font: .caption, weight: .semibold, signed: true)
                    .foregroundStyle(AppDesign.warning)
            }
        } footer: {
            Text("Tu banco ya los ha retenido y aún no los ha contabilizado (consulta del \(consulted)). Pasarán a tus movimientos cuando el banco los cierre; mientras tanto no cuentan en los presupuestos.")
        }
    }
}

private struct TransactionActionRow: View {
    let transaction: FinancialTransaction
    let isSelecting: Bool
    let isSelected: Bool
    var highlighted = false
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
        .listRowBackground(highlighted ? AppDesign.warningSurface : AppDesign.cardBackground)
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
            RowGlyph(systemImage: transaction.category?.systemImage ?? transaction.type.systemImage,
                     tint: transaction.category.map { Color(hex: $0.colorHex) } ?? glyphTint)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(transaction.listTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    if transaction.duplicateState == .possible {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.caption2)
                            .foregroundStyle(AppDesign.warning)
                            .accessibilityLabel("Posible duplicado")
                    }
                }

                Text(accountSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let issue = TransactionReviewService.issues(for: transaction).first(where: { $0 != .possibleDuplicate }) {
                    Label(issue.title, systemImage: issue.systemImage)
                        .font(.caption2).foregroundStyle(AppDesign.warning)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(displayAmount)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(amountColor)

                if transaction.bankEntryKey == nil && CardPaymentInbox.isAwaiting(transaction.externalID) {
                    StatusPill(text: "Pendiente del banco", tint: AppDesign.warning)
                } else {
                    Text(transaction.type == .transfer ? "Transferencia" : (transaction.category?.name ?? transaction.type.title))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var glyphTint: Color {
        switch transaction.type {
        case .income, .interest: AppDesign.income
        case .expense, .fee: AppDesign.expense
        case .transfer: AppDesign.savings
        }
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
        case .income, .interest: AppDesign.income
        case .expense, .fee: .primary
        case .transfer: AppDesign.savings
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
                            .foregroundStyle(AppDesign.expense)
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
                                Text(learningIssue).font(.footnote).foregroundStyle(AppDesign.expense)
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
            .alert("No se pudo guardar la categoría", isPresented: Binding(isPresent: $errorMessage)) { Button("Aceptar", role: .cancel) { errorMessage = nil } }
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

private struct InvestmentContributionShortcut: View {
    @Query private var transactions: [FinancialTransaction]
    @Query private var recurring: [RecurringMovement]

    var body: some View {
        let count = PersonalBankingImporter.contributionProposals(recurring: recurring, transactions: transactions).count
        NavigationLink {
            InvestmentContributionReviewView()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(count > 0 ? "\(count) aportaciones por confirmar" : "Reconocer aportaciones a inversión")
                    if count > 0 { Text("Cargos que pueden completar tus aportaciones periódicas").font(.caption).foregroundStyle(.secondary) }
                }
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
        }
    }
}

private struct InvestmentContributionReviewView: View {
    @Environment(\.modelContext) private var context
    @Query private var transactions: [FinancialTransaction]
    @Query private var recurring: [RecurringMovement]
    @State private var selected: [String: Set<UUID>] = [:]
    @State private var confirming: PersonalBankingImporter.ContributionProposal?
    @State private var error: String?
    @State private var status: String?

    private var proposals: [PersonalBankingImporter.ContributionProposal] {
        PersonalBankingImporter.contributionProposals(recurring: recurring, transactions: transactions)
    }

    var body: some View {
        List {
            Section {
                Text("Se buscan uno o varios cargos de la cuenta de origen que completen una aportación periódica. Revisa el destino antes de confirmar.")
                    .foregroundStyle(.secondary)
                if let status { Text(status).foregroundStyle(AppDesign.income) }
            }
            if proposals.isEmpty {
                ContentUnavailableView("Sin coincidencias completas", systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Las propuestas aparecerán cuando los cargos descargados puedan completar una aportación periódica a inversión. Comprueba su cuenta de origen e importe en Aportaciones y cargos periódicos."))
            }
            ForEach(proposals) { proposal in contributionSection(proposal) }
        }
        .navigationTitle("Aportaciones detectadas")
        .confirmationDialog("¿Confirmar estos cargos como aportación a inversión?", isPresented: Binding(isPresent: $confirming), titleVisibility: .visible,
            presenting: confirming) { proposal in
                Button("Confirmar aportación") {
                    do {
                        try PersonalBankingImporter.confirmContribution(proposal, selectedIDs: selection(for: proposal), in: context)
                        selected.removeValue(forKey: proposal.id)
                        status = "Aportación reconocida. Ya cuenta en el resumen de inversión."
                    } catch { self.error = error.localizedDescription }
                }
            } message: { proposal in
                let rule = recurring.first { $0.id == proposal.recurringID }
                Text("\(MoneyFormatter.string(minorUnits: proposal.remaining)) hacia \(rule?.destinationAccount?.bankAndAccountDisplayName ?? "la cuenta de inversión"). Los cargos se convertirán en transferencias.\(proposal.planned.isEmpty ? "" : " Se sustituirá la previsión de este periodo por los cargos seleccionados.")")
            }
        .alert("No se pudo reconocer la aportación", isPresented: Binding(isPresent: $error)) {
                Button("Aceptar", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }

    private func selection(for proposal: PersonalBankingImporter.ContributionProposal) -> Set<UUID> {
        if let selection = selected[proposal.id] { return selection }
        if case .unique(let ids) = proposal.match { return ids }
        return []
    }

    @ViewBuilder private func contributionSection(_ proposal: PersonalBankingImporter.ContributionProposal) -> some View {
        let rule = recurring.first { $0.id == proposal.recurringID }
        let selection = selection(for: proposal)
        let total = proposal.candidates.filter { selection.contains($0.id) }.reduce(Int64.zero) { $0 + $1.amountMinor }
        Section {
            Text("\(rule?.sourceAccount?.bankAndAccountDisplayName ?? "") → \(rule?.destinationAccount?.bankAndAccountDisplayName ?? "")")
                .font(.subheadline)
            LabeledContent("Previsto en el periodo", value: MoneyFormatter.string(minorUnits: proposal.expected))
            LabeledContent("Ya reconocido", value: MoneyFormatter.string(minorUnits: proposal.recognized))
            if case .ambiguous = proposal.match {
                Text("Hay varias combinaciones posibles. Selecciona los cargos que pertenecen a esta aportación.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if case .requiresSelection = proposal.match {
                Text("Hay muchos cargos candidatos. Selecciona los que pertenecen a esta aportación para comprobar el total.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .unique(let suggested) = proposal.match {
                ForEach(proposal.candidates.filter { suggested.contains($0.id) }) { transaction in
                    contributionPosting(transaction, proposal: proposal)
                }
                let others = proposal.candidates.filter { !suggested.contains($0.id) }
                if !others.isEmpty {
                    DisclosureGroup("Ver otros cargos del periodo (\(others.count))") {
                        ForEach(others) { transaction in contributionPosting(transaction, proposal: proposal) }
                    }
                }
            } else {
                ForEach(proposal.candidates) { transaction in contributionPosting(transaction, proposal: proposal) }
            }
            LabeledContent("Seleccionado", value: MoneyFormatter.string(minorUnits: total))
            if !proposal.planned.isEmpty {
                Text("Hay una previsión de esta aportación ya registrada. Al confirmar se sustituirá por los cargos seleccionados, conservando sus notas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Reconocer aportación") { confirming = proposal }
                .disabled(selection.isEmpty || total != proposal.remaining)
        } header: {
            Text("\(rule?.name ?? "Aportación") · \(proposal.period.start.formatted(date: .abbreviated, time: .omitted))")
        }
    }

    private func contributionPosting(_ transaction: FinancialTransaction,
                                     proposal: PersonalBankingImporter.ContributionProposal) -> some View {
        Toggle(isOn: Binding(get: { selection(for: proposal).contains(transaction.id) }, set: { checked in
            var ids = selection(for: proposal)
            if checked { ids.insert(transaction.id) } else { ids.remove(transaction.id) }
            selected[proposal.id] = ids
        })) {
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.displayDescription)
                Text("\(transaction.date.formatted(date: .abbreviated, time: .omitted)) · \(MoneyFormatter.string(minorUnits: transaction.amountMinor))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
    @State private var operationReviewRevision = 0
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
        .onReceive(NotificationCenter.default.publisher(for: TransactionOperationLearning.didChange)) { _ in
            learnedCategoryID = nil
            operationReviewRevision += 1
        }
        .task(id: "\(transaction.updatedAt.timeIntervalSince1970)|\(operationReviewRevision)") {
            learnedCategoryID = nil
            guard needsCategory, suggestedRule == nil, !transaction.hasBankTransferConcept else { return }
            if TransactionOperationLearning.supports(transaction),
               let operation = try? await TransactionOperationLearning.review(transaction, in: modelContext),
               let kind = operation.confirmed ?? operation.prediction?.kind, kind != .ordinary { return }
            let prediction = await TransactionLearning.suggest(transaction.displayDescription,
                type: transaction.type, categories: allowedCategories, in: modelContext)
            if !Task.isCancelled { learnedCategoryID = prediction }
        }
        .alert("No se pudo guardar la revisión", isPresented: Binding(isPresent: $errorMessage)) {
            Button("Aceptar", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("¿Unir los dos apuntes como transferencia propia?", isPresented: Binding(isPresent: $transferPartner), titleVisibility: .visible, presenting: transferPartner) { partner in
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
            Text(transaction.bankEntryKey == nil
                 ? "Esta opción conserva los movimientos. Si sobra uno, elimínalo desde la lista de Movimientos."
                 : "Esta opción conserva los movimientos. Si sobra uno, únelo con «¿Ya lo tenías registrado?», más abajo: si lo eliminas, el banco lo volverá a enviar.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func similarRow(_ other: FinancialTransaction) -> some View {
        AdaptiveValueRow {
            VStack(alignment: .leading, spacing: 4) {
                Text(other.listTitle).font(.subheadline.weight(.medium))
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

private struct TransactionOperationReviewCard: View {
    @Environment(\.modelContext) private var modelContext
    let transaction: FinancialTransaction
    @State private var review: TransactionOperationLearning.Review?
    @State private var refresh = 0
    @State private var errorMessage: String?
    @State private var savebackPercent = "1"
    @State private var roundUpMultiplier = 1
    @State private var termsFrom = Date.now
    @State private var termsMessage: String?
    @State private var automation: TransactionOperationLearning.AutomationStatus?

    var body: some View {
        SectionCard("Reconocimiento de inversión", subtitle: "La IA aprende de lo que confirmas") {
            if let automation {
                Toggle("Aplicar correcciones aprendidas", isOn: Binding(
                    get: { self.automation?.enabled ?? false }, set: { enabled in
                        do {
                            try TransactionOperationLearning.setAutomationEnabled(enabled, in: modelContext)
                            refresh += 1
                        } catch { errorMessage = "No se pudo cambiar la automatización." }
                    }))
                Text("\(automation.savedExamples) ejemplos de correcciones guardados en este perfil. La aplicación automática requiere ejemplos suficientes y aciertos al comprobar periodos posteriores.")
                    .font(.caption).foregroundStyle(.secondary)
                if automation.automaticallyApplied {
                    Label("Corregido automáticamente por la IA", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                    Text("Esta acción había acertado \(automation.validatedPredictions) comprobaciones temporales. Revisa el tipo, la categoría y la cuenta de destino.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Deshacer corrección y enseñar a la IA") {
                        do {
                            try TransactionOperationLearning.undoAutomaticCorrection(transaction, in: modelContext)
                            refresh += 1
                        } catch { errorMessage = "No se pudo deshacer: el movimiento puede haber cambiado. Revísalo manualmente." }
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let kind = review?.confirmed {
                Label("Identificado: \(kind.title)", systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.semibold))
                Text(kind.explanation).font(.footnote).foregroundStyle(.secondary)
            } else if let prediction = review?.prediction {
                Label("Propuesta de IA: \(prediction.kind.title)", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Text(prediction.usesContext
                     ? "Propuesta por contexto de tus ejemplos confirmados. La fecha y el importe no demuestran por sí solos el tipo de operación."
                     : "Propuesta aprendida del concepto. Revisa la información del banco antes de confirmar.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Confirmar identificación") { confirm(prediction.kind) }
                    .buttonStyle(.bordered)
            } else {
                Text("No hay evidencia suficiente para proponer un tipo. Puedes identificarlo consultando el detalle del banco; esa decisión ayuda a aprender.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Menu {
                ForEach(TransactionOperationKind.allCases) { kind in
                    Button(kind.title) { confirm(kind) }
                }
                if review?.confirmed != nil {
                    Button("Retirar esta identificación", role: .destructive) { confirm(nil) }
                }
            } label: {
                Label(review?.confirmed == nil ? "Identificar operación" : "Corregir identificación", systemImage: "tag")
                    .frame(minHeight: 44, alignment: .leading)
            }
            Text("Identificar el beneficio guarda su etiqueta. Corregir el tipo, la categoría o el destino del movimiento también enseña la acción que deseas para futuros apuntes. El aprendizaje se guarda en este dispositivo y perfil.")
                .font(.caption).foregroundStyle(.secondary)
            if review?.confirmed == .saveback {
                Text("Comprueba el abono de la recompensa, la retención y la inversión neta. Esta etiqueta no crea un ingreso en efectivo ni elimina un cargo bancario.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Condiciones de los beneficios de esta cuenta") {
                TextField("Saveback bruto (%)", text: $savebackPercent)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Picker("Multiplicador de Round up", selection: $roundUpMultiplier) {
                    ForEach([1, 2, 3, 5, 10], id: \.self) { value in Text("\(value)×").tag(value) }
                }
                DatePicker("Aplicar desde", selection: $termsFrom, in: ...Date.now, displayedComponents: .date)
                Button("Guardar condiciones") { saveTerms() }
                Text("Indica desde cuándo conoces estas condiciones. El porcentaje es sobre la recompensa bruta; la IA no deduce la retención ni atribuye un cargo solo por coincidir con una fórmula.")
                    .font(.caption).foregroundStyle(.secondary)
                if let termsMessage { Text(termsMessage).font(.caption).foregroundStyle(.secondary) }
            }
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(AppDesign.expense) }
        }
        .task(id: "\(transaction.updatedAt.timeIntervalSince1970)|\(refresh)") {
            review = nil
            do {
                let result = try await TransactionOperationLearning.review(transaction, in: modelContext)
                if !Task.isCancelled {
                    review = result; errorMessage = nil
                    automation = try TransactionOperationLearning.automationStatus(for: transaction, in: modelContext)
                    if let terms = try TransactionOperationLearning.terms(for: transaction, in: modelContext) {
                        savebackPercent = String(terms.savebackPercent)
                        roundUpMultiplier = terms.roundUpMultiplier
                        termsFrom = terms.validFrom
                    } else { termsFrom = min(transaction.date, .now) }
                }
            } catch {
                if !Task.isCancelled { errorMessage = "No se pudo leer el aprendizaje de este perfil. Tus movimientos se conservan." }
            }
        }
    }

    private func confirm(_ kind: TransactionOperationKind?) {
        do {
            try TransactionOperationLearning.confirm(kind, transaction: transaction, in: modelContext)
            errorMessage = nil
            refresh += 1
        } catch { errorMessage = "No se pudo guardar la identificación. Inténtalo de nuevo tras guardar los cambios pendientes." }
    }

    private func saveTerms() {
        guard let percent = Double(savebackPercent.replacingOccurrences(of: ",", with: ".")) else {
            errorMessage = "Introduce un porcentaje válido."; return
        }
        let terms = TransactionOperationModel.CardTerms(savebackPercent: percent,
            roundUpMultiplier: roundUpMultiplier, validFrom: Calendar.current.startOfDay(for: termsFrom))
        guard terms.valid else { errorMessage = "El porcentaje debe ser mayor que cero y no superar el 100 %."; return }
        do {
            try TransactionOperationLearning.saveTerms(terms, transaction: transaction, in: modelContext)
            termsMessage = "Condiciones guardadas para esta cuenta en este dispositivo."
            refresh += 1
        } catch { errorMessage = "No se pudieron guardar las condiciones. Guarda primero los cambios pendientes." }
    }
}

/// Proposes joining a debit and a credit of two linked accounts that look like one own transfer.
private struct OwnTransferProposalCard: View {
    @Query private var transactions: [FinancialTransaction]
    @State private var confirming = false
    let transaction: FinancialTransaction
    let onPair: (FinancialTransaction, FinancialTransaction) -> Void

    var body: some View {
        let pair = PersonalBankingImporter.ownTransferPairs(in: transactions, involving: [transaction.id]).first
        if let pair {
            SectionCard("Posible transferencia entre tus cuentas", subtitle: "Mismo importe en dos de tus bancos") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(pair.debit.sourceAccount?.bankAndAccountDisplayName ?? "Cuenta") → \(pair.credit.sourceAccount?.bankAndAccountDisplayName ?? "Cuenta")")
                        .font(.subheadline.weight(.semibold))
                    Text("Salida el \(pair.debit.date.formatted(date: .abbreviated, time: .omitted)) y entrada el \(pair.credit.date.formatted(date: .abbreviated, time: .omitted)). Si es un traspaso entre tus cuentas, únelos: dejará de contar como gasto e ingreso.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { confirming = true } label: {
                        Label("Unir como transferencia", systemImage: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .confirmationDialog("¿Unir los dos apuntes como transferencia propia?", isPresented: $confirming,
                                titleVisibility: .visible) {
                Button("Unir como transferencia") { onPair(pair.debit, pair.credit) }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se conservan las dos referencias bancarias. Podrás separarlos después desde el detalle de la transferencia.")
            }
        }
    }
}

/// Shows that two bank postings were joined as one own transfer and lets the user restore them.
private struct OwnTransferSeparationCard: View {
    @Environment(\.modelContext) private var modelContext
    @State private var confirming = false
    @State private var errorMessage: String?
    let transaction: FinancialTransaction

    var body: some View {
        SectionCard("Transferencia entre tus cuentas", subtitle: "Unida a partir de los apuntes de los dos bancos") {
            VStack(alignment: .leading, spacing: 8) {
                Text("La salida y la entrada se han reconocido como un traspaso entre tus cuentas, así que no cuentan como gasto ni como ingreso.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) { confirming = true } label: {
                    Label("Separar en dos movimientos", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
            }
        }
        .confirmationDialog("¿Separar esta transferencia?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Separar en gasto e ingreso", role: .destructive) {
                do { try PersonalBankingImporter.separateOwnTransfer(transaction, in: modelContext) }
                catch { errorMessage = error.localizedDescription }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Vuelven los dos apuntes del banco tal como llegaron y no se unirán automáticamente otra vez.")
        }
        .alert("No se pudo separar", isPresented: Binding(isPresent: $errorMessage)) {
            Button("Aceptar", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

/// Lets a bank posting hand its reference to a movement the user already recorded.
private struct BankEntryMergeCard: View {
    @Query private var transactions: [FinancialTransaction]
    @State private var chosen: FinancialTransaction?
    let transaction: FinancialTransaction
    let onMerge: (FinancialTransaction) -> Void

    private var candidates: [FinancialTransaction] {
        PersonalBankingImporter.mergeCandidates(for: transaction, in: transactions)
    }

    var body: some View {
        let candidates = candidates
        if !candidates.isEmpty {
            SectionCard("¿Ya lo tenías registrado?", subtitle: "Une este apunte del banco con tu movimiento") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Se conserva tu movimiento, con su categoría, notas y vínculos. Recibe la referencia del banco y este apunte se elimina; la próxima descarga no lo repetirá.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(candidates.prefix(5)) { candidate in
                        Button { chosen = candidate } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.listTitle)
                                Text("\(candidate.date.formatted(date: .abbreviated, time: .omitted)) · \(candidate.sourceAccount?.bankAndAccountDisplayName ?? "Cuenta")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .confirmationDialog("¿Unir con este movimiento?", isPresented: Binding(isPresent: $chosen), titleVisibility: .visible, presenting: chosen) { kept in
                Button("Unir con este movimiento") {
                    chosen = nil
                    onMerge(kept)
                }
                Button("Cancelar", role: .cancel) { chosen = nil }
            } message: { kept in
                Text("Se conservará «\(kept.displayDescription)» y se eliminará este apunte del banco.")
            }
        }
    }
}

private struct TransactionDetailView: View {
    @Query private var reservedFunds: [ReservedFund]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isCloudWorkspace) private var isCloudWorkspace
    @AppStorage("hideAmounts") private var hideAmounts = false

    let transaction: FinancialTransaction
    let onMergeBankEntry: (FinancialTransaction) -> Void
    let onPairOwnTransfer: (FinancialTransaction, FinancialTransaction) -> Void
    /// Set when the detail is shown beside the list (iPad) instead of in a sheet.
    var onClose: (() -> Void)? = nil

    @State private var showingEdit = false
    @State private var reviewingTransfer = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: AppDesign.sectionSpacing) {
                    summaryCard
                    movementDetails
                    if TransactionOperationLearning.supports(transaction) {
                        TransactionOperationReviewCard(transaction: transaction)
                    }
                    if transaction.listTitle != transaction.descriptionText {
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

                    if isCloudWorkspace && transaction.bankEntryKey != nil {
                        if transaction.type == .transfer {
                            if PersonalBankingImporter.canSeparateOwnTransfer(transaction) {
                                OwnTransferSeparationCard(transaction: transaction)
                            }
                        } else {
                            OwnTransferProposalCard(transaction: transaction, onPair: onPairOwnTransfer)
                        }
                        // Also for a posting the user turned into a transfer: it can duplicate another one.
                        BankEntryMergeCard(transaction: transaction, onMerge: onMergeBankEntry)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(AppDesign.pageBackground)
            .navigationTitle("Detalle del movimiento")
            .navigationBarTitleDisplayMode(.inline)
            .formSheetSizing()
            .sheet(isPresented: $reviewingTransfer) {
                TransactionFormView(transaction: transaction, asBankTransfer: true)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") {
                        if let onClose { onClose() } else { dismiss() }
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

            Text(transaction.listTitle)
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
        case .income, .interest: AppDesign.income
        case .expense, .fee: .primary
        case .transfer: AppDesign.savings
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
            // A plain row: a LabeledContent with a Label value could grow far taller than its text on iPad.
            HStack(spacing: 8) {
                Text("Categoría")
                Spacer(minLength: 12)
                if let category = categories.first(where: { $0.id == selection }) {
                    Image(systemName: category.systemImage).foregroundStyle(Color(hex: category.colorHex))
                    Text(category.name).foregroundStyle(.secondary).lineLimit(1)
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
                        tint: AppDesign.expense
                    )

                    MetricCard(
                        title: "Categorías activas",
                        value: "\(spending.count)",
                        systemImage: "tag",
                        tint: AppDesign.savings
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
                            .foregroundStyle(AppDesign.expense)
                    }
                }
            }
            .onChange(of: destinationAccountID) { _, _ in updateSuggestedReservedAmount() }
            .navigationTitle(transaction == nil ? "Nuevo movimiento" : "Editar movimiento")
            .navigationBarTitleDisplayMode(.inline)
            .formSheetSizing()
            .alert("Revisa el movimiento", isPresented: Binding(isPresent: $validationMessage)) {
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

        let correctionSnapshot: TransactionOperationLearning.EditSnapshot?
        do { correctionSnapshot = try transaction.flatMap { try TransactionOperationLearning.captureEdit($0, in: modelContext) } }
        catch { validationMessage = "No se pudo preparar el aprendizaje de la corrección. Inténtalo de nuevo."; return }

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
            let recordedFeedback = try TransactionOperationLearning.rememberEdit(correctionSnapshot, after: savedTransaction,
                explicitlyReviewed: confirmedCategory, in: modelContext)
            try modelContext.save()
            if confirmedCategory { TransactionLearning.confirm([savedTransaction], in: modelContext, recordCorrection: false) }
            if recordedFeedback { TransactionOperationLearning.feedbackDidSave(in: modelContext) }
            dismiss()
        } catch {
            modelContext.rollback()
            validationMessage = error.localizedDescription
        }
    }
}
