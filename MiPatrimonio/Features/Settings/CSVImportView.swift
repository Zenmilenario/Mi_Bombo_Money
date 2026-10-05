import CryptoKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct CSVImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]
    @Query(sort: \FinanceCategory.sortOrder) private var categories: [FinanceCategory]
    @Query(sort: \CategoryRule.updatedAt, order: .reverse) private var categoryRules: [CategoryRule]
    @Query(sort: \FinancialTransaction.date, order: .reverse) private var transactions: [FinancialTransaction]

    @State private var showingImporter = false
    @State private var selectedAccountID: UUID?
    @State private var parseResult: CSVParseResult?
    @State private var fileName = ""
    @State private var fileChecksum = ""
    @State private var includedRowIDs: Set<UUID> = []
    @State private var categoryCorrections: [UUID: CSVCategoryCorrection] = [:]
    @State private var editingCategoryRow: ImportPreviewRow?
    @State private var visibleRowLimit = 200
    @State private var errorMessage: String?
    @State private var confirmationMessage: String?

    private var activeAccounts: [FinancialAccount] {
        accounts.filter { !$0.isArchived }
    }

    private var previewRows: [ImportPreviewRow] {
        guard let parseResult else { return [] }
        return parseResult.drafts.map(makePreviewRow)
    }

    private var importableRows: [ImportPreviewRow] {
        previewRows.filter { row in
            includedRowIDs.contains(row.id) && row.isValid && !row.isExactDuplicate
        }
    }

    var body: some View {
        Form {
            Section {
                Button {
                    showingImporter = true
                } label: {
                    Label(fileName.isEmpty ? "Seleccionar CSV" : "Cambiar archivo", systemImage: "doc.badge.plus")
                }

                if !fileName.isEmpty {
                    LabeledContent("Archivo", value: fileName)
                }

                Picker("Cuenta por defecto", selection: $selectedAccountID) {
                    Text("Selecciona una cuenta").tag(nil as UUID?)
                    ForEach(activeAccounts) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
                .onChange(of: selectedAccountID) { _, _ in
                    resetDefaultSelection()
                }
            } header: {
                Text("Archivo")
            } footer: {
                Text("La cuenta por defecto se usa cuando el CSV no incluye una columna de cuenta. Para transferencias, el archivo debe identificar también la cuenta destino.")
            }

            if let parseResult {
                Section("Resumen") {
                    LabeledContent("Filas reconocidas", value: "\(parseResult.drafts.count)")
                    LabeledContent("Preparadas para importar", value: "\(importableRows.count)")
                    LabeledContent("Duplicados exactos", value: "\(previewRows.filter(\.isExactDuplicate).count)")
                    LabeledContent("Posibles duplicados", value: "\(previewRows.filter { $0.possibleDuplicateCount > 0 && !$0.isExactDuplicate }.count)")
                    LabeledContent("Filas con incidencias", value: "\(previewRows.filter { !$0.isValid }.count)")
                }

                if !parseResult.warnings.isEmpty {
                    Section("Avisos del archivo") {
                        ForEach(Array(parseResult.warnings.prefix(20).enumerated()), id: \.offset) { _, warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        if parseResult.warnings.count > 20 {
                            Text("Hay \(parseResult.warnings.count - 20) aviso(s) más.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    ForEach(Array(previewRows.prefix(visibleRowLimit))) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: inclusionBinding(for: row)) {
                                importRowLabel(row)
                            }
                            .disabled(!row.isValid || row.isExactDuplicate)

                            Button {
                                editingCategoryRow = row
                            } label: {
                                HStack {
                                    Label(row.category?.name ?? "Elegir categoría", systemImage: row.category?.systemImage ?? "tag")
                                        .foregroundStyle(Color(hex: row.category?.colorHex ?? "#4D7C8A"))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.subheadline)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(row.isExactDuplicate)
                            .accessibilityLabel("Cambiar categoría de \(row.draft.description): \(row.category?.name ?? "Sin categoría")")

                            if let phrase = categoryCorrections[row.id]?.rulePhrase {
                                Text(includedRowIDs.contains(row.id) && row.isValid && !row.isExactDuplicate
                                     ? "Al importar, recordar «\(phrase)»"
                                     : "Regla pendiente: selecciona esta fila para guardarla")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if previewRows.count > visibleRowLimit {
                        Button("Mostrar más movimientos (\(previewRows.count - visibleRowLimit) pendientes de mostrar)") {
                            visibleRowLimit += 200
                        }
                    }
                } header: {
                    Text("Revisión")
                } footer: {
                    Text("Toca una categoría para corregirla y, si quieres, recordarla como regla. Solo se guardan las reglas de las filas importadas. Los duplicados exactos se omiten; los posibles duplicados quedan desmarcados para que los revises.")
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "Selecciona un CSV",
                        systemImage: "tablecells",
                        description: Text("Se revisarán fechas, importes, cuentas, categorías y posibles duplicados antes de guardar.")
                    )
                    .frame(minHeight: 220)
                }
            }
        }
        .navigationTitle("Importar CSV")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingCategoryRow) { row in
            CSVCategoryCorrectionView(
                row: row,
                categories: categories,
                correction: categoryCorrections[row.id],
                otherCorrections: previewRows.filter { $0.id != row.id && $0.draft.type == row.draft.type }
                    .compactMap { categoryCorrections[$0.id] }
            ) { correction in
                categoryCorrections[row.id] = correction
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            Task { @MainActor in
                handleFileImporterResult(result)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if parseResult != nil {
                Button {
                    importSelectedRows()
                } label: {
                    Label(
                        importableRows.isEmpty ? "Nada seleccionado" : "Importar \(importableRows.count) movimiento(s)",
                        systemImage: "square.and.arrow.down"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(importableRows.isEmpty)
                .padding()
                .background(.bar)
            }
        }
        .onAppear {
            if selectedAccountID == nil { selectedAccountID = activeAccounts.first?.id }
        }
        .alert("No se pudo importar", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Aceptar", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Error desconocido")
        }
        .alert("Importación completada", isPresented: Binding(
            get: { confirmationMessage != nil },
            set: { if !$0 { confirmationMessage = nil } }
        )) {
            Button("Aceptar", role: .cancel) { confirmationMessage = nil }
        } message: {
            Text(confirmationMessage ?? "")
        }
    }

    private func importRowLabel(_ row: ImportPreviewRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.draft.description)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                PrivacyAmountText(
                    minorUnits: row.draft.amountMinor,
                    currencyCode: row.sourceAccount?.currencyCode ?? "EUR",
                    font: .subheadline,
                    weight: .semibold
                )
            }

            HStack(spacing: 5) {
                Text("Fila \(row.draft.rowNumber)")
                Text("·")
                Text(row.draft.date.formatted(date: .abbreviated, time: .omitted))
                Text("·")
                Text(row.draft.type.title)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(row.accountSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if categoryCorrections[row.id] != nil {
                Label("Categoría elegida por ti", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let phrase = row.categoryRulePhrase {
                Label("Categoría sugerida por «\(phrase)»", systemImage: "text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let validationMessage = row.validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if row.isExactDuplicate {
                Label("Duplicado exacto: se omitirá", systemImage: "equal.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if row.possibleDuplicateCount > 0 {
                Label(
                    "\(row.possibleDuplicateCount) posible(s) duplicado(s): revisar",
                    systemImage: "doc.on.doc.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func inclusionBinding(for row: ImportPreviewRow) -> Binding<Bool> {
        Binding(
            get: { includedRowIDs.contains(row.id) },
            set: { isIncluded in
                if isIncluded {
                    includedRowIDs.insert(row.id)
                } else {
                    includedRowIDs.remove(row.id)
                }
            }
        )
    }

    @MainActor
    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            let data = try Data(contentsOf: url)
            let parsed = try CSVImportService.parse(url: url)
            fileName = url.lastPathComponent
            fileChecksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            parseResult = parsed
            categoryCorrections.removeAll()
            visibleRowLimit = 200
            resetDefaultSelection()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError { return }
            parseResult = nil
            fileName = ""
            fileChecksum = ""
            includedRowIDs.removeAll()
            categoryCorrections.removeAll()
            visibleRowLimit = 200
            errorMessage = error.localizedDescription
        }
    }

    private func resetDefaultSelection() {
        let rows = previewRows
        includedRowIDs = Set(rows.compactMap { row in
            guard row.isValid, !row.isExactDuplicate, row.possibleDuplicateCount == 0 else { return nil }
            return row.id
        })
    }

    private func makePreviewRow(from draft: ImportedMovementDraft) -> ImportPreviewRow {
        let defaultAccount = activeAccounts.first { $0.id == selectedAccountID }
        let source = draft.sourceAccountName == nil
            ? defaultAccount
            : resolveAccount(named: draft.sourceAccountName)
        let destination = resolveAccount(named: draft.destinationAccountName)
        let resolvedCategory = resolveCategory(
            named: draft.categoryName,
            description: draft.description,
            for: draft.type
        )
        let correction = categoryCorrections[draft.id]
        let category: FinanceCategory?
        if let correction {
            category = categories.first {
                $0.id == correction.categoryID && CategoryRuleService.supports($0, for: draft.type)
            }
        } else {
            category = resolvedCategory.category
        }

        var validationMessage: String?
        if source == nil, let sourceName = draft.sourceAccountName {
            validationMessage = "La cuenta «\(sourceName)» no coincide con ninguna cuenta configurada."
        } else if source == nil {
            validationMessage = "Selecciona una cuenta por defecto."
        } else if draft.type == .transfer, destination == nil, let destinationName = draft.destinationAccountName {
            validationMessage = "La cuenta destino «\(destinationName)» no está configurada."
        } else if draft.type == .transfer, destination == nil {
            validationMessage = "La transferencia no identifica una cuenta destino."
        } else if draft.type == .transfer, source?.id == destination?.id {
            validationMessage = "La cuenta origen y destino son la misma."
        }

        let fingerprint = DuplicateDetectionService.fingerprint(
            date: draft.date,
            sourceAccountID: source?.id,
            destinationAccountID: draft.type == .transfer ? destination?.id : nil,
            type: draft.type,
            amountMinor: draft.amountMinor,
            description: draft.description
        )

        let exactByExternalID = draft.externalID.map { externalID in
            transactions.contains {
                $0.sourceAccount?.id == source?.id
                    && $0.externalID == externalID
                    && !externalID.isEmpty
            }
        } ?? false
        let exactByFingerprint = transactions.contains {
            !$0.fingerprint.isEmpty && $0.fingerprint == fingerprint
        }
        let exactDuplicate = exactByExternalID || exactByFingerprint

        let candidates = exactDuplicate ? [] : DuplicateDetectionService.candidates(
            date: draft.date,
            sourceAccountID: source?.id,
            destinationAccountID: draft.type == .transfer ? destination?.id : nil,
            type: draft.type,
            amountMinor: draft.amountMinor,
            description: draft.description,
            existing: transactions
        )

        return ImportPreviewRow(
            draft: draft,
            sourceAccount: source,
            destinationAccount: draft.type == .transfer ? destination : nil,
            category: category,
            categoryRulePhrase: correction == nil ? resolvedCategory.rulePhrase : nil,
            fingerprint: fingerprint,
            isExactDuplicate: exactDuplicate,
            possibleDuplicateCount: candidates.count,
            validationMessage: validationMessage
        )
    }

    private func resolveAccount(named rawName: String?) -> FinancialAccount? {
        guard let rawName else { return nil }
        let needle = normalized(rawName)
        guard !needle.isEmpty else { return nil }

        if let exact = activeAccounts.first(where: { normalized($0.name) == needle }) {
            return exact
        }
        if let institutionMatch = activeAccounts.first(where: { account in
            let combined = normalized("\(account.institution?.name ?? "") \(account.name)")
            return combined == needle
        }) {
            return institutionMatch
        }
        return activeAccounts.first { account in
            let accountName = normalized(account.name)
            return accountName.contains(needle) || needle.contains(accountName)
        }
    }

    private func resolveCategory(
        named rawName: String?,
        description: String,
        for type: TransactionType
    ) -> (category: FinanceCategory?, rulePhrase: String?) {
        if let rawName {
            let needle = normalized(rawName)
            if let match = categories.first(where: {
                CategoryRuleService.supports($0, for: type) && normalized($0.name) == needle
            }) {
                return (match, nil)
            }
        }

        if let match = CategoryRuleService.match(
            description: description, type: type, rules: categoryRules
        ) {
            return (match.category, match.phrase)
        }

        let preferredName: String
        switch type {
        case .income: preferredName = "Otros ingresos"
        case .expense: preferredName = "Otros gastos"
        case .interest: preferredName = "Intereses"
        case .fee: preferredName = "Impuestos y comisiones"
        case .transfer: preferredName = "Transferencias"
        }
        let fallback = categories.first {
            CategoryRuleService.supports($0, for: type) && $0.name == preferredName
        }
        return (fallback, nil)
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func importSelectedRows() {
        let rows = importableRows
        guard !rows.isEmpty else { return }

        // Build one rule per phrase/type, only from rows actually being imported.
        var pendingRules: [String: (phrase: String, type: TransactionType, category: FinanceCategory)] = [:]
        for row in rows {
            guard let correction = categoryCorrections[row.id] else { continue }
            guard let category = row.category,
                  CategoryRuleService.supports(category, for: row.draft.type) else {
                errorMessage = "Revisa la categoría de la fila \(row.draft.rowNumber). Ya no está disponible."
                return
            }
            guard let phrase = correction.rulePhrase else { continue }
            let key = "\(row.draft.type.rawValue):\(CategoryRuleService.normalized(phrase))"
            if let previous = pendingRules[key], previous.category.id != category.id {
                errorMessage = "La regla «\(phrase)» tiene dos categorías distintas. Revisa las filas antes de importar."
                return
            }
            pendingRules[key] = (phrase, row.draft.type, category)
        }

        // Preserve earlier edits before starting the atomic import.
        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let previousAutosave = modelContext.autosaveEnabled
        modelContext.autosaveEnabled = false
        defer { modelContext.autosaveEnabled = previousAutosave }

        do {
            let batch = ImportBatch(
                fileName: fileName,
                source: .csv,
                institutionName: rows.first?.sourceAccount?.institution?.name ?? "",
                importedRows: rows.count,
                skippedDuplicates: previewRows.filter(\.isExactDuplicate).count,
                possibleDuplicates: rows.filter { $0.possibleDuplicateCount > 0 }.count,
                checksum: fileChecksum,
                notes: "Importación revisada antes de guardar."
            )
            modelContext.insert(batch)

            for row in rows {
                let transaction = FinancialTransaction(
                    date: row.draft.date,
                    type: row.draft.type,
                    amountMinor: row.draft.amountMinor,
                    descriptionText: row.draft.description,
                    notes: row.draft.notes,
                    isReconciled: row.draft.isReconciled,
                    fingerprint: row.fingerprint,
                    duplicateState: row.possibleDuplicateCount > 0 ? .possible : .none,
                    externalID: row.draft.externalID,
                    importBatchID: batch.id,
                    sourceAccount: row.sourceAccount,
                    destinationAccount: row.destinationAccount,
                    category: row.category
                )
                modelContext.insert(transaction)
                if let sourceAccount = row.sourceAccount {
                    sourceAccount.lastUpdatedAt = Swift.max(sourceAccount.lastUpdatedAt, row.draft.date)
                    sourceAccount.updatedAt = .now
                }
                if let destinationAccount = row.destinationAccount {
                    destinationAccount.lastUpdatedAt = Swift.max(destinationAccount.lastUpdatedAt, row.draft.date)
                    destinationAccount.updatedAt = .now
                }
            }

            for rule in pendingRules.values {
                CategoryRuleService.remember(
                    phrase: rule.phrase, type: rule.type, category: rule.category,
                    existing: categoryRules, in: modelContext
                )
            }
            try modelContext.save()
            confirmationMessage = "Se han importado \(rows.count) movimiento(s). Los duplicados exactos se han omitido."
            if !pendingRules.isEmpty {
                confirmationMessage = (confirmationMessage ?? "") + " Se han guardado \(pendingRules.count) regla(s) de categorías."
            }
            parseResult = nil
            fileName = ""
            fileChecksum = ""
            includedRowIDs.removeAll()
            categoryCorrections.removeAll()
            visibleRowLimit = 200
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

private struct ImportPreviewRow: Identifiable {
    var id: UUID { draft.id }
    let draft: ImportedMovementDraft
    let sourceAccount: FinancialAccount?
    let destinationAccount: FinancialAccount?
    let category: FinanceCategory?
    let categoryRulePhrase: String?
    let fingerprint: String
    let isExactDuplicate: Bool
    let possibleDuplicateCount: Int
    let validationMessage: String?

    var isValid: Bool { validationMessage == nil }

    var accountSummary: String {
        guard let sourceAccount else { return "Cuenta sin resolver" }
        if let destinationAccount {
            return "\(sourceAccount.name) → \(destinationAccount.name)"
        }
        return sourceAccount.name
    }
}

private struct CSVCategoryCorrection {
    let categoryID: UUID
    let rulePhrase: String?
}

private struct CSVCategoryCorrectionView: View {
    @Environment(\.dismiss) private var dismiss
    let row: ImportPreviewRow
    let categories: [FinanceCategory]
    let otherCorrections: [CSVCategoryCorrection]
    let onApply: (CSVCategoryCorrection) -> Void

    @State private var categoryID: UUID?
    @State private var rememberRule: Bool
    @State private var phrase: String

    init(
        row: ImportPreviewRow,
        categories: [FinanceCategory],
        correction: CSVCategoryCorrection?,
        otherCorrections: [CSVCategoryCorrection],
        onApply: @escaping (CSVCategoryCorrection) -> Void
    ) {
        self.row = row
        self.categories = categories
        self.otherCorrections = otherCorrections
        self.onApply = onApply
        _categoryID = State(initialValue: correction?.categoryID ?? row.category?.id)
        _rememberRule = State(initialValue: correction?.rulePhrase != nil)
        _phrase = State(initialValue: correction?.rulePhrase ?? row.categoryRulePhrase ?? row.draft.description)
    }

    private var compatibleCategories: [FinanceCategory] {
        categories.filter { CategoryRuleService.supports($0, for: row.draft.type) }
    }

    private var ruleIssue: String? {
        guard rememberRule else { return nil }
        let normalizedPhrase = CategoryRuleService.normalized(phrase)
        guard normalizedPhrase.count >= 3 else {
            return "Escribe al menos tres caracteres reconocibles."
        }
        guard CategoryRuleService.normalized(row.draft.description).contains(normalizedPhrase) else {
            return "Usa una palabra o frase que aparezca en la descripción de este movimiento."
        }
        if otherCorrections.contains(where: {
            guard let otherPhrase = $0.rulePhrase else { return false }
            return CategoryRuleService.normalized(otherPhrase) == normalizedPhrase && $0.categoryID != categoryID
        }) {
            return "Has preparado esta misma regla con otra categoría en otra fila. Usa la misma categoría o desactiva una de las reglas."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Movimiento") {
                    Text(row.draft.description)
                    Text("Fila \(row.draft.rowNumber) · \(row.draft.type.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Recordar como regla", isOn: $rememberRule)
                    if rememberRule {
                        TextField("Texto que debe contener la descripción", text: $phrase, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if let ruleIssue {
                            Label(ruleIssue, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text("La corrección se aplica a esta fila. La regla se guardará al importar el movimiento y se usará en futuras sugerencias del mismo tipo. Si ya existe esa frase, se actualizará su categoría. Puedes acortarla, por ejemplo a «Mercadona». Las categorías reconocidas del CSV tienen prioridad sobre las reglas.")
                }

                Section("Categoría") {
                    if compatibleCategories.isEmpty {
                        Text("No hay categorías compatibles. Puedes crearlas en Ajustes → Categorías.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(compatibleCategories) { category in
                            Button {
                                categoryID = category.id
                            } label: {
                                HStack {
                                    Image(systemName: category.systemImage)
                                        .foregroundStyle(Color(hex: category.colorHex))
                                        .frame(width: 28)
                                    Text(category.name).foregroundStyle(.primary)
                                    Spacer()
                                    if categoryID == category.id {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(categoryID == category.id ? [.isSelected] : [])
                        }
                    }
                }
            }
            .navigationTitle("Elegir categoría")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aplicar") {
                        guard let categoryID else { return }
                        onApply(CSVCategoryCorrection(
                            categoryID: categoryID,
                            rulePhrase: rememberRule ? phrase.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                        ))
                        dismiss()
                    }
                    .disabled(!compatibleCategories.contains(where: { $0.id == categoryID }) || ruleIssue != nil)
                }
            }
        }
    }
}
