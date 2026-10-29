import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

private struct CloudWorkspaceKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isCloudWorkspace: Bool {
        get { self[CloudWorkspaceKey.self] }
        set { self[CloudWorkspaceKey.self] = newValue }
    }
}

struct FinanceWorkspaceRouter: View {
    @EnvironmentObject private var account: CloudAccountManager
    @AppStorage("cloudAccountModeEnabled") private var cloudMode = false
    var body: some View {
        Group {
            if account.pendingLink != nil { CloudLinkConfirmationView() }
            else if cloudMode {
                if let user = account.session?.user, !account.needsSignIn {
                    CloudFinanceWorkspaceView().id(user.id)
                } else { CloudSignInView() }
            } else { RootTabView() }
        }
    }
}

struct CloudSignInView: View {
    @EnvironmentObject private var account: CloudAccountManager
    @AppStorage("cloudAccountModeEnabled") private var cloudMode = false
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var creating = false
    @State private var validation: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Mi Bombo Money", systemImage: "cloud")
                        .font(.title2.bold())
                    Text("Tus finanzas, en tus dispositivos")
                        .font(.headline)
                    Text("Inicia sesión con la misma cuenta para mantener tus datos sincronizados. El usuario local de la app es un acceso distinto.")
                        .foregroundStyle(.secondary)
                }
                Section(creating ? "Crear cuenta cloud" : "Iniciar sesión") {
                    TextField("Correo electrónico", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Contraseña", text: $password)
                        .textContentType(creating ? .newPassword : .password)
                        .submitLabel(.go)
                        .onSubmit(submit)
                    if creating {
                        SecureField("Repite la contraseña", text: $confirmation).textContentType(.newPassword)
                        Text("Al menos 10 caracteres. Confirma tu correo desde este mismo dispositivo.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(action: submit) {
                        HStack {
                            if account.busy { ProgressView() }
                            Text(creating ? "Crear cuenta" : "Entrar")
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppDesign.actionFill)
                    .disabled(account.busy || !account.isConfigured)
                }
                if let message = validation ?? account.message {
                    Section { Text(message).font(.callout) }
                }
                Section {
                    Button(creating ? "Ya tengo una cuenta" : "Crear una cuenta") {
                        creating.toggle(); validation = nil; account.message = nil
                        password = ""; confirmation = ""
                    }
                    if !creating {
                        Button("He olvidado mi contraseña") {
                            Task { await account.recover(email: email) }
                        }
                    }
                    Button("Usar solo los datos de este dispositivo") { cloudMode = false }
                }
                .disabled(account.busy)
                Section {
                    Text("Al entrar se abre una copia local separada para tu cuenta. Tus datos actuales no se suben sin que elijas copiarlos.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Acceso cloud")
            .disabled(account.busy)
            .onDisappear { password = ""; confirmation = "" }
        }
    }
    private func submit() {
        validation = nil
        guard email.contains("@"), !password.isEmpty else { validation = "Introduce tu correo y contraseña."; return }
        if creating && (password.count < 10 || password != confirmation) {
            validation = "Usa al menos 10 caracteres y repite la misma contraseña."; return
        }
        let enteredPassword = password
        Task {
            await account.signIn(email: email, password: enteredPassword, create: creating)
            password = ""; confirmation = ""
        }
    }
}

private struct CloudLinkConfirmationView: View {
    @EnvironmentObject private var account: CloudAccountManager
    @State private var password = ""
    @State private var confirmation = ""
    @State private var validation: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(account.linkRequiresPassword ? "Nueva contraseña" : "Confirmar acceso", systemImage: "person.badge.key")
                        .font(.title2.bold())
                    Text(account.pendingLink?.user.email ?? "Cuenta verificada")
                    Text("El enlace se ha verificado con Supabase y con la solicitud de este dispositivo.")
                        .foregroundStyle(.secondary)
                }
                if account.linkRequiresPassword {
                    Section("Contraseña de tu cuenta cloud") {
                        SecureField("Nueva contraseña", text: $password).textContentType(.newPassword)
                        SecureField("Repite la contraseña", text: $confirmation).textContentType(.newPassword)
                        Text("Al menos 10 caracteres.").font(.caption)
                    }
                }
                if let message = validation ?? account.message { Section { Text(message) } }
                Section {
                    Button(account.linkRequiresPassword ? "Guardar contraseña y entrar" : "Continuar con esta cuenta") {
                        validation = nil
                        guard !account.linkRequiresPassword || (password.count >= 10 && password == confirmation) else {
                            validation = "Usa al menos 10 caracteres y repite la misma contraseña."; return
                        }
                        let entered = password
                        Task { await account.confirmLink(password: entered); password = ""; confirmation = "" }
                    }
                    .disabled(account.busy)
                    Button("Cancelar", role: .cancel) { account.cancelLink() }.disabled(account.busy)
                }
            }
            .navigationTitle("Acceso verificado")
            .onDisappear { password = ""; confirmation = "" }
        }
    }
}

