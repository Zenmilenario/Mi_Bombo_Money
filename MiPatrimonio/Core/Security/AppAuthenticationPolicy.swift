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
