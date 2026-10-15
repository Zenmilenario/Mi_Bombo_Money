import LocalAuthentication
import SwiftUI

struct BankConnectionsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var serverURL = ""
    @State private var token = ""
    @State private var configured = false
    @State private var status: BankingServerStatus?
    @State private var banks: [ConnectedBank] = []
    @State private var connections: [ConnectedBankSession] = []
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var selectedPreview: BankAccountPreviewSelection?
    @State private var disconnecting: ConnectedBankSession?
    @State private var showingForget = false
    @State private var browser = BankingBrowserAuthorization()

    var body: some View {
        List {
            Section {
                Label("Prueba de conexión bancaria", systemImage: "lock.shield")
                    .font(.headline)
                Text("Demostración y sandbox: solo datos ficticios. Esta prueba no incorpora movimientos a tus cuentas ni modifica sus saldos.")
                    .foregroundStyle(.secondary)
                if let status {
                    LabeledContent("Entorno", value: status.mode == "demo" ? "Demostración" : "Sandbox de Enable Banking")
                }
            }
            if !configured {
                Section {
                    TextField("https://tu-servidor.tu-usuario.workers.dev", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Clave personal del servidor", text: $token)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                    Button("Comprobar y guardar conexión") { run { try await configure() } }
                } header: {
                    Text("Tu servidor privado")
                } footer: {
                    Text("La clave se genera al configurar el servidor. Se guarda en el llavero de este dispositivo y requiere un código de desbloqueo. No es la contraseña de tu banco.")
                }
            } else {
                Section("Servidor") {
                    Text(serverURL).font(.caption).foregroundStyle(.secondary)
                    Button("Actualizar conexiones") { run { try await refresh() } }
                    if busy { ProgressView("Consultando…") }
                }
                Section("Conectar banco de prueba") {
                    if banks.isEmpty {
                        Text("Actualiza las conexiones para consultar los bancos disponibles en este entorno.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(banks) { bank in
                        Button { run { try await connect(bank) } } label: {
                            HStack {
                                Label(bank.name, systemImage: "building.columns.fill")
                                Spacer()
                                if bank.beta { Text("Beta").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                ForEach(connections) { connection in
                    Section(connection.bank) {
                        ForEach(connection.accounts) { account in
                            Button {
                                selectedPreview = BankAccountPreviewSelection(connection: connection, account: account)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "building.columns")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(account.name)
                                        Text(account.lastFour.isEmpty ? account.currency : "•••• \(account.lastFour) · \(account.currency)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                            }
                        }
                        Button("Desconectar \(connection.bank)", role: .destructive) { disconnecting = connection }
                    }
                }
                Section {
                    Button("Olvidar acceso en este dispositivo", role: .destructive) { showingForget = true }
                } footer: {
                    Text("Desconecta primero las cuentas para revocar sus sesiones en el servidor. Olvidar el acceso solo borra la clave del llavero de este dispositivo.")
                }
            }
        }
        .disabled(busy)
        .navigationTitle("Conexión bancaria")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                if let configuration = try BankingCredentialStore.load() {
                    serverURL = configuration.serverURL.absoluteString
                    configured = true
                    run { try await refresh() }
                }
            } catch { errorMessage = "No se ha podido leer el acceso protegido del dispositivo." }
        }
        .sheet(item: $selectedPreview) { selection in
            NavigationStack { BankAccountPreviewView(selection: selection) }
        }
        .confirmationDialog("¿Desconectar esta cuenta de prueba?", isPresented: Binding(
            get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }
        ), titleVisibility: .visible) {
            if let connection = disconnecting {
                Button("Desconectar", role: .destructive) {
                    run {
                        let client = try client()
                        try await authenticateLocally()
                        try await client.disconnect(connection)
                        try await refresh()
                    }
                }
            }
        }
        .confirmationDialog("¿Olvidar la clave del servidor en este dispositivo?", isPresented: $showingForget, titleVisibility: .visible) {
            Button("Olvidar acceso", role: .destructive) {
                run {
                    try await authenticateLocally()
                    try BankingCredentialStore.delete()
                    configured = false; status = nil; banks = []; connections = []; token = ""; serverURL = ""
                }
            }
        }
        .alert("Conexión bancaria", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("Aceptar", role: .cancel) { errorMessage = nil } } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { token = "" }
        }
    }

    @MainActor private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await action() }
            catch let error as BankingConnectionError { errorMessage = error.localizedDescription }
            catch is CancellationError { }
            catch { errorMessage = "No se pudo completar la operación. Comprueba tu conexión o el código de desbloqueo del dispositivo." }
        }
    }
    @MainActor private func configure() async throws {
        let configuration = try BankingServerConfiguration.validated(url: serverURL, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        try await authenticateLocally()
        let client = BankingConnectionClient(configuration: configuration)
        let verifiedStatus = try await client.status()
        try BankingCredentialStore.save(configuration)
        token = ""; serverURL = configuration.serverURL.absoluteString; configured = true; status = verifiedStatus
        try await refresh()
    }
    @MainActor private func client() throws -> BankingConnectionClient {
        guard let configuration = try BankingCredentialStore.load() else { throw BankingConnectionError.missingConfiguration }
        return BankingConnectionClient(configuration: configuration)
    }
    @MainActor private func refresh() async throws {
        let client = try client()
        status = try await client.status()
        connections = try await client.connections()
        banks = try await client.banks()
    }
    @MainActor private func connect(_ bank: ConnectedBank) async throws {
        try await authenticateLocally()
        let client = try client()
        let start = try await client.start(bank: bank)
        try await browser.authorize(start)
        try await refresh()
    }
    @MainActor private func authenticateLocally() async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Cancelar"
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Protege el acceso a tu conexión bancaria") else {
            throw BankingConnectionError.authorizationFailed
        }
    }
}

