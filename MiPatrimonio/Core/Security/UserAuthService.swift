import CryptoKit
import Foundation

struct UserAccountProfile: Codable {
    var username: String
    var passwordHash: String
    var salt: String
    var createdAt: Date
    var lastLoginAt: Date?
}

enum UserAuthError: LocalizedError {
    case alreadyConfigured
    case emptyUsername
    case emptyPassword
    case passwordTooShort
    case passwordMismatch
    case userNotFound
    case incorrectPassword

    var errorDescription: String? {
        switch self {
        case .alreadyConfigured:
            return "Ya hay un usuario configurado. Usa Cambiar contraseña desde Ajustes."
        case .emptyUsername:
            return "El nombre de usuario no puede estar vacío."
        case .emptyPassword:
            return "La contraseña no puede estar vacía."
        case .passwordTooShort:
            return "La contraseña debe tener al menos 10 caracteres."
        case .passwordMismatch:
            return "Las contraseñas no coinciden."
        case .userNotFound:
            return "No hay ningún usuario registrado todavía."
        case .incorrectPassword:
            return "Usuario o contraseña incorrectos."
        }
    }
}

enum UserAuthService {
    private static let keychainAccount = "app-user-credentials-v1"

    static var isConfigured: Bool {
        (try? profile()) != nil
    }

    static var storedUsername: String? {
        (try? profile())?.username
    }

    static func profile() throws -> UserAccountProfile? {
        guard let data = try KeychainStore.read(account: keychainAccount) else {
            return nil
        }
        return try JSONDecoder().decode(UserAccountProfile.self, from: data)
    }

    static func register(username: String, password: String) throws {
        guard try profile() == nil else { throw UserAuthError.alreadyConfigured }
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty else { throw UserAuthError.emptyUsername }
        guard password.count >= 10 else { throw UserAuthError.passwordTooShort }

        let saltKey = SymmetricKey(size: .bits128)
        let salt = saltKey.withUnsafeBytes { Data($0) }.base64EncodedString()
        let hash = try hashPassword(password, salt: salt)

        let profile = UserAccountProfile(
            username: cleanUsername,
            passwordHash: hash,
            salt: salt,
            createdAt: .now,
            lastLoginAt: .now
        )
        let data = try JSONEncoder().encode(profile)
        try KeychainStore.save(data, account: keychainAccount)
    }

    static func verify(username: String, password: String) -> Bool {
        guard let profile = try? profile() else { return false }
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanUsername.caseInsensitiveCompare(profile.username) == .orderedSame else {
            return false
        }
        let matches = verifyPassword(password, profile: profile)
        if matches {
            var updated = profile
            updated.lastLoginAt = .now
            if !profile.passwordHash.hasPrefix("pbkdf2-sha256$") {
                guard let upgraded = try? hashPassword(password, salt: profile.salt) else { return false }
                updated.passwordHash = upgraded
            }
            if let data = try? JSONEncoder().encode(updated) {
                try? KeychainStore.save(data, account: keychainAccount)
            }
        }
        return matches
    }

    static func changePassword(oldPassword: String, newPassword: String) throws {
        guard let current = try profile() else { throw UserAuthError.userNotFound }
        guard verifyPassword(oldPassword, profile: current) else { throw UserAuthError.incorrectPassword }
        guard newPassword.count >= 10 else { throw UserAuthError.passwordTooShort }

        let saltKey = SymmetricKey(size: .bits128)
        let newSalt = saltKey.withUnsafeBytes { Data($0) }.base64EncodedString()
        let newHash = try hashPassword(newPassword, salt: newSalt)

        var updated = current
        updated.passwordHash = newHash
        updated.salt = newSalt
        let data = try JSONEncoder().encode(updated)
        try KeychainStore.save(data, account: keychainAccount)
    }

    static func removeCredentials() throws {
        try KeychainStore.delete(account: keychainAccount)
    }

    private static func hashPassword(_ password: String, salt: String) throws -> String {
        guard let saltData = Data(base64Encoded: salt) else { throw UserAuthError.incorrectPassword }
        let key = try PasswordKeyDerivation.derive(password, salt: saltData)
        return "pbkdf2-sha256$600000$" + key.base64EncodedString()
    }

    private static func verifyPassword(_ password: String, profile: UserAccountProfile) -> Bool {
        if profile.passwordHash.hasPrefix("pbkdf2-sha256$") {
            let parts = profile.passwordHash.split(separator: "$", omittingEmptySubsequences: false)
            guard parts.count == 3, let rounds = UInt32(parts[1]), let salt = Data(base64Encoded: profile.salt),
                  let key = try? PasswordKeyDerivation.derive(password, salt: salt, rounds: rounds) else { return false }
            return PasswordKeyDerivation.matches(key.base64EncodedString(), String(parts[2]))
        }
        // Read existing credentials once, then upgrade after a successful login.
        let legacy = SHA256.hash(data: Data("\(password)|\(profile.salt)".utf8)).map { String(format: "%02x", $0) }.joined()
        return PasswordKeyDerivation.matches(legacy, profile.passwordHash)
    }
}
