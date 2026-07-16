import SwiftData
import SwiftUI

struct AccountsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]
    @Query(sort: \PaymentCard.name) private var cards: [PaymentCard]
    @Query(sort: \FinancialTransaction.date, order: .reverse) private var transactions: [FinancialTransaction]
    @Query(sort: \BalanceSnapshot.date, order: .reverse) private var snapshots: [BalanceSnapshot]
    @Query private var goals: [SavingsGoal]
    @Query private var recurringMovements: [RecurringMovement]

    @State private var showingAdd = false
    @State private var showingCardAdd = false
    @State private var editingAccount: FinancialAccount?
    @State private var editingCard: PaymentCard?
    @State private var errorMessage: String?

    private var activeAccounts: [FinancialAccount] {
        accounts.filter { !$0.isArchived }
    }

    private var assetAccounts: [FinancialAccount] {
        activeAccounts.filter { !$0.type.isLiability }
    }

    private var liabilityAccounts: [FinancialAccount] {
        activeAccounts.filter { $0.type.isLiability }
    }

    private var activeCards: [PaymentCard] {
        cards.filter { !$0.isArchived }
    }

    private var archivedCards: [PaymentCard] {
        cards.filter(\.isArchived)
    }

    var body: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty && cards.isEmpty {
                    ContentUnavailableView(
                        "Sin cuentas",
                        systemImage: "building.columns",
                        description: Text("Añade bancos, cuentas, tarjetas, efectivo o inversiones.")
                    )
                } else {
                    List {
                        Section("Resumen") {
                            HStack {
                                Text("Patrimonio incluido")
                                Spacer()
                                PrivacyAmountText(
                                    minorUnits: FinanceCalculator.netWorth(
                                        accounts: activeAccounts,
                                        transactions: transactions,
                                        snapshots: snapshots
                                    ),
                                    font: .headline,
                                    weight: .semibold
                                )
                            }
                        }

                        accountSection(title: "Activos", items: assetAccounts)
                        accountSection(title: "Pasivos", items: liabilityAccounts)
                        cardSection(title: "Tarjetas", items: activeCards)

                        if accounts.contains(where: \.isArchived) {
                            Section("Archivadas") {
                                ForEach(accounts.filter(\.isArchived)) { account in
                                    accountRow(account)
                                        .swipeActions {
                                            Button("Restaurar") {
                                                account.isArchived = false
                                                try? modelContext.save()
                                            }
                                            .tint(.blue)
                                        }
                                }
                            }
                        }

                        if !archivedCards.isEmpty {
                            Section("Tarjetas archivadas") {
                                ForEach(archivedCards) { card in
                                    cardRow(card)
                                        .swipeActions {
                                            Button("Restaurar") {
                                                card.isArchived = false
                                                card.updatedAt = .now
                                                try? modelContext.save()
                                            }
                                            .tint(.blue)
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Cuentas")
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
            .sheet(item: $editingAccount) { account in
                AccountFormView(account: account)
            }
            .sheet(item: $editingCard) { card in
                PaymentCardFormView(card: card)
            }
            .alert("No se pudo completar la operación", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("Aceptar", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Error desconocido")
            }
        }
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
                    .swipeActions(edge: .leading) {
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
        HStack(spacing: 12) {
            Image(systemName: account.type.systemImage)
                .foregroundStyle(Color(hex: account.institution?.colorHex ?? "#1F6B7A"))
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.09), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .font(.subheadline.weight(.medium))
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
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func cardSection(title: String, items: [PaymentCard]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { card in
                    Button {
                        editingCard = card
                    } label: {
                        cardRow(card)
                    }
                    .buttonStyle(.plain)
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
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.09), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(card.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(cardSubtitle(card))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let account = card.linkedAccount {
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
        }
        .padding(.vertical, 4)
    }

    private func cardSubtitle(_ card: PaymentCard) -> String {
        var parts = [card.type.title]
        if !card.lastFour.isEmpty { parts.append("•••• \(card.lastFour)") }
        if let account = card.linkedAccount { parts.append(account.name) }
        return parts.joined(separator: " · ")
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
        guard !hasTransactions && !hasSnapshots && !hasCards && !hasGoals && !hasRecurring else {
            errorMessage = "Esta cuenta está vinculada a movimientos, valoraciones, tarjetas, objetivos o reglas periódicas. Archívala para conservar el historial."
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


private struct PaymentCardFormView: View {
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
    @State private var notes: String
    @State private var errorMessage: String?

    init(card: PaymentCard? = nil) {
        self.card = card
        _name = State(initialValue: card?.name ?? "")
        _type = State(initialValue: card?.type ?? .debit)
        _lastFour = State(initialValue: card?.lastFour ?? "")
        _institutionID = State(initialValue: card?.institution?.id)
        _linkedAccountID = State(initialValue: card?.linkedAccount?.id)
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
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                } header: {
                    Text("Tarjeta")
                } footer: {
                    Text("La tarjeta es un medio de pago y no suma patrimonio por separado. Su saldo se toma de la cuenta vinculada. No se guarda el número completo ni el CVV.")
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

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLastFour = String(lastFour.filter(\.isNumber).suffix(4))
        guard !cleanName.isEmpty else {
            errorMessage = "Introduce un nombre."
            return
        }
        guard lastFour.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cleanLastFour.count == 4 else {
            errorMessage = "Introduce exactamente los últimos cuatro dígitos o deja el campo vacío."
            return
        }

        let institution = institutions.first { $0.id == institutionID }
        let linkedAccount = accounts.first { $0.id == linkedAccountID }

        if let card {
            card.name = cleanName
            card.type = type
            card.lastFour = cleanLastFour
            card.institution = institution
            card.linkedAccount = linkedAccount
            card.notes = notes
            card.updatedAt = .now
        } else {
            modelContext.insert(PaymentCard(
                name: cleanName,
                type: type,
                lastFour: cleanLastFour,
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

private struct AccountDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialTransaction.date, order: .reverse) private var transactions: [FinancialTransaction]
    @Query(sort: \BalanceSnapshot.date, order: .reverse) private var snapshots: [BalanceSnapshot]

    let account: FinancialAccount
    @State private var showingEdit = false
    @State private var showingSnapshot = false

    private var accountTransactions: [FinancialTransaction] {
        transactions.filter {
            $0.sourceAccount?.id == account.id || $0.destinationAccount?.id == account.id
        }
    }

    private var balance: Int64 {
        FinanceCalculator.balance(of: account, transactions: transactions, snapshots: snapshots)
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
        .navigationTitle(account.name)
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
            errorMessage = error.localizedDescription
        }
    }
}
