import AuthenticationServices
import Foundation
import Security
import UIKit

// This Keychain item is not migrated, synced to iCloud or included in the app's JSON export.
enum BankingCredentialStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "MiPatrimonio").banking",
         kSecAttrAccount as String: "personal-backend-v1",
         kSecAttrSynchronizable as String: false]
    }
    static func load() throws -> BankingServerConfiguration? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainStoreError.unexpectedStatus(status) }
        let saved = try JSONDecoder().decode(BankingServerConfiguration.self, from: data)
        return try .validated(url: saved.serverURL.absoluteString, token: saved.token)
    }
    static func save(_ configuration: BankingServerConfiguration) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(configuration),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainStoreError.unexpectedStatus(status) }
    }
}

// Foundation would otherwise follow redirects, potentially taking a private request to another host.
private final class BankingSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class BankingConnectionClient {
    private let configuration: BankingServerConfiguration
    private let session: URLSession
    init(configuration: BankingServerConfiguration) {
        self.configuration = configuration
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        session = URLSession(configuration: config, delegate: BankingSessionDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func status() async throws -> BankingServerStatus {
        let value: BankingServerStatus = try await get("/v1/status")
        guard ["demo", "sandbox"].contains(value.mode), !value.liveBankingEnabled, !value.accountingImportEnabled else {
            throw BankingConnectionError.invalidResponse
        }
        return value
    }
    func banks() async throws -> [ConnectedBank] {
        struct Payload: Decodable { let banks: [ConnectedBank] }
        let value: Payload = try await get("/v1/banks")
        return value.banks
    }
    func connections() async throws -> [ConnectedBankSession] {
        struct Payload: Decodable { let connections: [ConnectedBankSession] }
        let value: Payload = try await get("/v1/connections")
        return value.connections
    }
    func start(bank: ConnectedBank) async throws -> BankingAuthorizationStart {
        let value: BankingAuthorizationStart = try await send("/v1/authorizations", method: "POST", body: ["bank": bank.name])
        guard UUID(uuidString: value.id) != nil,
              BankingConnectionPolicy.acceptsAuthorizationURL(value.authorizationURL, server: configuration.serverURL) else {
            throw BankingConnectionError.invalidResponse
        }
        return value
    }
    func disconnect(_ connection: ConnectedBankSession) async throws {
        guard UUID(uuidString: connection.id) != nil else { throw BankingConnectionError.invalidResponse }
        var request = try request(path: "/v1/connections/\(connection.id)", method: "DELETE")
        request.timeoutInterval = 30
        let response = try await responseData(request)
        guard response.1.statusCode == 204 else { throw BankingConnectionError.invalidResponse }
    }
    func preview(connection: ConnectedBankSession, account: ConnectedBankAccount, continuation: String? = nil, asOf: Date = .now) async throws -> BankingPreview {
        guard UUID(uuidString: connection.id) != nil,
              account.id.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { throw BankingConnectionError.invalidResponse }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let to = asOf
        let from = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -30, to: to) ?? to
        var query = [URLQueryItem(name: "from", value: formatter.string(from: from)), URLQueryItem(name: "to", value: formatter.string(from: to))]
        if let continuation { query.append(URLQueryItem(name: "continuation", value: continuation)) }
        return try await get("/v1/connections/\(connection.id)/accounts/\(account.id)", query: query)
    }
    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(path, method: "GET", query: query)
    }
    private func send<T: Decodable>(_ path: String, method: String, body: [String: String]? = nil, query: [URLQueryItem] = []) async throws -> T {
        var request = try request(path: path, method: method, query: query)
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, _) = try await responseData(request)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw BankingConnectionError.invalidResponse }
    }
    private func request(path: String, method: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(url: configuration.serverURL, resolvingAgainstBaseURL: false) else { throw BankingConnectionError.invalidConfiguration }
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw BankingConnectionError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    private func responseData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.host == configuration.serverURL.host,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("application/json") || http.statusCode == 204 else {
            throw BankingConnectionError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw BankingConnectionError.invalidResponse }
            data.append(byte)
        }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "unknown"
            throw BankingConnectionError.server(code)
        }
        return (data, http)
    }
}

@MainActor
private final class BankingPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow
    init(window: UIWindow) { self.window = window; super.init() }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}

@MainActor
final class BankingBrowserAuthorization {
    private var session: ASWebAuthenticationSession?
    private var presentationContext: BankingPresentationContext?
    private var pendingCompletion: CheckedContinuation<Void, Error>?
    private var completionGate = AuthenticationCompletionGate()

    func authorize(_ start: BankingAuthorizationStart) async throws {
        guard pendingCompletion == nil, session == nil else { throw BankingConnectionError.authorizationFailed }
        let window = try await activePresentationWindow()
        try Task.checkCancellation()
        guard let operationID = completionGate.begin() else { throw BankingConnectionError.authorizationFailed }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pendingCompletion = continuation
                if Task.isCancelled {
                    finish(operationID, result: .failure(BankingConnectionError.cancelled))
                    return
                }
                let auth = ASWebAuthenticationSession(url: start.authorizationURL, callbackURLScheme: "mibombomoney-bank") { [weak self] url, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error {
                            let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                            self.finish(operationID, result: .failure(cancelled ? BankingConnectionError.cancelled : BankingConnectionError.authorizationFailed))
                            return
                        }
                        guard let url, BankingConnectionPolicy.acceptsCallback(url, flowID: start.id) else {
                            self.finish(operationID, result: .failure(BankingConnectionError.authorizationFailed))
                            return
                        }
                        self.finish(operationID, result: .success(Void()))
                    }
                }
                let context = BankingPresentationContext(window: window)
                presentationContext = context
                auth.prefersEphemeralWebBrowserSession = true
                auth.presentationContextProvider = context
                session = auth
                guard auth.canStart else {
                    finish(operationID, result: .failure(BankingConnectionError.presentationUnavailable))
                    return
                }
                if !auth.start() {
                    finish(operationID, result: .failure(BankingConnectionError.presentationUnavailable))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.completionGate.operationID == operationID else { return }
                let activeSession = self.session
                self.finish(operationID, result: .failure(BankingConnectionError.cancelled))
                activeSession?.cancel()
            }
        }
    }

    private func finish(_ operationID: UUID, result: Result<Void, Error>) {
        guard completionGate.finish(operationID), let completion = pendingCompletion else { return }
        pendingCompletion = nil
        session = nil
        presentationContext = nil
        completion.resume(with: result)
    }

    private func activePresentationWindow() async throws -> UIWindow {
        // The biometric sheet may still be disappearing when evaluatePolicy returns.
        // Wait briefly for a real active window rather than presenting with an empty anchor.
        for _ in 0..<40 {
            try Task.checkCancellation()
            if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows)
                .first(where: { $0.isKeyWindow && !$0.isHidden }) { return window }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw BankingConnectionError.presentationUnavailable
    }
}
