import SwiftUI

struct LockGateView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var lockManager: AppLockManager
    @AppStorage("appLockEnabled") private var appLockEnabled = true
    @AppStorage("autoPromptBiometrics") private var autoPromptBiometrics = false
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearance.system.rawValue
    @State private var hasOpenedContent = false

    var body: some View {
        ZStack {
            // Keep the authenticated browser flow alive when iOS makes the app inactive.
            // The lock overlay hides content and blocks touches and accessibility immediately.
            if hasOpenedContent || !appLockEnabled || lockManager.isUnlocked {
                FinanceWorkspaceRouter()
                    .opacity(contentHidden ? 0 : 1)
                    .allowsHitTesting(!contentHidden)
                    .accessibilityHidden(contentHidden)
            }
            if appLockEnabled && !lockManager.isUnlocked {
                LoginView()
                    // AutoFill and biometric sheets temporarily deactivate the scene.
                    // Preserve the form while hiding it from view, touches and accessibility.
                    .opacity(scenePhase == .active ? 1 : 0)
                    .allowsHitTesting(scenePhase == .active)
                    .accessibilityHidden(scenePhase != .active)
            }
            if scenePhase != .active {
                AppDesign.pageBackground.ignoresSafeArea()
            }
        }
        .tint(AppDesign.accent)
        .preferredColorScheme(AppAppearance(rawValue: appearanceMode)?.colorScheme)
        .task(id: appLockEnabled) {
            if scenePhase == .active { lockManager.becameActive() }
            if appLockEnabled {
                if autoPromptBiometrics {
                    await lockManager.authenticateAutomaticallyIfNeeded()
                }
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
                    if autoPromptBiometrics {
                        Task { await lockManager.authenticateAutomaticallyIfNeeded() }
                    }
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
            if !inProgress, scenePhase == .active, appLockEnabled, autoPromptBiometrics {
                Task { await lockManager.authenticateAutomaticallyIfNeeded() }
            }
        }
    }

    private var contentHidden: Bool {
        scenePhase != .active || (appLockEnabled && !lockManager.isUnlocked)
    }
}
