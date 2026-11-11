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
    private var privacyProfiles: [UUID: CloudJSON] = [:]
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
        if try await encrypted(session) { return try await sealedSnapshot(session: session, kind: "finance", expectedWorkspace: workspace) }
        let data = try await send(path: "/rest/v1/rpc/finance_snapshot", token: session.accessToken,
            body: .object(["p_workspace":workspace.map { .string($0.uuidString) } ?? .null]))
        return try JSONDecoder().decode(CloudSnapshot.self, from: data)
    }
    func save(session: CloudSession, workspace: UUID, revision: Int64, document: CloudJSON) async throws -> CloudSnapshot {
        if try await encrypted(session) { return try await sealedSave(session: session, workspace: workspace, revision: revision, document: CloudDocument.normalized(document), kind: "finance") }
        let data = try await send(path: "/rest/v1/rpc/finance_save_snapshot", token: session.accessToken,
            body: .object(["p_workspace":.string(workspace.uuidString),"p_expected_revision":.integer(revision),
                           "p_document":CloudDocument.normalized(document),"p_timezone":.string(TimeZone.autoupdatingCurrent.identifier)]))
        return try JSONDecoder().decode(CloudSnapshot.self, from: data)
    }
    /// What the person taught the models, shared by their devices (CloudBackend/learning-contract.md).
    func learningSnapshot(session: CloudSession) async throws -> CloudSnapshot {
        if try await encrypted(session) { return try await sealedSnapshot(session: session, kind: "learning") }
        let data = try await send(path: "/rest/v1/rpc/finance_learning_snapshot", token: session.accessToken, body: .object([:]))
        return try JSONDecoder().decode(CloudSnapshot.self, from: data)
    }
    func saveLearning(session: CloudSession, workspace: UUID, revision: Int64, document: CloudJSON) async throws -> CloudSnapshot {
        if try await encrypted(session) { return try await sealedSave(session: session, workspace: workspace, revision: revision, document: document, kind: "learning") }
        let data = try await send(path: "/rest/v1/rpc/finance_learning_save", token: session.accessToken,
            body: .object(["p_workspace":.string(workspace.uuidString),"p_expected_revision":.integer(revision),"p_document":document]))
        return try JSONDecoder().decode(CloudSnapshot.self, from: data)
    }

    private func privacyProfile(_ session: CloudSession, refresh: Bool = false) async throws -> CloudJSON {
        if !refresh, let profile = privacyProfiles[session.user.id] { return profile }
        let data = try await send(path: "/rest/v1/rpc/finance_privacy_profile", token: session.accessToken, body: .object([:]))
        let profile = try JSONDecoder().decode(CloudJSON.self, from: data)
        guard (profile.object["encryption_required"] == .bool(true) || profile.object["encryption_required"] == .bool(false)),
              profile.object["workspace_id"]?.string.flatMap(UUID.init(uuidString:)) != nil else { throw CloudTransportError.invalidData }
        privacyProfiles[session.user.id] = profile
        return profile
    }
    private func encrypted(_ session: CloudSession) async throws -> Bool {
        try await privacyProfile(session).object["encryption_required"] == .bool(true)
    }
    private func cipher(_ session: CloudSession) throws -> CloudCipher {
        guard let saved = try CloudPrivacyKeyStore.read(owner: session.user.id), let code = saved.object["code"]?.string,
              let id = saved.object["profile"]?.object["key_check"]?.object["key_id"]?.string else { throw CloudPrivacyError.recoveryRequired }
        return try CloudCipher.recover(code, keyID: id)
    }
    func preparePrivacy(session: CloudSession) async throws -> CloudPrivacyStatus {
        let profile: CloudJSON
        do { profile = try await privacyProfile(session, refresh: true) }
        catch CloudTransportError.unavailable {
            guard let cached = try CloudPrivacyKeyStore.read(owner: session.user.id)?.object["profile"] else { throw CloudTransportError.unavailable }
            profile = cached; privacyProfiles[session.user.id] = profile
        }
        if profile.object["encryption_required"] == .bool(false) {
            try CloudPrivacyKeyStore.save(.object(["profile":profile]), owner: session.user.id)
            return .init(ready: true, enrolled: false)
        }
        guard profile.object["key_check"] != .null, profile.object["key_check"] != nil else { return .init(ready: false, enrolled: false) }
        guard let code = try CloudPrivacyKeyStore.read(owner: session.user.id)?.object["code"]?.string else { return .init(ready: false, enrolled: true) }
        do { try await unlockPrivacy(session: session, code: code) }
        catch CloudPrivacyError.invalidCode { return .init(ready: false, enrolled: true) }
        catch CloudPrivacyError.invalidEnvelope { return .init(ready: false, enrolled: true) }
        return .init(ready: true, enrolled: true)
    }
    func unlockPrivacy(session: CloudSession, code: String) async throws {
        let profile = try await privacyProfile(session)
        guard let check = profile.object["key_check"], let id = check.object["key_id"]?.string,
              let workspace = profile.object["workspace_id"]?.string.flatMap(UUID.init(uuidString:)) else { throw CloudPrivacyError.recoveryRequired }
        let candidate = try CloudCipher.recover(code, keyID: id)
        guard try candidate.open(check, owner: session.user.id, workspace: workspace, kind: "key-check", revision: 0).object["check"]?.string == "doblon-key-v1" else { throw CloudPrivacyError.invalidCode }
        try CloudPrivacyKeyStore.save(.object(["profile":profile,"code":.string(candidate.recoveryCode)]), owner: session.user.id)
    }
    func enrollPrivacy(session: CloudSession, code: String) async throws {
        let profile = try await privacyProfile(session, refresh: true)
        guard profile.object["encryption_required"] == .bool(true), profile.object["key_check"] == .null,
              let workspace = profile.object["workspace_id"]?.string.flatMap(UUID.init(uuidString:)) else { throw CloudPrivacyError.recoveryRequired }
        let candidate = try CloudCipher.recover(code, keyID: UUID().uuidString)
        let data = try await send(path: "/rest/v1/rpc/finance_encryption_source", token: session.accessToken, body: .object([:]))
        let source = try JSONDecoder().decode(CloudJSON.self, from: data)
        let finance = try JSONDecoder().decode(CloudSnapshot.self, from: JSONEncoder().encode(source.object["finance"]))
        let learning = try JSONDecoder().decode(CloudSnapshot.self, from: JSONEncoder().encode(source.object["learning"]))
        guard finance.workspaceID == workspace, learning.workspaceID == workspace else { throw CloudTransportError.invalidData }
        try validatePrivacyDocument(finance.document, kind: "finance")
        try validatePrivacyDocument(learning.document, kind: "learning")
        let f = try candidate.seal(finance.document, owner: session.user.id, workspace: workspace, kind: "finance", revision: 1)
        let l = try candidate.seal(learning.document, owner: session.user.id, workspace: workspace, kind: "learning", revision: 1)
        _ = try candidate.open(f, owner: session.user.id, workspace: workspace, kind: "finance", revision: 1)
        _ = try candidate.open(l, owner: session.user.id, workspace: workspace, kind: "learning", revision: 1)
        let check = try candidate.seal(.object(["check":.string("doblon-key-v1")]), owner: session.user.id, workspace: workspace, kind: "key-check", revision: 0)
        var enrolled = profile.object; enrolled["key_check"] = check
        try CloudPrivacyKeyStore.save(.object(["profile":.object(enrolled),"code":.string(candidate.recoveryCode)]), owner: session.user.id)
        _ = try await send(path: "/rest/v1/rpc/finance_enable_encryption", token: session.accessToken, body: .object([
            "p_workspace":.string(workspace.uuidString),"p_finance_revision":.integer(finance.revision),"p_learning_revision":.integer(learning.revision),
            "p_finance":f,"p_learning":l,"p_key_check":check]))
        privacyProfiles[session.user.id] = .object(enrolled)
    }
    private func decodeSealed(_ data: Data, session: CloudSession, kind: String, expectedWorkspace: UUID? = nil) throws -> CloudSnapshot {
        let value = try JSONDecoder().decode(CloudSnapshot.self, from: data)
        let ws = privacyProfiles[session.user.id]?.object["workspace_id"]?.string.flatMap(UUID.init(uuidString:))
        guard value.workspaceID == ws, expectedWorkspace == nil || expectedWorkspace == ws else { throw CloudTransportError.invalidData }
        let document = try cipher(session).open(value.document, owner: session.user.id, workspace: value.workspaceID, kind: kind, revision: value.revision)
        try validatePrivacyDocument(document, kind: kind)
        return CloudSnapshot(workspaceID: value.workspaceID, revision: value.revision, document: document)
    }
    private func sealedSnapshot(session: CloudSession, kind: String, expectedWorkspace: UUID? = nil) async throws -> CloudSnapshot {
        let data = try await send(path: "/rest/v1/rpc/finance_encrypted_snapshot", token: session.accessToken, body: .object(["p_kind":.string(kind)]))
        return try decodeSealed(data, session: session, kind: kind, expectedWorkspace: expectedWorkspace)
    }
    private func sealedSave(session: CloudSession, workspace: UUID, revision: Int64, document: CloudJSON, kind: String) async throws -> CloudSnapshot {
        try validatePrivacyDocument(document, kind: kind)
        let envelope = try cipher(session).seal(document, owner: session.user.id, workspace: workspace, kind: kind, revision: revision + 1)
        let data = try await send(path: "/rest/v1/rpc/finance_encrypted_save", token: session.accessToken, body: .object([
            "p_workspace":.string(workspace.uuidString),"p_kind":.string(kind),"p_expected_revision":.integer(revision),"p_envelope":envelope]))
        return try decodeSealed(data, session: session, kind: kind, expectedWorkspace: workspace)
    }
    private func validatePrivacyDocument(_ document: CloudJSON, kind: String) throws {
        if kind == "learning" {
            guard document.object["version"] == .integer(1) else { throw CloudTransportError.invalidData }
            return
        }
        guard document.object["formatVersion"] == .integer(2) else { throw CloudTransportError.invalidData }
        for entity in CloudDocument.entities {
            guard case .array? = document.object[entity] else { throw CloudTransportError.invalidData }
        }
        guard try CloudDocument.integrityConflicts(document).isEmpty else { throw CloudTransportError.invalidData }
        for entry in document.object["transactions"]?.array ?? [] {
            let row = entry.object
            guard case .integer(let amount)? = row["amountMinor"], amount >= 0,
                  let date = row["date"]?.double, date.isFinite,
                  let type = row["typeRaw"]?.string, ["income","expense","interest","fee","transfer"].contains(type),
                  row["sourceAccountID"]?.string != nil else { throw CloudTransportError.invalidData }
            if type == "transfer" && (row["destinationAccountID"]?.string == nil || row["destinationAccountID"] == row["sourceAccountID"]) { throw CloudTransportError.invalidData }
        }
    }
    private func send(path: String, query: String? = nil, token: String? = nil, body: CloudJSON? = nil, method: String = "POST") async throws -> Data {
        try Task.checkCancellation()
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
        catch let error as URLError where error.code == .cancelled && Task.isCancelled { throw CancellationError() }
        catch { throw CloudTransportError.unavailable }
    }
}
