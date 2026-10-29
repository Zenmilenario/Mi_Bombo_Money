import Combine
import Foundation

@MainActor
final class CloudAccountManager: ObservableObject {
    @Published private(set) var session: CloudSession?
    @Published private(set) var busy = false
    @Published var message: String?
    @Published var needsSignIn = false
    @Published private(set) var pendingLink: CloudSession?
    @Published private(set) var linkRequiresPassword = false
    private let sessionKey = "supabase-coeicjffmpclqowsqeys-session-v1"
    private let flowKey = "supabase-coeicjffmpclqowsqeys-pkce-v1"
    private var client: CloudClient?
    private var identityGeneration = UUID()
    var isConfigured: Bool { client != nil }

    init() {
        if let config = CloudConfiguration.bundled { client = try? CloudClient(configuration: config) }
        if let data = try? KeychainStore.read(account: sessionKey) {
            session = try? JSONDecoder().decode(CloudSession.self, from: data)
        }
    }
    private func api() throws -> CloudClient {
        guard let client else { throw CloudTransportError.configuration }
        return client
    }
    private func accept(_ value: CloudSession) throws {
        guard !value.accessToken.isEmpty, !value.refreshToken.isEmpty, value.expiresAt > 0 else { throw CloudTransportError.invalidData }
        try KeychainStore.save(JSONEncoder().encode(value), account: sessionKey)
        identityGeneration = UUID()
        session = value
        needsSignIn = false
        pendingLink = nil
        try? KeychainStore.delete(account: flowKey)
    }
    func signIn(email: String, password: String, create: Bool) async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let api = try api()
            if create {
                let flow = CloudPKCEFlow(isRecovery: false)
                try KeychainStore.save(JSONEncoder().encode(flow), account: flowKey)
                if let value = try await api.signUp(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password, challenge: flow.challenge) { try accept(value) }
                else { message = "Revisa tu correo y confirma el acceso. Abre el enlace en este mismo dispositivo y vuelve a la app." }
            } else {
                try accept(await api.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password))
            }
        } catch { message = error.localizedDescription }
    }
    func recover(email: String) async {
        guard !busy, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "Escribe tu correo para solicitar el enlace de recuperación."; return
        }
        busy = true; message = nil
        defer { busy = false }
        do {
            let flow = CloudPKCEFlow(isRecovery: true)
            try KeychainStore.save(JSONEncoder().encode(flow), account: flowKey)
            try await api().recover(email: email.trimmingCharacters(in: .whitespacesAndNewlines), challenge: flow.challenge)
            message = "Si existe una cuenta con ese correo, recibirás un enlace. Ábrelo en este dispositivo para cambiar la contraseña."
        } catch { message = error.localizedDescription }
    }
    func handleLink(_ url: URL) async {
        guard url.scheme == "mibombomoney-cloud", !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            guard let code = CloudPKCEFlow.callbackCode(url), let data = try KeychainStore.read(account: flowKey),
                  let flow = try? JSONDecoder().decode(CloudPKCEFlow.self, from: data), !flow.isExpired else {
                throw CloudTransportError.requestRejected("Este enlace no corresponde a una solicitud vigente de este dispositivo. Solicita otro desde la app.")
            }
            let value = try await api().exchange(code: code, verifier: flow.verifier)
            try KeychainStore.delete(account: flowKey)
            pendingLink = value
            linkRequiresPassword = flow.isRecovery
            UserDefaults.standard.set(true, forKey: "cloudAccountModeEnabled")
        } catch { message = error.localizedDescription }
    }
    func confirmLink(password: String? = nil) async {
        guard let pendingLink, !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            if linkRequiresPassword {
                guard let password, password.count >= 10 else {
                    throw CloudTransportError.requestRejected("Usa una contraseña de al menos 10 caracteres.")
                }
                try await api().updatePassword(password, session: pendingLink)
            }
            try accept(pendingLink)
        } catch { message = error.localizedDescription }
    }
    func cancelLink() { pendingLink = nil; message = nil }
    func validSession(forceRefresh: Bool = false) async throws -> CloudSession {
        guard let current = session, !needsSignIn else { throw CloudTransportError.authentication }
        if !forceRefresh && current.expiresAt > Date.now.timeIntervalSince1970 + 60 { return current }
        let generation = identityGeneration
        do {
            let renewed = try await api().refresh(current)
            guard identityGeneration == generation, session?.user.id == current.user.id else { throw CancellationError() }
            try KeychainStore.save(JSONEncoder().encode(renewed), account: sessionKey)
            session = renewed
            return renewed
        } catch CloudTransportError.authentication {
            guard identityGeneration == generation else { throw CancellationError() }
            needsSignIn = true
            throw CloudTransportError.authentication
        }
    }
    func snapshot(workspace: UUID? = nil) async throws -> CloudSnapshot {
        do { return try await api().snapshot(session: validSession(), workspace: workspace) }
        catch CloudTransportError.authentication {
            do { return try await api().snapshot(session: validSession(forceRefresh: true), workspace: workspace) }
            catch CloudTransportError.authentication { needsSignIn = true; throw CloudTransportError.authentication }
        }
    }
    func save(workspace: UUID, revision: Int64, document: CloudJSON) async throws -> CloudSnapshot {
        do { return try await api().save(session: validSession(), workspace: workspace, revision: revision, document: document) }
        catch CloudTransportError.authentication {
            do { return try await api().save(session: validSession(forceRefresh: true), workspace: workspace, revision: revision, document: document) }
            catch CloudTransportError.authentication { needsSignIn = true; throw CloudTransportError.authentication }
        }
    }
    func signOut() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        let old = session
        do { try KeychainStore.delete(account: sessionKey) }
        catch { message = error.localizedDescription; return }
        identityGeneration = UUID()
        session = nil; needsSignIn = false; pendingLink = nil
        try? KeychainStore.delete(account: flowKey)
        if let old {
            do { try await api().signOut(old) }
            catch { message = "Has salido en este dispositivo. No se ha podido confirmar la revocación en el servidor." }
        }
    }
}
