import CryptoKit
import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case missingData

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            "Error de Keychain (código \(status))."
        case .missingData:
            "El elemento de Keychain no contiene datos."
        }
    }
}

enum KeychainStore {
    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "com.example.MiPatrimonio").security"
    }

    static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
    }

    static func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
        guard let data = item as? Data else { throw KeychainStoreError.missingData }
        return data
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }
}

enum LocalEncryptionService {
    private static let keyAccount = "local-aes-gcm-key-v1"

    static func encrypt(_ data: Data) throws -> Data {
        let key = try encryptionKey()
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        return combined
    }

    static func decrypt(_ data: Data) throws -> Data {
        let key = try encryptionKey()
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: key)
    }

    private static func encryptionKey() throws -> SymmetricKey {
        if let stored = try KeychainStore.read(account: keyAccount) {
            return SymmetricKey(data: stored)
        }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try KeychainStore.save(data, account: keyAccount)
        return key
    }
}
