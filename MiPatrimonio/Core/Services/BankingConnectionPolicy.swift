import Foundation

struct BankingBankSchedule: Codable, Equatable {
    var nextAttempt: Date = .distantPast
    var blockedUntil: Date?
    var manualBlockedUntil: Date?
    var lastDownloadedAt: Date?
    var lastImportedAt: Date?
    var awaitingReview: Bool?

    func allows(force: Bool, at date: Date) -> Bool {
        if force { return manualBlockedUntil.map { date >= $0 } ?? true }
        return date >= automaticDate
    }
    var automaticDate: Date { max(nextAttempt, max(blockedUntil ?? .distantPast, manualBlockedUntil ?? .distantPast)) }
    mutating func started(at date: Date) { nextAttempt = date.addingTimeInterval(15 * 60) }
    mutating func downloaded(at date: Date) {
        nextAttempt = date.addingTimeInterval(6 * 60 * 60)
        blockedUntil = nil; manualBlockedUntil = nil; lastDownloadedAt = date
    }
    mutating func failed(at date: Date, retryAfter: TimeInterval?, userInitiated: Bool = true) {
        nextAttempt = date.addingTimeInterval(retryAfter ?? 15 * 60)
        blockedUntil = retryAfter.map { date.addingTimeInterval($0) }
        manualBlockedUntil = userInitiated ? blockedUntil : nil
    }
}

struct BankingBankSyncStatus {
    var summary: String
    var errorMessage: String?
    var retryAt: Date?
    var deferredTransfers = 0
    var retryIsAutomatic = false
}

/// Two editions from one code base, chosen when the IPA is built. Both connect to banks. The public one
/// (`DOBLON_PUBLIC`), for other people, leaves out the developer tools: the banking lab, the pause meter
/// and the diagnostics of what each bank sent.
enum AppEdition {
    #if DOBLON_PUBLIC
    static let isPersonal = false
    #else
    static let isPersonal = true
    #endif
}

enum BankingConnectionPolicy {
    enum EntryDestination: Equatable { case personal, sandbox, requiresPersonalWorkspace }

    static func entryDestination(cloud: Bool, testWorkspace: Bool, testOnly: Bool,
                                 personalEdition: Bool = AppEdition.isPersonal) -> EntryDestination {
        if testWorkspace { return .requiresPersonalWorkspace }
        // The banking lab only exists in the personal edition; elsewhere the real connection is shown.
        if testOnly && personalEdition { return .sandbox }
        return cloud ? .personal : .requiresPersonalWorkspace
    }

    static let personalServerHost = "mi-bombo-banking-personal.albertor7722.workers.dev"
    static func bankRetryDelay(_ header: String?) -> TimeInterval {
        guard let header, let seconds = Double(header), seconds.isFinite else { return 6 * 60 * 60 }
        return max(60, min(7 * 24 * 60 * 60, seconds))
    }
    static func acceptsAuthorizationURL(_ url: URL, server: URL, live: Bool = false) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else { return false }
        if live {
            return url.host == "auth.enablebanking.com" || url.host == "tilisy.enablebanking.com"
        }
        return url.host == "auth.enablebanking.com" || url.host == "tilisy-sandbox.enablebanking.com" || url.host == server.host
    }

    static func acceptsCallback(_ url: URL, flowID: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.scheme == "mibombomoney-bank", url.host == "callback", url.path.isEmpty,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let items = components.queryItems, items.count == 2,
              items.filter({ $0.name == "flow" }).count == 1,
              items.first(where: { $0.name == "flow" })?.value == flowID,
              items.filter({ $0.name == "result" }).count == 1,
              items.first(where: { $0.name == "result" })?.value == "ok" else { return false }
        return true
    }
}

struct BankingServerConfiguration: Codable {
    let serverURL: URL
    let token: String

    static func cloud(url: String, accessToken: String) throws -> Self {
        // Reuse exact host validation. Cloud credentials are short-lived and are never saved here.
        let origin = try validated(url: url, token: String(repeating: "0", count: 64)).serverURL
        guard origin.host == BankingConnectionPolicy.personalServerHost, accessToken.count <= 8192,
              accessToken.range(of: #"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw BankingConnectionError.invalidConfiguration
        }
        return Self(serverURL: origin, token: accessToken)
    }

    static func validated(url: String, token: String) throws -> Self {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https", let host = components.host,
              host.range(of: #"^[a-z0-9-]+\.[a-z0-9-]+\.workers\.dev$"#, options: .regularExpression) != nil,
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let serverURL = URL(string: "https://\(host)"),
              token.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw BankingConnectionError.invalidConfiguration
        }
        return Self(serverURL: serverURL, token: token)
    }
}

