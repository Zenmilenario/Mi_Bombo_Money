import Foundation

struct BankingServerStatus: Decodable { let mode: String; let liveBankingEnabled: Bool; let accountingImportEnabled: Bool }
struct ConnectedBank: Decodable, Identifiable {
    let name: String
    let country: String
    let beta: Bool
    var id: String { "\(country):\(name)" }
}
struct ConnectedBankAccount: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let currency: String
    let lastFour: String
}
struct ConnectedBankSession: Decodable, Identifiable {
    let id: String
    let bank: String
    let validUntil: String
    let accounts: [ConnectedBankAccount]
}
struct BankingAuthorizationStart: Decodable { let id: String; let authorizationURL: URL }
struct BankingPreview: Decodable {
    struct Balance: Decodable { let amountMinor: Int64; let currency: String; let type: String }
    struct Movement: Decodable, Identifiable {
        let id: String?
        let bookingDate: String
        let signedAmountMinor: Int64
        let currency: String
        let description: String
    }
    let balances: [Balance]
    let transactions: [Movement]
    let continuation: String?
}

