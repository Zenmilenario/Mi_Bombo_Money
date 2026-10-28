import Foundation

@main
struct PasswordSecurityCheck {
    static func main() throws {
        let salt = Data("0123456789abcdef".utf8)
        let key = try PasswordKeyDerivation.derive("Clave-de-prueba-2026", salt: salt)
        precondition(key.base64EncodedString() == "sApcYP49kCyNS0MXalzvO76UT0WrD1c0NUTcAAAXcnA=", "PBKDF2 must match an independent reference vector")
        let other = try PasswordKeyDerivation.derive("Otra-clave-2026", salt: salt)
        precondition(key != other)
        for rounds in [UInt32(0), 99_999, 1_000_001] {
            do {
                _ = try PasswordKeyDerivation.derive("Clave-de-prueba-2026", salt: salt, rounds: rounds)
                preconditionFailure("Unsafe or unbounded work factor accepted")
            } catch { }
        }
        precondition(PasswordKeyDerivation.matches("abc", "abc"))
        precondition(!PasswordKeyDerivation.matches("abc", "abd"))
        var policy = AppAuthenticationPolicy()
        policy.becameActive()
        policy.unlockWithoutAuthentication() // App credentials can unlock content, never banking.
        precondition(policy.isUnlocked && !policy.hasRecentAuthentication(uptime: 10))
        print("Password checks passed: PBKDF2 reference vector, work bounds and device-owner authorization separation.")
    }
}