private struct CloudFinanceWorkspaceView: View {
    @EnvironmentObject private var account: CloudAccountManager
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLockEnabled") private var appLockEnabled = true
    @StateObject private var sync = CloudSyncCoordinator()
    var body: some View {
        Group {
            if sync.ready, let container = sync.container {
                RootTabView()
                    .id(sync.viewGeneration)
                    .modelContainer(container)
                    .environment(\.isCloudWorkspace, true)
                    .environmentObject(sync)
            } else if sync.needsMigrationChoice {
                NavigationStack {
                    List {
                        Section {
                            Text("¿Cómo quieres empezar?").font(.title2.bold())
                            Text("En este dispositivo hay \(sync.migrationRecordCount) registros. Puedes copiarlos a tu cuenta cloud o empezar con un espacio vacío. Los originales permanecen en el modo local.")
                        }
                        if let error = sync.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                        Section {
                            Button("Copiar mis datos a mi cuenta cloud") { Task { await sync.chooseMigration(copyLocal: true, account: account) } }
                            Button("Empezar sin copiar datos") { Task { await sync.chooseMigration(copyLocal: false, account: account) } }
                        }.disabled(sync.busy)
                    }.navigationTitle("Preparar mis finanzas")
                }
            } else {
                VStack(spacing: 20) {
                    if sync.busy { ProgressView("Abriendo tus finanzas…") }
                    if let message = sync.errorMessage {
                        Text(message).multilineTextAlignment(.center)
                        Button("Volver a intentar") { Task { await sync.retryOpening(account: account) } }
                        Button("Salir de la cuenta") { Task { await account.signOut() } }
                    }
                }.padding(24)
            }
        }
        .task {
            await sync.open(account: account)
            while !Task.isCancelled {
                if canSyncAutomatically { await sync.synchronize(account: account) }
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && canSyncAutomatically { Task { await sync.synchronize(account: account) } }
        }
    }
    private var canSyncAutomatically: Bool {
        guard scenePhase == .active, !appLockEnabled || lock.isUnlocked else { return false }
        #if canImport(UIKit)
        // Avoid pulling while an account/transaction form or a system sheet is open.
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            if scene.windows.contains(where: { $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil }) { return false }
        }
        #endif
        return true
    }
}

// The status belongs to each navigation stack, never above the TabView's safe area.
// Local and banking-test workspaces do not instantiate a view requiring a cloud object.
private struct CloudSyncToolbar: ViewModifier {
    @Environment(\.isCloudWorkspace) private var isCloudWorkspace
    @Environment(\.isBankingTestWorkspace) private var isBankingTestWorkspace
    @ViewBuilder func body(content: Content) -> some View {
        if isCloudWorkspace && !isBankingTestWorkspace {
            content.toolbar {
                ToolbarItem(placement: .topBarLeading) { CloudSyncStatusButton() }
            }
        } else { content }
    }
}

