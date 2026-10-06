import SwiftData
import SwiftUI

private enum AccountCollection: String, CaseIterable, Identifiable {
    case accounts
    case cards

    var id: String { rawValue }
    var title: String { self == .accounts ? "Cuentas" : "Tarjetas" }
}

private enum AccountManagementTool: String, Identifiable {
    case balances
    case reserves
    case recurring
    var id: String { rawValue }
}

struct AccountsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]
    @Query(sort: \PaymentCard.name) private var cards: [PaymentCard]
    @Query(sort: \FinancialTransaction.date, order: .reverse) private var transactions: [FinancialTransaction]
    @Query(sort: \BalanceSnapshot.date, order: .reverse) private var snapshots: [BalanceSnapshot]
    @Query private var goals: [SavingsGoal]
    @Query private var recurringMovements: [RecurringMovement]
    @Query private var reservedFunds: [ReservedFund]

    @State private var selectedCollection: AccountCollection = .accounts
    @State private var searchText = ""
    @State private var showOnlyStale = false
    @State private var updatingAccount: FinancialAccount?
    @State private var managementTool: AccountManagementTool?
    @State private var pendingBalanceAccount: FinancialAccount?
    @State private var showingAdd = false
    @State private var showingCardAdd = false
    @State private var editingAccount: FinancialAccount?
    @State private var editingCard: PaymentCard?
    @State private var errorMessage: String?

    private var activeAccounts: [FinancialAccount] {
        accounts.filter { !$0.isArchived }
    }

    private var visibleAccounts: [FinancialAccount] {
        activeAccounts.filter { account in
            (!showOnlyStale || isStale(account)) && matchesSearch([
                account.name, account.institution?.name ?? "", account.type.title
            ])
        }
    }

    private var activeCards: [PaymentCard] {
        cards.filter { !$0.isArchived }
    }

    private var visibleCards: [PaymentCard] {
        activeCards.filter { card in
            matchesSearch([card.name, card.institution?.name ?? "", card.linkedAccount?.name ?? "", card.lastFour, card.type.title])
        }
    }

    private var staleAccountCount: Int {
        activeAccounts.filter(isStale).count
    }

    private var archivedItemCount: Int {
        accounts.filter(\.isArchived).count + cards.filter(\.isArchived).count
    }

    var body: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty && cards.isEmpty {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "Sin cuentas",
                            systemImage: "building.columns",
                            description: Text("Añade tu primera cuenta, efectivo o inversión para empezar.")
                        )
                        Button("Añadir mi primera cuenta") {
                            showingAdd = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            accountManagementCard
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }

                        Section {
                            Picker("Mostrar", selection: $selectedCollection) {
                                ForEach(AccountCollection.allCases) { collection in
                                    Text(collection.title).tag(collection)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        collectionContent

                        if activeAccounts.isEmpty && activeCards.isEmpty {
                            Section {
                                ContentUnavailableView(
                                    "Todo está archivado",
                                    systemImage: "archivebox",
                                    description: Text("Restaura una cuenta o añade una nueva para volver a verla aquí.")
                                )
                                .frame(maxWidth: .infinity, minHeight: 180)
                            }
                        }

                        if archivedItemCount > 0 {
                            Section("Otros") {
                                NavigationLink {
                                    ArchivedFinancialItemsView()
                                } label: {
                                    HStack {
                                        Label("Elementos archivados", systemImage: "archivebox")
                                        Spacer()
                                        Text("\(archivedItemCount)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .contentMargins(.horizontal, 16, for: .scrollContent)
                }
            }
            .frame(maxWidth: .infinity)
            .background(AppDesign.pageBackground)
            .navigationTitle("Cuentas")
            .searchable(text: $searchText, prompt: "Buscar cuenta, banco o tarjeta")
            .onAppear {
                if activeAccounts.isEmpty && !activeCards.isEmpty { selectedCollection = .cards }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingAdd = true
                        } label: {
                            Label("Añadir cuenta o saldo", systemImage: "building.columns")
                        }

                        Button {
                            showingCardAdd = true
                        } label: {
                            Label("Añadir tarjeta", systemImage: "creditcard")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Añadir cuenta o tarjeta")
                }
            }
            .sheet(isPresented: $showingAdd) {
                AccountFormView()
            }
            .sheet(isPresented: $showingCardAdd) {
                PaymentCardFormView()
            }
            .sheet(item: $managementTool, onDismiss: openPendingBalanceForm) { tool in
                NavigationStack {
                    Group {
                        switch tool {
                        case .balances:
                            balanceAccountSelector
                        case .reserves:
                            ReservedFundsView()
                        case .recurring:
                            RecurringMovementsView()
                        }
                    }
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Volver a Cuentas") { managementTool = nil }
                        }
                    }
                }
            }
            .sheet(item: $updatingAccount) { account in
                BalanceSnapshotFormView(
                    account: account,
                    currentBalance: FinanceCalculator.balance(of: account, transactions: transactions, snapshots: snapshots)
                )
            }
            .sheet(item: $editingAccount) { account in
                AccountFormView(account: account)
            }
            .sheet(item: $editingCard) { card in
                PaymentCardFormView(card: card)
            }
            .alert(
                "No se pudo completar la operación",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            errorMessage = nil
                        }
                    }
                )
            ) {
                Button("Aceptar", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "Error desconocido")
            }
        }
    }

    @ViewBuilder
    private var collectionContent: some View {
        if selectedCollection == .accounts {
            if showOnlyStale {
                Section {
                    Button("Mostrar todas las cuentas") { showOnlyStale = false }
                }
            }
            accountSection(title: "Día a día", items: visibleAccounts.filter { $0.type == .checking || $0.type == .cash })
            accountSection(title: "Ahorro", items: visibleAccounts.filter { $0.type == .savings })
            accountSection(title: "Inversiones", items: visibleAccounts.filter { $0.type == .investment })
            accountSection(title: "Deudas y crédito", items: visibleAccounts.filter { $0.type.isLiability })
            accountSection(title: "Otras cuentas", items: visibleAccounts.filter { $0.type == .other })
            if visibleAccounts.isEmpty && !activeAccounts.isEmpty {
                Section {
                    ContentUnavailableView("Sin cuentas para esta búsqueda", systemImage: "magnifyingglass", description: Text("Cambia la búsqueda o muestra todas las cuentas."))
                }
            } else if activeAccounts.isEmpty && !activeCards.isEmpty {
                Section {
                    Button("Añadir mi primera cuenta") { showingAdd = true }
                }
            }
        } else {
            cardSection(title: "Tus tarjetas", items: visibleCards)
            if visibleCards.isEmpty && (!activeAccounts.isEmpty || !activeCards.isEmpty) {
                Section {
                    ContentUnavailableView(
                        activeCards.isEmpty ? "Añade tu primera tarjeta" : "Sin tarjetas para esta búsqueda",
                        systemImage: "creditcard",
                        description: Text(activeCards.isEmpty ? "Vincúlala a una cuenta para consultar sus límites y opciones." : "Prueba con otro nombre, banco o los últimos cuatro dígitos.")
                    )
                    if activeCards.isEmpty {
                        Button("Añadir tarjeta") { showingCardAdd = true }
                    }
                }
            }
        }
    }

    private var accountManagementCard: some View {
        SectionCard("Cada cuenta, bajo control", subtitle: "Consulta saldos, reservas y tarjetas; actualiza tus valoraciones.") {
            VStack(alignment: .leading, spacing: 14) {
                if staleAccountCount > 0 {
                    Button {
                        selectedCollection = .accounts
                        showOnlyStale = true
                        searchText = ""
                    } label: {
                        HStack {
                            Label("Revisar saldos sin actualizar (\(staleAccountCount))", systemImage: "clock.badge.exclamationmark")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
                AdaptiveCardGrid(minimumColumnWidth: 240, maximumColumns: 3, spacing: 12) {
                    Button {
                        managementTool = .balances
                    } label: {
                        managementShortcut("Actualizar saldo o valoración", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(activeAccounts.isEmpty)
                    Button {
                        managementTool = .reserves
                    } label: {
                        managementShortcut("Gestionar dinero reservado", systemImage: "lock.circle")
                    }
                    .buttonStyle(.borderless)
                    Button {
                        managementTool = .recurring
                    } label: {
                        managementShortcut("Aportaciones y cargos periódicos", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                }
                .foregroundStyle(.tint)
            }
            .font(.subheadline)
        }
    }

    private func managementShortcut(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(12)
            .background(AppDesign.tertiaryBackground, in: RoundedRectangle(cornerRadius: AppDesign.compactRadius))
    }

    private var balanceAccountSelector: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Toca el banco y la cuenta cuyo saldo quieres actualizar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                AdaptiveCardGrid(minimumColumnWidth: 250, maximumColumns: 3) {
                    ForEach(activeAccounts) { account in
                        Button {
                            pendingBalanceAccount = account
                            managementTool = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 14) {
                                BankAccountIdentity(account: account)
                                Divider()
                                Text("Saldo actual")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                PrivacyAmountText(
                                    minorUnits: FinanceCalculator.balance(of: account, transactions: transactions, snapshots: snapshots),
                                    currencyCode: account.currencyCode,
                                    font: .title3,
                                    weight: .semibold
                                )
                                .foregroundStyle(.primary)
                            }
                            .padding(AppDesign.cardPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppDesign.cardBackground, in: RoundedRectangle(cornerRadius: AppDesign.cardRadius))
                            .overlay {
                                RoundedRectangle(cornerRadius: AppDesign.cardRadius)
                                    .strokeBorder(Color(hex: account.institution?.colorHex ?? "#1F6B7A").opacity(0.25), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Actualizar saldo de \(account.bankAndAccountDisplayName)")
                    }
                }
            }
            .padding(16)
        }
        .background(AppDesign.pageBackground)
        .navigationTitle("Elige banco y cuenta")
    }

    private func openPendingBalanceForm() {
        if let account = pendingBalanceAccount {
            pendingBalanceAccount = nil
            updatingAccount = account
        }
    }

    private func matchesSearch(_ values: [String]) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || values.contains { $0.localizedStandardContains(query) }
    }

    @ViewBuilder
    private func accountSection(title: String, items: [FinancialAccount]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { account in
                    NavigationLink {
                        AccountDetailView(account: account)
                    } label: {
                        accountRow(account)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            updatingAccount = account
                        } label: {
                            Label("Actualizar saldo", systemImage: "arrow.clockwise")
                        }
                        .tint(.teal)
                        Button {
                            editingAccount = account
                        } label: {
                            Label("Editar", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            account.isArchived = true
                            account.updatedAt = .now
                            try? modelContext.save()
                        } label: {
                            Label("Archivar", systemImage: "archivebox")
                        }
                        .tint(.orange)

                        Button(role: .destructive) {
                            delete(account)
                        } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func accountRow(_ account: FinancialAccount) -> some View {
        AdaptiveValueRow {
            accountIdentity(account)
        } value: {
            accountAmounts(account)
        }
        .padding(.vertical, 5)
    }

    private func accountIdentity(_ account: FinancialAccount) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: account.bankSystemImage)
                .foregroundStyle(Color(hex: account.institution?.colorHex ?? "#1F6B7A"))
                .frame(width: 42, height: 42)
                .background(Color.secondary.opacity(0.09), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(account.bankDisplayName)
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 6) {
                    Text(account.bankDisplayName == account.name ? account.type.title : account.name)
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

                let linkedCardCount = activeCards.filter { $0.linkedAccount?.id == account.id }.count
                if linkedCardCount > 0 {
                    Label(linkedCardCount == 1 ? "1 tarjeta" : "\(linkedCardCount) tarjetas", systemImage: "creditcard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !account.includeInNetWorth {
                    Text("Fuera del patrimonio").font(.caption).foregroundStyle(.secondary)
                }
                Text("Actualizada \(relativeUpdateText(account.lastUpdatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func accountAmounts(_ account: FinancialAccount) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            PrivacyAmountText(
                minorUnits: FinanceCalculator.balance(of: account, transactions: transactions, snapshots: snapshots),
                currencyCode: account.currencyCode,
                font: .subheadline,
                weight: .semibold
            )
            let reserved = FinanceCalculator.reservedAmount(for: account, funds: reservedFunds)
            if reserved > 0 && !account.type.isLiability && account.type != .investment {
                Text("Disponible").font(.caption2).foregroundStyle(.secondary)
                PrivacyAmountText(
                    minorUnits: FinanceCalculator.balance(of: account, transactions: transactions, snapshots: snapshots) - reserved,
                    currencyCode: account.currencyCode,
                    font: .caption,
                    weight: .medium
                )
            }
        }
    }

    @ViewBuilder
    private func cardSection(title: String, items: [PaymentCard]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { card in
                    NavigationLink {
                        PaymentCardDetailView(card: card)
                    } label: {
                        cardRow(card)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            editingCard = card
                        } label: {
                            Label("Editar", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            card.isArchived = true
                            card.updatedAt = .now
                            try? modelContext.save()
                        } label: {
                            Label("Archivar", systemImage: "archivebox")
                        }
                        .tint(.orange)

                        Button(role: .destructive) {
                            delete(card)
                        } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func cardRow(_ card: PaymentCard) -> some View {
        HStack(spacing: 12) {
            Image(systemName: card.type.systemImage)
                .foregroundStyle(Color(hex: card.institution?.colorHex ?? "#1F6B7A"))
                .frame(width: 42, height: 42)
                .background(Color.secondary.opacity(0.09), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(card.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(cardSubtitle(card))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 5)
    }

    private func cardSubtitle(_ card: PaymentCard) -> String {
        var parts = [card.type.title]
        if !card.lastFour.isEmpty {
            parts.append("•••• \(card.lastFour)")
        }
        if let account = card.linkedAccount {
            parts.append(account.bankAndAccountDisplayName)
        }
        return parts.joined(separator: " · ")
    }

    private func isStale(_ account: FinancialAccount) -> Bool {
        let limit = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: -30,
            to: .now
        ) ?? .now
        return account.lastUpdatedAt < limit
    }

    private func relativeUpdateText(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) { return "hoy" }
        if calendar.isDateInYesterday(date) { return "ayer" }
        return "el \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private func delete(_ card: PaymentCard) {
        modelContext.delete(card)
        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ account: FinancialAccount) {
        let hasTransactions = transactions.contains {
            $0.sourceAccount?.id == account.id || $0.destinationAccount?.id == account.id
        }
        let hasSnapshots = snapshots.contains { $0.account?.id == account.id }
        let hasCards = cards.contains { $0.linkedAccount?.id == account.id }
        let hasGoals = goals.contains { $0.linkedAccount?.id == account.id }
        let hasRecurring = recurringMovements.contains {
            $0.sourceAccount?.id == account.id || $0.destinationAccount?.id == account.id
        }
        let hasReserved = reservedFunds.contains { $0.account?.id == account.id }

        guard !hasTransactions && !hasSnapshots && !hasCards && !hasGoals && !hasRecurring && !hasReserved else {
            errorMessage = "Esta cuenta está vinculada a movimientos, valoraciones, tarjetas, objetivos, reservas o reglas periódicas. Archívala para conservar el historial."
            return
        }

        modelContext.delete(account)
        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ArchivedFinancialItemsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]
    @Query(sort: \PaymentCard.name) private var cards: [PaymentCard]

    private var archivedAccounts: [FinancialAccount] {
        accounts.filter(\.isArchived)
    }

    private var archivedCards: [PaymentCard] {
        cards.filter(\.isArchived)
    }

    var body: some View {
        List {
            if archivedAccounts.isEmpty && archivedCards.isEmpty {
                ContentUnavailableView(
                    "Sin elementos archivados",
                    systemImage: "archivebox",
                    description: Text("Las cuentas y tarjetas que archives aparecerán aquí.")
                )
            }

            if !archivedAccounts.isEmpty {
                Section("Cuentas") {
                    ForEach(archivedAccounts) { account in
                        HStack(spacing: 12) {
                            Image(systemName: account.type.systemImage)
                                .foregroundStyle(Color(hex: account.institution?.colorHex ?? "#1F6B7A"))
                                .frame(width: 38, height: 38)
                                .background(Color.secondary.opacity(0.09), in: Circle())

                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.name)
                                    .font(.subheadline.weight(.medium))
                                Text(account.institution?.name ?? account.type.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("Restaurar") {
                                account.isArchived = false
                                account.updatedAt = .now
                                try? modelContext.save()
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                }
            }

            if !archivedCards.isEmpty {
                Section("Tarjetas") {
                    ForEach(archivedCards) { card in
                        HStack(spacing: 12) {
                            Image(systemName: card.type.systemImage)
                                .foregroundStyle(Color(hex: card.institution?.colorHex ?? "#1F6B7A"))
                                .frame(width: 38, height: 38)
                                .background(Color.secondary.opacity(0.09), in: Circle())

                            VStack(alignment: .leading, spacing: 3) {
                                Text(card.name)
                                    .font(.subheadline.weight(.medium))
                                Text(card.type.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("Restaurar") {
                                card.isArchived = false
                                card.updatedAt = .now
                                try? modelContext.save()
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
        }
        .navigationTitle("Archivados")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PaymentCardFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialInstitution.name) private var institutions: [FinancialInstitution]
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]

    private let card: PaymentCard?

    @State private var name: String
    @State private var type: PaymentCardType
    @State private var lastFour: String
    @State private var institutionID: UUID?
    @State private var linkedAccountID: UUID?
    @State private var limitKind: CardLimitKind?
    @State private var limitText: String
    @State private var onlinePurchasesEnabled: Bool?
    @State private var contactlessEnabled: Bool?
    @State private var atmWithdrawalsEnabled: Bool?
    @State private var internationalPaymentsEnabled: Bool?
    @State private var cashbackEnabled: Bool?
    @State private var cashbackPercentText: String
    @State private var roundUpEnabled: Bool?
    @State private var notes: String
    @State private var errorMessage: String?

    init(card: PaymentCard? = nil, institution: FinancialInstitution? = nil, linkedAccount: FinancialAccount? = nil) {
        self.card = card
        _name = State(initialValue: card?.name ?? "")
        _type = State(initialValue: card?.type ?? .debit)
        _lastFour = State(initialValue: card?.lastFour ?? "")
        _institutionID = State(initialValue: card?.institution?.id ?? institution?.id ?? linkedAccount?.institution?.id ?? card?.linkedAccount?.institution?.id)
        _linkedAccountID = State(initialValue: card?.linkedAccount?.id ?? linkedAccount?.id)
        _limitKind = State(initialValue: card?.limitKind)
        _limitText = State(initialValue: card?.limitMinor.map {
            String(format: "%.2f", Double($0) / 100)
        } ?? "")
        _onlinePurchasesEnabled = State(initialValue: card?.onlinePurchasesEnabled)
        _contactlessEnabled = State(initialValue: card?.contactlessEnabled)
        _atmWithdrawalsEnabled = State(initialValue: card?.atmWithdrawalsEnabled)
        _internationalPaymentsEnabled = State(initialValue: card?.internationalPaymentsEnabled)
        _cashbackEnabled = State(initialValue: card?.cashbackEnabled)
        _cashbackPercentText = State(initialValue: card?.cashbackPercent.map {
            String(format: "%.2f", $0)
        } ?? "")
        _roundUpEnabled = State(initialValue: card?.roundUpEnabled)
        _notes = State(initialValue: card?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nombre", text: $name)
                    Picker("Tipo", selection: $type) {
                        ForEach(PaymentCardType.allCases) { type in
                            Label(type.title, systemImage: type.systemImage).tag(type)
                        }
                    }
                    TextField("Últimos 4 dígitos (opcional)", text: $lastFour)
                        .keyboardType(.numberPad)
                    Picker("Banco / entidad", selection: $institutionID) {
                        Text("Sin entidad").tag(nil as UUID?)
                        ForEach(institutions) { institution in
                            Text(institution.name).tag(Optional(institution.id))
                        }
                    }
                    Picker("Cuenta vinculada", selection: $linkedAccountID) {
                        Text("Sin vincular").tag(nil as UUID?)
                        ForEach(accounts.filter { !$0.isArchived }) { account in
                            Label(account.bankAndAccountDisplayName, systemImage: account.bankSystemImage)
                                .tag(Optional(account.id))
                        }
                    }
                    .onChange(of: linkedAccountID) { _, newID in
                        if institutionID == nil, let newID {
                            institutionID = accounts.first { $0.id == newID }?.institution?.id
                        }
                    }
                } header: {
                    Text("Tarjeta")
                } footer: {
                    Text("La tarjeta es un medio de pago y no suma patrimonio por separado. Su saldo se toma de la cuenta vinculada. No se guarda el número completo ni el CVV.")
                }

                Section {
                    Picker("Tipo de límite", selection: $limitKind) {
                        Text("Sin indicar").tag(nil as CardLimitKind?)
                        ForEach(CardLimitKind.allCases) { kind in
                            Text(kind.title).tag(Optional(kind))
                        }
                    }
                    if limitKind != nil {
                        TextField("Importe del límite (\(selectedCurrency))", text: $limitText)
                            .keyboardType(.decimalPad)
                    }
                } header: {
                    Text("Límite")
                } footer: {
                    Text("Indica el límite configurado por tu entidad. La app no lo consulta ni lo aplica automáticamente.")
                }

                Section("Uso de la tarjeta") {
                    CardSettingPicker(title: "Compras online", selection: $onlinePurchasesEnabled)
                    CardSettingPicker(title: "Pago sin contacto", selection: $contactlessEnabled)
                    CardSettingPicker(title: "Retiradas en cajero", selection: $atmWithdrawalsEnabled)
                    CardSettingPicker(title: "Pagos internacionales", selection: $internationalPaymentsEnabled)
                }

                Section("Ventajas") {
                    CardSettingPicker(title: "Cashback", selection: $cashbackEnabled)
                    if cashbackEnabled == true {
                        TextField("Porcentaje de cashback (opcional)", text: $cashbackPercentText)
                            .keyboardType(.decimalPad)
                    }
                    CardSettingPicker(title: "Redondeo de compras", selection: $roundUpEnabled)
                }

                Section("Notas") {
                    TextField("Notas", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(card == nil ? "Nueva tarjeta" : "Editar tarjeta")
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

    private var selectedCurrency: String {
        accounts.first { $0.id == linkedAccountID }?.currencyCode ?? "EUR"
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLastFour = lastFour.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "Introduce un nombre."
            return
        }
        guard cleanLastFour.isEmpty || (cleanLastFour.count == 4 && cleanLastFour.allSatisfy(\.isNumber)) else {
            errorMessage = "Introduce exactamente los últimos cuatro dígitos o deja el campo vacío."
            return
        }

        var limitMinor: Int64?
        if limitKind != nil {
            guard let parsedLimit = MoneyParser.minorUnits(from: limitText), parsedLimit > 0 else {
                errorMessage = "Introduce un límite mayor que cero."
                return
            }
            limitMinor = parsedLimit
        }

        var cashbackPercent: Double?
        if cashbackEnabled == true && !cashbackPercentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsedPercent = Double(cashbackPercentText.replacingOccurrences(of: ",", with: ".")),
                  parsedPercent > 0, parsedPercent <= 100 else {
                errorMessage = "El cashback debe ser un porcentaje entre 0 y 100."
                return
            }
            cashbackPercent = parsedPercent
        }

        let institution = institutions.first { $0.id == institutionID }
        let linkedAccount = accounts.first { $0.id == linkedAccountID }

        if let card {
            card.name = cleanName
            card.type = type
            card.lastFour = cleanLastFour
            card.limitKind = limitKind
            card.limitMinor = limitMinor
            card.onlinePurchasesEnabled = onlinePurchasesEnabled
            card.contactlessEnabled = contactlessEnabled
            card.atmWithdrawalsEnabled = atmWithdrawalsEnabled
            card.internationalPaymentsEnabled = internationalPaymentsEnabled
            card.cashbackEnabled = cashbackEnabled
            card.cashbackPercent = cashbackPercent
            card.roundUpEnabled = roundUpEnabled
            card.institution = institution
            card.linkedAccount = linkedAccount
            card.notes = notes
            card.updatedAt = .now
        } else {
            modelContext.insert(PaymentCard(
                name: cleanName,
                type: type,
                lastFour: cleanLastFour,
                limitMinor: limitMinor,
                limitKind: limitKind,
                onlinePurchasesEnabled: onlinePurchasesEnabled,
                contactlessEnabled: contactlessEnabled,
                atmWithdrawalsEnabled: atmWithdrawalsEnabled,
                internationalPaymentsEnabled: internationalPaymentsEnabled,
                cashbackEnabled: cashbackEnabled,
                cashbackPercent: cashbackPercent,
                roundUpEnabled: roundUpEnabled,
                notes: notes,
                institution: institution,
                linkedAccount: linkedAccount
            ))
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CardSettingPicker: View {
    let title: String
    @Binding var selection: Bool?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Sin indicar").tag(nil as Bool?)
            Text("Sí").tag(true as Bool?)
            Text("No").tag(false as Bool?)
        }
    }
}

struct PaymentCardDetailView: View {
    let card: PaymentCard
    @State private var showingEdit = false

    var body: some View {
        List {
            Section("Tarjeta") {
                LabeledContent("Tipo", value: card.type.title)
                LabeledContent("Últimos dígitos", value: card.lastFour.isEmpty ? "Sin indicar" : "•••• \(card.lastFour)")
                LabeledContent("Entidad", value: card.institution?.name ?? "Sin entidad")
                LabeledContent("Cuenta vinculada", value: card.linkedAccount?.bankAndAccountDisplayName ?? "Sin vincular")
            }

            Section("Límite") {
                if let kind = card.limitKind, let amount = card.limitMinor {
                    LabeledContent("Tipo", value: kind.title)
                    LabeledContent("Importe") {
                        PrivacyAmountText(minorUnits: amount, currencyCode: card.linkedAccount?.currencyCode ?? "EUR")
                    }
                } else {
                    Text("Sin indicar")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Uso de la tarjeta") {
                LabeledContent("Compras online", value: statusText(card.onlinePurchasesEnabled))
                LabeledContent("Pago sin contacto", value: statusText(card.contactlessEnabled))
                LabeledContent("Retiradas en cajero", value: statusText(card.atmWithdrawalsEnabled))
                LabeledContent("Pagos internacionales", value: statusText(card.internationalPaymentsEnabled))
            }

            Section("Ventajas") {
                LabeledContent("Cashback", value: cashbackText)
                LabeledContent("Redondeo de compras", value: statusText(card.roundUpEnabled))
            }

            if !card.notes.isEmpty {
                Section("Notas") {
                    Text(card.notes)
                }
            }
        }
        .navigationTitle(card.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Editar") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            PaymentCardFormView(card: card)
        }
    }

    private var cashbackText: String {
        guard let enabled = card.cashbackEnabled else { return "Sin indicar" }
        guard enabled else { return "No" }
        guard let percent = card.cashbackPercent else { return "Sí" }
        return "\(percent.formatted(.number.precision(.fractionLength(0...2)))) %"
    }

    private func statusText(_ value: Bool?) -> String {
        guard let value else { return "Sin indicar" }
        return value ? "Sí" : "No"
    }
}

private struct AccountDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialTransaction.date, order: .reverse) private var transactions: [FinancialTransaction]
    @Query(sort: \BalanceSnapshot.date, order: .reverse) private var snapshots: [BalanceSnapshot]
    @Query(sort: \PaymentCard.name) private var cards: [PaymentCard]
    @Query private var reservedFunds: [ReservedFund]

    let account: FinancialAccount
    @State private var showingEdit = false
    @State private var showingSnapshot = false
    @State private var showingAddCard = false
    @State private var showingAddReservation = false

    private var linkedCards: [PaymentCard] {
        cards.filter { $0.linkedAccount?.id == account.id && !$0.isArchived }
    }

    private var accountTransactions: [FinancialTransaction] {
        transactions.filter {
            $0.sourceAccount?.id == account.id || $0.destinationAccount?.id == account.id
        }
    }

    private var balance: Int64 {
        FinanceCalculator.balance(of: account, transactions: transactions, snapshots: snapshots)
    }

    private var reservedAmount: Int64 {
        FinanceCalculator.reservedAmount(for: account, funds: reservedFunds)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(account.institution?.name ?? account.type.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    PrivacyAmountText(
                        minorUnits: balance,
                        currencyCode: account.currencyCode,
                        font: .system(size: 34, weight: .bold, design: .rounded),
                        weight: .bold
                    )
                    Text("Saldo actual calculado a partir del saldo inicial, movimientos y valoraciones.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section("Datos de la cuenta") {
                LabeledContent("Tipo", value: account.type.title)
                LabeledContent("Saldo inicial") {
                    PrivacyAmountText(minorUnits: account.openingBalanceMinor, currencyCode: account.currencyCode)
                }
                LabeledContent("TAE / interés") {
                    Text(account.annualInterestRate, format: .percent.precision(.fractionLength(2)))
                }
                LabeledContent("Interés anual estimado") {
                    PrivacyAmountText(
                        minorUnits: FinanceCalculator.estimatedAnnualInterestMinor(
                            account: account,
                            transactions: transactions,
                            snapshots: snapshots
                        ),
                        currencyCode: account.currencyCode
                    )
                }
                LabeledContent("Objetivo") {
                    PrivacyAmountText(minorUnits: account.targetBalanceMinor, currencyCode: account.currencyCode)
                }
                LabeledContent("Desviación") {
                    PrivacyAmountText(
                        minorUnits: balance - account.targetBalanceMinor,
                        currencyCode: account.currencyCode
                    )
                }
                LabeledContent("Última actualización", value: account.lastUpdatedAt.formatted(date: .abbreviated, time: .omitted))
            }

            if !account.type.isLiability && account.type != .investment {
                Section("Dinero reservado") {
                    LabeledContent("Reservado") {
                        PrivacyAmountText(minorUnits: reservedAmount, currencyCode: account.currencyCode)
                    }
                    LabeledContent("Disponible") {
                        PrivacyAmountText(minorUnits: balance - reservedAmount, currencyCode: account.currencyCode)
                    }
                    if reservedAmount > balance {
                        Text("La reserva supera el saldo actual de esta cuenta.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        showingAddReservation = true
                    } label: {
                        Label("Reservar dinero de esta cuenta", systemImage: "lock.circle")
                    }
                    .disabled(account.isArchived || !account.includeInNetWorth)
                }
            }

            Section("Movimientos recientes") {
                if accountTransactions.isEmpty {
                    Text("No hay movimientos.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(accountTransactions.prefix(8)) { transaction in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(transaction.descriptionText)
                                Text(transaction.date, format: .dateTime.day().month().year())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            PrivacyAmountText(
                                minorUnits: FinanceCalculator.effect(of: transaction, on: account),
                                currencyCode: account.currencyCode
                            )
                        }
                    }
                }
            }

            Section("Tarjetas vinculadas") {
                if linkedCards.isEmpty {
                    Text("No hay tarjetas vinculadas a esta cuenta.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(linkedCards) { card in
                        NavigationLink {
                            PaymentCardDetailView(card: card)
                        } label: {
                            Label(card.name, systemImage: card.type.systemImage)
                        }
                    }
                }
                Button {
                    showingAddCard = true
                } label: {
                    Label("Añadir tarjeta a esta cuenta", systemImage: "plus.circle")
                }
            }

            Section {
                Button {
                    showingSnapshot = true
                } label: {
                    Label("Registrar saldo / valoración", systemImage: "camera.metering.matrix")
                }
            } footer: {
                Text("Las valoraciones permiten reflejar inversiones o ajustes de saldo sin convertirlos en ingresos o gastos.")
            }
        }
        .navigationTitle(account.bankAndAccountDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Editar") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            AccountFormView(account: account)
        }
        .sheet(isPresented: $showingSnapshot) {
            BalanceSnapshotFormView(account: account, currentBalance: balance)
        }
        .sheet(isPresented: $showingAddCard) {
            PaymentCardFormView(linkedAccount: account)
        }
        .sheet(isPresented: $showingAddReservation) {
            ReservedFundFormView(preferredAccount: account)
        }
    }
}

struct AccountFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialInstitution.name) private var institutions: [FinancialInstitution]
    @Query(sort: \FinancialAccount.sortOrder) private var allAccounts: [FinancialAccount]

    private let account: FinancialAccount?

    @State private var name: String
    @State private var institutionID: UUID?
    @State private var type: AccountType
    @State private var openingBalanceText: String
    @State private var openingDate: Date
    @State private var rateText: String
    @State private var targetText: String
    @State private var creditLimitText: String
    @State private var includeInNetWorth: Bool
    @State private var lastUpdatedAt: Date
    @State private var notes: String
    @State private var errorMessage: String?

    init(account: FinancialAccount? = nil) {
        self.account = account
        _name = State(initialValue: account?.name ?? "")
        _institutionID = State(initialValue: account?.institution?.id)
        _type = State(initialValue: account?.type ?? .checking)
        _openingBalanceText = State(initialValue: account.map {
            String(format: "%.2f", Double($0.openingBalanceMinor) / 100)
        } ?? "")
        _openingDate = State(initialValue: account?.openingDate ?? .now)
        _rateText = State(initialValue: account.map { String(format: "%.2f", $0.annualInterestRate * 100) } ?? "")
        _targetText = State(initialValue: account.map { String(format: "%.2f", Double($0.targetBalanceMinor) / 100) } ?? "")
        _creditLimitText = State(initialValue: account?.creditLimitMinor.map { String(format: "%.2f", Double($0) / 100) } ?? "")
        _includeInNetWorth = State(initialValue: account?.includeInNetWorth ?? true)
        _lastUpdatedAt = State(initialValue: account?.lastUpdatedAt ?? .now)
        _notes = State(initialValue: account?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identificación") {
                    TextField("Nombre de la cuenta", text: $name)
                    Picker("Banco / entidad", selection: $institutionID) {
                        Text("Sin entidad").tag(nil as UUID?)
                        ForEach(institutions) { institution in
                            Text(institution.name).tag(Optional(institution.id))
                        }
                    }
                    Picker("Tipo", selection: $type) {
                        ForEach(AccountType.allCases) { type in
                            Label(type.title, systemImage: type.systemImage).tag(type)
                        }
                    }
                }

                Section {
                    TextField("Saldo inicial", text: $openingBalanceText)
                        .keyboardType(.numbersAndPunctuation)
                    DatePicker("Fecha del saldo inicial", selection: $openingDate, displayedComponents: .date)
                    TextField("TAE / interés anual (%)", text: $rateText)
                        .keyboardType(.decimalPad)
                    TextField("Objetivo de saldo", text: $targetText)
                        .keyboardType(.decimalPad)
                    if type == .creditCard {
                        TextField("Límite de crédito", text: $creditLimitText)
                            .keyboardType(.decimalPad)
                    }
                } header: {
                    Text("Saldo y rentabilidad")
                } footer: {
                    if type == .creditCard {
                        Text("En tarjetas, guarda la deuda como saldo negativo. Un pago desde otra cuenta se registra como transferencia hacia la tarjeta.")
                    }
                }

                Section("Control") {
                    DatePicker("Última actualización", selection: $lastUpdatedAt, displayedComponents: .date)
                    Toggle("Incluir en el patrimonio", isOn: $includeInNetWorth)
                    TextField("Notas", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(account == nil ? "Nueva cuenta" : "Editar cuenta")
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
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "Introduce un nombre."
            return
        }

        let openingBalance = MoneyParser.minorUnits(from: openingBalanceText) ?? 0
        let target = MoneyParser.minorUnits(from: targetText) ?? 0
        let creditLimit = MoneyParser.minorUnits(from: creditLimitText)
        let ratePercent = Double(rateText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let institution = institutions.first(where: { $0.id == institutionID })

        if let account {
            account.name = cleanName
            account.institution = institution
            account.type = type
            account.openingBalanceMinor = openingBalance
            account.openingDate = openingDate
            account.annualInterestRate = ratePercent / 100
            account.targetBalanceMinor = target
            account.creditLimitMinor = type == .creditCard ? creditLimit : nil
            account.includeInNetWorth = includeInNetWorth
            account.lastUpdatedAt = lastUpdatedAt
            account.notes = notes
            account.updatedAt = .now
        } else {
            modelContext.insert(FinancialAccount(
                name: cleanName,
                type: type,
                openingBalanceMinor: openingBalance,
                openingDate: openingDate,
                annualInterestRate: ratePercent / 100,
                targetBalanceMinor: target,
                creditLimitMinor: type == .creditCard ? creditLimit : nil,
                includeInNetWorth: includeInNetWorth,
                sortOrder: allAccounts.count,
                notes: notes,
                lastUpdatedAt: lastUpdatedAt,
                institution: institution
            ))
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BalanceSnapshotFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let account: FinancialAccount
    @State private var date = Date.now
    @State private var balanceText: String
    @State private var notes = ""
    @State private var errorMessage: String?

    init(account: FinancialAccount, currentBalance: Int64) {
        self.account = account
        _balanceText = State(initialValue: String(format: "%.2f", Double(currentBalance) / 100))
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Fecha", selection: $date, displayedComponents: .date)
                TextField("Saldo o valoración", text: $balanceText)
                    .keyboardType(.numbersAndPunctuation)
                TextField("Notas", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Registrar valoración")
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
        guard let balance = MoneyParser.minorUnits(from: balanceText) else {
            errorMessage = "Introduce un saldo válido."
            return
        }
        modelContext.insert(BalanceSnapshot(
            date: date,
            balanceMinor: balance,
            notes: notes,
            account: account
        ))
        account.lastUpdatedAt = date
        account.updatedAt = .now
        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
