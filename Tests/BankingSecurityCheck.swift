import Foundation

@main
struct BankingSecurityCheck {
    static func main() throws {
        // Fictional credentials used only to validate destination policy; never used for a server.
        let token = String(repeating: "a", count: 64)
        let server = "https://bank-test.personal.workers.dev"
        let configuration = try BankingServerConfiguration.validated(url: server, token: token)
        precondition(configuration.serverURL.absoluteString == server)
        for invalid in ["http://bank-test.personal.workers.dev", "https://evil.test", "https://bank-test.personal.workers.dev.evil.test",
                        "https://user@bank-test.personal.workers.dev", "https://bank-test.personal.workers.dev:443",
                        "https://bank-test.personal.workers.dev/path", "https://bank-test.personal.workers.dev?token=test",
                        "https://bank-test.personal.workers.dev#fragment"] {
            do {
                _ = try BankingServerConfiguration.validated(url: invalid, token: token)
                preconditionFailure("Unsafe banking server accepted")
            } catch is BankingConnectionError { }
        }
        for invalid in ["", "1234", token + "x", String(repeating: "g", count: 64)] {
            do {
                _ = try BankingServerConfiguration.validated(url: server, token: invalid)
                preconditionFailure("Malformed credential accepted")
            } catch is BankingConnectionError { }
        }
        precondition(BankingConnectionPolicy.acceptsAuthorizationURL(URL(string: "https://auth.enablebanking.com/authorize")!, server: configuration.serverURL))
        precondition(!BankingConnectionPolicy.acceptsAuthorizationURL(URL(string: "https://auth.enablebanking.com.evil.test/authorize")!, server: configuration.serverURL))
        precondition(!BankingConnectionPolicy.acceptsAuthorizationURL(URL(string: "http://auth.enablebanking.com/authorize")!, server: configuration.serverURL))
        let flow = UUID().uuidString.lowercased()
        precondition(BankingConnectionPolicy.acceptsCallback(URL(string: "mibombomoney-bank://callback?flow=\(flow)&result=ok")!, flowID: flow))
        for invalid in ["mibombomoney-bank://callback?flow=other&result=ok", "other://callback?flow=\(flow)&result=ok",
                        "mibombomoney-bank://callback?flow=\(flow)&result=ok&flow=other",
                        "mibombomoney-bank://callback?flow=\(flow)&result=ok&token=secret",
                        "mibombomoney-bank://callback/path?flow=\(flow)&result=ok",
                        "mibombomoney-bank://callback?flow=\(flow)&result=failed"] {
            precondition(!BankingConnectionPolicy.acceptsCallback(URL(string: invalid)!, flowID: flow))
        }
        print("Banking client policy checks passed: HTTPS, trusted origin, credential format and callback correlation.")
    }
}
