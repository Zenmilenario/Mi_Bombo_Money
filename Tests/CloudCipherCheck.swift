import Foundation

@main struct CloudCipherCheck {
    static func main() throws {
        let owner = UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
        let workspace = UUID(uuidString:"00000000-0000-0000-0000-000000000011")!
        let cipher = try CloudCipher(key:Data((0..<32).map { UInt8($0) }),keyID:"00000000-0000-4000-8000-000000000099")
        let vector = try JSONDecoder().decode(CloudJSON.self,from:Data(#"{"v":1,"alg":"A256GCM","key_id":"00000000-0000-4000-8000-000000000099","nonce":"AAECAwQFBgcICQoL","ciphertext":"PCC1c6CGqTm3Y/Pk04UXA6694k3dDW5eRQ==","tag":"nUBs5LlHRGvnzd1azH+qVw=="}"#.utf8))
        let decoded = try cipher.open(vector,owner:owner,workspace:workspace,kind:"key-check",revision:0)
        precondition(decoded.object["check"]?.string == "doblon-key-v1")
        let encoded = try cipher.seal(decoded, owner: owner, workspace: workspace, kind: "key-check", revision: 0, nonce: Data((0..<12).map { UInt8($0) }))
        precondition(encoded == vector)
        let recovered = try CloudCipher.recover(cipher.recoveryCode,keyID:cipher.keyID)
        precondition(recovered.key == cipher.key)
        for (o,w,k,r) in [(UUID(),workspace,"key-check",Int64(0)),(owner,UUID(),"key-check",0),(owner,workspace,"learning",0),(owner,workspace,"key-check",1)] {
            do { _ = try cipher.open(vector,owner:o,workspace:w,kind:k,revision:r); preconditionFailure("Context substitution accepted") }
            catch CloudPrivacyError.invalidCode { }
        }
        let doc: CloudJSON = .object(["amountMinor":.integer(9876543210123),"text":.string("Comercio ficticio"),"version":.integer(1)])
        let a = try cipher.seal(doc,owner:owner,workspace:workspace,kind:"finance",revision:4)
        let b = try cipher.seal(doc,owner:owner,workspace:workspace,kind:"finance",revision:4)
        precondition(a.object["nonce"] != b.object["nonce"])
        let plain = try cipher.open(a,owner:owner,workspace:workspace,kind:"finance",revision:4)
        precondition(plain == doc)
        var bad = a.object; bad["tag"] = .string(Data(repeating:0,count:16).base64EncodedString())
        do { _ = try cipher.open(.object(bad),owner:owner,workspace:workspace,kind:"finance",revision:4); preconditionFailure("Tampered tag accepted") }
        catch CloudPrivacyError.invalidCode { }
        print("Cloud encryption: independent AES-GCM vector, recovery, context binding, random nonces and exact cents passed.")
    }
}
