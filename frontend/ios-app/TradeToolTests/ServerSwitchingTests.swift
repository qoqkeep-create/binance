import Foundation
import XCTest
@testable import TradeTool

final class ServerSwitchingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "ServerSwitchingTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    func testAPIRequestPreservesDeploymentPrefixAndQuery() throws {
        let request = APIRequest<EmptyResponse>(path: "/v1/position/list", queryItems: [.init(name: "page", value: "2")])
        let url = try request.makeURLRequest(baseURL: URL(string: "https://example.invalid/integrated/")!).url
        XCTAssertEqual(url?.absoluteString, "https://example.invalid/integrated/v1/position/list?page=2")
        let root = try request.makeURLRequest(baseURL: URL(string: "https://example.invalid")!).url
        XCTAssertEqual(root?.path, "/v1/position/list")
    }

    func testSelectionPersistsAndRejectsUnknownSavedOrigin() {
        let store = selectionStore()
        XCTAssertEqual(store.current, .original)
        store.save(.seoul)
        XCTAssertEqual(selectionStore().current, .seoul)
        defaults.set("https://unknown.example", forKey: ServerSelectionStore.storageKey)
        XCTAssertEqual(selectionStore().current, .original)
    }

    @MainActor
    func testSuccessfulSwitchRebuildsContainerAndPersistsTarget() async throws {
        let runtime = makeRuntime(probe: StubProbe())
        let previous = runtime.container
        try await runtime.switchServer(to: .seoul)
        XCTAssertFalse(runtime.container === previous)
        XCTAssertEqual(runtime.container.baseURL, AppServer.seoul.url)
        XCTAssertEqual(selectionStore().current, .seoul)
        XCTAssertFalse(runtime.isSwitching)
        runtime.container.prepareForServerChange()
    }

    @MainActor
    func testFailedSwitchPreservesCurrentContainerAndSelection() async {
        let runtime = makeRuntime(probe: StubProbe(error: URLError(.cannotConnectToHost)))
        let previous = runtime.container
        do {
            try await runtime.switchServer(to: .seoul)
            XCTFail("An unreachable server must not be selected")
        } catch {}
        XCTAssertTrue(runtime.container === previous)
        XCTAssertEqual(selectionStore().current, .original)
        XCTAssertFalse(runtime.isSwitching)
        runtime.container.prepareForServerChange()
    }

    @MainActor
    func testCancelledSwitchDoesNotPersistOrRebuildContainer() async {
        let runtime = makeRuntime(probe: StubProbe(delay: true))
        let previous = runtime.container
        let task = Task { try await runtime.switchServer(to: .seoul) }
        await Task.yield()
        task.cancel()
        do {
            try await task.value
            XCTFail("A cancelled switch must not be committed")
        } catch {}
        XCTAssertTrue(runtime.container === previous)
        XCTAssertEqual(selectionStore().current, .original)
        XCTAssertFalse(runtime.isSwitching)
        runtime.container.prepareForServerChange()
    }

    func testProbeAcceptsUnauthenticatedAPIWithoutSendingCredentials() async throws {
        let probe = configuredProbe()
        let result = try await probe.check(
            AppServer(name: "Test", url: URL(string: "https://api.example")!), samples: 3
        )
        XCTAssertEqual(result.samplesMilliseconds.count, 3)
        XCTAssertGreaterThanOrEqual(result.medianMilliseconds, 0)
    }

    func testProbeRejectsHTMLAndMismatchedAPIStatus() async {
        for host in ["html.example", "mismatch.example"] {
            do {
                _ = try await configuredProbe().check(
                    AppServer(name: "Test", url: URL(string: "https://\(host)")!), samples: 1
                )
                XCTFail("A non-API response must fail the connectivity check")
            } catch {}
        }
    }

    @MainActor
    func testUnauthorizedFromPreviousServerDoesNotExpireNewSession() async throws {
        let previousEvents = NotificationCenter()
        let currentEvents = NotificationCenter()
        let service = StubAuthenticationService()
        let auth = AuthStore(
            service: service, toastCenter: AppToastCenter(), notificationCenter: currentEvents
        )
        await auth.restore()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let previousClient = URLSessionAPIClient(
            baseURL: URL(string: "https://api.example")!, session: session,
            notificationCenter: previousEvents
        )
        do {
            let _: EmptyResponse = try await previousClient.send(APIRequest(path: "/api/auth/me"))
            XCTFail("The old server returns 401")
        } catch {}
        await Task.yield()
        XCTAssertNotNil(auth.session)
        XCTAssertFalse(service.cleared)
        currentEvents.post(name: .apiSessionUnauthorized, object: nil)
        for _ in 0..<10 where auth.session != nil { await Task.yield() }
        XCTAssertNil(auth.session)
        XCTAssertTrue(service.cleared)
    }

    private func selectionStore() -> ServerSelectionStore {
        ServerSelectionStore(defaults: defaults, configuredURL: AppServer.original.url)
    }

    @MainActor
    private func makeRuntime(probe: any ServerNetworkProbing) -> AppRuntime {
        let namespace = suite!
        return AppRuntime(store: selectionStore(), probe: probe) {
            AppContainer(baseURL: $0, bundleIdentifier: namespace)
        }
    }

    private func configuredProbe() -> ServerNetworkProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocol.self]
        return ServerNetworkProbe(configuration: configuration)
    }
}

