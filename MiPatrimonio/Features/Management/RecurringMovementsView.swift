import SwiftData
import SwiftUI

struct RecurringMovementsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurringMovement.nextDueDate) private var recurringMovements: [RecurringMovement]
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]

    @State private var showingAdd = false
    @State private var showingInvestmentAdd = false
    @State private var editingMovement: RecurringMovement?
    @State private var errorMessage: String?
    @State private var confirmationMessage: String?

    private var activeMovements: [RecurringMovement] {
        recurringMovements.filter(\.isActive)
    }

    private var inactiveMovements: [RecurringMovement] {
        recurringMovements.filter { !$0.isActive }
    }

    var body: some View {
        List {
            Section {
                Button {
                    showingInvestmentAdd = true
                } label: {
                    Label("Programar aportación mensual a inversión", systemImage: "arrow.left.arrow.right.circle")
                }
                .disabled(!hasInvestmentPair)
            } header: {
                Text("Cuenta de valores")
            } footer: {
                Text("Necesitas una cuenta de origen y otra de tipo Inversión. La aportación se registrará al abrir la app cuando llegue su fecha.")
            }

            if recurringMovements.isEmpty {
                ContentUnavailableView(
                    "Sin movimientos periódicos",
                    systemImage: "repeat.circle",
                    description: Text("Añade nóminas, recibos, cuotas y suscripciones recurrentes.")
                )
            } else {
                movementSection("Activos", items: activeMovements)
                movementSection("Inactivos", items: inactiveMovements)
            }
        }
        .navigationTitle("Movimientos recurrentes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Añadir movimiento periódico")
            }
        }
        .sheet(isPresented: $showingAdd) {
            RecurringMovementFormView()
        }
        .sheet(isPresented: $showingInvestmentAdd) {
            RecurringMovementFormView(investmentContribution: true)
        }
        .sheet(item: $editingMovement) { movement in
            RecurringMovementFormView(movement: movement)
        }
        .alert("No se pudo completar la operación", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Aceptar", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Error desconocido")
        }
        .alert("Movimiento creado", isPresented: Binding(
            get: { confirmationMessage != nil },
            set: { if !$0 { confirmationMessage = nil } }
        )) {
            Button("Aceptar", role: .cancel) { confirmationMessage = nil }
        } message: {
            Text(confirmationMessage ?? "")
        }
    }

    private var hasInvestmentPair: Bool {
        accounts.contains { !$0.isArchived && $0.type == .investment }
            && accounts.contains { !$0.isArchived && !$0.type.isLiability && $0.type != .investment }
    }

    @ViewBuilder
    private func movementSection(_ title: String, items: [RecurringMovement]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { movement in
                    Button {
                        editingMovement = movement
                    } label: {
                        movementRow(movement)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        Button {
                            createNow(from: movement)
                        } label: {
                            Label("Registrar", systemImage: "checkmark.circle")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            movement.isActive.toggle()
                            movement.updatedAt = .now
                            saveContext()
                        } label: {
                            Label(movement.isActive ? "Pausar" : "Activar", systemImage: movement.isActive ? "pause" : "play")
                        }
                        .tint(.orange)

                        Button(role: .destructive) {
                            delete(movement)
                        } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func movementRow(_ movement: RecurringMovement) -> some View {
        HStack(spacing: 12) {
            Image(systemName: movement.isSubscription ? "repeat.circle.fill" : movement.type.systemImage)
                .foregroundStyle(movement.isActive ? Color.accentColor : .secondary)
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.09), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(movement.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                HStack(spacing: 5) {
                    Text(movement.frequency.title)
                    Text("·")
                    Text("Próximo: \(movement.nextDueDate.formatted(date: .abbreviated, time: .omitted))")
                    if movement.postsAutomatically == true && movement.type == .transfer {
                        Text("· Automático")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            PrivacyAmountText(minorUnits: movement.amountMinor, font: .subheadline, weight: .semibold)
        }
        .padding(.vertical, 4)
    }

    private func createNow(from movement: RecurringMovement) {
        guard movement.isActive else {
            errorMessage = "Activa el movimiento antes de registrarlo."
            return
        }
        if let endDate = movement.endDate, endDate < .now {
            errorMessage = "Este movimiento periódico ya ha finalizado."
            return
        }

        do {
            let transaction = try RecurringMovementService.createTransaction(from: movement, in: modelContext)
            confirmationMessage = "Se ha registrado «\(transaction.descriptionText)» y se ha actualizado la próxima fecha."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ movement: RecurringMovement) {
        modelContext.delete(movement)
        saveContext()
    }

    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RecurringMovementFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]
    @Query(sort: \FinanceCategory.sortOrder) private var categories: [FinanceCategory]

    private let movement: RecurringMovement?
    private let investmentContribution: Bool

    @State private var name: String
    @State private var type: TransactionType
    @State private var amountText: String
    @State private var sourceAccountID: UUID?
    @State private var destinationAccountID: UUID?
    @State private var categoryID: UUID?
    @State private var descriptionText: String
    @State private var notes: String
    @State private var frequency: RecurrenceFrequency
    @State private var interval: Int
    @State private var nextDueDate: Date
    @State private var hasEndDate: Bool
    @State private var endDate: Date
    @State private var isActive: Bool
    @State private var isSubscription: Bool
    @State private var postsAutomatically: Bool
    @State private var errorMessage: String?

    init(movement: RecurringMovement? = nil, investmentContribution: Bool = false) {
        self.movement = movement
        self.investmentContribution = investmentContribution
        _name = State(initialValue: movement?.name ?? (investmentContribution ? "Aportación a cuenta de valores" : ""))
        _type = State(initialValue: movement?.type ?? (investmentContribution ? .transfer : .expense))
        _amountText = State(initialValue: movement.map { String(format: "%.2f", Double($0.amountMinor) / 100) } ?? "")
        _sourceAccountID = State(initialValue: movement?.sourceAccount?.id)
        _destinationAccountID = State(initialValue: movement?.destinationAccount?.id)
        _categoryID = State(initialValue: movement?.category?.id)
        _descriptionText = State(initialValue: movement?.descriptionText ?? (investmentContribution ? "Aportación a cuenta de valores" : ""))
        _notes = State(initialValue: movement?.notes ?? "")
        _frequency = State(initialValue: movement?.frequency ?? .monthly)
        _interval = State(initialValue: movement?.interval ?? 1)
        _nextDueDate = State(initialValue: movement?.nextDueDate ?? .now)
        _hasEndDate = State(initialValue: movement?.endDate != nil)
        _endDate = State(initialValue: movement?.endDate ?? Calendar.autoupdatingCurrent.date(byAdding: .year, value: 1, to: .now) ?? .now)
        _isActive = State(initialValue: movement?.isActive ?? true)
        _isSubscription = State(initialValue: movement?.isSubscription ?? false)
        _postsAutomatically = State(initialValue: movement?.postsAutomatically ?? investmentContribution)
    }

    private var activeAccounts: [FinancialAccount] {
        accounts.filter { !$0.isArchived }
    }

    private var destinationAccounts: [FinancialAccount] {
        investmentContribution && movement == nil
            ? activeAccounts.filter { $0.type == .investment }
            : activeAccounts
    }

    private var compatibleCategories: [FinanceCategory] {
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
                    TextField("Nombre de la regla", text: $name)
                    if investmentContribution {
                        LabeledContent("Tipo", value: "Transferencia propia")
                    } else {
                        Picker("Tipo", selection: $type) {
                            ForEach(TransactionType.allCases) { type in
                                Label(type.title, systemImage: type.systemImage).tag(type)
                            }
                        }
                        .onChange(of: type) { _, newValue in
                            destinationAccountID = newValue == .transfer ? destinationAccountID : nil
                            if !compatibleCategories.contains(where: { $0.id == categoryID }) {
                                categoryID = defaultCategory(for: newValue)?.id
                            }
                            if newValue != .expense && newValue != .fee {
                                isSubscription = false
                            }
                            if newValue != .transfer { postsAutomatically = false }
                        }
                    }
                    TextField("Importe", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Descripción del movimiento", text: $descriptionText)
                }

                Section(type == .transfer ? "Cuentas de la transferencia" : "Cuenta y categoría") {
                    Picker(type == .transfer ? "Cuenta origen" : "Cuenta", selection: $sourceAccountID) {
                        Text("Selecciona una cuenta").tag(nil as UUID?)
                        ForEach(activeAccounts.filter { !investmentContribution || ($0.type != .investment && !$0.type.isLiability) }) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }

                    if type == .transfer {
                        Picker("Cuenta destino", selection: $destinationAccountID) {
                            Text("Selecciona una cuenta").tag(nil as UUID?)
                            ForEach(destinationAccounts) { account in
                                Text(account.name).tag(Optional(account.id))
                            }
                        }
                    }

                    Picker("Categoría", selection: $categoryID) {
                        Text("Sin categoría").tag(nil as UUID?)
                        ForEach(compatibleCategories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                }

                Section("Periodicidad") {
                    if investmentContribution {
                        LabeledContent("Frecuencia", value: "Cada mes")
                    } else {
                        Picker("Frecuencia", selection: $frequency) {
                            ForEach(RecurrenceFrequency.allCases) { frequency in
                                Text(frequency.title).tag(frequency)
                            }
                        }
                        Stepper("Cada \(interval) \(intervalUnit)", value: $interval, in: 1...24)
                    }
                    DatePicker("Próxima fecha", selection: $nextDueDate, displayedComponents: .date)
                    Toggle("Definir fecha de fin", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("Fecha de fin", selection: $endDate, in: nextDueDate..., displayedComponents: .date)
                    }
                }

                Section("Control") {
                    Toggle("Activo", isOn: $isActive)
                    if type == .transfer {
                        Toggle("Registrar automáticamente", isOn: $postsAutomatically)
                    }
                    if type == .expense || type == .fee {
                        Toggle("Es una suscripción", isOn: $isSubscription)
                    }
                    TextField("Notas", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if type == .transfer && postsAutomatically {
                    Section {
                        Text("Al abrir la app tras la fecha indicada, se registrará la transferencia. Bajará el saldo de origen y subirá el de destino sin contarse como gasto.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(movement == nil ? "Nuevo movimiento recurrente" : "Editar movimiento recurrente")
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
            .onAppear {
                if sourceAccountID == nil {
                    sourceAccountID = activeAccounts.first { !$0.type.isLiability && $0.type != .investment }?.id
                        ?? activeAccounts.first?.id
                }
                if investmentContribution && destinationAccountID == nil {
                    destinationAccountID = destinationAccounts.first?.id
                }
                if categoryID == nil { categoryID = defaultCategory(for: type)?.id }
            }
        }
    }

    private var intervalUnit: String {
        switch frequency {
        case .weekly: interval == 1 ? "semana" : "semanas"
        case .monthly: interval == 1 ? "mes" : "meses"
        case .quarterly: interval == 1 ? "trimestre" : "trimestres"
        case .yearly: interval == 1 ? "año" : "años"
        }
    }

    private func defaultCategory(for type: TransactionType) -> FinanceCategory? {
        switch type {
        case .interest:
            return categories.first { $0.name == "Intereses" }
        case .fee:
            return categories.first { $0.name == "Impuestos y comisiones" }
        case .transfer:
            return categories.first { $0.kind == .transfer }
        default:
            return categories.first { category in
                !category.isArchived && (
                    (type.countsAsIncome && (category.kind == .income || category.kind == .both))
                        || (type.countsAsExpense && (category.kind == .expense || category.kind == .both))
                )
            }
        }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "Introduce un nombre para la regla."
            return
        }
        guard let amount = MoneyParser.minorUnits(from: amountText), amount != 0 else {
            errorMessage = "Introduce un importe mayor que cero."
            return
        }
        guard let source = activeAccounts.first(where: { $0.id == sourceAccountID }) else {
            errorMessage = "Selecciona una cuenta."
            return
        }
        if investmentContribution && (source.type == .investment || source.type.isLiability) {
            errorMessage = "Selecciona una cuenta de origen disponible."
            return
        }

        let destination = destinationAccounts.first(where: { $0.id == destinationAccountID })
        if type == .transfer {
            guard let destination else {
                errorMessage = "Selecciona la cuenta destino."
                return
            }
            guard destination.id != source.id else {
                errorMessage = "La cuenta origen y destino deben ser distintas."
                return
            }
        }

        let category = categories.first(where: { $0.id == categoryID })
        let finalDescription = cleanDescription.isEmpty ? cleanName : cleanDescription

        if let movement {
            movement.name = cleanName
            movement.type = type
            movement.amountMinor = Swift.abs(amount)
            movement.sourceAccount = source
            movement.destinationAccount = type == .transfer ? destination : nil
            movement.category = category
            movement.descriptionText = finalDescription
            movement.notes = notes
            movement.frequency = investmentContribution ? .monthly : frequency
            movement.interval = investmentContribution ? 1 : Swift.max(1, interval)
            movement.nextDueDate = nextDueDate
            movement.endDate = hasEndDate ? endDate : nil
            movement.isActive = isActive
            movement.isSubscription = (type == .expense || type == .fee) && isSubscription
            movement.postsAutomatically = type == .transfer && postsAutomatically
            movement.updatedAt = .now
        } else {
            modelContext.insert(RecurringMovement(
                name: cleanName,
                type: type,
                amountMinor: Swift.abs(amount),
                descriptionText: finalDescription,
                notes: notes,
                frequency: investmentContribution ? .monthly : frequency,
                interval: investmentContribution ? 1 : interval,
                nextDueDate: nextDueDate,
                endDate: hasEndDate ? endDate : nil,
                isActive: isActive,
                isSubscription: (type == .expense || type == .fee) && isSubscription,
                postsAutomatically: type == .transfer && postsAutomatically,
                sourceAccount: source,
                destinationAccount: type == .transfer ? destination : nil,
                category: category
            ))
        }

        do {
            try modelContext.save()
            if type == .transfer && postsAutomatically && isActive {
                do {
                    try RecurringMovementService.postDueTransfers(in: modelContext)
                } catch {
                    errorMessage = "La regla se ha guardado, pero no se pudo registrar la aportación pendiente: \(error.localizedDescription)"
                    return
                }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
