import SwiftData
import SwiftUI

private struct BankingTestWorkspaceKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var isBankingTestWorkspace: Bool {
        get { self[BankingTestWorkspaceKey.self] }
        set { self[BankingTestWorkspaceKey.self] = newValue }
    }
}

struct BankingWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var container: ModelContainer?
    @State private var errorMessage: String?
    var body: some View {
        Group {
            if let container {
                BankingWorkspaceContent(container: container)
                    .modelContainer(container)
                    .environment(\.isBankingTestWorkspace, true)
            } else if let errorMessage {
                VStack(spacing: 20) {
                    Text("No se pudo abrir el espacio de prueba").font(.headline)
                    Text(errorMessage)
                    Button("Volver a mis finanzas") { dismiss() }
                }.padding()
            } else { ProgressView("Abriendo el espacio de prueba…") }
        }
        .task {
            guard container == nil else { return }
            do { container = try PersistenceController.makeBankingTestContainer() }
            catch { errorMessage = "No se han modificado tus datos reales. Cierra esta pantalla y vuelve a intentarlo." }
        }
    }
}

private struct BankingWorkspaceContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var lockManager: AppLockManager
    @AppStorage("appLockEnabled") private var appLockEnabled = true
    let container: ModelContainer
    @State private var busy = false
    @State private var lastSync: Date?
    @State private var summary = "Conectando con las cuentas de prueba…"
    @State private var errorMessage: String?

    private var canAccessContent: Bool { scenePhase == .active && (!appLockEnabled || lockManager.isUnlocked) }
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack { title; Spacer(); actions }
                        VStack(alignment: .leading, spacing: 10) { title; actions }
                    }
                    Text(errorMessage ?? summary).font(.caption).foregroundStyle(errorMessage == nil ? Color.secondary : .red)
                    Text("Almacenamiento de prueba separado. Tus cuentas reales no cambian.").font(.caption)
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.14))
                RootTabView()
            }
            .opacity(canAccessContent ? 1 : 0)
            .allowsHitTesting(canAccessContent)
            .accessibilityHidden(!canAccessContent)
            if !canAccessContent {
                AppDesign.pageBackground.ignoresSafeArea()
                if scenePhase == .active {
                    VStack(spacing: 20) {
                        Label("Mi Patrimonio está bloqueado", systemImage: "lock.shield.fill")
                        Button("Desbloquear") { Task { await lockManager.authenticate() } }
                            .disabled(lockManager.isAuthenticating || lockManager.protectedActionInProgress)
                        if lockManager.isAuthenticating { ProgressView() }
                        if let message = lockManager.lastErrorMessage { Text(message).font(.caption) }
                    }.padding()
                }
            }
        }
        .task(id: canAccessContent) {
            if canAccessContent { await synchronize(force: false) }
        }
    }
    private var title: some View {
        Label("App de prueba · Datos ficticios", systemImage: "testtube.2").font(.headline)
    }
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack { refreshButton; closeButton }
            VStack(alignment: .leading) { refreshButton; closeButton }
        }.buttonStyle(.bordered)
    }
    private var refreshButton: some View {
        Button { Task { await synchronize(force: true) } } label: {
            HStack { if busy { ProgressView() }; Label("Actualizar", systemImage: "arrow.clockwise") }
        }.disabled(busy)
    }
    private var closeButton: some View {
        Button("Volver a mis finanzas") { dismiss() }
    }

    @MainActor private func synchronize(force: Bool) async {
        guard canAccessContent, !busy else { return }
        if !force, let lastSync, Date.now.timeIntervalSince(lastSync) < 60 { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            guard let configuration = try BankingCredentialStore.load() else { throw BankingConnectionError.missingConfiguration }
            let client = BankingConnectionClient(configuration: configuration)
            let status = try await client.status()
            guard ["demo", "sandbox"].contains(status.mode) else { throw BankingWorkspaceError.unsupportedEnvironment }
            let observedAt = Date.now
            let connections = try await client.connections()
            var feeds: [BankingAccountFeed] = []
            for connection in connections {
                for account in connection.accounts {
                    var movements: [BankingPreview.Movement] = []
                    var balances: [BankingPreview.Balance] = []
                    var cursor: String?
                    var visited = Set<String>()
                    var completed = false
                    for page in 0..<50 {
                        try Task.checkCancellation()
                        let preview = try await client.preview(connection: connection, account: account, continuation: cursor, asOf: observedAt)
                        if page == 0 { balances = preview.balances }
                        movements.append(contentsOf: preview.transactions)
                        guard movements.count <= 20_000 else { throw BankingWorkspaceError.incompleteHistory }
                        guard let next = preview.continuation else { completed = true; break }
                        guard visited.insert(next).inserted else { throw BankingWorkspaceError.incompleteHistory }
                        cursor = next
                    }
                    guard completed else { throw BankingWorkspaceError.incompleteHistory }
                    feeds.append(BankingAccountFeed(connection: connection, account: account, balances: balances, movements: movements))
                }
            }
            try Task.checkCancellation()
            guard canAccessContent else { throw CancellationError() }
            let result = try BankingWorkspaceImporter.apply(feeds, server: configuration.serverURL,
                mode: status.mode, in: container.mainContext, observedAt: observedAt)
            lastSync = observedAt
            summary = "\(result.accounts) cuentas actualizadas · \(result.inserted) movimientos nuevos. Se ven en Inicio, Cuentas y Movimientos."
            if connections.isEmpty { summary = "No hay conexiones activas. Vuelve a mis finanzas y conecta un banco de prueba." }
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch let error as BankingWorkspaceError { errorMessage = error.localizedDescription }
        catch let error as BankingConnectionError { errorMessage = error.localizedDescription }
        catch { errorMessage = "No se ha podido sincronizar. Se conservan los datos anteriores; pulsa Actualizar para reintentar." }
    }
}
