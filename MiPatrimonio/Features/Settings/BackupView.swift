import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private struct FinanceBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw BackupError.invalidFile("no contiene datos.")
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct BackupView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var showingRestoreConfirmation = false
    @State private var exportDocument: FinanceBackupDocument?
    @State private var pendingBackup: FinanceBackup?
    @State private var pendingFileName: String?
    @State private var message: String?

    private var defaultFileName: String {
        let day = String(ISO8601DateFormatter().string(from: .now).prefix(10))
        return "MiPatrimonio-copia-\(day)"
    }

    var body: some View {
        List {
            Section {
                Text("Guarda una copia completa en Archivos antes de reinstalar la app o cambiar de dispositivo. Después podrás seleccionarla aquí para recuperar tus datos.")
                    .foregroundStyle(.secondary)
            }

            Section("Crear copia") {
                Button {
                    exportBackup()
                } label: {
                    Label("Exportar todos mis datos", systemImage: "square.and.arrow.up")
                }
                Text("Incluye cuentas, tarjetas, movimientos, presupuestos repetidos, reglas de categorías, objetivos y los demás datos financieros.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    showingImporter = true
                } label: {
                    Label("Elegir copia JSON", systemImage: "square.and.arrow.down")
                }

                if let backup = pendingBackup {
                    LabeledContent("Archivo", value: pendingFileName ?? "Copia seleccionada")
                    LabeledContent("Creada", value: backup.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Cuentas", value: "\(backup.accounts.count)")
                    LabeledContent("Movimientos", value: "\(backup.transactions.count)")
                    LabeledContent("Tarjetas", value: "\(backup.cards.count)")
                    LabeledContent("Presupuestos", value: "\(backup.budgets.count + (backup.recurringBudgets?.count ?? 0))")
                    LabeledContent("Reglas de categorías", value: "\(backup.categoryRules?.count ?? 0)")
                    LabeledContent("Registros en total", value: "\(backup.totalRecords)")

                    Button(role: .destructive) {
                        showingRestoreConfirmation = true
                    } label: {
                        Label("Reemplazar datos con esta copia", systemImage: "arrow.counterclockwise")
                    }
                }
            } header: {
                Text("Restaurar copia")
            } footer: {
                Text("La restauración sustituye todos los datos financieros que haya ahora en esta app. Revisa la fecha y el contenido de la copia antes de continuar.")
            }

            Section("Privacidad") {
                Text("El archivo JSON contiene tus datos financieros sin contraseña. Guárdalo en una ubicación privada y no lo compartas.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Copia de seguridad")
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: defaultFileName
        ) { result in
            exportDocument = nil
            switch result {
            case .success:
                message = "Copia guardada. Conserva este archivo para recuperar tus datos."
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            Task { @MainActor in
                importBackup(result)
            }
        }
        .confirmationDialog(
            "Reemplazar todos los datos financieros",
            isPresented: $showingRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sí, restaurar esta copia", role: .destructive) {
                restoreBackup()
            }
        } message: {
            Text("Los datos actuales se eliminarán y se reemplazarán por los de «\(pendingFileName ?? "la copia")». Esta acción no se puede deshacer.")
        }
        .alert("Copia de seguridad", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("Aceptar", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func exportBackup() {
        do {
            let backup = try BackupService.capture(in: modelContext)
            exportDocument = FinanceBackupDocument(data: try BackupService.encode(backup))
            showingExporter = true
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func importBackup(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            pendingBackup = try BackupService.decode(data)
            pendingFileName = url.lastPathComponent
        } catch {
            pendingBackup = nil
            pendingFileName = nil
            message = error.localizedDescription
        }
    }

    private func restoreBackup() {
        guard let backup = pendingBackup else { return }
        do {
            try BackupService.restore(backup, in: modelContext)
            pendingBackup = nil
            pendingFileName = nil
            message = "Datos restaurados correctamente: \(backup.totalRecords) registros."
        } catch {
            message = "No se pudo restaurar la copia: \(error.localizedDescription)"
        }
    }
}
