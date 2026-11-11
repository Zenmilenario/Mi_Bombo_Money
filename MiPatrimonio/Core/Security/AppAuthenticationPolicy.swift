import Foundation

// Inactive is a privacy transition, not a new authentication session: Touch ID,
// Face ID and the system browser can all make the scene temporarily inactive.
struct AppAuthenticationPolicy {
    private(set) var isUnlocked = false
    private(set) var isForeground = false
    private(set) var protectedActionInProgress = false
    private(set) var authenticationID: UUID?
    private(set) var lastAuthenticatedAt: TimeInterval?
    private var attemptedAutomatically = false

    var shouldAuthenticateAutomatically: Bool {
        isForeground && !isUnlocked && authenticationID == nil
            && !protectedActionInProgress && !attemptedAutomatically
    }
    mutating func becameActive() {
        if !isForeground { attemptedAutomatically = false }
        isForeground = true
    }
    mutating func enteredBackground() {
        isForeground = false
        lock()
    }
    mutating func lock() {
        isUnlocked = false
        lastAuthenticatedAt = nil
        authenticationID = nil
    }
    mutating func unlockWithoutAuthentication() {
        isUnlocked = true
        lastAuthenticatedAt = nil // Disabling the app lock does not authorize a banking action.
    }
    mutating func beginAuthentication() -> UUID? {
        guard isForeground, authenticationID == nil else { return nil }
        let id = UUID()
        authenticationID = id
        isUnlocked = false
        attemptedAutomatically = true
        return id
    }
    @discardableResult
    mutating func finishAuthentication(id: UUID, succeeded: Bool, uptime: TimeInterval) -> Bool {
        guard authenticationID == id, isForeground else { return false }
        authenticationID = nil
        isUnlocked = succeeded
        lastAuthenticatedAt = succeeded ? uptime : nil
        return true
    }
    func hasRecentAuthentication(uptime: TimeInterval) -> Bool {
        guard isUnlocked, let lastAuthenticatedAt else { return false }
        let elapsed = uptime - lastAuthenticatedAt
        return elapsed >= 0 && elapsed <= 30
    }
    mutating func beginProtectedAction() -> Bool {
        guard isForeground, !protectedActionInProgress else { return false }
        protectedActionInProgress = true
        return true
    }
    mutating func endProtectedAction() { protectedActionInProgress = false }
}

// Callback completion and start/cancel failures may race. A continuation must
// finish at most once, and an old callback must not finish a newer operation.
struct AuthenticationCompletionGate {
    private(set) var operationID: UUID?
    mutating func begin() -> UUID? {
        guard operationID == nil else { return nil }
        let id = UUID(); operationID = id; return id
    }
    mutating func finish(_ id: UUID) -> Bool {
        guard operationID == id else { return false }
        operationID = nil
        return true
    }
}

/// The cloud's password rule (Supabase Auth, set on 11 November 2026): at least 10 characters with lower case,
/// upper case, digits and symbols. The Android app checks the same rule (`password_policy.dart`) before sending.
enum CloudPasswordPolicy {
    static let minimumLength = 10
    /// The symbols Supabase counts as such.
    static let symbols = Set(#"!@#$%^&*()_+-=[]{};'\:"|<>?,./`~"#)
    static let ruleText = "Al menos 10 caracteres, con mayúsculas, minúsculas, números y algún símbolo (por ejemplo ! ? # $ %)."

    /// What a new password lacks to be accepted by the cloud, or nil when it is valid.
    static func problem(_ password: String) -> String? {
        var missing: [String] = []
        if password.count < minimumLength { missing.append("al menos 10 caracteres") }
        if !password.contains(where: { ("a"..."z").contains($0) }) { missing.append("una minúscula") }
        if !password.contains(where: { ("A"..."Z").contains($0) }) { missing.append("una mayúscula") }
        if !password.contains(where: { ("0"..."9").contains($0) }) { missing.append("un número") }
        if !password.contains(where: symbols.contains) { missing.append("un símbolo (por ejemplo ! ? # $ %)") }
        guard let last = missing.last else { return nil }
        let list = missing.count == 1 ? last : missing.dropLast().joined(separator: ", ") + " y " + last
        return "A la contraseña le falta " + list + "."
    }
}
