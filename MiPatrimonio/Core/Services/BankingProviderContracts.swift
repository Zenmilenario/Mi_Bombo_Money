import Foundation

/// Contract reserved for the PSD2/Open Banking phase.
/// Implementations must use the provider's OAuth/SCA flow and must never request
/// or persist the user's online-banking password.
protocol BankingDataProvider: Sendable {
    var providerID: String { get }
    var displayName: String { get }

    func authorizationRequest(callbackURL: URL) async throws -> BankingAuthorizationRequest
    func exchangeAuthorizationCode(_ code: String, callbackURL: URL) async throws -> BankingSessionReference
    func fetchAccounts(session: BankingSessionReference) async throws -> [ExternalBankAccount]
    func fetchTransactions(
        accountID: String,
        from startDate: Date,
        to endDate: Date,
        session: BankingSessionReference
    ) async throws -> [ExternalBankTransaction]
    func revoke(session: BankingSessionReference) async throws
}

struct BankingAuthorizationRequest: Sendable {
    let authorizationURL: URL
    let state: String
}

/// Contains only identifiers and the Keychain account where a short-lived token
/// is stored. The token itself is intentionally absent from the data model.
struct BankingSessionReference: Sendable, Codable {
    let providerID: String
    let connectionID: String
    let tokenKeychainAccount: String
    let expiresAt: Date?
}

struct ExternalBankAccount: Sendable, Identifiable {
    let id: String
    let institutionName: String
    let displayName: String
    let currencyCode: String
    let currentBalanceMinor: Int64?
}

struct ExternalBankTransaction: Sendable, Identifiable {
    let id: String
    let bookingDate: Date
    let valueDate: Date?
    let signedAmountMinor: Int64
    let currencyCode: String
    let description: String
    let merchantName: String?
    let bankCategory: String?
}
