import Foundation

@main
struct BankingSecurityCheck {
    static func main() throws {
        checkAuthenticationLifecycle()
        checkSingleCompletion()
        // Fictional credentials used only to validate destination policy; never used for a server.
        let token = String(repeating: "a", count: 64)
        let server = "https://bank-test.personal.workers.dev"
        let personal = "https://" + BankingConnectionPolicy.personalServerHost
        _ = try BankingServerConfiguration.cloud(url: personal, accessToken: "fixture.payload.signature")
        for invalid in [server, "https://evil.workers.dev", personal + ".evil.test"] {
            do { _ = try BankingServerConfiguration.cloud(url: invalid, accessToken: "fixture.payload.signature"); preconditionFailure("Cloud token could be sent to another host") }
            catch is BankingConnectionError { }
        }
        let configuration = try BankingServerConfiguration.validated(url: server, token: token)
        for host in ["auth.enablebanking.com", "tilisy.enablebanking.com"] {
            precondition(BankingConnectionPolicy.acceptsAuthorizationURL(URL(string: "https://\(host)/ais/start?sessionid=fixture")!, server: configuration.serverURL, live: true))
        }
        for invalid in ["https://tilisy.enablebanking.com.evil.test/ais/start", "https://evil-tilisy.enablebanking.com/ais/start",
                        "http://tilisy.enablebanking.com/ais/start", "https://user:password@tilisy.enablebanking.com/ais/start",
                        "https://tilisy.enablebanking.com:8443/ais/start", "https://tilisy-sandbox.enablebanking.com/authorize", server + "/demo/consent"] {
            precondition(!BankingConnectionPolicy.acceptsAuthorizationURL(URL(string: invalid)!, server: configuration.serverURL, live: true))
        }
        precondition(!BankingConnectionPolicy.acceptsAuthorizationURL(URL(string: "https://tilisy.enablebanking.com/ais/start")!, server: configuration.serverURL))
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
        precondition(BankingConnectionPolicy.acceptsAuthorizationURL(URL(string: "https://tilisy-sandbox.enablebanking.com/authorize")!, server: configuration.serverURL))
        for invalid in ["https://tilisy-sandbox.enablebanking.com.evil.test/authorize", "http://tilisy-sandbox.enablebanking.com/authorize",
                        "https://user@tilisy-sandbox.enablebanking.com/authorize", "https://tilisy-sandbox.enablebanking.com:8443/authorize"] {
            precondition(!BankingConnectionPolicy.acceptsAuthorizationURL(URL(string: invalid)!, server: configuration.serverURL))
        }
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
        print("Banking client checks passed: lifecycle, biometric reuse/cancellation, single callback completion, HTTPS, trusted origin and callback correlation.")
    }

    private static func checkAuthenticationLifecycle() {
        var policy = AppAuthenticationPolicy()
        precondition(!policy.shouldAuthenticateAutomatically)
        policy.becameActive()
        precondition(policy.shouldAuthenticateAutomatically)
        let opening = policy.beginAuthentication()!
        precondition(policy.beginAuthentication() == nil, "Only one biometric request may run at a time")
        // Re-entering active after an inactive system sheet must not create another prompt.
        for _ in 0..<10 { policy.becameActive(); precondition(!policy.shouldAuthenticateAutomatically) }
        precondition(policy.finishAuthentication(id: opening, succeeded: true, uptime: 100))
        policy.becameActive()
        precondition(policy.isUnlocked && !policy.shouldAuthenticateAutomatically)
        precondition(policy.hasRecentAuthentication(uptime: 120))
        precondition(!policy.hasRecentAuthentication(uptime: 131))
        precondition(!policy.hasRecentAuthentication(uptime: 99), "Clock inconsistencies must not extend the reuse window")

        precondition(policy.beginProtectedAction())
        precondition(!policy.beginProtectedAction(), "A second banking flow must not run concurrently")
        policy.enteredBackground()
        policy.becameActive()
        precondition(!policy.isUnlocked && !policy.shouldAuthenticateAutomatically,
                     "A browser return must not compete with the still-active banking flow")
        precondition(!policy.hasRecentAuthentication(uptime: 121), "Real backgrounding invalidates biometric reuse")
        policy.endProtectedAction()
        precondition(policy.shouldAuthenticateAutomatically)
        let returning = policy.beginAuthentication()!
        precondition(policy.finishAuthentication(id: returning, succeeded: false, uptime: 122))
        for _ in 0..<10 { policy.becameActive(); precondition(!policy.shouldAuthenticateAutomatically) }
        let manualRetry = policy.beginAuthentication()!
        precondition(policy.finishAuthentication(id: manualRetry, succeeded: true, uptime: 123))

        policy.enteredBackground(); policy.becameActive()
        let stale = policy.beginAuthentication()!
        policy.enteredBackground()
        precondition(!policy.finishAuthentication(id: stale, succeeded: true, uptime: 124))
        precondition(!policy.isUnlocked, "A late biometric callback must never unlock after backgrounding")
        policy.becameActive()
        let fresh = policy.beginAuthentication()!
        precondition(!policy.finishAuthentication(id: stale, succeeded: true, uptime: 125))
        precondition(policy.authenticationID == fresh, "A stale callback must not clear a newer prompt")
        precondition(policy.finishAuthentication(id: fresh, succeeded: true, uptime: 126))
        policy.unlockWithoutAuthentication()
        precondition(!policy.hasRecentAuthentication(uptime: 127), "Disabling the app lock cannot bypass banking verification")
    }

    private static func checkSingleCompletion() {
        var gate = AuthenticationCompletionGate()
        let failedStart = gate.begin()!
        precondition(gate.begin() == nil)
        precondition(gate.finish(failedStart))
        precondition(!gate.finish(failedStart), "The late failure callback after start() returns false must not resume twice")
        let next = gate.begin()!
        precondition(!gate.finish(failedStart), "A callback from the prior session cannot complete a new session")
        precondition(gate.operationID == next)
        precondition(gate.finish(next))
        precondition(!gate.finish(next), "Cancel and completion races must resolve only once")
    }
}
