import Foundation
import CryptoKit

struct CloudPKCEFlow: Codable {
    let verifier: String
    let startedAt: Date
    let isRecovery: Bool
    init(isRecovery: Bool) {
        let random = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        verifier = Self.base64URL(random)
        startedAt = .now
        self.isRecovery = isRecovery
    }
    var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    var isExpired: Bool { Date.now.timeIntervalSince(startedAt) > 3600 || startedAt > .now }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func callbackCode(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "mibombomoney-cloud", components.host == "auth",
              components.path.isEmpty, components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "code", let code = items[0].value, !code.isEmpty, code.count <= 4096 else { return nil }
        return code
    }
}
