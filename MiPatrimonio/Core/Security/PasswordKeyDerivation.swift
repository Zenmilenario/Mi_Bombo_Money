import CommonCrypto
import Foundation

enum PasswordKeyDerivation {
    static let iterations: UInt32 = 600_000

    static func derive(_ password: String, salt: Data, rounds: UInt32 = iterations) throws -> Data {
        guard !password.isEmpty, password.utf8.count <= 4096, (16...64).contains(salt.count),
              (100_000...1_000_000).contains(rounds) else {
            throw CocoaError(.coderInvalidValue)
        }
        let bytes = Array(password.utf8)
        var result = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                result.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
        return Data(result)
    }

    static func matches(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8.zero) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
