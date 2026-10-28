import Combine
import Foundation
import LocalAuthentication

enum BiometricDeviceType: String, CaseIterable, Identifiable {
    case faceID
    case touchID
    case opticID
    case passcode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .passcode: "Código"
        }
    }

    var systemImage: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .passcode: "lock.fill"
        }
    }
}

@MainActor
final class AppLockManager: ObservableObject {
    @Published private(set) var policy = AppAuthenticationPolicy()
    @Published var lastErrorMessage: String?
    private var authenticationTask: Task<Bool, Never>?
    private var context: LAContext?

    var isUnlocked: Bool { policy.isUnlocked }
    var isAuthenticating: Bool { policy.authenticationID != nil }
    var protectedActionInProgress: Bool { policy.protectedActionInProgress }

    static var biometricType: BiometricDeviceType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .passcode
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .passcode
        }
    }

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

    func unlockWithCredentials() {
        guard policy.isForeground, !isAuthenticating, !protectedActionInProgress else { return }
        // An app password never counts as device-owner verification for banking.
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
