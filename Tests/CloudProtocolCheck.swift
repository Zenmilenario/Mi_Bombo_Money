import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class MockCloudProtocol: URLProtocol {
    static let lock = NSLock()
    static var calls = 0
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.calls += 1; let handler = Self.handler; Self.lock.unlock()
        do {
            let (status,data) = try handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() { }
}

@MainActor private final class AutomaticSyncProbe {
    var permitted = true
    var calls = 0
    var running = 0
    var maximumRunning = 0
}

@main
struct CloudProtocolCheck {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "Check failed") throws {
        let value = try condition()
        precondition(value, message)
    }
    static func id(_ value: Int) -> String { String(format: "00000000-0000-4000-8000-%012d",value) }
    static func record(_ value: Int, _ name: String) -> CloudJSON { .object(["id":.string(id(value)),"name":.string(name)]) }
    static func document(_ fields: [String:[CloudJSON]]) -> CloudJSON {
        CloudDocument.normalized(.object(fields.mapValues { .array($0) }))
    }
    static func modified(_ value: CloudJSON, _ fields: [String:CloudJSON]) -> CloudJSON { .object(value.object.merging(fields) { _,new in new }) }
    static func expectConflict(_ operation: () throws -> CloudJSON) {
        do { _ = try operation(); preconditionFailure("Expected a conflict") }
        catch is CloudMergeConflict { }
        catch { preconditionFailure("Unexpected error: \(error)") }
    }
    static func main() async throws {
        let big: CloudJSON = .integer(Int64.max-1)
        try check(try JSONDecoder().decode(CloudJSON.self,from:JSONEncoder().encode(big)) == big)
        let base = document(["accounts":[record(1,"Original"),record(2,"Otra")]])
        let local = document(["accounts":[record(1,"Local"),record(2,"Otra")]])
        let remote = document(["accounts":[record(1,"Original"),record(2,"Remota")]])
        let merged = try CloudDocument.merge(base:base,local:local,remote:remote)
        try check(try CloudDocument.indexed(merged,entity:"accounts")[id(1)]?.object["name"] == .string("Local"))
        try check(try CloudDocument.indexed(merged,entity:"accounts")[id(2)]?.object["name"] == .string("Remota"))
        let simultaneous = document(["accounts":[record(1,"Remota distinta"),record(2,"Remota")]])
        expectConflict { try CloudDocument.merge(base:base,local:local,remote:simultaneous) }
        let chosen = try CloudDocument.resolving(base:base,local:local,remote:simultaneous,preferLocal:true)
        try check(try CloudDocument.indexed(chosen,entity:"accounts")[id(1)]?.object["name"] == .string("Local"))
        try check(try CloudDocument.indexed(chosen,entity:"accounts")[id(2)]?.object["name"] == .string("Remota"))
        let deleted = document(["accounts":[record(2,"Otra")]])
        expectConflict { try CloudDocument.merge(base:base,local:local,remote:deleted) }
        let deletionWon = try CloudDocument.resolving(base:base,local:local,remote:deleted,preferLocal:false)
        try check(try CloudDocument.indexed(deletionWon,entity:"accounts")[id(1)] == nil)
        let metadataOnly = document(["accounts":[modified(record(1,"Original"),["updatedAt":.number(55)]),record(2,"Otra")]])
        try check(try CloudDocument.same(base,metadataOnly))
        let repeated = try CloudDocument.merge(base:CloudDocument.empty,local:merged,remote:merged)
        try check(try CloudDocument.same(repeated,merged),"A response lost after commit must be safe to replay")
        let editWhileSending = try CloudDocument.merge(base:local,local:document(["accounts":[record(1,"Editada mientras sube"),record(2,"Otra")]]),remote:merged)
        try check(try CloudDocument.indexed(editWhileSending,entity:"accounts")[id(1)]?.object["name"] == .string("Editada mientras sube"))
        try checkGraphConflicts()
        #if canImport(CryptoKit)
        let flow = CloudPKCEFlow(isRecovery:true)
        precondition(flow.verifier.count == 43 && flow.challenge.count == 43 && !flow.isExpired)
        precondition(flow.verifier != CloudPKCEFlow(isRecovery:false).verifier)
        precondition(CloudPKCEFlow.callbackCode(URL(string:"mibombomoney-cloud://auth?code=valid")!) == "valid")
        for invalid in ["other://auth?code=valid","mibombomoney-cloud://evil?code=valid","mibombomoney-cloud://auth/path?code=valid","mibombomoney-cloud://auth?code=a&code=b","mibombomoney-cloud://auth?code=a#access_token=bad","mibombomoney-cloud://auth?access_token=bad"] {
            precondition(CloudPKCEFlow.callbackCode(URL(string:invalid)!) == nil)
        }
        #endif
        try await checkTransport()
        try await checkCancelledRequest()
        try await checkAutomaticPolling()
        print("Cloud checks passed: exact integer cents, three-way merge, explicit conflicts, relational/funding conflicts, replay safety, edits during upload, scoped HTTPS transport, session refresh, server revision rejection and automatic polling lifecycle.")
    }

    @MainActor static func checkCancelledRequest() async throws {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [MockCloudProtocol.self]
        let transport = URLSession(configuration:settings)
        let config = CloudConfiguration(url:URL(string:"https://\(CloudConfiguration.projectHost)")!,publishableKey:"sb_publishable_fictional")
        let client = try CloudClient(configuration:config,transport:transport)
        let session = CloudSession(accessToken:"fictional",refreshToken:"fictional",expiresAt:Date.now.timeIntervalSince1970+3600,
                                   user:CloudUser(id:UUID(),email:nil))
        let before = MockCloudProtocol.calls
        let request = Task { @MainActor in try await client.snapshot(session:session) }
        request.cancel()
        do {
            _ = try await request.value
            preconditionFailure("A cancelled lifecycle must not start a cloud request")
        } catch is CancellationError { }
        precondition(MockCloudProtocol.calls == before,"Cancellation must be checked before transmitting credentials")
    }

    @MainActor static func checkAutomaticPolling() async throws {
        let active = CloudAutomaticSyncState(ready:true,foreground:true,unlocked:true,authenticated:true)
        let probe = AutomaticSyncProbe()
        for blocked in [
            CloudAutomaticSyncState(ready:false,foreground:true,unlocked:true,authenticated:true),
            CloudAutomaticSyncState(ready:true,foreground:false,unlocked:true,authenticated:true),
            CloudAutomaticSyncState(ready:true,foreground:true,unlocked:false,authenticated:true),
            CloudAutomaticSyncState(ready:true,foreground:true,unlocked:true,authenticated:false)
        ] {
            await CloudAutomaticSync.run(state:blocked,interval:.milliseconds(5),
                maySynchronize:{ preconditionFailure("A blocked lifecycle must not start polling") },
                synchronize:{ probe.calls += 1 })
            precondition(blocked != active, "SwiftUI must restart when a lifecycle input changes")
        }
        func start() -> Task<Void,Never> {
            Task { @MainActor in
                await CloudAutomaticSync.run(state:active,interval:.milliseconds(5),maySynchronize:{probe.permitted}) {
                    probe.calls += 1; probe.running += 1
                    probe.maximumRunning = max(probe.maximumRunning,probe.running)
                    try? await Task.sleep(for:.milliseconds(3))
                    probe.running -= 1
                }
            }
        }
        func eventually(_ condition:() -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by:.seconds(5))
            while !condition() {
                precondition(ContinuousClock.now < deadline,"Automatic polling failed to resume")
                try await Task.sleep(for:.milliseconds(1))
            }
        }
        let first = start()
        try await eventually { probe.calls >= 2 }
        probe.permitted = false
        try await eventually { probe.running == 0 }
        let pausedCount = probe.calls
        try await Task.sleep(for:.milliseconds(30))
        precondition(probe.calls == pausedCount,"A presented form must pause automatic sync")
        probe.permitted = true
        try await eventually { probe.calls > pausedCount }
        first.cancel(); await first.value
        let stoppedCount = probe.calls
        try await Task.sleep(for:.milliseconds(20))
        precondition(probe.calls == stoppedCount,"A cancelled lifecycle must stop polling")
        let restarted = start()
        try await eventually { probe.calls > stoppedCount }
        restarted.cancel(); await restarted.value
        precondition(probe.maximumRunning == 1,"Polling must not overlap its own requests")
    }
    static func checkGraphConflicts() throws {
        let account=record(1,"Cuenta")
        let fund=modified(record(3,"Reserva"),["amountMinor":.integer(500),"accountID":.string(id(1))])
        func payment(_ key:Int) -> CloudJSON { modified(record(key,"Pago"),["sourceAccountID":.string(id(1)),"reservedFundID":.string(id(3)),"reservedAmountMinor":.integer(400),"amountMinor":.integer(400)]) }
        let base=document(["accounts":[account],"reservedFunds":[fund]])
        let local=document(["accounts":[account],"reservedFunds":[fund],"transactions":[payment(4)]])
        let remote=document(["accounts":[account],"reservedFunds":[fund],"transactions":[payment(5)]])
        expectConflict { try CloudDocument.merge(base:base,local:local,remote:remote) }
        let resolved=try CloudDocument.resolving(base:base,local:local,remote:remote,preferLocal:true)
        precondition(resolved.object["transactions"]?.array.count == 1)
        try check(try CloudDocument.indexed(resolved,entity:"transactions")[id(4)] != nil)
        let deleted=document(["accounts":[account]])
        expectConflict { try CloudDocument.merge(base:base,local:local,remote:deleted) }
        let preserve=try CloudDocument.resolving(base:base,local:local,remote:deleted,preferLocal:true)
        precondition(preserve.object["reservedFunds"]?.array.count == 1 && preserve.object["transactions"]?.array.count == 1)
        let remove=try CloudDocument.resolving(base:base,local:local,remote:deleted,preferLocal:false)
        precondition(remove.object["reservedFunds"]?.array.isEmpty == true && remove.object["transactions"]?.array.isEmpty == true)
    }
    static func checkTransport() async throws {
        let config=CloudConfiguration(url:URL(string:"https://coeicjffmpclqowsqeys.supabase.co")!,publishableKey:"sb_publishable_fictional")
        precondition(config.isValid)
        for url in ["http://coeicjffmpclqowsqeys.supabase.co","https://evil.test","https://coeicjffmpclqowsqeys.supabase.co.evil.test","https://user@coeicjffmpclqowsqeys.supabase.co","https://coeicjffmpclqowsqeys.supabase.co:443"] {
            precondition(!CloudConfiguration(url:URL(string:url)!,publishableKey:"sb_publishable_fictional").isValid)
        }
        precondition(!CloudConfiguration(url:config.url,publishableKey:"sb_secret_FORBIDDEN").isValid)
        let settings=URLSessionConfiguration.ephemeral
        settings.protocolClasses=[MockCloudProtocol.self]
        let transport=URLSession(configuration:settings)
        defer { transport.invalidateAndCancel() }
        let client=try CloudClient(configuration:config,transport:transport)
        let session=CloudSession(accessToken:"fictional-access",refreshToken:"fictional-refresh",expiresAt:Date.now.timeIntervalSince1970+3600,user:CloudUser(id:UUID(uuidString:id(99))!,email:"fictional@example.invalid"))
        let sessionData=try JSONEncoder().encode(session)
        MockCloudProtocol.handler = { request in
            precondition(request.url?.host == CloudConfiguration.projectHost)
            precondition(request.value(forHTTPHeaderField:"apikey") == config.publishableKey)
            return (200,sessionData)
        }
        let signedIn=try await client.signIn(email:"fictional@example.invalid",password:"fictional-password")
        precondition(signedIn.user.id == session.user.id)
        MockCloudProtocol.calls=0
        MockCloudProtocol.handler = { _ in Thread.sleep(forTimeInterval:0.1); return (200,sessionData) }
        try await withThrowingTaskGroup(of:UUID.self) { group in
            for _ in 0..<10 { group.addTask { try await client.refresh(session).user.id } }
            for try await user in group { precondition(user == session.user.id) }
        }
        precondition(MockCloudProtocol.calls == 1,"Concurrent refreshes must share one rotating-token request")
        MockCloudProtocol.handler = { _ in (200,Data("{}".utf8)) }
        let pending=try await client.signUp(email:"fictional@example.invalid",password:"fictional-password",challenge:"fictional-challenge")
        precondition(pending == nil,"A confirmation email is not an authenticated session")
        MockCloudProtocol.handler = { request in
            precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer fictional-access")
            return (400,Data("{\"code\":\"40001\"}".utf8))
        }
        do {
            _=try await client.save(session:session,workspace:UUID(),revision:1,document:CloudDocument.empty)
            preconditionFailure("Expected server revision conflict")
        } catch CloudTransportError.conflict { }
    }
}
