import Foundation
import CryptoKit
import Security

enum CloudPrivacyError: Error, LocalizedError {
    case recoveryRequired, invalidCode, invalidEnvelope, storage
    var errorDescription: String? {
        switch self {
        case .recoveryRequired: "Desbloquea tus datos con el código de recuperación."
        case .invalidCode: "El código no corresponde a esta cuenta o los datos cifrados no se pueden verificar. No se ha modificado la copia cloud."
        case .invalidEnvelope: "Los datos cifrados no tienen un formato compatible."
        case .storage: "No se ha podido guardar la clave en el llavero de este dispositivo."
        }
    }
}

/// Cross-platform format: AES-256-GCM, random 96-bit nonce, 128-bit tag, bound to identity and revision.
/// Only decrypted JSON reaches the existing merge, accounting and on-device learning code.
struct CloudCipher {
    let key: Data
    let keyID: String
    init(key: Data, keyID: String) throws {
        guard key.count == 32, UUID(uuidString: keyID) != nil else { throw CloudPrivacyError.invalidCode }
        self.key = key; self.keyID = keyID.lowercased()
    }
    static func generate() throws -> CloudCipher {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return try .init(key: key, keyID: UUID().uuidString)
    }
    var recoveryCode: String {
        "DBL1-" + key.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func recover(_ code: String, keyID: String) throws -> CloudCipher {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix("DBL1-") else { throw CloudPrivacyError.invalidCode }
        var raw = String(code.dropFirst(5)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
        guard let data = Data(base64Encoded: raw) else { throw CloudPrivacyError.invalidCode }
        return try .init(key: data, keyID: keyID)
    }
    private func aad(owner: UUID, workspace: UUID, kind: String, revision: Int64) -> Data {
        Data("doblon:e2ee:1:\(owner.uuidString.lowercased()):\(workspace.uuidString.lowercased()):\(kind):\(revision):\(keyID)".utf8)
    }
    func seal(_ document: CloudJSON, owner: UUID, workspace: UUID, kind: String, revision: Int64, nonce: Data? = nil) throws -> CloudJSON {
        let box = try AES.GCM.seal(JSONEncoder().encode(document), using: SymmetricKey(data: key),
            nonce: nonce.map { try AES.GCM.Nonce(data: $0) }, authenticating: aad(owner: owner, workspace: workspace, kind: kind, revision: revision))
        return .object(["v":.integer(1),"alg":.string("A256GCM"),"key_id":.string(keyID),
                        "nonce":.string(Data(box.nonce).base64EncodedString()),"ciphertext":.string(box.ciphertext.base64EncodedString()),"tag":.string(box.tag.base64EncodedString())])
    }
    func open(_ envelope: CloudJSON, owner: UUID, workspace: UUID, kind: String, revision: Int64) throws -> CloudJSON {
        let values = envelope.object
        guard values.count == 6, values["v"] == .integer(1), values["alg"]?.string == "A256GCM", values["key_id"]?.string == keyID,
              let nonce = values["nonce"]?.string.flatMap({ Data(base64Encoded: $0) }), nonce.count == 12,
              let tag = values["tag"]?.string.flatMap({ Data(base64Encoded: $0) }), tag.count == 16,
              let ciphertext = values["ciphertext"]?.string.flatMap({ Data(base64Encoded: $0) }) else { throw CloudPrivacyError.invalidEnvelope }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            let data = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad(owner: owner, workspace: workspace, kind: kind, revision: revision))
            let value = try JSONDecoder().decode(CloudJSON.self, from: data)
            guard case .object = value else { throw CloudPrivacyError.invalidEnvelope }
            return value
        } catch { throw CloudPrivacyError.invalidCode }
    }
}

struct CloudPrivacyStatus { let ready: Bool; let enrolled: Bool }

/// Device-only, unlocked Keychain item, per cloud identity. No iCloud Keychain synchronization.
enum CloudPrivacyKeyStore {
    static func read(owner: UUID) throws -> CloudJSON? {
        var query = base(owner)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CloudPrivacyError.storage }
        return try JSONDecoder().decode(CloudJSON.self, from: data)
    }
    static func save(_ value: CloudJSON, owner: UUID) throws {
        let query = base(owner)
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw CloudPrivacyError.storage }
    }
    private static func base(_ owner: UUID) -> [String: Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"doblon.cloud.privacy.v1",
         kSecAttrAccount as String:owner.uuidString.lowercased()]
    }
}
