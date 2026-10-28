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

    @State private var encryptExport = true
    @State private var showingExportPasswordDialog = false
    @State private var exportPassword = ""
    @State private var exportPasswordConfirm = ""

    @State private var pendingEncryptedData: Data?
    @State private var pendingEncryptedFileName: String?
    @State private var showingImportPasswordDialog = false
    @State private var importPassword = ""

    private var defaultFileName: String {
        let day = String(ISO8601DateFormatter().string(from: .now).prefix(10))
        return encryptExport ? "MiPatrimonio-copia-\(day).enc" : "MiPatrimonio-copia-\(day)"
    }

    var body: some View {
        List {
            Section {
                Text("Guarda una copia completa en Archivos antes de reinstalar la app o cambiar de dispositivo. Después podrás seleccionarla aquí para recuperar tus datos.")
                    .foregroundStyle(.secondary)
            }

            Section("Crear copia") {
                Toggle("Proteger con contraseña (cifrado AES)", isOn: $encryptExport)

                Button {
                    if encryptExport {
                        exportPassword = ""
                        exportPasswordConfirm = ""
                        showingExportPasswordDialog = true
                    } else {
                        exportBackup(password: nil)
                    }
                } label: {
                    Label(encryptExport ? "Exportar copia cifrada" : "Exportar todos mis datos", systemImage: encryptExport ? "lock.doc" : "square.and.arrow.up")
                }

                Text(encryptExport
                    ? "Cifra todos tus datos con AES-256 para guardarlos de forma segura en iCloud Drive o compartirlos."
                    : "Incluye cuentas, tarjetas, movimientos, presupuestos, reglas, objetivos y valoraciones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    showingImporter = true
                } label: {
                    Label("Elegir copia JSON o cifrada", systemImage: "square.and.arrow.down")
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

            Section("Seguridad y Privacidad") {
                Text("Las copias cifradas con contraseña utilizan AES-GCM y derivación PBKDF2-SHA256. Si olvidas la contraseña, la copia cifrada no se podrá recuperar.")
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
                message = "Copia guardada con éxito. Conserva este archivo para recuperar tus datos."
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json, .data],
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
        .alert("Establecer contraseña de copia", isPresented: $showingExportPasswordDialog) {
            SecureField("Contraseña", text: $exportPassword)
            SecureField("Confirmar contraseña", text: $exportPasswordConfirm)
            Button("Cifrar y guardar") {
                if exportPassword.count < 10 {
                    message = "Usa una contraseña de al menos 10 caracteres."
                } else if exportPassword != exportPasswordConfirm {
                    message = "Las contraseñas no coinciden."
                } else {
                    exportBackup(password: exportPassword)
                }
            }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Introduce una contraseña para proteger tu archivo de copia.")
        }
        .alert("Copia protegida", isPresented: $showingImportPasswordDialog) {
            SecureField("Contraseña de la copia", text: $importPassword)
            Button("Descifrar") {
                decryptAndLoadPendingBackup(password: importPassword)
            }
            Button("Cancelar", role: .cancel) {
                pendingEncryptedData = nil
                pendingEncryptedFileName = nil
            }
        } message: {
            Text("Esta copia de seguridad está cifrada. Introduce su contraseña para abrirla.")
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

    private func exportBackup(password: String?) {
        defer { exportPassword = ""; exportPasswordConfirm = "" }
        do {
            let backup = try BackupService.capture(in: modelContext)
            let data: Data
            if let password, !password.isEmpty {
                data = try BackupService.encodeEncrypted(backup, password: password)
            } else {
                data = try BackupService.encode(backup)
            }
            exportDocument = FinanceBackupDocument(data: data)
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
            let fileName = url.lastPathComponent

            if BackupService.isEncrypted(data) {
                pendingEncryptedData = data
                pendingEncryptedFileName = fileName
                importPassword = ""
                showingImportPasswordDialog = true
            } else {
                pendingBackup = try BackupService.decode(data)
                pendingFileName = fileName
            }
        } catch {
            pendingBackup = nil
            pendingFileName = nil
            message = error.localizedDescription
        }
    }

    private func decryptAndLoadPendingBackup(password: String) {
        defer { importPassword = "" }
        guard let data = pendingEncryptedData else { return }
        do {
            pendingBackup = try BackupService.decode(data, password: password)
            pendingFileName = pendingEncryptedFileName
            pendingEncryptedData = nil
            pendingEncryptedFileName = nil
        } catch {
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
