import SwiftData
import SwiftUI

struct InstitutionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialInstitution.name) private var institutions: [FinancialInstitution]
    @Query private var accounts: [FinancialAccount]
    @Query private var cards: [PaymentCard]

    @State private var showingAdd = false
    @State private var editingInstitution: FinancialInstitution?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if institutions.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "Sin entidades",
                        systemImage: "building.columns",
                        description: Text("Añade bancos, brókeres u otras entidades.")
                    )
                    Button("Añadir entidad") { showingAdd = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ForEach(institutions) { institution in
                    NavigationLink {
                        InstitutionDetailView(institution: institution)
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(hex: institution.colorHex))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    Image(systemName: "building.columns")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(institution.name)
                                    .foregroundStyle(.primary)
                                let accountCount = accounts.filter { $0.institution?.id == institution.id && !$0.isArchived }.count
                                let cardCount = cards.filter {
                                    !$0.isArchived && (
                                        $0.institution?.id == institution.id ||
                                        $0.linkedAccount?.institution?.id == institution.id
                                    )
                                }.count
                                Text("\(accountCount) cuenta(s) · \(cardCount) tarjeta(s)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Editar") { editingInstitution = institution }
                            .tint(.blue)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            delete(institution)
                        } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Bancos y entidades")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            InstitutionFormView()
        }
        .sheet(item: $editingInstitution) { institution in
            InstitutionFormView(institution: institution)
        }
        .alert("No se pudo eliminar", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Aceptar", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Error desconocido")
        }
    }

    private func delete(_ institution: FinancialInstitution) {
        let hasAccounts = accounts.contains { $0.institution?.id == institution.id }
        let hasCards = cards.contains { $0.institution?.id == institution.id }
        guard !hasAccounts && !hasCards else {
            errorMessage = "Esta entidad tiene cuentas o tarjetas asociadas. Cámbialas o elimínalas antes."
            return
        }
        modelContext.delete(institution)
        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct InstitutionDetailView: View {
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]
    @Query(sort: \PaymentCard.name) private var cards: [PaymentCard]

    let institution: FinancialInstitution
    @State private var showingAddCard = false
    @State private var showingEditInstitution = false

    private var linkedAccounts: [FinancialAccount] {
        accounts.filter { $0.institution?.id == institution.id && !$0.isArchived }
    }

    private var linkedCards: [PaymentCard] {
        cards.filter {
            !$0.isArchived && (
                $0.institution?.id == institution.id ||
                $0.linkedAccount?.institution?.id == institution.id
            )
        }
    }

    var body: some View {
        List {
            Section("Cuentas asociadas") {
                if linkedAccounts.isEmpty {
                    Text("Todavía no hay cuentas asociadas a esta entidad.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(linkedAccounts) { account in
                        Label(account.name, systemImage: account.type.systemImage)
                    }
                }
            }

            Section {
                if linkedCards.isEmpty {
                    Text("Todavía no hay tarjetas asociadas a esta entidad.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(linkedCards) { card in
                        NavigationLink {
                            PaymentCardDetailView(card: card)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(card.name, systemImage: card.type.systemImage)
                                Text(cardSubtitle(card))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Button {
                    showingAddCard = true
                } label: {
                    Label("Añadir tarjeta", systemImage: "plus.circle")
                }
            } header: {
                Text("Tarjetas")
            } footer: {
                Text("Las tarjetas son medios de pago. Su saldo pertenece a la cuenta vinculada.")
            }

            if !institution.notes.isEmpty {
                Section("Notas") {
                    Text(institution.notes)
                }
            }
        }
        .navigationTitle(institution.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Editar") { showingEditInstitution = true }
            }
        }
        .sheet(isPresented: $showingAddCard) {
            PaymentCardFormView(institution: institution)
        }
        .sheet(isPresented: $showingEditInstitution) {
            InstitutionFormView(institution: institution)
        }
    }

    private func cardSubtitle(_ card: PaymentCard) -> String {
        var parts: [String] = []
        if !card.lastFour.isEmpty {
            parts.append("•••• \(card.lastFour)")
        }
        parts.append(card.linkedAccount?.name ?? "Sin cuenta vinculada")
        return parts.joined(separator: " · ")
    }
}

private struct InstitutionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let institution: FinancialInstitution?
    @State private var name: String
    @State private var selectedColor: Color
    @State private var notes: String
    @State private var errorMessage: String?

    init(institution: FinancialInstitution? = nil) {
        self.institution = institution
        _name = State(initialValue: institution?.name ?? "")
        _selectedColor = State(initialValue: Color(hex: institution?.colorHex ?? "#1F6B7A"))
        _notes = State(initialValue: institution?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nombre", text: $name)
                ColorPicker("Color de la entidad", selection: $selectedColor, supportsOpacity: false)
                HStack {
                    Text("Vista previa")
                    Spacer()
                    Circle()
                        .fill(selectedColor)
                        .frame(width: 30, height: 30)
                }
                TextField("Notas", text: $notes, axis: .vertical)
                    .lineLimit(2...4)

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle(institution == nil ? "Nueva entidad" : "Editar entidad")
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
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "Introduce un nombre."
            return
        }

        if let institution {
            institution.name = cleanName
            institution.colorHex = selectedColor.hexRGB()
            institution.notes = notes
            institution.updatedAt = .now
        } else {
            modelContext.insert(FinancialInstitution(
                name: cleanName,
                colorHex: selectedColor.hexRGB(),
                notes: notes
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