private struct BankAccountPreviewSelection: Identifiable {
    let connection: ConnectedBankSession
    let account: ConnectedBankAccount
    var id: String { "\(connection.id):\(account.id)" }
}

private struct BankAccountPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let selection: BankAccountPreviewSelection
    @State private var preview: BankingPreview?
    @State private var movements: [BankingPreview.Movement] = []
    @State private var busy = false
    @State private var errorMessage: String?
    var body: some View {
        List {
            Section {
                Label("Datos de prueba · No se contabilizan", systemImage: "testtube.2")
                Text("Consulta de los últimos 30 días. Solo movimientos contabilizados por el banco de pruebas; no incluye la cartera de valores.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let preview {
                Section("Saldos recibidos") {
                    ForEach(Array(preview.balances.enumerated()), id: \.offset) { _, balance in
                        AdaptiveValueRow {
                            Text(balance.type).font(.caption)
                        } value: {
                            PrivacyAmountText(minorUnits: balance.amountMinor, currencyCode: balance.currency)
                        }
                    }
                }
                Section("Movimientos de prueba") {
                    ForEach(Array(movements.enumerated()), id: \.offset) { _, movement in
                        AdaptiveValueRow {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(movement.description)
                                Text(movement.bookingDate).font(.caption).foregroundStyle(.secondary)
                            }
                        } value: {
                            PrivacyAmountText(minorUnits: movement.signedAmountMinor, currencyCode: movement.currency, signed: true)
                        }
                    }
                    if preview.continuation != nil { Button("Cargar más movimientos") { Task { await loadNext() } }.disabled(busy) }
                }
            }
            if busy { ProgressView("Consultando…") }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
                Button("Reintentar") { Task { await loadNext() } }.disabled(busy)
            }
        }
        .navigationTitle(selection.connection.bank)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { dismiss() } } }
        .task(id: scenePhase) {
            if scenePhase == .active && preview == nil { await loadNext() }
        }
    }
    @MainActor private func loadNext() async {
        guard !busy else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            guard let configuration = try BankingCredentialStore.load() else { throw BankingConnectionError.missingConfiguration }
            let client = BankingConnectionClient(configuration: configuration)
            let data = try await client.preview(connection: selection.connection, account: selection.account, continuation: preview?.continuation)
            if let first = preview {
                preview = BankingPreview(balances: first.balances, transactions: [], continuation: data.continuation)
            } else { preview = data }
            var knownIDs = Set(movements.compactMap(\.id))
            movements.append(contentsOf: data.transactions.filter { item in
                guard let id = item.id else { return true }
                return knownIDs.insert(id).inserted
            })
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch let error as BankingConnectionError { errorMessage = error.localizedDescription }
        catch { errorMessage = "No se pudo consultar la cuenta de prueba. Vuelve a intentarlo." }
    }
}
