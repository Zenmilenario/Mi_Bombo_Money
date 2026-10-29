import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CloudConfiguration: Codable, Sendable {
    let url: URL
    let publishableKey: String
    static let projectHost = "coeicjffmpclqowsqeys.supabase.co"
    static var bundled: CloudConfiguration? {
        guard let path = Bundle.main.url(forResource: "CloudConfiguration", withExtension: "json"),
              let data = try? Data(contentsOf: path), let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return nil }
        return value
    }
    var isValid: Bool {
        url.scheme == "https" && url.host == Self.projectHost && url.user == nil && url.password == nil
        && url.port == nil && (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
        && publishableKey.hasPrefix("sb_publishable_") && !publishableKey.contains(where: \.isWhitespace)
    }
}

struct CloudUser: Codable, Sendable, Equatable { let id: UUID; let email: String? }
struct CloudSession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval
    let user: CloudUser
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at", user }
}

enum CloudTransportError: Error, LocalizedError {
    case configuration, invalidData, authentication, unavailable, conflict, requestRejected(String)
    var errorDescription: String? {
        switch self {
        case .configuration: "La conexión cloud de esta versión no está configurada."
        case .invalidData: "La nube ha devuelto datos que esta versión no puede interpretar."
        case .authentication: "La sesión ha caducado. Vuelve a iniciar sesión; tus cambios locales se conservan."
        case .unavailable: "No se ha podido conectar con la nube. Tus cambios permanecen en este dispositivo."
        case .conflict: "Otro dispositivo ha actualizado los datos. Vuelve a sincronizar para combinar los cambios."
        case .requestRejected(let message): message
        }
    }
}

private final class CloudRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward a password or bearer token to another destination.
    }
}

actor CloudClient {
    private let configuration: CloudConfiguration
    private let transport: URLSession
    private var refreshTask: Task<CloudSession, Error>?
    private var refreshOwner: UUID?
    init(configuration: CloudConfiguration, transport: URLSession? = nil) throws {
        guard configuration.isValid else { throw CloudTransportError.configuration }
        self.configuration = configuration
        if let transport { self.transport = transport }
        else {
            let settings = URLSessionConfiguration.ephemeral
            settings.httpCookieStorage = nil
            settings.urlCache = nil
            settings.timeoutIntervalForRequest = 30
            settings.timeoutIntervalForResource = 60
            self.transport = URLSession(configuration: settings, delegate: CloudRedirectPolicy(), delegateQueue: nil)
        }
    }
    func signIn(email: String, password: String) async throws -> CloudSession {
        let data = try await send(path: "/auth/v1/token", query: "grant_type=password", body: .object(["email":.string(email),"password":.string(password)]))
        return try JSONDecoder().decode(CloudSession.self, from: data)
    }
    func signUp(email: String, password: String, challenge: String) async throws -> CloudSession? {
        let data = try await send(path: "/auth/v1/signup", query: "redirect_to=mibombomoney-cloud%3A%2F%2Fauth", body: .object(["email":.string(email),"password":.string(password),"code_challenge":.string(challenge),"code_challenge_method":.string("s256")]))
        if (try JSONDecoder().decode(CloudJSON.self, from: data)).object["access_token"]?.string != nil {
            return try JSONDecoder().decode(CloudSession.self, from: data)
        }
        return nil // Confirmation is required; do not manufacture an authenticated session.
    }
    func refresh(_ session: CloudSession) async throws -> CloudSession {
        if let refreshTask {
            guard refreshOwner == session.user.id else { throw CloudTransportError.authentication }
            return try await refreshTask.value
        }
        let task = Task {
            let data = try await self.send(path: "/auth/v1/token", query: "grant_type=refresh_token",
                body: .object(["refresh_token":.string(session.refreshToken)]))
            let renewed = try JSONDecoder().decode(CloudSession.self, from: data)
            guard renewed.user.id == session.user.id else { throw CloudTransportError.invalidData }
            return renewed
        }
        refreshTask = task
        refreshOwner = session.user.id
        defer { refreshTask = nil; refreshOwner = nil }
        return try await task.value
    }
    func signOut(_ session: CloudSession) async throws {
        _ = try await send(path: "/auth/v1/logout", query: "scope=local", token: session.accessToken)
    }
    func recover(email: String, challenge: String) async throws {
        _ = try await send(path: "/auth/v1/recover", query: "redirect_to=mibombomoney-cloud%3A%2F%2Fauth", body: .object(["email":.string(email),"code_challenge":.string(challenge),"code_challenge_method":.string("s256")]))
    }
    func exchange(code: String, verifier: String) async throws -> CloudSession {
        let data = try await send(path: "/auth/v1/token", query: "grant_type=pkce",
            body: .object(["auth_code":.string(code),"code_verifier":.string(verifier)]))
        return try JSONDecoder().decode(CloudSession.self, from: data)
    }
    func updatePassword(_ password: String, session: CloudSession) async throws {
        let data = try await send(path: "/auth/v1/user", token: session.accessToken, body: .object(["password":.string(password)]), method: "PUT")
        let user = try JSONDecoder().decode(CloudUser.self, from: data)
        guard user.id == session.user.id else { throw CloudTransportError.invalidData }
    }
    func snapshot(session: CloudSession, workspace: UUID? = nil) async throws -> CloudSnapshot {
        let data = try await send(path: "/rest/v1/rpc/finance_snapshot", token: session.accessToken,
            body: .object(["p_workspace":workspace.map { .string($0.uuidString) } ?? .null]))
        return try JSONDecoder().decode(CloudSnapshot.self, from: data)
    }
    func save(session: CloudSession, workspace: UUID, revision: Int64, document: CloudJSON) async throws -> CloudSnapshot {
        let data = try await send(path: "/rest/v1/rpc/finance_save_snapshot", token: session.accessToken,
            body: .object(["p_workspace":.string(workspace.uuidString),"p_expected_revision":.integer(revision),
                           "p_document":CloudDocument.normalized(document),"p_timezone":.string(TimeZone.autoupdatingCurrent.identifier)]))
        return try JSONDecoder().decode(CloudSnapshot.self, from: data)
    }
    private func send(path: String, query: String? = nil, token: String? = nil, body: CloudJSON? = nil, method: String = "POST") async throws -> Data {
        var components = URLComponents(url: configuration.url, resolvingAgainstBaseURL: false)!
        components.path = path
        components.percentEncodedQuery = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        do {
            let (data, response) = try await transport.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw CloudTransportError.invalidData }
            guard (200..<300).contains(response.statusCode) else {
                let error = try? JSONDecoder().decode(CloudJSON.self, from: data)
                if error?.object["code"]?.string == "40001" { throw CloudTransportError.conflict }
                if response.statusCode == 401 || response.statusCode == 403 || (query == "grant_type=refresh_token" && response.statusCode == 400) { throw CloudTransportError.authentication }
                if path.hasPrefix("/auth/") {
                    if response.statusCode == 429 { throw CloudTransportError.requestRejected("Has realizado varios intentos. Espera un momento antes de repetir.") }
                    throw CloudTransportError.requestRejected("No se ha podido completar el acceso. Revisa el correo, la contraseña y la confirmación de tu cuenta.")
                }
                throw CloudTransportError.requestRejected("La nube ha rechazado la actualización. Tus datos locales se conservan; revisa las cuentas y reservas antes de repetir.")
            }
            guard data.count <= 50_000_000 else { throw CloudTransportError.invalidData }
            return data
        } catch let error as CloudTransportError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw CloudTransportError.unavailable }
    }
}
