import SwiftData
import SwiftUI

struct CategoryRulesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CategoryRule.updatedAt, order: .reverse) private var rules: [CategoryRule]

    @State private var showingAdd = false
    @State private var editingRule: CategoryRule?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if rules.isEmpty {
                ContentUnavailableView(
                    "Sin reglas todavía",
                    systemImage: "text.magnifyingglass",
                    description: Text("Guarda una regla al registrar un movimiento o créala aquí para reconocer una descripción habitual.")
                )
            } else {
                Section {
                    ForEach(rules) { rule in
                        Button {
                            editingRule = rule
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: rule.category?.systemImage ?? "tag")
                                    .foregroundStyle(Color(hex: rule.category?.colorHex ?? "#4D7C8A"))
                                    .frame(width: 34, height: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rule.phrase)
                                        .foregroundStyle(.primary)
                                    Text("\(rule.transactionType.title) · \(rule.category?.name ?? "Sin categoría")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !rule.isActive || rule.category?.isArchived == true {
                                    Text(rule.category?.isArchived == true ? "Categoría archivada" : "Pausada")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                modelContext.delete(rule)
                                do { try modelContext.save() }
                                catch { errorMessage = error.localizedDescription }
                            } label: {
                                Label("Eliminar", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("Se aplica la frase más específica. La categoría se propone al escribir o importar; puedes cambiarla antes de guardar.")
                }
            }
        }
        .navigationTitle("Reglas de categorías")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Añadir regla")
            }
        }
        .sheet(isPresented: $showingAdd) { CategoryRuleFormView() }
        .sheet(item: $editingRule) { CategoryRuleFormView(rule: $0) }
        .alert("No se pudo guardar", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Aceptar", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Error desconocido")
        }
    }
}

private struct CategoryRuleFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinanceCategory.sortOrder) private var categories: [FinanceCategory]
    @Query private var allRules: [CategoryRule]

    private let rule: CategoryRule?
    @State private var phrase: String
    @State private var type: TransactionType
    @State private var categoryID: UUID?
    @State private var isActive: Bool
    @State private var errorMessage: String?

    init(rule: CategoryRule? = nil) {
        self.rule = rule
        _phrase = State(initialValue: rule?.phrase ?? "")
        _type = State(initialValue: rule?.transactionType ?? .expense)
        _categoryID = State(initialValue: rule?.category?.id)
        _isActive = State(initialValue: rule?.isActive ?? true)
    }

    private var compatibleCategories: [FinanceCategory] {
        categories.filter { CategoryRuleService.supports($0, for: type) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Por ejemplo: Mercadona", text: $phrase)
                        .textInputAutocapitalization(.sentences)
                    Picker("Tipo", selection: $type) {
                        ForEach(TransactionType.allCases) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option)
                        }
                    }
                    .onChange(of: type) { _, _ in
                        if !compatibleCategories.contains(where: { $0.id == categoryID }) {
                            categoryID = compatibleCategories.first?.id
                        }
                    }
                    Picker("Categoría", selection: $categoryID) {
                        ForEach(compatibleCategories) { option in
                            Label(option.name, systemImage: option.systemImage)
                                .tag(option.id as UUID?)
                        }
                    }
                    Toggle("Regla activa", isOn: $isActive)
                } footer: {
                    Text("Cuando la descripción contenga esta frase, se propondrá la categoría elegida. No distingue mayúsculas ni tildes.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(rule == nil ? "Nueva regla" : "Editar regla")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if categoryID == nil { categoryID = compatibleCategories.first?.id }
            }
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
        let cleanPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CategoryRuleService.normalized(cleanPhrase).count >= 3 else {
            errorMessage = "Escribe al menos tres caracteres reconocibles."
            return
        }
        guard let category = compatibleCategories.first(where: { $0.id == categoryID }) else {
            errorMessage = "Selecciona una categoría compatible."
            return
        }
        guard !allRules.contains(where: {
            $0.id != rule?.id && $0.transactionType == type
                && CategoryRuleService.normalized($0.phrase) == CategoryRuleService.normalized(cleanPhrase)
        }) else {
            errorMessage = "Ya existe una regla para esa frase y tipo de movimiento."
            return
        }

        if let rule {
            rule.phrase = cleanPhrase
            rule.transactionType = type
            rule.category = category
            rule.isActive = isActive
            rule.updatedAt = .now
        } else {
            modelContext.insert(CategoryRule(
                phrase: cleanPhrase, transactionType: type,
                isActive: isActive, category: category
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
