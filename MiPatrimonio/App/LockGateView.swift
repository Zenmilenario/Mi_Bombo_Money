import SwiftUI

struct LockGateView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var lockManager: AppLockManager
    @AppStorage("appLockEnabled") private var appLockEnabled = true
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearance.system.rawValue
    @State private var hasOpenedContent = false

    var body: some View {
        ZStack {
            // Keep the authenticated browser flow alive when iOS makes the app inactive.
            // The lock overlay hides content and blocks touches and accessibility immediately.
            if hasOpenedContent || !appLockEnabled || lockManager.isUnlocked {
                RootTabView()
                    .opacity(contentHidden ? 0 : 1)
                    .allowsHitTesting(!contentHidden)
                    .accessibilityHidden(contentHidden)
            }
            if scenePhase != .active {
                AppDesign.pageBackground.ignoresSafeArea()
            } else if appLockEnabled && !lockManager.isUnlocked {
                lockedContent
            }
        }
        .tint(Color(hex: "#176B87"))
        .preferredColorScheme(AppAppearance(rawValue: appearanceMode)?.colorScheme)
        .task(id: appLockEnabled) {
            if scenePhase == .active { lockManager.becameActive() }
            if appLockEnabled {
                await lockManager.authenticateAutomaticallyIfNeeded()
            } else {
                lockManager.unlockWithoutAuthentication()
            }
        }
        .onChange(of: lockManager.isUnlocked) { _, unlocked in
            if unlocked { hasOpenedContent = true }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                lockManager.becameActive()
                if appLockEnabled {
                    Task { await lockManager.authenticateAutomaticallyIfNeeded() }
                } else if !lockManager.isAuthenticating && !lockManager.protectedActionInProgress {
                    lockManager.unlockWithoutAuthentication()
                }
            case .inactive:
                break // Hide content, but do not re-lock because a system prompt appeared.
            case .background:
                lockManager.enteredBackground()
            @unknown default:
                break
            }
        }
        .onChange(of: lockManager.protectedActionInProgress) { _, inProgress in
            if !inProgress, scenePhase == .active, appLockEnabled {
                Task { await lockManager.authenticateAutomaticallyIfNeeded() }
            }
        }
    }

    private var contentHidden: Bool {
        scenePhase != .active || (appLockEnabled && !lockManager.isUnlocked)
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
                if lockManager.isAuthenticating || lockManager.protectedActionInProgress {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Desbloquear", systemImage: "faceid")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(lockManager.isAuthenticating || lockManager.protectedActionInProgress)
        }
        .padding(32)
    }
}