private struct StubProbe: ServerNetworkProbing {
    var error: Error?
    var delay = false

    func check(_ server: AppServer, samples: Int) async throws -> ServerNetworkResult {
        if delay { try await Task.sleep(for: .seconds(30)) }
        if let error { throw error }
        return ServerNetworkResult(samplesMilliseconds: [1])
    }
}

private final class ProbeURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.url?.path, "/api/auth/me")
        let host = request.url!.host!
        let body: String
        switch host {
        case "html.example": body = "<html>unavailable</html>"
        case "mismatch.example": body = "{\"code\":200}"
        default: body = "{\"code\":401,\"message\":\"Unauthorized\",\"data\":null}"
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class StubAuthenticationService: AuthenticationService {
    var cleared = false
    private let session = AuthSession(
        accessToken: "unit-test-token",
        user: AuthUser(id: "test", email: "test@example.com", displayName: "Test",
                       canViewReferenceNotifications: false)
    )

    func storedSession() throws -> AuthSession? { session }
    func refresh(_ session: AuthSession) async throws -> AuthSession { session }
    func clearStoredSession() throws { cleared = true }
    func login(account: String, password: String) async throws -> AuthSession { session }
    func register(account: String, password: String) async throws -> AuthSession { session }
    func logout() async {}
}

final class NativeIntegrationTests: XCTestCase {
    func testSignedSimulatorKeychainRoundTrip() throws {
        let service = "integrated-test-\(UUID().uuidString)"
        let store = KeychainAuthSessionStore(service: service)
        defer { try? store.delete() }
        let session = AuthSession(accessToken: "isolated-test-token", user: AuthUser(id: "qa", email: "qa@example.invalid", displayName: "QA", canViewReferenceNotifications: false))
        try store.save(session)
        XCTAssertEqual(try KeychainAuthSessionStore(service: service).load()?.accessToken, session.accessToken)
        try store.delete()
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testLatestPageWinsWhenSwitchingTabsDuringRequest() async throws {
        let store = USDTStore(api: NativeFixtureClient())
        let page = USDTPageModel()
        let slow = Task { await page.load(store, path: "/slow") }
        try await Task.sleep(for: .milliseconds(20))
        await page.load(store, path: "/fast")
        await slow.value
        XCTAssertEqual(page.items.first?.value("symbol"), "FASTUSDT")
        XCTAssertFalse(page.loading)
    }

    @MainActor
    func testPrivateEventBurstCoalescesAndMarketEventsDoNotRefreshAccount() async throws {
        let api = NativeFixtureClient()
        let store = USDTStore(api: api)
        for _ in 0..<20 { store.receive(message(channel: "market.ticker")) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.liveRevision, 0)
        for _ in 0..<20 { store.receive(message(channel: "trading.order")) }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(store.liveRevision, 1)
        let paths = await api.paths
        XCTAssertEqual(paths.filter { $0 == "/v1/api/info" }.count, 1)
        store.stopRealtime()
    }

    @MainActor
    func testInvalidationClearsAccountAndCancelsPendingPrivateRefresh() async throws {
        let store = USDTStore(api: NativeFixtureClient())
        store.profile = .object(["display_name": .string("Previous")])
        store.account = .object(["balance": .string("100")])
        store.receive(message(channel: "trading.position"))
        store.invalidate()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(store.account.fields.isEmpty)
        XCTAssertTrue(store.profile.fields.isEmpty)
        XCTAssertEqual(store.liveRevision, 0)
    }

    private func message(channel: String) -> RealtimeServerMessage {
        RealtimeServerMessage(version: 1, type: "event", requestId: nil, channel: channel,
            event: nil, key: nil, sequence: nil, timestamp: 0, data: nil, error: nil)
    }
}

private actor NativeFixtureClient: APIClient {
    private(set) var paths: [String] = []
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        paths.append(request.path)
        let value: JSONValue
        switch request.path {
        case "/slow":
            try await Task.sleep(for: .milliseconds(200))
            value = .array([.object(["symbol": .string("SLOWUSDT")])])
        case "/fast": value = .array([.object(["symbol": .string("FASTUSDT")])])
        case "/v1/api/info": value = .null
        case "/v1/strategy/list": value = .array([])
        default: value = .object([:])
        }
        return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(value))
    }
}
