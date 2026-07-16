import CryptoKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct CSVImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]
    @Query(sort: \FinanceCategory.sortOrder) private var categories: [FinanceCategory]
    @Query(sort: \FinancialTransaction.date, order: .reverse) private var transactions: [FinancialTransaction]

    @State private var showingImporter = false
    @State private var selectedAccountID: UUID?
    @State private var parseResult: CSVParseResult?
    @State private var fileName = ""
    @State private var fileChecksum = ""
    @State private var includedRowIDs: Set<UUID> = []
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
                    ForEach(Array(previewRows.prefix(200))) { row in
                        Toggle(isOn: inclusionBinding(for: row)) {
                            importRowLabel(row)
                        }
                        .disabled(!row.isValid || row.isExactDuplicate)
                    }

                    if previewRows.count > 200 {
                        Text("La vista previa muestra las primeras 200 filas. El resto conserva la selección automática.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Revisión")
                } footer: {
                    Text("Los duplicados exactos se omiten. Los posibles duplicados quedan desmarcados para que decidas si deben importarse.")
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
            resetDefaultSelection()
        } catch {
            parseResult = nil
            includedRowIDs.removeAll()
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
        let category = resolveCategory(named: draft.categoryName, for: draft.type)

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

    private func resolveCategory(named rawName: String?, for type: TransactionType) -> FinanceCategory? {
        if let rawName {
            let needle = normalized(rawName)
            if let match = categories.first(where: { !$0.isArchived && normalized($0.name) == needle }) {
                return match
            }
        }

        switch type {
        case .interest:
            return categories.first { $0.name == "Intereses" }
        case .fee:
            return categories.first { $0.name == "Impuestos y comisiones" }
        case .transfer:
            return categories.first { $0.kind == .transfer }
        default:
            return categories.first { $0.name == "Sin categoría" }
        }
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

        do {
            try modelContext.save()
            confirmationMessage = "Se han importado \(rows.count) movimiento(s). Los duplicados exactos se han omitido."
            parseResult = nil
            fileName = ""
            fileChecksum = ""
            includedRowIDs.removeAll()
        } catch {
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
        return "\(sourceAccount.name) · \(category?.name ?? "Sin categoría")"
    }
}
