import Foundation

enum BankingConnectionPolicy {
    static let personalServerHost = "mi-bombo-banking-personal.albertor7722.workers.dev"
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

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Usa la dirección HTTPS de tu servidor workers.dev y su clave de acceso de 64 caracteres."
        case .missingConfiguration: "Configura primero tu servidor de prueba."
        case .invalidResponse: "La respuesta del servidor no es válida. No se han modificado tus datos financieros."
        case .authorizationFailed: "No se ha podido completar la autorización. Inténtalo de nuevo."
        case .presentationUnavailable: "No se ha podido abrir la ventana de autorización. Mantén la app en primer plano y vuelve a intentarlo."
        case .cancelled: "Has cancelado la conexión."
        case .server(let code):
            switch code {
            case "unauthorized": "La clave de acceso no es válida o ha sido revocada."
            case "owner_required": "Esta conexión bancaria pertenece a otra cuenta cloud."
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
            case "bank_unavailable": "El banco de pruebas no está disponible. Vuelve a intentarlo más tarde."
            default: "No se pudo completar la consulta. Comprueba la conexión y la configuración del servidor."
            }
        }
    }
}

