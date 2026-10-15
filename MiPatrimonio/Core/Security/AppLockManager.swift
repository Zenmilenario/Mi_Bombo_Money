import Combine
import Foundation
import LocalAuthentication

@MainActor
final class AppLockManager: ObservableObject {
    @Published private(set) var policy = AppAuthenticationPolicy()
    @Published var lastErrorMessage: String?
    private var authenticationTask: Task<Bool, Never>?
    private var context: LAContext?

    var isUnlocked: Bool { policy.isUnlocked }
    var isAuthenticating: Bool { policy.authenticationID != nil }
    var protectedActionInProgress: Bool { policy.protectedActionInProgress }

    enum AuthorizationError: LocalizedError {
        case unavailable, notAuthenticated
        var errorDescription: String? {
            switch self {
            case .unavailable: "Espera a que termine la autorización actual y vuelve a intentarlo."
            case .notAuthenticated: "No se ha completado la verificación de identidad. Puedes volver a intentarlo."
            }
        }
    }

    func lock() {
        policy.lock()
        context?.invalidate()
        context = nil
        authenticationTask?.cancel()
        authenticationTask = nil
    }

    func becameActive() { policy.becameActive() }

    func enteredBackground() {
        policy.enteredBackground()
        context?.invalidate()
        context = nil
        authenticationTask?.cancel()
        authenticationTask = nil
    }

    func unlockWithoutAuthentication() {
        lock()
        policy.unlockWithoutAuthentication()
        lastErrorMessage = nil
    }

    @discardableResult
    func authenticate() async -> Bool {
        // App entry and banking operations await the same LAContext, never compete.
        if let authenticationTask { return await authenticationTask.value }
        guard let id = policy.beginAuthentication() else { return false }
        let context = LAContext()
        context.localizedCancelTitle = "Cancelar"
        context.localizedFallbackTitle = "Usar código"
        self.context = context
        lastErrorMessage = nil
        let task = Task { @MainActor in
            let success: Bool
            let message: String?
            var availabilityError: NSError?
            if !context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availabilityError) {
                success = false
                message = availabilityError?.localizedDescription ?? "Este dispositivo no permite autenticación local."
            } else {
                do {
                    success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Accede a tu información financiera")
                    message = success ? nil : "No se ha podido verificar tu identidad."
                } catch {
                    success = false
                    message = error.localizedDescription
                }
            }
            // A prompt completed after a real background transition must not unlock the app.
            guard self.policy.finishAuthentication(id: id, succeeded: success, uptime: ProcessInfo.processInfo.systemUptime) else { return false }
            self.lastErrorMessage = message
            self.context = nil
            self.authenticationTask = nil
            return success
        }
        authenticationTask = task
        return await task.value
    }

    func authenticateAutomaticallyIfNeeded() async {
        guard policy.shouldAuthenticateAutomatically else { return }
        await authenticate()
    }

    func withProtectedAction(_ action: @MainActor () async throws -> Void) async throws {
        guard policy.beginProtectedAction() else { throw AuthorizationError.unavailable }
        defer { policy.endProtectedAction() }
        if !policy.hasRecentAuthentication(uptime: ProcessInfo.processInfo.systemUptime) {
            guard await authenticate() else { throw AuthorizationError.notAuthenticated }
        }
        try Task.checkCancellation()
        try await action()
    }
}
