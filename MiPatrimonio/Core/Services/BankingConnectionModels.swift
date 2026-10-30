import Foundation

struct BankingServerStatus: Decodable { let mode: String; let liveBankingEnabled: Bool; let accountingImportEnabled: Bool }
struct BankingAccountFeed {
    let connection: ConnectedBankSession
    let account: ConnectedBankAccount
    let balances: [BankingPreview.Balance]
    let movements: [BankingPreview.Movement]
}
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
    let ownershipKey: String?
    let testRole: String?
    init(id: String, name: String, currency: String, lastFour: String, ownershipKey: String? = nil, testRole: String? = nil) {
        self.id = id; self.name = name; self.currency = currency; self.lastFour = lastFour
        self.ownershipKey = ownershipKey; self.testRole = testRole
    }
}
struct ConnectedBankSession: Decodable, Identifiable {
    let id: String
    let bank: String
    let validUntil: String
    let accounts: [ConnectedBankAccount]
    let testScenario: String?
    init(id: String, bank: String, validUntil: String, accounts: [ConnectedBankAccount], testScenario: String? = nil) {
        self.id = id; self.bank = bank; self.validUntil = validUntil; self.accounts = accounts; self.testScenario = testScenario
    }
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
        let counterpartyKey: String?
        let transferKey: String?
        init(id: String?, bookingDate: String, signedAmountMinor: Int64, currency: String, description: String,
             counterpartyKey: String? = nil, transferKey: String? = nil) {
            self.id = id; self.bookingDate = bookingDate; self.signedAmountMinor = signedAmountMinor
            self.currency = currency; self.description = description; self.counterpartyKey = counterpartyKey; self.transferKey = transferKey
        }
    }
    let balances: [Balance]
    let transactions: [Movement]
    let continuation: String?
}