enum BankingConnectionError: LocalizedError {
    case invalidConfiguration, missingConfiguration, invalidResponse, authorizationFailed, presentationUnavailable, cancelled
    case server(String)
    indirect case accountQuery(bank: String, lastFour: String, reason: BankingConnectionError)
    case bankRateLimited(retryAfter: TimeInterval)

    var retryDelay: TimeInterval? {
        switch self {
        case .bankRateLimited(let seconds): seconds
        case .accountQuery(_, _, let reason): reason.retryDelay
        case .server("bank_rate_limited"): 6 * 60 * 60
        default: nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Usa la dirección HTTPS de tu servidor workers.dev y su clave de acceso de 64 caracteres."
        case .missingConfiguration: "Configura primero tu servidor de prueba."
        case .invalidResponse: "La respuesta del servidor no es válida. No se han modificado tus datos financieros."
        case .authorizationFailed: "No se ha podido completar la autorización. Inténtalo de nuevo."
        case .presentationUnavailable: "No se ha podido abrir la ventana de autorización. Mantén la app en primer plano y vuelve a intentarlo."
        case .cancelled: "Has cancelado la conexión."
        case .accountQuery(let bank, let lastFour, let reason):
            "\(bank) · •••• \(lastFour): \(reason.localizedDescription)"
        case .bankRateLimited:
            "El banco o el proveedor ha limitado las consultas. Se respetará el plazo de espera antes de volver a actualizar. No necesitas desconectar ni volver a asociar la cuenta."
        case .server(let code):
            switch code {
            case "unauthorized": "La clave de acceso no es válida o ha sido revocada."
            case "owner_required": "Tu cuenta no tiene acceso a la conexión bancaria. Pide al responsable de Doblón que te invite."
            case "identity_unavailable": "No se ha podido verificar tu sesión cloud. Inténtalo más tarde."
            case "production_configuration_required": "El servidor necesita una aplicación de Enable Banking de producción activa, con acceso AIS y el retorno correcto."
            case "stable_account_identity_required": "El banco no devuelve una identificación estable de la cuenta. No se importará para evitar duplicados al renovar el permiso."
            case "authorization_destination_rejected": "No se ha abierto la autorización porque la dirección recibida no es un destino permitido de Enable Banking. Actualiza la app y, si continúa, revisa la conexión con el proveedor."
            case "invalid_provider_data": "El proveedor ha devuelto datos incompletos o no compatibles. No se han incorporado movimientos."
            case "service_unavailable": "El servidor de conexión no ha podido completar la operación. Inténtalo de nuevo más tarde."
            case "rate_limited": "Se han hecho demasiadas solicitudes. Espera un minuto antes de reintentar."
            case "live_banking_disabled", "sandbox_configuration_required": "Esta versión solo admite demostración y pruebas sandbox. Las cuentas reales están bloqueadas."
            case "not_configured", "invalid_signing_key": "Falta completar la configuración del servidor de prueba."
            case "connection_not_found": "La conexión ha caducado o ya se ha desconectado."
            case "bank_unavailable": "El banco o el proveedor no ha podido completar la consulta. Vuelve a intentarlo más tarde."
            case "bank_session_expired", "bank_action_required": "El banco requiere que renueves la autorización desde Conectar o renovar un banco. Tus movimientos guardados se conservan."
            case "bank_rate_limited": "El banco o el proveedor ha limitado las consultas. Espera antes de volver a actualizar; no necesitas desconectar la cuenta."
            case "bank_timeout": "El banco no ha respondido a tiempo. Vuelve a actualizar más tarde."
            case "bank_psu_headers_required": "El banco exige información de la conexión del dispositivo que el servidor no ha enviado correctamente. Es necesario actualizar el servidor; no necesitas borrar ni volver a asociar la cuenta."
            case "psu_context_unavailable": "No se ha podido identificar la conexión del dispositivo para esta consulta manual. Es necesario revisar el servidor."
            case "bank_account_unavailable": "El banco no permite consultar esta cuenta con el permiso actual. Comprueba las cuentas autorizadas al renovar el banco."
            case "bank_history_unavailable": "El banco ha rechazado el periodo de movimientos solicitado. Es necesario revisar la consulta del servidor."
            case "bank_request_rejected": "El banco ha rechazado los parámetros de la consulta. Es necesario revisar el servidor de conexión."
            case "provider_access_denied": "Enable Banking ha rechazado el acceso del servidor. Hay que revisar su configuración y permisos."
            default: "No se pudo completar la consulta. Comprueba la conexión y la configuración del servidor."
            }
        }
    }
}

