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
    @State private var showingFilters = false
    @State private var showingAdd = false
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
            if let selectedCategoryID, transaction.category?.id != selectedCategoryID { return false }
            if let selectedType, transaction.type != selectedType { return false }
            if !matchesDateFilter(transaction.date) { return false }

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
        Array(Dictionary(grouping: filteredTransactions) {
            Calendar.autoupdatingCurrent.startOfDay(for: $0.date)
        }.keys).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    ContentUnavailableView(
                        "Sin movimientos",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Añade un movimiento manual o importa un archivo CSV.")
                    )
                } else if filteredTransactions.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        ForEach(groupedDates, id: \.self) { date in
                            Section(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())) {
                                ForEach(transactions(for: date)) { transaction in
                                    Button {
                                        editingTransaction = transaction
                                    } label: {
                                        TransactionRow(transaction: transaction)
                                    }
                                    .buttonStyle(.plain)
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
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Movimientos")
            .searchable(text: $searchText, prompt: "Buscar descripción, cuenta o categoría")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingFilters = true
                    } label: {
                        Image(systemName: activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filtros")

                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Añadir movimiento")
                }
            }
            .sheet(isPresented: $showingFilters) {
                NavigationStack {
                    TransactionFiltersView(
                        selectedAccountID: $selectedAccountID,
                        selectedCategoryID: $selectedCategoryID,
                        selectedType: $selectedType,
                        dateFilter: $dateFilter,
                        accounts: accounts.filter { !$0.isArchived },
                        categories: categories.filter { !$0.isArchived }
                    )
                }
            }
            .sheet(isPresented: $showingAdd) {
                TransactionFormView()
            }
            .sheet(item: $editingTransaction) { transaction in
                TransactionFormView(transaction: transaction)
            }
            .alert("No se pudo eliminar", isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )) {
                Button("Aceptar", role: .cancel) { deletionError = nil }
            } message: {
                Text(deletionError ?? "Error desconocido")
            }
        }
    }

    private var activeFilterCount: Int {
        [selectedAccountID != nil, selectedCategoryID != nil, selectedType != nil, dateFilter != .all]
            .filter { $0 }
            .count
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

    private func delete(_ transaction: FinancialTransaction) {
        modelContext.delete(transaction)
        do {
            try modelContext.save()
        } catch {
            deletionError = error.localizedDescription
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

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
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
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(displayAmount)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(amountColor)
                Text(transaction.category?.name ?? transaction.type.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
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
        case .income, .interest: return "+\(base)"
        case .expense, .fee: return "−\(base)"
        case .transfer: return base
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

    let accounts: [FinancialAccount]
    let categories: [FinanceCategory]

    var body: some View {
        Form {
            Picker("Fecha", selection: $dateFilter) {
                ForEach(TransactionDateFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

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

            Button("Restablecer filtros", role: .destructive) {
                selectedAccountID = nil
                selectedCategoryID = nil
                selectedType = nil
                dateFilter = .all
            }
        }
        .navigationTitle("Filtros")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Hecho") { dismiss() }
            }
        }
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
