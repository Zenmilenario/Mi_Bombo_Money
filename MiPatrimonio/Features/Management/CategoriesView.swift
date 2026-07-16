import SwiftData
import SwiftUI

struct CategoriesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinanceCategory.sortOrder) private var categories: [FinanceCategory]
    @Query private var transactions: [FinancialTransaction]
    @Query private var budgets: [MonthlyBudget]
    @Query private var recurringMovements: [RecurringMovement]

    @State private var showingAdd = false
    @State private var editingCategory: FinanceCategory?
    @State private var errorMessage: String?

    private var activeCategories: [FinanceCategory] {
        categories.filter { !$0.isArchived }
    }

    private var archivedCategories: [FinanceCategory] {
        categories.filter(\.isArchived)
    }

    var body: some View {
        List {
            if activeCategories.isEmpty {
                ContentUnavailableView(
                    "Sin categorías",
                    systemImage: "tag",
                    description: Text("Crea categorías para clasificar ingresos, gastos y transferencias.")
                )
            } else {
                categorySection("Activas", items: activeCategories)
            }

            if !archivedCategories.isEmpty {
                Section("Archivadas") {
                    ForEach(archivedCategories) { category in
                        categoryRow(category)
                            .swipeActions {
                                Button("Restaurar") {
                                    category.isArchived = false
                                    category.updatedAt = .now
                                    saveContext()
                                }
                                .tint(.blue)
                            }
                    }
                }
            }
        }
        .navigationTitle("Categorías")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Añadir categoría")
            }
        }
        .sheet(isPresented: $showingAdd) {
            CategoryFormView()
        }
        .sheet(item: $editingCategory) { category in
            CategoryFormView(category: category)
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

    @ViewBuilder
    private func categorySection(_ title: String, items: [FinanceCategory]) -> some View {
        Section(title) {
            ForEach(items) { category in
                Button {
                    editingCategory = category
                } label: {
                    categoryRow(category)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button {
                        archive(category)
                    } label: {
                        Label("Archivar", systemImage: "archivebox")
                    }
                    .tint(.orange)

                    Button(role: .destructive) {
                        delete(category)
                    } label: {
                        Label("Eliminar", systemImage: "trash")
                    }
                    .disabled(category.isSystem)
                }
            }
        }
    }

    private func categoryRow(_ category: FinanceCategory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: category.systemImage)
                .foregroundStyle(Color(hex: category.colorHex))
                .frame(width: 38, height: 38)
                .background(Color(hex: category.colorHex).opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(category.name)
                        .foregroundStyle(.primary)
                    if category.isSystem {
                        Text("Sistema")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.thinMaterial, in: Capsule())
                    }
                }
                Text(category.kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private func archive(_ category: FinanceCategory) {
        guard !category.isSystem else {
            errorMessage = "Las categorías del sistema no se pueden archivar."
            return
        }
        category.isArchived = true
        category.updatedAt = .now
        saveContext()
    }

    private func delete(_ category: FinanceCategory) {
        guard !category.isSystem else {
            errorMessage = "Las categorías del sistema no se pueden eliminar."
            return
        }

        let isReferenced = transactions.contains { $0.category?.id == category.id }
            || budgets.contains { $0.category?.id == category.id }
            || recurringMovements.contains { $0.category?.id == category.id }

        guard !isReferenced else {
            errorMessage = "Esta categoría está en uso. Archívala para conservar el historial."
            return
        }

        modelContext.delete(category)
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

private struct CategoryFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinanceCategory.sortOrder) private var allCategories: [FinanceCategory]

    private let category: FinanceCategory?

    @State private var name: String
    @State private var kind: CategoryKind
    @State private var systemImage: String
    @State private var colorHex: String
    @State private var errorMessage: String?

    init(category: FinanceCategory? = nil) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _kind = State(initialValue: category?.kind ?? .expense)
        _systemImage = State(initialValue: category?.systemImage ?? "tag")
        _colorHex = State(initialValue: category?.colorHex ?? "#4D7C8A")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Categoría") {
                    TextField("Nombre", text: $name)
                    Picker("Uso", selection: $kind) {
                        ForEach(CategoryKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .disabled(category?.isSystem == true)
                }

                Section("Apariencia") {
                    TextField("Símbolo SF Symbols", text: $systemImage)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Color hexadecimal", text: $colorHex)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    HStack {
                        Label("Vista previa", systemImage: systemImage.isEmpty ? "tag" : systemImage)
                            .foregroundStyle(Color(hex: colorHex))
                        Spacer()
                        Circle()
                            .fill(Color(hex: colorHex))
                            .frame(width: 28, height: 28)
                    }
                }

                if category?.isSystem == true {
                    Section {
                        Label("Esta categoría es necesaria para la lógica interna de la aplicación.", systemImage: "lock.shield")
                            .font(.footnote)
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
            .navigationTitle(category == nil ? "Nueva categoría" : "Editar categoría")
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
        let cleanImage = systemImage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "Introduce un nombre."
            return
        }

        let duplicateName = allCategories.contains {
            $0.id != category?.id
                && $0.name.compare(cleanName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard !duplicateName else {
            errorMessage = "Ya existe una categoría con ese nombre."
            return
        }

        if let category {
            category.name = cleanName
            if !category.isSystem { category.kind = kind }
            category.systemImage = cleanImage.isEmpty ? "tag" : cleanImage
            category.colorHex = colorHex
            category.updatedAt = .now
        } else {
            modelContext.insert(FinanceCategory(
                name: cleanName,
                kind: kind,
                systemImage: cleanImage.isEmpty ? "tag" : cleanImage,
                colorHex: colorHex,
                sortOrder: allCategories.count
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
