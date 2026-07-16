import Combine
import Foundation
import LocalAuthentication

@MainActor
final class AppLockManager: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var isAuthenticating = false
    @Published var lastErrorMessage: String?

    func lock() {
        isUnlocked = false
    }

    func unlockWithoutAuthentication() {
        isUnlocked = true
        lastErrorMessage = nil
    }

    func authenticate() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = "Cancelar"
        context.localizedFallbackTitle = "Usar código"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isUnlocked = false
            lastErrorMessage = error?.localizedDescription ?? "Este dispositivo no permite autenticación local."
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Accede a tu información financiera"
            )
            isUnlocked = success
            lastErrorMessage = success ? nil : "No se ha podido verificar tu identidad."
        } catch {
            isUnlocked = false
            lastErrorMessage = error.localizedDescription
        }
    }
}
