import SwiftData
import SwiftUI

struct ReservedFundsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReservedFund.createdAt, order: .reverse) private var funds: [ReservedFund]
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]
    @Query private var transactions: [FinancialTransaction]
    @Query private var snapshots: [BalanceSnapshot]

    @State private var showingAdd = false
    @State private var editingFund: ReservedFund?
    @State private var errorMessage: String?

    private var eligibleAccounts: [FinancialAccount] {
        accounts.filter { !$0.isArchived && $0.includeInNetWorth && !$0.type.isLiability && $0.type != .investment }
    }

    var body: some View {
        List {
            Section {
                Text("Aparta una parte del saldo de una cuenta para un pago concreto, como el máster. El saldo real no cambia; la app lo descuenta del dinero disponible para gastar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !eligibleAccounts.isEmpty {
                Section("Dinero disponible") {
                    LabeledContent("Disponible para usar") {
                        PrivacyAmountText(minorUnits: FinanceCalculator.spendableCash(
                            accounts: accounts,
                            funds: funds,
                            transactions: transactions,
                            snapshots: snapshots
                        ))
                    }
                }
            }

            Section("Reservas") {
                if funds.isEmpty {
                    ContentUnavailableView(
                        "Sin dinero reservado",
                        systemImage: "lock.circle",
                        description: Text("Añade un importe y la cuenta en la que se encuentra.")
                    )
                } else {
                    ForEach(funds) { fund in
                        Button {
                            editingFund = fund
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(fund.name)
                                        .foregroundStyle(.primary)
                                    Text(fund.account?.name ?? "Cuenta eliminada")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                PrivacyAmountText(minorUnits: fund.amountMinor)
                            }
                        }
                        .swipeActions {
                            Button("Eliminar", role: .destructive) {
                                modelContext.delete(fund)
                                save()
                            }
                        }
                    }
                }

                Button {
                    showingAdd = true
                } label: {
                    Label("Reservar dinero", systemImage: "plus.circle")
                }
                .disabled(eligibleAccounts.isEmpty)
            }

            if eligibleAccounts.isEmpty {
                Section {
                    Text("Primero añade una cuenta corriente, de ahorro, de efectivo u otra cuenta incluida en el patrimonio.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Dinero reservado")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Reservar dinero")
                .disabled(eligibleAccounts.isEmpty)
            }
        }
        .sheet(isPresented: $showingAdd) { ReservedFundFormView() }
        .sheet(item: $editingFund) { ReservedFundFormView(fund: $0) }
        .alert("No se pudo guardar", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Aceptar", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Error desconocido")
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

struct ReservedFundFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]

    private let fund: ReservedFund?
    private let preferredAccount: FinancialAccount?

    @State private var name: String
    @State private var amountText: String
    @State private var accountID: UUID?
    @State private var notes: String
    @State private var errorMessage: String?

    init(fund: ReservedFund? = nil, preferredAccount: FinancialAccount? = nil) {
        self.fund = fund
        self.preferredAccount = preferredAccount
        _name = State(initialValue: fund?.name ?? "")
        _amountText = State(initialValue: fund.map {
            String(format: "%.2f", Double($0.amountMinor) / 100)
        } ?? "")
        _accountID = State(initialValue: fund?.account?.id ?? preferredAccount?.id)
        _notes = State(initialValue: fund?.notes ?? "")
    }

    private var eligibleAccounts: [FinancialAccount] {
        accounts.filter { !$0.isArchived && $0.includeInNetWorth && !$0.type.isLiability && $0.type != .investment }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reserva") {
                    TextField("Nombre, por ejemplo Máster", text: $name)
                    TextField("Importe reservado", text: $amountText)
                        .keyboardType(.decimalPad)
                    Picker("Está en la cuenta", selection: $accountID) {
                        Text("Selecciona una cuenta").tag(nil as UUID?)
                        ForEach(eligibleAccounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                }

                Section {
                    TextField("Notas", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    Text("La reserva no crea un movimiento. Cuando pagues el máster, registra el gasto y reduce o elimina esta reserva.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(fund == nil ? "Reservar dinero" : "Editar reserva")
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
                if accountID == nil { accountID = preferredAccount?.id ?? eligibleAccounts.first?.id }
            }
        }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "Indica para qué reservas el dinero."
            return
        }
        guard let amount = MoneyParser.minorUnits(from: amountText), amount > 0 else {
            errorMessage = "Introduce un importe mayor que cero."
            return
        }
        guard let account = eligibleAccounts.first(where: { $0.id == accountID }) else {
            errorMessage = "Selecciona una cuenta disponible."
            return
        }

        if let fund {
            fund.name = cleanName
            fund.amountMinor = amount
            fund.account = account
            fund.notes = notes
            fund.updatedAt = .now
        } else {
            modelContext.insert(ReservedFund(
                name: cleanName,
                amountMinor: amount,
                notes: notes,
                account: account
            ))
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