extension View {
    func cloudSyncToolbar() -> some View { modifier(CloudSyncToolbar()) }
}

private struct CloudSyncStatusButton: View {
    @EnvironmentObject private var sync: CloudSyncCoordinator
    @State private var showingAccount = false
    private var needsAttention: Bool { sync.conflict != nil || sync.errorMessage != nil }
    var body: some View {
        Button { showingAccount = true } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    statusIcon
                    Text(needsAttention ? "Revisar nube" : sync.busy ? "Sincronizando" : "Mi nube")
                        .font(.caption.weight(.semibold))
                }
                statusIcon
            }
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(needsAttention ? AppDesign.warning : AppDesign.accent)
        }
        .accessibilityLabel("Cuenta cloud. \(sync.status)")
        .accessibilityHint("Ver el estado de sincronización y gestionar tu cuenta")
        .sheet(isPresented: $showingAccount) {
            NavigationStack {
                CloudAccountSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Cerrar") { showingAccount = false }
                        }
                    }
            }
            .environmentObject(sync)
        }
    }
    @ViewBuilder private var statusIcon: some View {
        if sync.busy { ProgressView().controlSize(.small) }
        else {
            Image(systemName: needsAttention ? "exclamationmark.icloud" : sync.status == "Al día" ? "checkmark.icloud" : "icloud")
        }
    }
}

struct CloudAccountSettingsView: View {
    @EnvironmentObject private var account: CloudAccountManager
    @EnvironmentObject private var sync: CloudSyncCoordinator
    @State private var resolving = false
    @State private var signingOut = false
    var body: some View {
        List {
            Section("Mi cuenta") {
                Label(account.session?.user.email ?? "Cuenta cloud", systemImage: "person.crop.circle")
                LabeledContent("Estado", value: sync.status)
                if let date = sync.lastSync {
                    LabeledContent("Última sincronización", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Text("Los cambios se guardan en este dispositivo y se sincronizan al abrir la app y mientras la utilizas. Sin conexión, permanecen pendientes.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let message = sync.errorMessage { Section { Text(message).foregroundStyle(.red) } }
            if let message = account.message { Section { Text(message) } }
            if sync.conflict != nil {
                Section("Cambios que requieren revisión") {
                    ForEach(Array(sync.conflictDescriptions.enumerated()), id: \.offset) { _, name in Text(name) }
                    Text("Elige qué versión conservar para estos registros. Los demás cambios de ambos dispositivos se combinan.")
                        .font(.footnote)
                    Button("Resolver cambios") { resolving = true }
                }
            }
            Section {
                Button { Task { await sync.synchronize(account: account) } } label: {
                    Label("Sincronizar ahora", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(sync.busy || account.busy || sync.conflict != nil)
                Button("Cerrar sesión", role: .destructive) { signingOut = true }
                    .disabled(sync.busy || account.busy)
            }
        }
        .navigationTitle("Cuenta y sincronización")
        .confirmationDialog("¿Qué versión quieres conservar en los registros en conflicto?", isPresented: $resolving, titleVisibility: .visible) {
            Button("Conservar los cambios de este dispositivo") { Task { await sync.synchronize(account: account, preferLocal: true) } }
            Button("Conservar los cambios de la nube") { Task { await sync.synchronize(account: account, preferLocal: false) } }
            Button("Cancelar", role: .cancel) { }
        }
        .confirmationDialog("¿Cerrar sesión en este dispositivo?", isPresented: $signingOut, titleVisibility: .visible) {
            Button("Cerrar sesión", role: .destructive) { Task { await account.signOut() } }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("La copia local de esta cuenta permanece separada y volverá a abrirse cuando inicies sesión con la misma cuenta. Si hay cambios sin subir, se conservan aquí.")
        }
    }
}
