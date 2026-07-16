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
                ContentUnavailableView(
                    "Sin entidades",
                    systemImage: "building.columns",
                    description: Text("Añade bancos, brókeres u otras entidades.")
                )
            } else {
                ForEach(institutions) { institution in
                    Button {
                        editingInstitution = institution
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
                                let accountCount = accounts.filter { $0.institution?.id == institution.id }.count
                                let cardCount = cards.filter { $0.institution?.id == institution.id }.count
                                Text("\(accountCount) cuenta(s) · \(cardCount) tarjeta(s)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
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

private struct InstitutionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let institution: FinancialInstitution?
    @State private var name: String
    @State private var colorHex: String
    @State private var notes: String
    @State private var errorMessage: String?

    init(institution: FinancialInstitution? = nil) {
        self.institution = institution
        _name = State(initialValue: institution?.name ?? "")
        _colorHex = State(initialValue: institution?.colorHex ?? "#1F6B7A")
        _notes = State(initialValue: institution?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nombre", text: $name)
                TextField("Color hexadecimal", text: $colorHex)
                    .textInputAutocapitalization(.characters)
                HStack {
                    Text("Vista previa")
                    Spacer()
                    Circle()
                        .fill(Color(hex: colorHex))
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
            institution.colorHex = colorHex
            institution.notes = notes
            institution.updatedAt = .now
        } else {
            modelContext.insert(FinancialInstitution(
                name: cleanName,
                colorHex: colorHex,
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
