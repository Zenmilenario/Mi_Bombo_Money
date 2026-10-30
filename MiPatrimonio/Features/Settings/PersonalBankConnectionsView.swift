import SwiftData
import SwiftUI

struct PersonalBankConnectionsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var account: CloudAccountManager
    @EnvironmentObject private var banking: PersonalBankingCoordinator
    @EnvironmentObject private var lock: AppLockManager
    @Query(sort: \FinancialAccount.sortOrder) private var accounts: [FinancialAccount]
    @Query private var transactions: [FinancialTransaction]
    @State private var server = ""
    @State private var search = ""
    @State private var busy = false
    @State private var error: String?
    @State private var selection: LinkingSelection?
    @State private var disconnecting: ConnectedBankSession?
    @State private var choices: [String: PersonalBankingPlan.Choice] = [:]
    @State private var browser = BankingBrowserAuthorization()
    @State private var operation: Task<Void, Never>?

    private struct LinkingSelection: Identifiable {
        let connection: ConnectedBankSession
        let remote: ConnectedBankAccount
        var id: String { remote.id }
    }
    private var filteredBanks: [ConnectedBank] {
        banking.banks.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            Section {
                Label("Tus bancos, en tus finanzas", systemImage: "building.columns.circle.fill").font(.headline)
                Text("Recibe saldos y movimientos. La conexión solo consulta información; no permite realizar pagos.")
                    .foregroundStyle(.secondary)
                Text(banking.message).font(.callout)
                if let message = banking.errorMessage { Text(message).foregroundStyle(.red) }
            }
            Section("Servidor de conexión personal") {
                Button("Comprobar conexión") { run { try await banking.configure(server: server, account: account) } }
                Text("Usa el servidor de producción preparado para tu cuenta cloud. No necesitas introducir una clave del servidor ni contraseñas bancarias aquí.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Detalles del servidor") { Text(server).font(.caption).textSelection(.enabled) }
            }
            if !banking.connections.isEmpty {
                Section {
                    Button { run { _ = await banking.synchronize(account: account, context: context, force: true); choices = [:] } } label: {
                        Label("Actualizar movimientos bancarios", systemImage: "arrow.clockwise")
                    }
                    Text("Se comprueban automáticamente al abrir la app, como máximo cada seis horas mientras siga abierta. Si el banco requiere renovar el permiso, tendrás que autorizarlo de nuevo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(banking.connections) { connection in
                Section(connection.bank) {
                    ForEach(connection.accounts) { remote in
                        let linked = linkedAccount(remote)
                        Button { selection = LinkingSelection(connection: connection, remote: remote) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: linked == nil ? "link.badge.plus" : "checkmark.circle.fill")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("•••• \(remote.lastFour) · \(remote.currency)")
                                    Text(linked?.name ?? "Asociar con una cuenta de la app").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.disabled(linked != nil || remote.currency != "EUR")
                    }
                    Text("Permiso válido hasta \(connection.validUntil.prefix(10)).").font(.caption).foregroundStyle(.secondary)
                    Button("Desconectar \(connection.bank)", role: .destructive) { disconnecting = connection }
                }
            }
            if let plan = banking.pendingPlan {
                reviewSection(plan)
            }
            if !banking.banks.isEmpty {
                Section("Conectar o renovar un banco") {
                    TextField("Buscar banco", text: $search)
                    ForEach(filteredBanks) { bank in
                        Button { run(protected: true) {
                            let client = try await banking.client(account: account)
                            let authorization = try await client.start(bank: bank)
                            try await browser.authorize(authorization)
                            try await banking.refresh(account: account)
                            banking.disconnected()
                        } } label: {
                            HStack {
                                Label(bank.name, systemImage: "building.columns.fill")
                                Spacer()
                                if bank.beta { Text("Beta").font(.caption) }
                            }
                        }
                    }
                }
            }
            Section {
                Text("Los movimientos nuevos se guardan en esta copia personal y se sincronizan con Supabase al cerrar esta pantalla. Los pagos ya registrados conservan su categoría y el dinero reservado que hayas utilizado.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Mis bancos")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy || banking.busy)
        .overlay { if busy || banking.busy { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
        .task {
            if let owner = account.session?.user.id {
                let saved = banking.savedServer(owner: owner)
                server = saved.isEmpty ? "https://" + BankingConnectionPolicy.personalServerHost : saved
                if !saved.isEmpty { run { try await banking.refresh(account: account) } }
            }
        }
        .onDisappear { operation?.cancel() }
        .sheet(item: $selection) { item in
            NavigationStack {
                List {
                    Section {
                        Text("\(item.connection.bank) · •••• \(item.remote.lastFour)").font(.headline)
                        Text("Elige la cuenta que ya utilizas para conservar sus reservas y movimientos. Se incorporará el saldo contable del banco al actualizar.")
                    }
                    Section("Cuentas existentes") {
                        ForEach(accounts.filter { !$0.isArchived && $0.bankIdentityKey == nil && $0.currencyCode == item.remote.currency && !$0.type.isLiability && $0.type != .investment }) { local in
                            Button { link(item, to: local) } label: {
                                Label(local.institution.map { "\($0.name) · \(local.name)" } ?? local.name, systemImage: local.type.systemImage)
                            }
                        }
                    }
                    Section {
                        Button("Crear una cuenta nueva") { link(item, to: nil) }
                        Text("Una cuenta de efectivo de un bróker no incluye el valor de sus acciones o ETF.").font(.caption)
                    }
                }
                .navigationTitle("Asociar cuenta")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { selection = nil } } }
            }
        }
        .confirmationDialog("¿Desconectar este banco? Se revocará el permiso; tus movimientos guardados se conservan.", isPresented: Binding(
            get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }
        ), titleVisibility: .visible) {
            if let connection = disconnecting {
                Button("Desconectar", role: .destructive) { run(protected: true) {
                    let client = try await banking.client(account: account)
                    try await client.disconnect(connection)
                    banking.disconnected(); try await banking.refresh(account: account)
                } }
            }
        }
        .alert("Conexión bancaria", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Aceptar", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
    @ViewBuilder private func reviewSection(_ plan: PersonalBankingPlan) -> some View {
        Section("Coincidencias por revisar") {
            Text("\(plan.items.count) movimientos pendientes · \(plan.alreadyImported) ya incorporados.")
            DisclosureGroup("Ver movimientos de esta consulta") {
                ForEach(plan.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text)
                        HStack {
                            Text(item.date, style: .date).font(.caption)
                            Spacer()
                            PrivacyAmountText(minorUnits: item.kind == "expense" ? -item.amount : item.amount, currencyCode: "EUR", signed: true)
                        }
                        if item.automaticMatch != nil { Text("Coincide con un movimiento existente").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Text("No se incorporará esta consulta hasta resolver las coincidencias. Si ya registraste un pago, selecciónalo: conservaremos su categoría, reserva y relación con cargos periódicos.")
                .font(.caption)
            ForEach(plan.items.filter { !$0.candidates.isEmpty && $0.automaticMatch == nil }) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.text).font(.headline)
                    HStack {
                        Text(item.date, style: .date).font(.caption)
                        PrivacyAmountText(minorUnits: item.amount, currencyCode: "EUR")
                    }
                    Menu {
                        Button("Es otro movimiento: añadirlo") { choices[item.id] = .new }
                        ForEach(transactions.filter { item.candidates.contains($0.id) }) { candidate in
                            Button("\(candidate.type.title) · \(candidate.descriptionText) · \(candidate.date.formatted(date: .abbreviated, time: .omitted))") {
                                choices[item.id] = .match(candidate.id)
                            }
                        }
                    } label: {
                        Label(choices[item.id] == nil ? "Elegir qué hacer" : "Decisión preparada", systemImage: choices[item.id] == nil ? "questionmark.circle" : "checkmark.circle")
                    }
                }.padding(.vertical, 4)
            }
            Button("Incorporar movimientos revisados") {
                do { try banking.confirm(choices: choices, account: account, context: context); choices = [:] }
                catch { self.error = error.localizedDescription }
            }
            .disabled((try? plan.resolutions(choices)) == nil)
        }
    }
    private func linkedAccount(_ remote: ConnectedBankAccount) -> FinancialAccount? {
        guard let server = URL(string: server) else { return nil }
        return accounts.first { $0.bankIdentityKey == PersonalBankingImporter.identity(server: server, accountID: remote.id) }
    }
    private func link(_ item: LinkingSelection, to local: FinancialAccount?) {
        do {
            guard let server = URL(string: server) else { throw BankingConnectionError.invalidConfiguration }
            try PersonalBankingImporter.link(item.remote, bank: item.connection.bank, server: server, to: local, in: context)
            selection = nil; banking.disconnected()
        } catch { self.error = error.localizedDescription; selection = nil }
    }
    private func run(protected: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                if protected { try await lock.withProtectedAction(action) }
                else { try await action() }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
