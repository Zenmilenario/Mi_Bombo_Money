import SwiftUI

struct LockGateView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var lockManager: AppLockManager
    @AppStorage("appLockEnabled") private var appLockEnabled = true
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearance.system.rawValue

    var body: some View {
        Group {
            if !appLockEnabled || lockManager.isUnlocked {
                RootTabView()
            } else {
                lockedContent
            }
        }
        .tint(Color(hex: "#176B87"))
        .preferredColorScheme(AppAppearance(rawValue: appearanceMode)?.colorScheme)
        .task(id: appLockEnabled) {
            if appLockEnabled {
                await lockManager.authenticate()
            } else {
                lockManager.unlockWithoutAuthentication()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if appLockEnabled, !lockManager.isUnlocked {
                    Task { await lockManager.authenticate() }
                }
            case .inactive, .background:
                if appLockEnabled { lockManager.lock() }
            @unknown default:
                break
            }
        }
    }

    private var lockedContent: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 62))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Mi Patrimonio está bloqueado")
                    .font(.title2.bold())
                Text("Usa Face ID, Touch ID o el código del dispositivo para acceder.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            if let error = lockManager.lastErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await lockManager.authenticate() }
            } label: {
                if lockManager.isAuthenticating {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Desbloquear", systemImage: "faceid")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(lockManager.isAuthenticating)
        }
        .padding(32)
    }
}
