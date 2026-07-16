import SwiftData
import SwiftUI

struct GoalsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavingsGoal.createdAt, order: .reverse) private var goals: [SavingsGoal]
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]
    @Query private var transactions: [FinancialTransaction]
    @Query private var snapshots: [BalanceSnapshot]

    @State private var showingAdd = false
    @State private var editingGoal: SavingsGoal?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if goals.isEmpty {
                ContentUnavailableView(
                    "Sin objetivos",
                    systemImage: "target",
                    description: Text("Crea un objetivo de ahorro y sigue su progreso.")
                )
            } else {
                ForEach(goals) { goal in
                    Button {
                        editingGoal = goal
                    } label: {
                        goalRow(goal)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            delete(goal)
                        } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Objetivos de ahorro")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Añadir objetivo")
            }
        }
        .sheet(isPresented: $showingAdd) {
            GoalFormView()
        }
        .sheet(item: $editingGoal) { goal in
            GoalFormView(goal: goal)
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

    private func goalRow(_ goal: SavingsGoal) -> some View {
        let current = currentAmount(for: goal)
        let target = Swift.max(0, goal.targetAmountMinor)
        let progress = target > 0 ? Swift.min(1, Double(current) / Double(target)) : 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: goal.isCompleted || progress >= 1 ? "checkmark.seal.fill" : "target")
                    .foregroundStyle(Color(hex: goal.colorHex))
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let account = goal.linkedAccount {
                        Text("Vinculado a \(account.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let targetDate = goal.targetDate {
                        Text("Objetivo: \(targetDate.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress)
                .tint(Color(hex: goal.colorHex))

            HStack {
                PrivacyAmountText(minorUnits: current, font: .subheadline, weight: .semibold)
                Spacer()
                Text("de")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PrivacyAmountText(minorUnits: target, font: .subheadline, weight: .semibold)
            }
        }
        .padding(.vertical, 6)
    }

    private func currentAmount(for goal: SavingsGoal) -> Int64 {
        guard let account = goal.linkedAccount else {
            return goal.currentAmountMinor
        }
        return Swift.max(0, FinanceCalculator.balance(
            of: account,
            transactions: transactions,
            snapshots: snapshots
        ))
    }

    private func delete(_ goal: SavingsGoal) {
        modelContext.delete(goal)
        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct GoalFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]

    private let goal: SavingsGoal?

    @State private var name: String
    @State private var targetText: String
    @State private var currentText: String
    @State private var linkedAccountID: UUID?
    @State private var hasTargetDate: Bool
    @State private var targetDate: Date
    @State private var colorHex: String
    @State private var notes: String
    @State private var errorMessage: String?

    init(goal: SavingsGoal? = nil) {
        self.goal = goal
        _name = State(initialValue: goal?.name ?? "")
        _targetText = State(initialValue: goal.map { String(format: "%.2f", Double($0.targetAmountMinor) / 100) } ?? "")
        _currentText = State(initialValue: goal.map { String(format: "%.2f", Double($0.currentAmountMinor) / 100) } ?? "")
        _linkedAccountID = State(initialValue: goal?.linkedAccount?.id)
        _hasTargetDate = State(initialValue: goal?.targetDate != nil)
        _targetDate = State(initialValue: goal?.targetDate ?? Calendar.autoupdatingCurrent.date(byAdding: .month, value: 6, to: .now) ?? .now)
        _colorHex = State(initialValue: goal?.colorHex ?? "#2F7D66")
        _notes = State(initialValue: goal?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nombre", text: $name)
                    TextField("Importe objetivo", text: $targetText)
                        .keyboardType(.decimalPad)
                    Picker("Cuenta vinculada", selection: $linkedAccountID) {
                        Text("Ninguna").tag(nil as UUID?)
                        ForEach(accounts.filter { !$0.isArchived }) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                } header: {
                    Text("Objetivo")
                } footer: {
                    Text("Al vincular una cuenta, el progreso usa automáticamente su saldo actual. Sin vínculo, puedes actualizar el importe acumulado manualmente.")
                }

                if linkedAccountID == nil {
                    Section("Progreso manual") {
                        TextField("Importe acumulado", text: $currentText)
                            .keyboardType(.decimalPad)
                    }
                }

                Section("Plazo") {
                    Toggle("Definir fecha objetivo", isOn: $hasTargetDate)
                    if hasTargetDate {
                        DatePicker("Fecha", selection: $targetDate, displayedComponents: .date)
                    }
                }

                Section("Detalles") {
                    TextField("Color hexadecimal", text: $colorHex)
                        .textInputAutocapitalization(.characters)
                    HStack {
                        Text("Vista previa")
                        Spacer()
                        Circle()
                            .fill(Color(hex: colorHex))
                            .frame(width: 28, height: 28)
                    }
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
            .navigationTitle(goal == nil ? "Nuevo objetivo" : "Editar objetivo")
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
        guard let target = MoneyParser.minorUnits(from: targetText), target > 0 else {
            errorMessage = "El importe objetivo debe ser mayor que cero."
            return
        }

        let current = linkedAccountID == nil ? (MoneyParser.minorUnits(from: currentText) ?? 0) : 0
        let account = accounts.first { $0.id == linkedAccountID }

        if let goal {
            goal.name = cleanName
            goal.targetAmountMinor = target
            goal.currentAmountMinor = Swift.max(0, current)
            goal.linkedAccount = account
            goal.targetDate = hasTargetDate ? targetDate : nil
            goal.colorHex = colorHex
            goal.notes = notes
            goal.isCompleted = account == nil && current >= target
            goal.updatedAt = .now
        } else {
            modelContext.insert(SavingsGoal(
                name: cleanName,
                targetAmountMinor: target,
                currentAmountMinor: Swift.max(0, current),
                targetDate: hasTargetDate ? targetDate : nil,
                colorHex: colorHex,
                notes: notes,
                isCompleted: account == nil && current >= target,
                linkedAccount: account
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
