import Combine
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
        XCTAssertFalse(paths.contains("/v1/account/info"), "Account events must not poll the profile balance")
        await store.refresh(freshBalance: true)
        let refreshed = await api.paths
        XCTAssertEqual(refreshed.filter { $0 == "/v1/account/info" }.count, 1)
        let queries = await api.balanceQueries
        XCTAssertEqual(queries.last?.first(where: { $0.name == "fresh" })?.value, "1")
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

@MainActor
final class PositionHistoryLoadingTests: XCTestCase {
    func testLocalHistoryIsVisibleBeforeSlowExchangeReadFinishes() async {
        let started = expectation(description: "Exchange read started")
        let api = HistorySnapshotFixtureAPI(onFullRead: { started.fulfill() })
        let store = USDTStore(api: api)
        let page = USDTPageModel()
        let task = Task { await page.load(store, path: "/v1/position/history", snapshotFirst: true) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(page.items.first?.value("symbol"), "LOCALUSDT")
        XCTAssertFalse(page.loading)
        XCTAssertTrue(page.refreshing)
        XCTAssertTrue(page.hasNext)
        await api.finish()
        await task.value
        XCTAssertEqual(page.items.first?.value("symbol"), "VERIFIEDUSDT")
        XCTAssertFalse(page.loading)
        XCTAssertFalse(page.refreshing)
    }

    func testCompleteSnapshotAndOlderServersNeedOnlyOneRead() async {
        for refreshRequired in [JSONValue.bool(false), .null] {
            let api = HistorySnapshotFixtureAPI(refreshRequired: refreshRequired, gated: false)
            let page = USDTPageModel()
            await page.load(USDTStore(api: api), path: "/v1/position/history", snapshotFirst: true)
            let reads = await api.reads
            XCTAssertEqual(reads, ["/v1/position/history:snapshot"])
            XCTAssertEqual(page.items.first?.value("symbol"), "LOCALUSDT")
            XCTAssertFalse(page.loading)
            XCTAssertFalse(page.refreshing)
        }
    }

    func testResetForUnboundAccountRejectsLateHistoryResponse() async {
        let started = expectation(description: "Exchange read started")
        let api = HistorySnapshotFixtureAPI(onFullRead: { started.fulfill() })
        let page = USDTPageModel()
        let store = USDTStore(api: api)
        let task = Task { await page.load(store, path: "/v1/position/history", snapshotFirst: true) }
        await fulfillment(of: [started], timeout: 2)
        page.reset()
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertFalse(page.loading)
        XCTAssertFalse(page.refreshing)
        XCTAssertFalse(page.hasNext)
        await api.finish()
        await task.value
        XCTAssertTrue(page.items.isEmpty)
    }

    func testTabSwitchWinsOverLateExchangeResponse() async {
        let started = expectation(description: "Exchange read started")
        let api = HistorySnapshotFixtureAPI(onFullRead: { started.fulfill() })
        let page = USDTPageModel()
        let store = USDTStore(api: api)
        let task = Task { await page.load(store, path: "/v1/position/history", snapshotFirst: true) }
        await fulfillment(of: [started], timeout: 2)
        await page.load(store, path: "/v1/position/list")
        await api.finish()
        await task.value
        XCTAssertEqual(page.items.first?.value("symbol"), "CURRENTUSDT")
        XCTAssertFalse(page.loading)
        XCTAssertFalse(page.refreshing)
    }

    func testFailedExchangeReadKeepsSnapshotAndEndsProgress() async {
        let started = expectation(description: "Exchange read started")
        let api = HistorySnapshotFixtureAPI(onFullRead: { started.fulfill() })
        let page = USDTPageModel()
        let task = Task { await page.load(USDTStore(api: api), path: "/v1/position/history", snapshotFirst: true) }
        await fulfillment(of: [started], timeout: 2)
        await api.finish(error: .business(code: "TEST", message: "历史更新超时"))
        await task.value
        XCTAssertEqual(page.items.first?.value("symbol"), "LOCALUSDT")
        XCTAssertFalse(page.loading)
        XCTAssertFalse(page.refreshing)
        XCTAssertTrue(page.error.contains("历史更新超时"))
    }

    func testCancelledExchangeReadCannotReplaceSnapshot() async {
        let started = expectation(description: "Exchange read started")
        let api = HistorySnapshotFixtureAPI(onFullRead: { started.fulfill() })
        let page = USDTPageModel()
        let task = Task { await page.load(USDTStore(api: api), path: "/v1/position/history", snapshotFirst: true) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await api.finish()
        await task.value
        XCTAssertEqual(page.items.first?.value("symbol"), "LOCALUSDT")
        XCTAssertFalse(page.loading)
        XCTAssertFalse(page.refreshing)
        XCTAssertTrue(page.error.isEmpty)
    }
}

@MainActor
final class PositionPageReuseTests: XCTestCase {
    private func query(_ page: Int = 1) -> [URLQueryItem] {
        [.init(name: "filter", value: "all"), .init(name: "page", value: String(page))]
    }

    func testReturningToLoadedPositionsDoesNotReadAgain() async {
        let api = PositionPageReuseFixtureAPI()
        let store = USDTStore(api: api)
        let model = USDTPageModel()
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        for _ in 0..<3 {
            await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        }
        let reads = await api.readCount("/positions")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.items.first?.value("read"), "1")
        XCTAssertFalse(model.loading)
    }

    func testReturningFromAnotherSegmentRestoresRowsAndPagination() async {
        let api = PositionPageReuseFixtureAPI()
        let store = USDTStore(api: api)
        let model = USDTPageModel()
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        model.page = 2
        await model.load(store, path: "/positions", query: query(2), append: true)
        model.page = 1
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        XCTAssertEqual(model.page, 2, "Reappearing must retain the last loaded page")
        model.page = 1
        await model.load(store, path: "/limits", query: query(), reuseIfLoaded: true)
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        let reads = await api.readCount("/positions")
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.items.map { $0.value("page") }, ["1", "2"])
        XCTAssertEqual(model.page, 2)
        XCTAssertFalse(model.hasNext)
    }

    func testTradingRevisionAndExplicitRefreshUpdateCachedPage() async {
        let api = PositionPageReuseFixtureAPI()
        let store = USDTStore(api: api)
        let model = USDTPageModel()
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        store.liveRevision += 1
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        XCTAssertEqual(model.items.first?.value("read"), "2")
        await model.load(store, path: "/positions", query: query())
        XCTAssertEqual(model.items.first?.value("read"), "3")
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        let reads = await api.readCount("/positions")
        XCTAssertEqual(reads, 3)
    }

    func testFailedRefreshKeepsVisibleRowsAndRetriesOnReturn() async {
        let api = PositionPageReuseFixtureAPI()
        let store = USDTStore(api: api)
        let model = USDTPageModel()
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        await api.failNextRead()
        await model.load(store, path: "/positions", query: query())
        XCTAssertEqual(model.items.first?.value("read"), "1")
        XCTAssertFalse(model.error.isEmpty)
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        XCTAssertEqual(model.items.first?.value("read"), "3")
        XCTAssertTrue(model.error.isEmpty)
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        let reads = await api.readCount("/positions")
        XCTAssertEqual(reads, 3)
    }

    func testResetAndAccountGenerationNeverReuseAnOldSnapshot() async {
        let api = PositionPageReuseFixtureAPI()
        let store = USDTStore(api: api)
        let model = USDTPageModel()
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        model.reset()
        XCTAssertTrue(model.items.isEmpty)
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        store.invalidate()
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        XCTAssertEqual(model.items.first?.value("read"), "3")
        let reads = await api.readCount("/positions")
        XCTAssertEqual(reads, 3)
    }

    func testRestoringCachedSegmentRejectsAnotherSegmentsLateResponse() async {
        let started = expectation(description: "Another segment read started")
        let api = PositionPageReuseFixtureAPI(onSlowRead: { started.fulfill() })
        let store = USDTStore(api: api)
        let model = USDTPageModel()
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        let slow = Task { await model.load(store, path: "/slow", query: query(), reuseIfLoaded: true) }
        await fulfillment(of: [started], timeout: 2)
        await model.load(store, path: "/positions", query: query(), reuseIfLoaded: true)
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.items.first?.value("symbol"), "/positions")
        await api.finishSlowRead()
        await slow.value
        XCTAssertEqual(model.items.first?.value("symbol"), "/positions")
        let reads = await api.readCount("/positions")
        XCTAssertEqual(reads, 1)
    }
}

private actor PositionPageReuseFixtureAPI: APIClient {
    private var counts: [String: Int] = [:]
    private var failNext = false
    private var slow: CheckedContinuation<JSONValue, Error>?
    private let onSlowRead: @Sendable () -> Void

    init(onSlowRead: @escaping @Sendable () -> Void = {}) { self.onSlowRead = onSlowRead }
    func readCount(_ path: String) -> Int { counts[path, default: 0] }
    func failNextRead() { failNext = true }
    func finishSlowRead() {
        slow?.resume(returning: .array([.object(["symbol": .string("/slow")])]))
        slow = nil
    }
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        counts[request.path, default: 0] += 1
        if failNext { failNext = false; throw URLError(.notConnectedToInternet) }
        let result: JSONValue
        if request.path == "/slow" {
            result = try await withCheckedThrowingContinuation {
                slow = $0
                onSlowRead()
            }
        } else {
            let page = request.queryItems.first { $0.name == "page" }?.value ?? "1"
            result = .object([
                "items": .array([.object(["symbol": .string(request.path), "page": .string(page),
                    "read": .number(Double(counts[request.path, default: 0]))])]),
                "pagination": .object(["has_next": .bool(page == "1")]),
            ])
        }
        return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(result))
    }
}

private actor HistorySnapshotFixtureAPI: APIClient {
    let refreshRequired: JSONValue
    let gated: Bool
    let onFullRead: @Sendable () -> Void
    private(set) var reads: [String] = []
    private var continuation: CheckedContinuation<JSONValue, Error>?

    init(refreshRequired: JSONValue = .bool(true), gated: Bool = true,
         onFullRead: @escaping @Sendable () -> Void = {}) {
        self.refreshRequired = refreshRequired
        self.gated = gated
        self.onFullRead = onFullRead
    }

    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        let snapshot = request.queryItems.contains { $0.name == "snapshot" && $0.value == "local" }
        reads.append(request.path + (snapshot ? ":snapshot" : ""))
        let value: JSONValue
        if snapshot {
            value = .object([
                "items": .array([.object(["symbol": .string("LOCALUSDT")])]),
                "exchange_refresh_required": refreshRequired,
                "pagination": .object(["has_next": .bool(true)]),
            ])
        } else if request.path == "/v1/position/history" && gated {
            value = try await withCheckedThrowingContinuation {
                continuation = $0
                onFullRead()
            }
        } else {
            value = .array([.object(["symbol": .string("CURRENTUSDT")])])
        }
        return value as! Response
    }

    func finish(error: APIError? = nil) {
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: .object([
            "items": .array([.object(["symbol": .string("VERIFIEDUSDT")])]),
            "pagination": .object(["has_next": .bool(false)]),
        ])) }
        continuation = nil
    }
}

private actor NativeFixtureClient: APIClient {
    private(set) var paths: [String] = []
    private(set) var balanceQueries: [[URLQueryItem]] = []
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        paths.append(request.path)
        if request.path == "/v1/account/info" { balanceQueries.append(request.queryItems) }
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

@MainActor
final class SharedLoadingHandoffTests: XCTestCase {
    func testPageRefreshWaitsForTheReadAlreadyLoadingItsContent() async {
        let api = SharedLoadingFixtureAPI()
        let store = USDTStore(api: api)
        let model = USDTPageModel()
        let original = Task { await model.load(store, path: "/slow") }
        await api.waitUntilBlocked()
        var joinedFinished = false
        let joined = Task { await model.load(store, path: "/slow"); joinedFinished = true }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(joinedFinished, "Refresh feedback must remain until the shared content read finishes")
        XCTAssertTrue(model.loading)
        await api.finish()
        await original.value
        await joined.value
        XCTAssertTrue(joinedFinished)
        XCTAssertEqual(model.items.first?.value("symbol"), "READYUSDT")
        XCTAssertFalse(model.loading)
        let reads = await api.count("/slow")
        XCTAssertEqual(reads, 1, "Joining refreshes must not create duplicate HTTP reads")
    }

    func testProfileRefreshWaitsForTheReadAlreadyLoadingItsContent() async {
        let api = SharedLoadingFixtureAPI(blockedPath: "/v1/api/info")
        let store = USDTStore(api: api)
        let original = Task { await store.refresh() }
        await api.waitUntilBlocked()
        var joinedFinished = false
        let joined = Task { await store.refresh(); joinedFinished = true }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(joinedFinished, "The profile refresh action must wait for its in-flight account read")
        XCTAssertTrue(store.isLoading)
        await api.finish()
        await original.value
        await joined.value
        XCTAssertEqual(store.account.value("balance"), "50")
        XCTAssertFalse(store.isLoading)
        let reads = await api.count("/v1/api/info")
        XCTAssertEqual(reads, 1)
    }

    func testCancelledPageWaiterFinishesWithoutCancellingTheOriginalRead() async {
        let api = SharedLoadingFixtureAPI()
        let store = USDTStore(api: api)
        let model = USDTPageModel()
        let original = Task { await model.load(store, path: "/slow") }
        await api.waitUntilBlocked()
        let joined = Task { await model.load(store, path: "/slow") }
        await Task.yield()
        joined.cancel()
        await joined.value
        XCTAssertTrue(model.loading)
        await api.finish()
        await original.value
        XCTAssertEqual(model.items.first?.value("symbol"), "READYUSDT")
        let reads = await api.count("/slow")
        XCTAssertEqual(reads, 1)
    }

    func testPageResetReleasesWaitersAndRejectsLateContent() async {
        let api = SharedLoadingFixtureAPI()
        let store = USDTStore(api: api)
        let model = USDTPageModel()
        let original = Task { await model.load(store, path: "/slow") }
        await api.waitUntilBlocked()
        let joined = Task { await model.load(store, path: "/slow") }
        await Task.yield()
        model.reset()
        await joined.value
        XCTAssertFalse(model.loading)
        await api.finish()
        await original.value
        XCTAssertTrue(model.items.isEmpty)
    }

    func testSwitchingPageReleasesOldWaitersAndKeepsTheNewContent() async {
        let api = SharedLoadingFixtureAPI()
        let store = USDTStore(api: api)
        let model = USDTPageModel()
        let original = Task { await model.load(store, path: "/slow") }
        await api.waitUntilBlocked()
        let joined = Task { await model.load(store, path: "/slow") }
        await Task.yield()
        await model.load(store, path: "/fast")
        await joined.value
        XCTAssertEqual(model.items.first?.value("symbol"), "FASTUSDT")
        await api.finish()
        await original.value
        XCTAssertEqual(model.items.first?.value("symbol"), "FASTUSDT")
        XCTAssertFalse(model.loading)
    }

    func testIdentityChangeReleasesProfileWaitersAndClearsProgress() async {
        let api = SharedLoadingFixtureAPI(blockedPath: "/v1/api/info")
        let store = USDTStore(api: api)
        let original = Task { await store.refresh() }
        await api.waitUntilBlocked()
        let joined = Task { await store.refresh() }
        await Task.yield()
        store.prepareSession(userID: UUID().uuidString)
        await joined.value
        XCTAssertFalse(store.isLoading)
        await api.finish()
        await original.value
        XCTAssertTrue(store.account.fields.isEmpty)
        XCTAssertFalse(store.isBound)
    }

    func testFailedSharedReadFinishesAllWaitersWithVisibleError() async {
        let api = SharedLoadingFixtureAPI()
        let store = USDTStore(api: api)
        let model = USDTPageModel()
        let original = Task { await model.load(store, path: "/slow") }
        await api.waitUntilBlocked()
        let joined = Task { await model.load(store, path: "/slow") }
        await Task.yield()
        await api.finish(failed: true)
        await original.value
        await joined.value
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.error.isEmpty)
        let reads = await api.count("/slow")
        XCTAssertEqual(reads, 1)
    }

    func testMarketRefreshWaitsForItsExistingTickerSnapshot() async {
        let api = SharedLoadingFixtureAPI(blockedPath: "/api/market/tickers")
        let model = DashboardViewModel(apiClient: api)
        await model.loadSymbolCatalog()
        let original = Task { await model.refresh() }
        await api.waitUntilBlocked()
        var joinedFinished = false
        let joined = Task { await model.refresh(); joinedFinished = true }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(joinedFinished, "Market refresh feedback must wait for its shared ticker snapshot")
        XCTAssertTrue(model.isRefreshing)
        await api.finish()
        await original.value
        await joined.value
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.markets.first?.price, 123)
        let reads = await api.count("/api/market/tickers")
        XCTAssertEqual(reads, 1)
    }

    func testMarketStopReleasesWaitersWithoutApplyingLateContent() async {
        let api = SharedLoadingFixtureAPI(blockedPath: "/api/market/tickers")
        let model = DashboardViewModel(apiClient: api)
        await model.loadSymbolCatalog()
        let original = Task { await model.refresh() }
        await api.waitUntilBlocked()
        let joined = Task { await model.refresh() }
        await Task.yield()
        model.stopRealtime()
        await joined.value
        XCTAssertFalse(model.isRefreshing)
        await api.finish()
        await original.value
        XCTAssertEqual(model.markets.first?.price, 0)
    }

    func testMarketRefreshJoinsTheFirstWatchlistTickerRead() async {
        let api = SharedLoadingFixtureAPI(blockedPath: "/api/market/tickers")
        let realtime = RealtimeClient(baseURL: URL(string: "https://example.invalid")!, tokenProvider: { nil })
        let model = DashboardViewModel(apiClient: api, realtimeClient: realtime)
        model.startRealtime(userID: "fixture-user")
        defer { model.stopRealtime() }
        await api.waitUntilBlocked()
        var refreshFinished = false
        let refresh = Task { await model.refresh(); refreshFinished = true }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(refreshFinished, "The first ticker snapshot must reach the page before refresh ends")
        await api.finish()
        await refresh.value
        XCTAssertEqual(model.markets.first?.price, 123)
        let reads = await api.count("/api/market/tickers")
        XCTAssertEqual(reads, 1, "Refresh must join the initial snapshot instead of duplicating it")
    }

    func testMarginRefreshWaitsForExistingReadAndQueuedFreshFollowup() async {
        let api = SharedLoadingFixtureAPI(blockedPath: "/v1/position/margin", blockedReads: 2)
        let store = USDTStore(api: api)
        store.binding = .object(["id": .string("fixture")])
        let model = PositionMarginModel()
        let original = Task { await model.refresh(store) }
        await api.waitUntilBlocked()
        var joinedFinished = false
        let joined = Task { await model.refresh(store, afterChange: true); joinedFinished = true }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(joinedFinished, "A margin refresh must wait for the queued fresh account read too")
        await api.finish()
        await api.waitUntilBlocked()
        XCTAssertFalse(joinedFinished)
        await api.finish()
        await original.value
        await joined.value
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.snapshot.value("margin_ratio_percent"), "55")
        let reads = await api.count("/v1/position/margin")
        XCTAssertEqual(reads, 2)
    }

    func testMarginSuspensionReleasesWaitersAndRejectsLateContent() async {
        let api = SharedLoadingFixtureAPI(blockedPath: "/v1/position/margin")
        let store = USDTStore(api: api)
        store.binding = .object(["id": .string("fixture")])
        let model = PositionMarginModel()
        let original = Task { await model.refresh(store) }
        await api.waitUntilBlocked()
        let joined = Task { await model.refresh(store) }
        await Task.yield()
        model.suspend()
        await joined.value
        XCTAssertFalse(model.loading)
        await api.finish()
        await original.value
        XCTAssertEqual(model.snapshot, .null)
    }

    func testCancelledInitialWatchlistCannotOverwriteRestartedSameUser() async {
        await checkCancelledInitialWatchlistRestart(failed: false)
    }

    func testCancelledInitialWatchlistFailureCannotRefreshRestartedSameUser() async {
        await checkCancelledInitialWatchlistRestart(failed: true)
    }

    private func checkCancelledInitialWatchlistRestart(failed: Bool) async {
        let api = SharedLoadingFixtureAPI(blockedPath: "/api/market/watchlist/defaults")
        let realtime = RealtimeClient(baseURL: URL(string: "https://example.invalid")!, tokenProvider: { nil })
        let model = DashboardViewModel(apiClient: api, realtimeClient: realtime)
        model.startRealtime(userID: "fixture-user")
        defer { model.stopRealtime() }
        await api.waitUntilBlocked()
        model.stopRealtime()
        model.startRealtime(userID: "fixture-user")
        await model.refresh()
        XCTAssertEqual(model.markets.map(\.symbol), ["BTCUSDT"])
        XCTAssertEqual(model.markets.first?.price, 123)
        let oldConfiguration = JSONValue.object([
            "quoteAsset": .string("USDT"), "symbols": .array([.string("OLDUSDT")]),
            "availableSymbols": .array([.string("OLDUSDT")])])
        await api.finish(failed: failed, value: oldConfiguration)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.markets.map(\.symbol), ["BTCUSDT"],
            "An obsolete initial read must not replace the restarted user's watchlist")
        XCTAssertEqual(model.markets.first?.price, 123)
        let tickerReads = await api.count("/api/market/tickers")
        XCTAssertEqual(tickerReads, 1,
            "Neither success nor failure of an obsolete initial read may start another ticker request")
    }
}

private actor SharedLoadingFixtureAPI: APIClient {
    private let blockedPath: String
    private let blockedReads: Int
    private var continuation: CheckedContinuation<JSONValue, Error>?
    private var started: [CheckedContinuation<Void, Never>] = []
    private var counts: [String: Int] = [:]
    init(blockedPath: String = "/slow", blockedReads: Int = 1) {
        self.blockedPath = blockedPath; self.blockedReads = blockedReads
    }
    func count(_ path: String) -> Int { counts[path, default: 0] }
    func waitUntilBlocked() async {
        if continuation != nil { return }
        await withCheckedContinuation { started.append($0) }
    }
    func finish(failed: Bool = false, value: JSONValue? = nil) {
        if failed { continuation?.resume(throwing: URLError(.notConnectedToInternet)) }
        else { continuation?.resume(returning: value ?? self.value(for: blockedPath)) }
        continuation = nil
    }
    private func value(for path: String) -> JSONValue {
        switch path {
        case "/slow": return .array([.object(["symbol": .string("READYUSDT")])])
        case "/v1/api/info": return .object(["alias": .string("fixture")])
        case "/v1/account/info": return .object(["balance": .string("50")])
        case "/v1/strategy/list": return .array([])
        case "/api/market/symbols": return .object([
            "quoteAsset": .string("USDT"), "symbols": .array([.string("BTCUSDT")])])
        case "/api/market/watchlist/defaults": return .object([
            "quoteAsset": .string("USDT"), "symbols": .array([.string("BTCUSDT")]),
            "availableSymbols": .array([.string("BTCUSDT")])])
        case "/api/market/tickers": return .object([
            "quoteAsset": .string("USDT"), "tickers": .array([.object([
                "symbol": .string("BTCUSDT"), "lastPrice": .number(123),
                "quoteVolume24h": .number(100), "priceChangePercent24h": .number(1),
                "eventTime": .number(Double(Int64(Date().timeIntervalSince1970 * 1000)))])])])
        case "/v1/position/margin": return .object([
            "supported": .bool(true), "margin_ratio_percent": .string("55")])
        default: return .array([.object(["symbol": .string("FASTUSDT")])])
        }
    }
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        counts[request.path, default: 0] += 1
        let value: JSONValue
        if request.path == blockedPath, counts[request.path, default: 0] <= blockedReads {
            value = try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started.forEach { $0.resume() }
                started = []
            }
        } else {
            value = self.value(for: request.path)
        }
        return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(value))
    }
}

@MainActor
final class MarketFastPathTests: XCTestCase {
    func testReturningToRecentIntervalUsesCompleteCachedFrameWithoutDownloading() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        let original = try XCTUnwrap(model.chartDataFrame)
        model.selectInterval(.fiveMinutes)
        try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
        await api.closeGate()

        model.selectInterval(.oneHour)
        let restored = try XCTUnwrap(model.chartDataFrame,
            "Returning to a verified recent interval must not wait for another HTTP response")
        XCTAssertEqual(restored.stream.interval, "1h")
        XCTAssertNotEqual(restored.epoch, original.epoch)
        XCTAssertTrue(restored.candles.history === original.candles.history)
        XCTAssertTrue(restored.indicators.history === original.indicators.history,
            "A warm return must reuse the completed indicator history")
        try await Task.sleep(for: .milliseconds(30))
        let reads = await api.reads
        XCTAssertEqual(reads, 3)
        let limits = await api.limits
        XCTAssertEqual(limits, [1500, 1500, 2], "Only the tail is checked in the background")
    }

    func testCachedActivationAcknowledgementDoesNotDownloadButRealNoticeDoes() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        model.selectInterval(.fiveMinutes)
        try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
        await api.closeGate()
        model.selectInterval(.oneHour)
        for timestamp in 100...105 {
            await model.receive(ack(symbol: "BTCUSDT", interval: "1h", timestamp: Int64(timestamp)))
        }
        model.chartFirstFramePresented(epoch: try XCTUnwrap(model.chartDataFrame?.epoch),
            at: ProcessInfo.processInfo.systemUptime)
        try await Task.sleep(for: .milliseconds(30))
        var reads = await api.reads
        XCTAssertEqual(reads, 3, "Ack bursts must not add a full read to the two-bar tail check")
        await model.receive(notice(symbol: "BTCUSDT", timestamp: 101))
        await api.setServerTime(Int64(Date().timeIntervalSince1970 * 1000))
        await api.releaseCurrentRead()
        try await waitForReads(4, api)
        reads = await api.reads
        XCTAssertEqual(reads, 4, "A real history notice must follow the small check with a full read")
        let limits = await api.limits
        XCTAssertEqual(limits, [1500, 1500, 2, 1500])
    }

    func testIntervalCacheTTLIsNotExtendedByRepeatedSwitching() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        var clock = Date()
        let model = makeChart(api, cacheTimeProvider: { clock })
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        clock.addTimeInterval(2)
        model.selectInterval(.fiveMinutes)
        try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
        clock.addTimeInterval(2)
        model.selectInterval(.oneHour)
        XCTAssertEqual(model.chartDataFrame?.stream.interval, "1h")
        try await Task.sleep(for: .milliseconds(20))
        clock.addTimeInterval(4)
        model.selectInterval(.fiveMinutes)
        XCTAssertEqual(model.chartDataFrame?.stream.interval, "5m")
        try await Task.sleep(for: .milliseconds(20))
        clock.addTimeInterval(3)
        await api.closeGate()
        model.selectInterval(.oneHour)
        XCTAssertNil(model.chartDataFrame, "11s since HTTP must expire despite a return at 4s")
        try await waitForFullReads(3, api)
    }

    func testCachedActivationLateAcknowledgementRechecksTTLAndCandleBoundary() async throws {
        for crossesBucket in [false, true] {
            let api = GatedChartHistoryAPI()
            await api.openGate()
            var clock = Date()
            let model = makeChart(api, cacheTimeProvider: { clock })
            model.start()
            try await waitUntil { model.chartDataFrame != nil }
            model.selectInterval(.fiveMinutes)
            try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
            model.selectInterval(.oneHour)
            XCTAssertEqual(model.chartDataFrame?.stream.interval, "1h")
            await api.closeGate()
            clock.addTimeInterval(crossesBucket ? 3600 : 11)
            await model.receive(ack(symbol: "BTCUSDT", interval: "1h", timestamp: 100))
            model.chartFirstFramePresented(epoch: try XCTUnwrap(model.chartDataFrame?.epoch),
                at: ProcessInfo.processInfo.systemUptime)
            await api.releaseCurrentRead()
            try await waitForFullReads(3, api)
            model.stop()
        }
    }

    func testIntervalCacheIsInvalidatedByConfigurationBackgroundAndReconnect() async throws {
        for invalidation in ["configuration", "background", "reconnect", "bucket"] {
            let api = GatedChartHistoryAPI()
            await api.openGate()
            var clock = Date()
            let model = makeChart(api, cacheTimeProvider: { clock })
            model.start()
            await model.receive(ready())
            try await waitUntil { model.chartDataFrame != nil }
            model.selectInterval(.fiveMinutes)
            try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
            switch invalidation {
            case "configuration": model.toggleChartIndicator("RSI")
            case "background": model.suspendForBackground(); await model.resumeFromBackground()
            case "reconnect": await model.receive(ready())
            default: clock.addTimeInterval(3600)
            }
            if invalidation == "background" || invalidation == "reconnect" {
                try await waitUntil { model.candles.first?.closePrice == 103 }
            } else { try await Task.sleep(for: .milliseconds(20)) }
            await api.closeGate()
            model.selectInterval(.oneHour)
            XCTAssertNil(model.chartDataFrame, "Must discard cached history after \(invalidation)")
            model.stop()
        }
    }

    func testIntervalCacheIsBoundedAndNeverSharedWithAnotherModel() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        for interval in [MarketKlineInterval.fiveMinutes, .fifteenMinutes, .fourHours, .oneDay] {
            model.selectInterval(interval)
            try await waitUntil { model.chartDataFrame?.stream.interval == interval.rawValue }
        }
        await api.closeGate()
        model.selectInterval(.oneHour)
        XCTAssertNil(model.chartDataFrame, "A fourth saved interval evicts the oldest of three")
        let other = makeChart(api)
        other.start()
        defer { other.stop() }
        XCTAssertNil(other.chartDataFrame, "Another model/session cannot see this model's cache")
    }

    func testCacheResetsSequenceBaselineAndStillDetectsTheNextGap() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        await model.receive(liveKline(sequence: 40, close: 105))
        model.selectInterval(.fiveMinutes)
        try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
        await api.closeGate()
        model.selectInterval(.oneHour)
        await model.receive(liveKline(sequence: 900, close: 106))
        XCTAssertEqual(model.chartDataFrame?.candles.liveTail?.closePrice, 106)
        var reads = await api.reads
        XCTAssertEqual(reads, 3, "Skipped inactive events only need the small tail check")
        await model.receive(liveKline(sequence: 902, close: 107))
        await api.releaseCurrentRead()
        try await waitForFullReads(3, api)
        reads = await api.reads
        XCTAssertEqual(reads, 4, "The next true sequence gap must still repair")
    }

    func testSequenceRepairInvalidatesOtherCachedIntervals() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        model.selectInterval(.fiveMinutes)
        try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
        await api.closeGate()
        await model.receive(liveKline(interval: .fiveMinutes, sequence: 40))
        await model.receive(liveKline(interval: .fiveMinutes, sequence: 42))
        try await waitForReads(3, api)
        model.selectInterval(.oneHour)
        XCTAssertNil(model.chartDataFrame, "An ingress repair invalidates the session's cached verification")
    }

    func testCachedReturnMergesTheNewerSharedQuoteAndTrustedOHLCStillCorrectsItsRange() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        model.selectInterval(.fiveMinutes)
        try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
        await model.receive(liveKline(interval: .oneMinute, close: 200))
        await api.closeGate()
        model.selectInterval(.oneHour)
        await model.receive(ack(symbol: "BTCUSDT", interval: "1h"))
        XCTAssertEqual(model.chartDataFrame?.candles.liveTail?.closePrice, 200)
        let history = try XCTUnwrap(model.chartDataFrame?.candles.history)
        await model.receive(liveKline(sequence: 900, close: 106))
        XCTAssertEqual(model.chartDataFrame?.candles.liveTail?.highPrice, 110)
        XCTAssertEqual(model.chartDataFrame?.candles.liveTail?.lowPrice, 99)
        XCTAssertTrue(model.chartDataFrame?.candles.history === history,
            "Refreshing a provisional price must not rewrite closed bars")
        let reads = await api.reads
        XCTAssertEqual(reads, 3)
    }

    func testHistoryRequestCrossingCandleBoundaryNeverEntersIntervalCache() async throws {
        let api = GatedChartHistoryAPI()
        let hour = floor(Date().timeIntervalSince1970 / 3600) * 3600
        var clock = Date(timeIntervalSince1970: hour + 3599.8)
        let model = makeChart(api, cacheTimeProvider: { clock })
        model.start()
        defer { model.stop() }
        try await waitForReads(1, api)
        clock.addTimeInterval(0.4)
        await api.openGate()
        try await waitUntil { model.chartDataFrame != nil }
        model.selectInterval(.fiveMinutes)
        try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
        await api.closeGate()
        model.selectInterval(.oneHour)
        XCTAssertNil(model.chartDataFrame, "A request spanning an hour boundary did not verify its new bucket")
        try await waitForReads(3, api)
    }

    func testPendingStatisticsAndFailedVerificationCannotEnterTheCache() async throws {
        for fails in [false, true] {
            let api = GatedChartHistoryAPI()
            await api.setStatisticsPending(!fails)
            await api.openGate()
            let model = makeChart(api)
            model.start()
            try await waitUntil { model.chartDataFrame != nil }
            if fails {
                await api.closeGate()
                model.reload()
                try await waitForReads(2, api)
                await api.finishRead(2, error: APIError.invalidResponse)
                try await waitUntil { model.lastError != nil }
                await api.openGate()
            }
            await api.setStatisticsPending(false)
            model.selectInterval(.fiveMinutes)
            try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
            await api.closeGate()
            model.selectInterval(.oneHour)
            XCTAssertNil(model.chartDataFrame, "Unverified first history must not be cached")
            model.stop()
        }
    }

    func testSmallTailCorrectsOHLCWithoutReplacingHistoryIndicatorsOrPagination() async throws {
        let api = GatedChartHistoryAPI()
        await api.setIncludeTradingData(true)
        await api.openGate()
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        let first = try XCTUnwrap(model.chartDataFrame)
        let count = model.candles.count
        model.selectInterval(.fiveMinutes)
        try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
        await api.closeGate()
        model.selectInterval(.oneHour)
        try await waitForReads(3, api)
        await api.releaseCurrentRead()
        try await waitUntil { model.chartDataFrame?.candles.liveTail?.volume == 20 }
        let corrected = try XCTUnwrap(model.chartDataFrame)
        XCTAssertEqual(corrected.candles.liveTail?.highPrice, 120)
        XCTAssertEqual(corrected.candles.liveTail?.lowPrice, 90)
        XCTAssertEqual(corrected.candles.liveTail?.closePrice, 109)
        XCTAssertTrue(corrected.candles.history === first.candles.history)
        XCTAssertTrue(corrected.indicators.history === first.indicators.history)
        XCTAssertEqual(corrected.candles.history.candles.last?.tradingData?.openInterest, 100)
        XCTAssertEqual(model.candles.count, count)
        XCTAssertTrue(model.hasMoreHistory, "Two-bar hasMoreHistory must not replace full pagination state")
    }

    func testSmallTailPreservesAQuoteReceivedDuringItsDownload() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        model.selectInterval(.fiveMinutes)
        try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
        await api.closeGate()
        model.selectInterval(.oneHour)
        try await waitForReads(3, api)
        await model.receive(liveKline(interval: .oneMinute, close: 108))
        await api.releaseCurrentRead()
        try await waitUntil { model.chartDataFrame?.candles.liveTail?.volume == 20 }
        XCTAssertEqual(model.chartDataFrame?.candles.liveTail?.closePrice, 108)
        XCTAssertEqual(model.chartDataFrame?.candles.liveTail?.highPrice, 120)
        XCTAssertEqual(model.chartDataFrame?.candles.liveTail?.lowPrice, 90)
    }

    func testFastSwitchesCancelBlockedSmallChecksWithoutDownloadingFullHistoryAgain() async throws {
        let api = GatedChartHistoryAPI(ignoresCancellation: true)
        await api.openGate()
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        model.selectInterval(.fiveMinutes)
        try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
        await api.closeGate()
        for (index, interval) in [MarketKlineInterval.oneHour, .fiveMinutes, .oneHour, .fiveMinutes].enumerated() {
            model.selectInterval(interval)
            XCTAssertEqual(model.chartDataFrame?.stream.interval, interval.rawValue)
            try await waitForReads(3 + index, api)
        }
        let epoch = try XCTUnwrap(model.chartDataFrame?.epoch)
        await api.openGate()
        try await waitUntil { model.chartDataFrame?.candles.liveTail?.volume == 20 }
        XCTAssertEqual(model.chartDataFrame?.stream.interval, "5m")
        XCTAssertEqual(model.chartDataFrame?.epoch, epoch)
        let limits = await api.limits
        XCTAssertEqual(limits, [1500, 1500, 2, 2, 2, 2])
    }

    func testSmallTailCrossingBucketBoundaryUpgradesToFullHistory() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        var clock = Date()
        let model = makeChart(api, cacheTimeProvider: { clock })
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        model.selectInterval(.fiveMinutes)
        try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
        await api.closeGate()
        model.selectInterval(.oneHour)
        try await waitForReads(3, api)
        let previous = try XCTUnwrap(model.chartDataFrame)
        clock.addTimeInterval(3600)
        await api.releaseCurrentRead()
        try await waitForReads(4, api)
        let limits = await api.limits
        XCTAssertEqual(limits, [1500, 1500, 2, 1500])
        XCTAssertTrue(model.chartDataFrame?.candles.history === previous.candles.history,
            "Cross-boundary small responses cannot release a complete-history repair")
    }

    func testImmediateReloadAndPageAfterCacheRestoreKeepTheNewEpoch() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        model.selectInterval(.fiveMinutes)
        try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
        await api.closeGate()
        model.selectInterval(.oneHour)
        let epoch = try XCTUnwrap(model.chartDataFrame?.epoch)
        model.reload()
        model.requestOlderHistory()
        try await waitForReads(4, api)
        await api.openGate()
        try await waitUntil { !model.isLoadingOlderHistory && model.candles.first?.closePrice ?? 0 >= 103 }
        XCTAssertEqual(model.chartDataFrame?.epoch, epoch)
        XCTAssertEqual(model.chartDataFrame?.stream.interval, "1h")
        XCTAssertTrue(model.hasMoreHistory)
    }

    func testOldPresentationAndBackgroundCannotReleaseANewOrCancelledNoticeGate() async throws {
        let api = GatedChartHistoryAPI()
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitForReads(1, api)
        await model.receive(notice(symbol: "BTCUSDT"))
        await api.releaseCurrentRead()
        try await waitUntil { model.chartDataFrame != nil }
        let oldEpoch = try XCTUnwrap(model.chartDataFrame?.epoch)
        model.selectInterval(.fiveMinutes)
        try await waitForReads(2, api)
        await api.releaseCurrentRead()
        try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
        await model.receive(notice(symbol: "BTCUSDT", interval: "5m"))
        model.chartFirstFramePresented(epoch: oldEpoch, at: ProcessInfo.processInfo.systemUptime)
        try await Task.sleep(for: .milliseconds(30))
        var reads = await api.reads
        XCTAssertEqual(reads, 2, "An old epoch cannot release the new interval's presentation gate")
        model.suspendForBackground()
        try await Task.sleep(for: .milliseconds(550))
        reads = await api.reads
        XCTAssertEqual(reads, 2, "Backgrounding cancels both old and new fallback reads")
    }

    func testLateCoveredSocketSignalsDoNotReloadAnInstalledSnapshot() async throws {
        let api = GatedChartHistoryAPI()
        await api.setServerTime(102)
        await api.openGate()
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        await model.receive(ack(symbol: "BTCUSDT", interval: "1h", timestamp: 100))
        await model.receive(notice(symbol: "BTCUSDT", timestamp: 101))
        try await Task.sleep(for: .milliseconds(550))
        let reads = await api.reads
        XCTAssertEqual(reads, 1)
    }

    func testServerWatermarkCoversOlderAcknowledgementAndNoticeWithoutSecondRead() async throws {
        let api = GatedChartHistoryAPI()
        await api.setServerTime(102)
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitForReads(1, api)
        await model.receive(ack(symbol: "BTCUSDT", interval: "1h", timestamp: 100))
        await model.receive(notice(symbol: "BTCUSDT", timestamp: 101))
        await api.openGate()
        try await waitUntil { model.chartDataFrame != nil }
        model.chartFirstFramePresented(epoch: try XCTUnwrap(model.chartDataFrame?.epoch),
            at: ProcessInfo.processInfo.systemUptime)
        try await Task.sleep(for: .milliseconds(550))
        let reads = await api.reads
        XCTAssertEqual(reads, 1)
    }

    func testUncoveredNoticeWaitsForFirstPresentationThenRefreshesOnce() async throws {
        let api = GatedChartHistoryAPI()
        await api.setServerTime(102)
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitForReads(1, api)
        await model.receive(ack(symbol: "BTCUSDT", interval: "1h", timestamp: 100))
        await model.receive(notice(symbol: "BTCUSDT", timestamp: 105))
        await api.releaseCurrentRead()
        try await waitUntil { model.chartDataFrame != nil }
        try await Task.sleep(for: .milliseconds(30))
        var reads = await api.reads
        XCTAssertEqual(reads, 1, "Do not compete with the first scene and presentation")
        let epoch = try XCTUnwrap(model.chartDataFrame?.epoch)
        model.chartFirstFramePresented(epoch: epoch, at: ProcessInfo.processInfo.systemUptime)
        try await waitForReads(2, api)
        await api.setServerTime(106)
        await api.openGate()
        try await waitUntil { model.candles.first?.closePrice == 102 }
        model.chartFirstFramePresented(epoch: epoch, at: ProcessInfo.processInfo.systemUptime)
        try await Task.sleep(for: .milliseconds(30))
        reads = await api.reads
        XCTAssertEqual(reads, 2)
    }

    func testUnknownOrEqualWatermarkUsesOneBoundedFallbackWithoutRendererCallback() async throws {
        for serverTime in [Int64(101), nil] {
            let api = GatedChartHistoryAPI()
            await api.setServerTime(serverTime)
            let model = makeChart(api)
            model.start()
            try await waitForReads(1, api)
            await model.receive(notice(symbol: "BTCUSDT", timestamp: 101))
            await api.releaseCurrentRead()
            try await waitUntil { model.chartDataFrame != nil }
            let epoch = try XCTUnwrap(model.chartDataFrame?.epoch)
            try await Task.sleep(for: .milliseconds(30))
            var reads = await api.reads
            XCTAssertEqual(reads, 1)
            try await waitForReads(2, api)
            await api.openGate()
            try await waitUntil { model.candles.first?.closePrice == 102 }
            model.chartFirstFramePresented(epoch: epoch, at: ProcessInfo.processInfo.systemUptime)
            try await Task.sleep(for: .milliseconds(50))
            reads = await api.reads
            XCTAssertEqual(reads, 2, "Fallback and late presentation must not each refresh")
            model.stop()
        }
    }

    func testBackgroundRecoveryCoversOldChartOnlyAtThirtyMinutes() async throws {
        for elapsed in [1_799.0, 1_800.0, 7_200.0] {
            var clock = Date()
            let api = GatedChartHistoryAPI()
            await api.openGate()
            let model = makeChart(api, cacheTimeProvider: { clock })
            model.start()
            await model.receive(ready())
            try await waitUntil { model.chartDataFrame != nil }
            let previous = try XCTUnwrap(model.chartDataFrame)
            let oldCandles = model.candles
            await api.closeGate()
            model.suspendForBackground()
            clock.addTimeInterval(elapsed)
            await model.resumeFromBackground()
            try await waitForReads(2, api)
            XCTAssertEqual(model.recoveryState, elapsed >= 1_800 ? .restoring : .idle)
            XCTAssertTrue(model.preservesPresentedChart)
            if elapsed >= 1_800 {
                XCTAssertNotNil(model.chartDataFrame, "A stale chart remains visible behind the recovery animation")
            } else {
                XCTAssertEqual(model.chartDataFrame?.epoch, previous.epoch)
            }
            XCTAssertTrue(model.candles == oldCandles, "Keep reusable history while replacing the displayed frame")
            model.chartFirstFramePresented(epoch: previous.epoch, at: ProcessInfo.processInfo.systemUptime)
            XCTAssertTrue(model.preservesPresentedChart, "The old presentation cannot release a new recovery")
            await api.openGate()
            try await waitUntil { model.chartDataFrame?.epoch != nil && model.chartDataFrame?.epoch != previous.epoch }
            XCTAssertEqual(model.recoveryState, elapsed >= 1_800 ? .restoring : .idle,
                "HTTP and scene readiness cannot end loading")
            model.chartFirstFramePresented(epoch: previous.epoch, at: ProcessInfo.processInfo.systemUptime)
            XCTAssertEqual(model.recoveryState, elapsed >= 1_800 ? .restoring : .idle)
            model.chartFirstFramePresented(epoch: try XCTUnwrap(model.chartDataFrame?.epoch),
                at: ProcessInfo.processInfo.systemUptime)
            XCTAssertEqual(model.recoveryState, .idle)
            model.stop()
        }
    }

    func testRepeatedBackgroundNotificationsKeepTheOriginalOfflineStart() async throws {
        var clock = Date()
        let api = GatedChartHistoryAPI()
        await api.openGate()
        let model = makeChart(api, cacheTimeProvider: { clock })
        model.start()
        await model.receive(ready())
        try await waitUntil { model.chartDataFrame != nil }
        await api.closeGate()
        model.suspendForBackground()
        model.chartFirstFramePresented(epoch: try XCTUnwrap(model.chartDataFrame?.epoch),
            at: ProcessInfo.processInfo.systemUptime)
        clock.addTimeInterval(1_799)
        model.suspendForBackground()
        clock.addTimeInterval(1)
        await model.resumeFromBackground()
        XCTAssertNotNil(model.chartDataFrame, "Keep the last chart visible during stale recovery")
        XCTAssertEqual(model.recoveryState, .restoring)
        await api.openGate()
        model.stop()
    }

    func testForegroundDisconnectKeepsItsStartAcrossReconnectAttemptsAndBackground() async throws {
        var clock = Date()
        let api = GatedChartHistoryAPI()
        await api.openGate()
        let model = makeChart(api, cacheTimeProvider: { clock })
        model.start()
        defer { model.stop() }
        await model.receive(ready())
        try await waitUntil { model.chartDataFrame != nil }
        let previous = try XCTUnwrap(model.chartDataFrame)
        model.chartFirstFramePresented(epoch: previous.epoch, at: ProcessInfo.processInfo.systemUptime)
        model.realtimeConnectionChanged(.disconnected)
        XCTAssertEqual(model.recoveryState, .disconnected)
        XCTAssertEqual(model.chartDataFrame?.epoch, previous.epoch)
        clock.addTimeInterval(1_799)
        model.realtimeConnectionChanged(.connecting)
        XCTAssertEqual(model.chartDataFrame?.epoch, previous.epoch)
        model.suspendForBackground()
        clock.addTimeInterval(1)
        await api.closeGate()
        await model.resumeFromBackground()
        XCTAssertNotNil(model.chartDataFrame, "Backgrounding must not reset an earlier disconnect")
        try await waitForReads(2, api)
        await api.openGate()
        try await waitUntil { model.chartDataFrame?.epoch != nil && model.chartDataFrame?.epoch != previous.epoch }
    }

    func testForegroundDisconnectCoversTheChartAtThirtyMinutesWithoutBackgrounding() async throws {
        var clock = Date()
        let api = GatedChartHistoryAPI()
        await api.openGate()
        let model = makeChart(api, cacheTimeProvider: { clock })
        model.start()
        defer { model.stop() }
        await model.receive(ready())
        try await waitUntil { model.chartDataFrame != nil }
        let previous = try XCTUnwrap(model.chartDataFrame)
        model.realtimeConnectionChanged(.disconnected)
        clock.addTimeInterval(1_800)
        model.realtimeConnectionChanged(.connecting)
        XCTAssertNotNil(model.chartDataFrame, "Keep the last chart visible while reconnecting")
        XCTAssertEqual(model.recoveryState, .disconnected)
        await api.closeGate()
        await model.receive(ready())
        XCTAssertEqual(model.recoveryState, .restoring)
        try await waitForReads(2, api)
        await api.openGate()
        try await waitUntil { model.chartDataFrame?.epoch != nil && model.chartDataFrame?.epoch != previous.epoch }
        model.chartFirstFramePresented(epoch: try XCTUnwrap(model.chartDataFrame?.epoch),
            at: ProcessInfo.processInfo.systemUptime)
        XCTAssertEqual(model.recoveryState, .idle)
    }

    func testOfflineAndTimeoutFailuresOfferRetryUntilTheNewFrameIsPresented() async throws {
        for error in [APIError.networkUnavailable, .connectionFailed, .timeout, .invalidResponse] {
            let api = GatedChartHistoryAPI()
            let model = makeChart(api)
            model.start()
            try await waitForReads(1, api)
            await api.finishRead(1, error: error)
            try await waitUntil { model.recoveryState.failureMessage != nil }
            XCTAssertNil(model.chartDataFrame)
            XCTAssertNotNil(model.lastError)
            await model.retryLoading()
            XCTAssertEqual(model.recoveryState, .restoring)
            try await waitForReads(2, api)
            await api.openGate()
            try await waitUntil { model.chartDataFrame != nil }
            XCTAssertEqual(model.recoveryState, .restoring)
            model.chartFirstFramePresented(epoch: try XCTUnwrap(model.chartDataFrame?.epoch),
                at: ProcessInfo.processInfo.systemUptime)
            XCTAssertEqual(model.recoveryState, .idle)
            XCTAssertNil(model.lastError)
            model.stop()
        }
    }

    func testReadinessRetryAfterPresentedFrameClearsRecoveryWithoutANewEpoch() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        let epoch = try XCTUnwrap(model.chartDataFrame?.epoch)
        model.chartFirstFramePresented(epoch: epoch, at: ProcessInfo.processInfo.systemUptime)
        await api.closeGate()
        model.reload()
        try await waitForReads(2, api)
        await api.finishRead(2, error: APIError.invalidResponse)
        try await waitUntil { model.recoveryState.failureMessage != nil }
        await model.receive(notice(symbol: "BTCUSDT"))
        try await waitForReads(3, api)
        await api.openGate()
        try await waitUntil { model.candles.first?.closePrice == 103 }
        XCTAssertEqual(model.recoveryState, .idle,
            "An already presented epoch cannot wait for a second first-presentation callback")
    }

    func testRecoveryDeadlineRejectsLateHTTPAndDoesNotRestartOnHistoryNotices() async throws {
        let deadline = GatedChartRecoveryWait()
        let api = GatedChartHistoryAPI(ignoresCancellation: true)
        let model = makeChart(api, recoveryWait: { try await deadline.wait($0) })
        model.start()
        defer { model.stop() }
        try await waitForReads(1, api)
        await deadline.waitForCount(1)
        await deadline.fire(1)
        try await waitUntil { model.recoveryState.failureMessage != nil }
        XCTAssertEqual(model.lastError, "K线加载超时，请重试")
        await model.receive(notice(symbol: "BTCUSDT"))
        try await Task.sleep(for: .milliseconds(40))
        let readsBeforeRetry = await api.reads
        XCTAssertEqual(readsBeforeRetry, 1)
        await model.retryLoading()
        try await waitForReads(2, api)
        await api.finishRead(1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(model.chartDataFrame, "A timed-out response cannot fill the retry's chart")
        XCTAssertEqual(model.recoveryState, .restoring)
        await api.finishRead(2)
        try await waitUntil { model.chartDataFrame != nil }
        model.chartFirstFramePresented(epoch: KlineStreamEpoch(generation: 1), at: ProcessInfo.processInfo.systemUptime)
        XCTAssertEqual(model.recoveryState, .restoring)
        model.chartFirstFramePresented(epoch: try XCTUnwrap(model.chartDataFrame?.epoch),
            at: ProcessInfo.processInfo.systemUptime)
        XCTAssertEqual(model.recoveryState, .idle)
        await deadline.fireAll()
    }

    func testFirstReadyAfterAnInitialTimeoutStartsANewRecovery() async throws {
        let deadline = GatedChartRecoveryWait()
        let api = GatedChartHistoryAPI()
        let model = makeChart(api, recoveryWait: { try await deadline.wait($0) })
        model.start()
        defer { model.stop() }
        try await waitForReads(1, api)
        await deadline.waitForCount(1)
        await deadline.fire(1)
        try await waitUntil { model.recoveryState.failureMessage != nil }
        await model.receive(ready())
        try await waitForReads(2, api)
        XCTAssertEqual(model.recoveryState, .restoring)
        await api.openGate()
        try await waitUntil { model.chartDataFrame != nil }
        model.chartFirstFramePresented(epoch: try XCTUnwrap(model.chartDataFrame?.epoch),
            at: ProcessInfo.processInfo.systemUptime)
        XCTAssertEqual(model.recoveryState, .idle)
        await deadline.fireAll()
    }

    func testRecoveryDeadlineIncludesRenderingAndIsNotExtendedByReconnects() async throws {
        let deadline = GatedChartRecoveryWait()
        let api = GatedChartHistoryAPI()
        await api.openGate()
        let model = makeChart(api, recoveryWait: { try await deadline.wait($0) })
        model.start()
        defer { model.stop() }
        await model.receive(ready())
        try await waitUntil { model.chartDataFrame != nil }
        await model.receive(ready())
        try await waitForReads(2, api)
        let durations = await deadline.durations
        XCTAssertEqual(durations, [.seconds(20)], "A reconnect must share the outstanding presentation deadline")
        await deadline.fire(1)
        try await waitUntil { model.lastError != nil }
        XCTAssertNotNil(model.chartDataFrame, "Timeout can occur after data arrived but before GPU presentation")
        model.chartFirstFramePresented(epoch: try XCTUnwrap(model.chartDataFrame?.epoch),
            at: ProcessInfo.processInfo.systemUptime)
        XCTAssertEqual(model.recoveryState, .idle)
    }

    func testCancelledRecoveryDeadlineCannotFailANewForegroundOrInterval() async throws {
        let deadline = GatedChartRecoveryWait()
        let api = GatedChartHistoryAPI()
        let model = makeChart(api, recoveryWait: { try await deadline.wait($0) })
        model.start()
        try await waitForReads(1, api)
        await deadline.waitForCount(1)
        model.suspendForBackground()
        await model.resumeFromBackground()
        try await waitForReads(2, api)
        await deadline.fire(1)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.recoveryState, .idle)
        model.selectInterval(.fiveMinutes)
        try await waitForReads(3, api)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.recoveryState, .restoring)
        model.stop()
        await deadline.fireAll()
        await api.openGate()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.recoveryState, .idle)
        XCTAssertNil(model.chartDataFrame)
    }

    func testForegroundWithoutSocketReconnectWaitsForACompleteSnapshot() async throws {
        for interval in [MarketKlineInterval.oneMinute, .oneHour] {
            let api = GatedChartHistoryAPI()
            await api.openGate()
            let model = makeChart(api, initialInterval: interval)
            model.start()
            await model.receive(ready())
            try await waitUntil { model.chartDataFrame != nil }
            let previous = try XCTUnwrap(model.chartDataFrame)
            let oldCandles = model.candles
            await api.closeGate()
            model.suspendForBackground()
            await model.receive(liveKline(interval: interval))
            XCTAssertTrue(model.chartDataFrame?.candles.liveTail == previous.candles.liveTail)
            await model.resumeFromBackground()
            try await waitForReads(2, api)
            await model.receive(liveKline(interval: interval))
            XCTAssertEqual(model.chartDataFrame?.epoch, previous.epoch)
            XCTAssertTrue(model.candles == oldCandles)
            model.toggleChartIndicator("RSI")
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(model.chartDataFrame?.epoch, previous.epoch,
                "Indicator changes must also wait for the foreground snapshot")
            await api.openGate()
            try await waitUntil { model.candles.first?.closePrice == 102 }
            XCTAssertNotEqual(model.chartDataFrame?.epoch, previous.epoch)
            await model.resumeFromBackground()
            let reads = await api.reads
            XCTAssertEqual(reads, 2)
            model.stop()
        }
    }

    func testFirstSocketReadyPreservesTheDownloadingInitialSnapshot() async throws {
        let cancelled = expectation(description: "The first socket handshake must preserve HTTP history")
        cancelled.isInverted = true
        let api = GatedChartHistoryAPI(onCancelled: { cancelled.fulfill() })
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        try await waitForReads(1, api)
        await model.receive(ready())
        await fulfillment(of: [cancelled], timeout: 0.15)
        let reads = await api.reads
        XCTAssertEqual(reads, 1, "A slow handshake must not restart the first HTTP download")
        await api.openGate()
        try await waitUntil { model.chartDataFrame != nil }
    }

    func testReconnectKeepsTheLastCompleteFrameUntilHistoryArrives() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        let model = makeChart(api)
        model.start()
        defer { model.stop() }
        await model.receive(ready())
        try await waitUntil { model.chartDataFrame != nil }
        let previous = try XCTUnwrap(model.chartDataFrame)
        let previousCandles = model.candles
        await api.closeGate()
        await model.receive(ready())
        try await waitForReads(2, api)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tick = RealtimeServerMessage(version: 1, type: "event", requestId: nil,
            channel: "market.ticker", event: "upsert", key: "BTCUSDT", sequence: 1,
            timestamp: now, data: .object(["symbol": .string("BTCUSDT"),
                "lastPrice": .number(300), "priceChangePercent24h": .number(1),
                "quoteVolume24h": .number(1000),
                "eventTime": .number(Double(now))]), error: nil)
        _ = try XCTUnwrap(tick.decodeData(as: MarketTickerPayload.self))
        await model.receive(tick)
        await model.receive(liveKline())
        XCTAssertEqual(model.chartDataFrame?.epoch, previous.epoch,
            "Keep the complete old frame while the reconnect snapshot is downloading")
        XCTAssertTrue(model.chartDataFrame?.candles.history === previous.candles.history)
        XCTAssertEqual(model.chartDataFrame?.candles.liveTail, previous.candles.liveTail)
        XCTAssertTrue(model.candles == previousCandles)
        await api.openGate()
        try await waitUntil { model.candles.first?.closePrice == 102 }
        XCTAssertNotEqual(model.chartDataFrame?.epoch, previous.epoch)
    }

    func testDiagnosticBackgroundRecoveryGetsItsOwnTraceAndRejectsOldPresentations() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        var reports: [Data] = []
        let model = makeChart(api, diagnosticUpload: { reports.append($0) })
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        let old = try presentChart(model)
        let initialID = try XCTUnwrap(model.loadDiagnostics?.id)
        XCTAssertEqual(reports.count, 1)

        await api.closeGate()
        model.suspendForBackground()
        await model.resumeFromBackground()
        await model.resumeFromBackground()
        try await waitForReads(2, api)
        let recoveryID = try XCTUnwrap(model.loadDiagnostics?.id)
        XCTAssertNotEqual(recoveryID, initialID)
        let requests = await api.requestDiagnostics
        XCTAssertEqual(requests.count, 2, "Repeated foreground callbacks must not add reads")
        XCTAssertEqual(requests[1]?.traceID, recoveryID)
        model.chartFirstFramePresented(epoch: old, at: ProcessInfo.processInfo.systemUptime)
        XCTAssertEqual(reports.count, 1, "Retained content cannot complete the new recovery")

        await api.openGate()
        try await waitUntil { model.chartDataFrame?.epoch != old }
        let current = try presentChart(model)
        model.chartFirstFramePresented(epoch: current, at: ProcessInfo.processInfo.systemUptime)
        XCTAssertEqual(reports.count, 2)
        let payload = try diagnosticPayload(reports.last!)
        XCTAssertEqual(payload["traceId"] as? String, recoveryID.uuidString)
        XCTAssertEqual(try diagnosticTrigger(payload), 2)
        XCTAssertEqual(payload["outcome"] as? String, "displayed")
        let stages = try XCTUnwrap(payload["events"] as? [[String: Any]]).compactMap { $0["stage"] as? String }
        XCTAssertTrue(stages.contains("epoch_changed"))
        XCTAssertTrue(stages.contains("snapshot_installed"))
        XCTAssertTrue(stages.contains("frame_ready"))
        XCTAssertEqual(stages.last, "first_frame")
    }

    func testDiagnosticReconnectIncludesSocketWaitAndCoalescesRepeatedReady() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        var reports: [Data] = []
        let model = makeChart(api, diagnosticUpload: { reports.append($0) })
        model.start()
        defer { model.stop() }
        await model.receive(ready())
        try await waitUntil { model.chartDataFrame != nil }
        let old = try presentChart(model)
        let initialID = try XCTUnwrap(model.loadDiagnostics?.id)
        await api.closeGate()
        model.realtimeConnectionChanged(.disconnected)
        let recoveryID = try XCTUnwrap(model.loadDiagnostics?.id)
        XCTAssertNotEqual(recoveryID, initialID, "Measure connection recovery before socket ready")
        model.chartFirstFramePresented(epoch: old, at: ProcessInfo.processInfo.systemUptime)
        XCTAssertEqual(reports.count, 1, "Old presentation while offline cannot finish recovery")
        await model.receive(ready())
        try await waitForReads(2, api)
        await model.receive(ready())
        try await waitForReads(3, api)
        XCTAssertEqual(model.loadDiagnostics?.id, recoveryID)
        let requests = await api.requestDiagnostics
        XCTAssertEqual(requests[1]?.traceID, recoveryID)
        XCTAssertEqual(requests[2]?.traceID, recoveryID)
        await api.openGate()
        try await waitUntil { model.chartDataFrame?.epoch != old }
        _ = try presentChart(model)
        XCTAssertEqual(reports.count, 2, "One recovery burst must produce one report")
        let payload = try diagnosticPayload(reports.last!)
        XCTAssertEqual(try diagnosticTrigger(payload), 3)
        let stages = try XCTUnwrap(payload["events"] as? [[String: Any]]).compactMap { $0["stage"] as? String }
        XCTAssertTrue(stages.contains("socket_ready"))
    }

    func testDiagnosticFirstHandshakePreservesTheInitialTraceAndDownload() async throws {
        let api = GatedChartHistoryAPI()
        var reports: [Data] = []
        let model = makeChart(api, diagnosticUpload: { reports.append($0) })
        model.start()
        defer { model.stop() }
        try await waitForReads(1, api)
        let trace = model.loadDiagnostics?.id
        await model.receive(ready())
        XCTAssertEqual(model.loadDiagnostics?.id, trace)
        let reads = await api.reads
        XCTAssertEqual(reads, 1)
        await api.openGate()
        try await waitUntil { model.chartDataFrame != nil }
        _ = try presentChart(model)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(try diagnosticTrigger(diagnosticPayload(reports[0])), 0)
    }

    func testDiagnosticBackgroundSuspensionClosesTheTraceAndRejectsLateHTTP() async throws {
        let api = GatedChartHistoryAPI(ignoresCancellation: true)
        var reports: [Data] = []
        let model = makeChart(api, diagnosticUpload: { reports.append($0) })
        model.start()
        defer { model.stop() }
        try await waitForReads(1, api)
        model.suspendForBackground()
        model.suspendForBackground()
        XCTAssertEqual(reports.count, 1, "End timing at background entry, excluding suspended time")
        if let cancelled = reports.first {
            XCTAssertEqual(try diagnosticPayload(cancelled)["outcome"] as? String, "cancelled")
        }
        await model.resumeFromBackground()
        try await waitForReads(2, api)
        let oldRequest = (await api.requestDiagnostics)[0]
        oldRequest?.mark("decode_finished")
        await api.finishRead(1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(model.chartDataFrame)
        await api.finishRead(2)
        try await waitUntil { model.chartDataFrame != nil }
        _ = try presentChart(model)
        XCTAssertEqual(reports.count, 2)
        let payload = try diagnosticPayload(reports.last!)
        let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
        XCTAssertFalse(events.contains { $0["requestId"] as? String == oldRequest?.requestID.uuidString })
        XCTAssertEqual(try diagnosticTrigger(payload), 2)
    }

    func testDiagnosticRecoveryDeadlineReportsImmediatelyAndRetryStartsFresh() async throws {
        let deadline = GatedChartRecoveryWait()
        let api = GatedChartHistoryAPI(ignoresCancellation: true)
        await api.openGate()
        var reports: [Data] = []
        var clock = Date()
        let model = makeChart(api, cacheTimeProvider: { clock }, recoveryWait: { try await deadline.wait($0) },
            diagnosticUpload: { reports.append($0) })
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        let old = try presentChart(model)
        await api.closeGate()
        model.suspendForBackground()
        clock.addTimeInterval(1_800)
        await model.resumeFromBackground()
        try await waitForReads(2, api)
        await deadline.waitForCount(2)
        await deadline.fire(2)
        try await waitUntil { model.lastError != nil }
        XCTAssertEqual(reports.count, 2, "Do not wait for exit or the 40-second diagnostic timer")
        if let timeout = reports.last, reports.count == 2 {
            XCTAssertEqual(try diagnosticPayload(timeout)["outcome"] as? String, "timeout")
        }
        let timedOutID = model.loadDiagnostics?.id
        await model.retryLoading()
        try await waitForReads(3, api)
        XCTAssertNotEqual(model.loadDiagnostics?.id, timedOutID)
        await api.finishRead(2)
        await deadline.fire(1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.chartDataFrame?.epoch, old)
        await api.finishRead(3)
        try await waitUntil { model.chartDataFrame?.epoch != old }
        _ = try presentChart(model)
        XCTAssertEqual(reports.count, 3)
        let payload = try diagnosticPayload(reports.last!)
        XCTAssertEqual(payload["outcome"] as? String, "displayed")
        XCTAssertEqual(try diagnosticTrigger(payload), 4)
        model.stop()
        await deadline.fireAll()
    }

    func testDiagnosticRecoveryRetainsFailureEvidenceAndSeparatesManualRetry() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        var reports: [Data] = []
        let model = makeChart(api, diagnosticUpload: { reports.append($0) })
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        let old = try presentChart(model)
        await api.closeGate()
        model.suspendForBackground()
        await model.resumeFromBackground()
        try await waitForReads(2, api)
        let recordedRequests = await api.requestDiagnostics
        let failedRequest = try XCTUnwrap(recordedRequests[1])
        // The transport normally records this before returning its error to the model.
        failedRequest.finished(error: APIError.connectionFailed)
        await api.finishRead(2, error: APIError.connectionFailed)
        try await waitUntil { model.lastError != nil }
        await model.retryLoading()
        try await waitForReads(3, api)
        XCTAssertEqual(reports.count, 2)
        if reports.count == 2 {
            let failed = try diagnosticPayload(reports[1])
            XCTAssertEqual(failed["outcome"] as? String, "superseded")
            let requests = try XCTUnwrap(failed["requests"] as? [[String: Any]])
            XCTAssertEqual(requests.first?["result"] as? String, "error")
            XCTAssertNotNil(requests.first?["errorCode"])
        }
        await api.openGate()
        try await waitUntil { model.chartDataFrame?.epoch != old }
        _ = try presentChart(model)
        XCTAssertEqual(reports.count, 3)
        XCTAssertEqual(try diagnosticTrigger(diagnosticPayload(reports.last!)), 4)
    }

    func testDiagnosticRecoverySupersededByIntervalAndStopIsReportedOnce() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        var reports: [Data] = []
        let model = makeChart(api, diagnosticUpload: { reports.append($0) })
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        _ = try presentChart(model)
        await api.closeGate()
        model.suspendForBackground()
        await model.resumeFromBackground()
        try await waitForReads(2, api)
        model.selectInterval(.fiveMinutes)
        try await waitForReads(3, api)
        model.stop()
        model.stop()
        XCTAssertEqual(reports.count, 3)
        if reports.count == 3 {
            XCTAssertEqual(try diagnosticPayload(reports[1])["outcome"] as? String, "superseded")
            let stopped = try diagnosticPayload(reports[2])
            XCTAssertEqual(stopped["outcome"] as? String, "cancelled")
            XCTAssertEqual(stopped["interval"] as? String, "5m")
            XCTAssertEqual(try diagnosticTrigger(stopped), 1)
        }
    }

    private func presentChart(_ model: MarketChartViewModel) throws -> KlineStreamEpoch {
        let epoch = try XCTUnwrap(model.chartDataFrame?.epoch)
        model.chartFirstFramePresented(epoch: epoch, at: ProcessInfo.processInfo.systemUptime)
        return epoch
    }

    private func diagnosticPayload(_ report: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: report) as? [String: Any])
    }

    private func diagnosticTrigger(_ payload: [String: Any]) throws -> Int? {
        let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
        return events.first { $0["stage"] as? String == "load_started" }?["value"] as? Int
    }

    func testDiagnosticFirstFrameIgnoresOldEpochAndFinishesEachLoadOnce() async throws {
        let api = GatedChartHistoryAPI()
        await api.openGate()
        var reports: [Data] = []
        let market = MarketSnapshot(symbol: "BTCUSDT", quoteAsset: "USDT", price: 100,
            changePercent24h: 0, updatedAt: .now)
        let model = MarketChartViewModel(market: market, apiClient: api,
            realtimeClient: RealtimeClient(baseURL: URL(string: "http://127.0.0.1")!, tokenProvider: { nil }),
            diagnosticUpload: { reports.append($0) })
        model.start()
        defer { model.stop() }
        try await waitUntil { model.chartDataFrame != nil }
        let old = try XCTUnwrap(model.chartDataFrame?.epoch)
        model.selectInterval(.fiveMinutes)
        XCTAssertEqual(reports.count, 1)
        try await waitUntil { model.chartDataFrame?.stream.interval == "5m" }
        model.chartFirstFramePresented(epoch: old, at: ProcessInfo.processInfo.systemUptime)
        XCTAssertEqual(reports.count, 1)
        let current = try XCTUnwrap(model.chartDataFrame?.epoch)
        model.chartFirstFramePresented(epoch: current, at: ProcessInfo.processInfo.systemUptime)
        model.chartFirstFramePresented(epoch: current, at: ProcessInfo.processInfo.systemUptime)
        model.stop()
        XCTAssertEqual(reports.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: reports[0]) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: reports[1]) as? [String: Any])
        XCTAssertEqual(first["outcome"] as? String, "superseded")
        XCTAssertEqual(second["outcome"] as? String, "displayed")
        XCTAssertEqual(second["interval"] as? String, "5m")
    }

    func testReadinessBurstDoesNotCancelTheFirstHistoryDownload() async throws {
        let cancelled = expectation(description: "Readiness must preserve the in-flight history download")
        cancelled.isInverted = true
        cancelled.assertForOverFulfill = false
        let started = expectation(description: "First history download started")
        let api = GatedChartHistoryAPI(onFirstRead: { started.fulfill() },
                                       onCancelled: { cancelled.fulfill() })
        let market = MarketSnapshot(symbol: "BTCUSDT", quoteAsset: "USDT", price: 100,
            changePercent24h: 0, updatedAt: .now)
        let viewModel = MarketChartViewModel(market: market, apiClient: api,
            realtimeClient: RealtimeClient(baseURL: URL(string: "http://127.0.0.1")!, tokenProvider: { nil }))
        viewModel.start()
        defer { viewModel.stop() }
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<6 {
            await viewModel.receive(notice(symbol: "BTCUSDT"))
            await Task.yield()
        }
        await fulfillment(of: [cancelled], timeout: 0.2)
        let initialReads = await api.reads
        XCTAssertEqual(initialReads, 1, "Ready notices must coalesce while the first response is downloading")
        await api.releaseCurrentRead()
        try await waitUntil { viewModel.candles.first?.closePrice == 101 }
        XCTAssertNotNil(viewModel.chartDataFrame, "The first response must appear before the follow-up completes")
        await api.openGate()
        try await waitUntil { viewModel.candles.first?.closePrice == 102 }
        let finalReads = await api.reads
        XCTAssertEqual(finalReads, 2, "One follow-up read must recover notices received during the first request")
    }

    func testIntervalSwitchStillCancelsTheObsoleteHistoryDownload() async throws {
        let started = expectation(description: "First history download started")
        let cancelled = expectation(description: "Changing interval cancels the obsolete download")
        let api = GatedChartHistoryAPI(onFirstRead: { started.fulfill() },
                                       onCancelled: { cancelled.fulfill() })
        let viewModel = makeChart(api)
        viewModel.start()
        defer { viewModel.stop() }
        await fulfillment(of: [started], timeout: 2)
        await viewModel.receive(notice(symbol: "BTCUSDT"))
        viewModel.selectInterval(.fiveMinutes)
        await fulfillment(of: [cancelled], timeout: 2)
        await api.openGate()
        try await waitUntil { viewModel.chartDataFrame?.stream.interval == "5m" }
        let reads = await api.reads
        XCTAssertEqual(reads, 2, "The queued notice for the old interval must be discarded")
        XCTAssertEqual(viewModel.candles.first?.closePrice, 102)
    }

    func testStoppingChartCancelsDownloadAndQueuedReadinessRefresh() async throws {
        let started = expectation(description: "First history download started")
        let cancelled = expectation(description: "Leaving the chart cancels its download")
        let api = GatedChartHistoryAPI(onFirstRead: { started.fulfill() },
                                       onCancelled: { cancelled.fulfill() })
        let viewModel = makeChart(api)
        viewModel.start()
        await fulfillment(of: [started], timeout: 2)
        await viewModel.receive(notice(symbol: "BTCUSDT"))
        viewModel.stop()
        await fulfillment(of: [cancelled], timeout: 2)
        await api.openGate()
        await Task.yield()
        let reads = await api.reads
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(viewModel.candles.isEmpty)
        XCTAssertNil(viewModel.chartDataFrame)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testPageReadinessBurstPreservesTheDownloadingPage() async throws {
        let cancelled = expectation(description: "Ready notices must preserve an in-flight page")
        cancelled.isInverted = true
        cancelled.assertForOverFulfill = false
        let api = GatedChartHistoryAPI(onFirstRead: {}, onCancelled: { cancelled.fulfill() })
        await api.openGate()
        let viewModel = makeChart(api)
        viewModel.start()
        defer { viewModel.stop() }
        try await waitUntil { viewModel.chartDataFrame != nil }
        let first = try XCTUnwrap(viewModel.chartDataFrame?.candles.history.candles.first?.openTime)
        await api.closeGate()
        viewModel.requestOlderHistory()
        let pageStarted = ContinuousClock.now.advanced(by: .seconds(2))
        while await api.reads < 2, ContinuousClock.now < pageStarted { await Task.yield() }
        let notice = RealtimeServerMessage(version: 1, type: "event", requestId: nil, channel: "market.history",
            event: "upsert", key: nil, sequence: 1, timestamp: 1,
            data: .object(["symbol": .string("BTCUSDT"), "interval": .string("1h"),
                           "kind": .string("history"), "beforeOpenTime": .number(Double(first))]), error: nil)
        for _ in 0..<6 { await viewModel.receive(notice) }
        await fulfillment(of: [cancelled], timeout: 0.2)
        let beforeCompletion = await api.reads
        XCTAssertEqual(beforeCompletion, 2)
        await api.releaseCurrentRead()
        try await waitUntil {
            (viewModel.chartDataFrame?.candles.history.candles.first?.openTime ?? first) < first
        }
        await api.openGate()
        try await waitUntil { !viewModel.isLoadingOlderHistory }
        let finalReads = await api.reads
        XCTAssertEqual(finalReads, 3, "All page notices must merge into one follow-up")
    }

    func testRecoverySharesTheDownloadingFirstSnapshot() async throws {
        let api = GatedChartHistoryAPI()
        let viewModel = makeChart(api)
        defer { viewModel.stop() }
        viewModel.start()
        try await waitForReads(1, api)
        await viewModel.receive(liveKline())
        try await Task.sleep(for: .milliseconds(100))
        let reads = await api.reads
        XCTAssertEqual(reads, 1, "Recovery must join the snapshot already downloading")
        await api.openGate()
        try await waitUntil { viewModel.chartDataFrame != nil }
    }

    func testPendingSnapshotWaitsForReadinessDespiteRealtimeUpdates() async throws {
        let api = EmptyPendingChartAPI()
        let viewModel = makeChart(api)
        defer { viewModel.stop() }
        viewModel.start()
        try await waitUntil { viewModel.isLoading }
        try await Task.sleep(for: .milliseconds(30))
        await viewModel.receive(liveKline())
        try await Task.sleep(for: .milliseconds(100))
        let reads = await api.reads
        XCTAssertEqual(reads, 1, "A pending server backfill must wait for readiness or reconciliation")
        await viewModel.receive(notice(symbol: "BTCUSDT"))
        try await Task.sleep(for: .milliseconds(100))
        let afterNotice = await api.reads
        XCTAssertEqual(afterNotice, 2)
    }

    func testMatchingAckCoalescesWhileUnrelatedFiltersDoNotQueueARefresh() async throws {
        let api = GatedChartHistoryAPI()
        let viewModel = makeChart(api)
        viewModel.start()
        defer { viewModel.stop() }
        try await waitForReads(1, api)
        await viewModel.receive(ack(symbol: "ETHUSDT", interval: "1h"))
        await viewModel.receive(ack(symbol: "BTCUSDT", interval: "4h"))
        await viewModel.receive(notice(symbol: "BTCUSDT", interval: "4h"))
        await api.finishRead(1)
        try await waitUntil { viewModel.chartDataFrame != nil }
        await Task.yield()
        let unrelatedReads = await api.reads
        XCTAssertEqual(unrelatedReads, 1)
        viewModel.reload()
        try await waitForReads(2, api)
        for _ in 0..<6 { await viewModel.receive(ack(symbol: "BTCUSDT", interval: "1h")) }
        await api.finishRead(2)
        try await waitUntil { viewModel.candles.first?.closePrice == 102 }
        try await waitForReads(3, api)
        await api.openGate()
        try await waitUntil { viewModel.candles.first?.closePrice == 103 }
        let finalReads = await api.reads
        XCTAssertEqual(finalReads, 3)
    }

    func testFailedHistoryReleasesItsSlotForTheNextReadinessNotice() async throws {
        let api = GatedChartHistoryAPI()
        let viewModel = makeChart(api)
        viewModel.start()
        defer { viewModel.stop() }
        try await waitForReads(1, api)
        await api.finishRead(1, error: APIError.invalidResponse)
        try await waitUntil { viewModel.lastError != nil && !viewModel.isLoading }
        await viewModel.receive(notice(symbol: "BTCUSDT"))
        try await waitForReads(2, api)
        await api.openGate()
        try await waitUntil { viewModel.chartDataFrame != nil }
        XCTAssertNil(viewModel.lastError)
    }

    func testLateCancelledRequestCannotReleaseTheNewRequestSlot() async throws {
        let api = GatedChartHistoryAPI(ignoresCancellation: true)
        let viewModel = makeChart(api)
        viewModel.start()
        defer { viewModel.stop() }
        try await waitForReads(1, api)
        viewModel.reload()
        try await waitForReads(2, api)
        await api.finishRead(1)
        await viewModel.receive(notice(symbol: "BTCUSDT"))
        await Task.yield()
        XCTAssertNil(viewModel.chartDataFrame)
        XCTAssertTrue(viewModel.isLoading)
        let inFlightReads = await api.reads
        XCTAssertEqual(inFlightReads, 2)
        await api.finishRead(2)
        try await waitUntil { viewModel.candles.first?.closePrice == 102 }
        await api.openGate()
        try await waitUntil { viewModel.candles.first?.closePrice == 103 }
        let finalReads = await api.reads
        XCTAssertEqual(finalReads, 3)
    }

    func testRealReconnectCancelsOldEpochHistoryAndKeepsNewResponse() async throws {
        let cancelled = expectation(description: "A new connection epoch cancels the old snapshot")
        let api = GatedChartHistoryAPI(onCancelled: { cancelled.fulfill() })
        let viewModel = makeChart(api)
        viewModel.start()
        defer { viewModel.stop() }
        await viewModel.receive(ready())
        try await waitForReads(1, api)
        await viewModel.receive(ready())
        await fulfillment(of: [cancelled], timeout: 2)
        try await waitForReads(2, api)
        await api.openGate()
        try await waitUntil { viewModel.chartDataFrame != nil }
        XCTAssertEqual(viewModel.candles.first?.closePrice, 102)
    }

    func testRealReconnectCancelsAndResumesAnOldEpochHistoryPage() async throws {
        let cancelled = expectation(description: "A new epoch cancels its obsolete page")
        let api = GatedChartHistoryAPI(onCancelled: { cancelled.fulfill() })
        await api.openGate()
        let viewModel = makeChart(api)
        viewModel.start()
        defer { viewModel.stop() }
        await viewModel.receive(ready())
        try await waitUntil { viewModel.chartDataFrame != nil }
        let first = try XCTUnwrap(viewModel.chartDataFrame?.candles.history.candles.first?.openTime)
        await api.closeGate()
        viewModel.requestOlderHistory()
        try await waitForReads(2, api)
        await viewModel.receive(ready())
        await fulfillment(of: [cancelled], timeout: 1)
        await api.openGate()
        try await waitUntil { !viewModel.isLoadingOlderHistory }
        try await waitUntil {
            (viewModel.chartDataFrame?.candles.history.candles.first?.openTime ?? first) < first
        }
    }

    func testReconciliationTimerCoalescesWithTheDownloadingFirstSnapshot() async throws {
        let api = GatedChartHistoryAPI()
        let viewModel = makeChart(api)
        viewModel.start()
        defer { viewModel.stop() }
        try await waitForReads(1, api)
        // Exercise the production timer itself, including its cancellation path.
        try await Task.sleep(for: .milliseconds(15_200))
        let readsDuringDownload = await api.reads
        XCTAssertEqual(readsDuringDownload, 1)
        await api.finishRead(1)
        try await waitUntil { viewModel.candles.first?.closePrice == 101 }
        try await waitForReads(2, api)
        await api.openGate()
        try await waitUntil { viewModel.candles.first?.closePrice == 102 }
        let finalReads = await api.reads
        XCTAssertEqual(finalReads, 2)
    }

    func testReconnectResumesItsPageOnlyAfterTheNewSnapshotIsInstalled() async throws {
        let api = GatedChartHistoryAPI(ignoresCancellation: true)
        await api.openGate()
        let viewModel = makeChart(api)
        viewModel.start()
        defer { viewModel.stop() }
        await viewModel.receive(ready())
        try await waitUntil { viewModel.chartDataFrame != nil }
        let first = try XCTUnwrap(viewModel.chartDataFrame?.candles.history.candles.first?.openTime)
        await api.closeGate()
        viewModel.requestOlderHistory()
        try await waitForReads(2, api)
        await viewModel.receive(ready())
        try await waitForReads(3, api)
        await api.finishRead(2)
        await Task.yield()
        let readsWhileSnapshotIsPending = await api.reads
        XCTAssertEqual(readsWhileSnapshotIsPending, 3, "Do not install a page that the next snapshot will discard")
        await api.finishRead(3)
        try await waitForReads(4, api)
        await api.openGate()
        try await waitUntil { !viewModel.isLoadingOlderHistory }
        XCTAssertLessThan(try XCTUnwrap(viewModel.chartDataFrame?.candles.history.candles.first?.openTime), first)
    }

    func testIntervalSwitchDiscardsALatePageFromTheOldInterval() async throws {
        let api = GatedChartHistoryAPI(ignoresCancellation: true)
        await api.openGate()
        let viewModel = makeChart(api)
        viewModel.start()
        defer { viewModel.stop() }
        try await waitUntil { viewModel.chartDataFrame != nil }
        await api.closeGate()
        viewModel.requestOlderHistory()
        try await waitForReads(2, api)
        viewModel.selectInterval(.fiveMinutes)
        try await waitForReads(3, api)
        await api.finishRead(3)
        try await waitUntil { viewModel.candles.first?.closePrice == 103 }
        let first = viewModel.chartDataFrame?.candles.history.candles.first?.openTime
        await api.finishRead(2)
        await Task.yield()
        XCTAssertEqual(viewModel.chartDataFrame?.candles.history.candles.first?.openTime, first)
        XCTAssertFalse(viewModel.isLoadingOlderHistory)
        viewModel.requestOlderHistory()
        try await waitForReads(4, api)
        await api.openGate()
        try await waitUntil { !viewModel.isLoadingOlderHistory }
        XCTAssertLessThan(try XCTUnwrap(viewModel.chartDataFrame?.candles.history.candles.first?.openTime),
                          try XCTUnwrap(first))
    }

    func testLegacyBackendKeepsMarketAndAccountSubscriptions() {
        let subscriptions: [RealtimeSubscription] = [.marketKline(symbols: ["BTCUSDT"]),
            .marketTicker(symbols: ["BTCUSDT"]), .tradingAccount,
            .marketHistory(symbols: ["BTCUSDT"], intervals: ["1h"])]
        XCTAssertEqual(RealtimeSubscription.compatible(subscriptions, capabilities: []).map(\.channel),
            ["market.kline", "market.ticker", "trading.account"])
        XCTAssertEqual(RealtimeSubscription.compatible(subscriptions, capabilities: ["market.history"]), subscriptions)
    }

    func testPreparingSessionMakesNoAccountRequests() async throws {
        let api = NativeFixtureClient()
        let store = USDTStore(api: api)
        store.prepareSession(userID: "market-session-qa")
        XCTAssertTrue(store.scope.hasPrefix("market-session-qa:"))
        let paths = await api.paths
        XCTAssertTrue(paths.isEmpty)
    }

    func testReadinessNoticeRefreshesOnlyTheSelectedMarket() async throws {
        let api = PendingChartAPI()
        let viewModel = makeChart(api)
        viewModel.start()
        defer { viewModel.stop() }
        try await waitUntil { viewModel.chartDataFrame != nil }
        await viewModel.receive(notice(symbol: "ETHUSDT"))
        let unchanged = await api.latestReads
        XCTAssertEqual(unchanged, 1)
        await viewModel.receive(notice(symbol: "BTCUSDT"))
        try await waitUntil { viewModel.candles.first?.closePrice == 102 }
    }

    func testSubscriptionAcknowledgementRecoversAMissedReadinessNotice() async throws {
        let api = PendingChartAPI()
        let viewModel = makeChart(api)
        viewModel.start()
        defer { viewModel.stop() }
        try await waitUntil { viewModel.chartDataFrame != nil }
        let data = Data("""
        {"version":1,"type":"ack","timestamp":1,"data":{"subscriptions":[{"channel":"market.history","filters":{"symbols":["BTCUSDT"],"intervals":["1h"]}}]}}
        """.utf8)
        await viewModel.receive(try JSONDecoder().decode(RealtimeServerMessage.self, from: data))
        try await waitUntil { viewModel.candles.first?.closePrice == 102 }
    }

    func testPartialHistoryPageAppearsWhileBackfillIsPending() async throws {
        let api = PendingChartAPI()
        let viewModel = makeChart(api)
        viewModel.start()
        defer { viewModel.stop() }
        try await waitUntil { viewModel.chartDataFrame != nil }
        let first = try XCTUnwrap(viewModel.chartDataFrame?.candles.history.candles.first?.openTime)
        viewModel.requestOlderHistory()
        try await waitUntil {
            (viewModel.chartDataFrame?.candles.history.candles.first?.openTime ?? first) < first
        }
        XCTAssertTrue(viewModel.hasMoreHistory)
    }

    func testPendingStatisticsDoNotPollAndReinstallTheWholeSnapshot() async throws {
        let api = PendingChartAPI()
        let viewModel = makeChart(api)
        viewModel.start()
        defer { viewModel.stop() }
        try await waitUntil { viewModel.chartDataFrame != nil }
        try await Task.sleep(for: .milliseconds(1300))
        let count = await api.latestReads
        XCTAssertEqual(count, 1)
    }

    private func makeChart(_ api: any APIClient, initialInterval: MarketKlineInterval = .oneHour,
                           cacheTimeProvider: @escaping () -> Date = Date.init,
                           recoveryWait: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                           diagnosticUpload: ((Data) -> Void)? = nil) -> MarketChartViewModel {
        let market = MarketSnapshot(symbol: "BTCUSDT", quoteAsset: "USDT", price: 100,
            changePercent24h: 0, updatedAt: .now)
        return MarketChartViewModel(market: market, apiClient: api,
            realtimeClient: RealtimeClient(baseURL: URL(string: "http://127.0.0.1")!, tokenProvider: { nil }),
            initialInterval: initialInterval,
            chartIndicatorSelectionStore: .init(key: "chart-test-selection-\(UUID())"),
            chartIndicatorParametersStore: .init(key: "chart-test-parameters-\(UUID())"),
            diagnosticUpload: diagnosticUpload, cacheTimeProvider: cacheTimeProvider, recoveryWait: recoveryWait)
    }

    private func liveKline(interval: MarketKlineInterval = .oneHour, sequence: Int64 = 1,
                           close: Double = 105) -> RealtimeServerMessage {
        let width = Int64(interval.duration * 1000)
        let at = Int64(Date().timeIntervalSince1970 * 1000) / width * width
        let data: JSONValue = .object([
            "symbol": .string("BTCUSDT"), "contractType": .string("PERPETUAL"), "interval": .string(interval.rawValue),
            "openTime": .number(Double(at)), "closeTime": .number(Double(at + width - 1)),
            "openPrice": .number(100), "highPrice": .number(110), "lowPrice": .number(99),
            "closePrice": .number(close), "volume": .number(1), "quoteVolume": .number(100),
            "closed": .bool(false), "eventTime": .number(Double(at + 1000))])
        return RealtimeServerMessage(version: 1, type: "event", requestId: nil,
            channel: "market.kline", event: "upsert", key: "BTCUSDT:" + interval.rawValue, sequence: sequence,
            timestamp: at + 1000, data: data, error: nil)
    }

    private func notice(symbol: String, interval: String = "1h", timestamp: Int64 = 1) -> RealtimeServerMessage {
        RealtimeServerMessage(version: 1, type: "event", requestId: nil, channel: "market.history",
            event: "upsert", key: nil, sequence: 1, timestamp: timestamp,
            data: .object(["symbol": .string(symbol), "interval": .string(interval), "kind": .string("history")]), error: nil)
    }

    private func ack(symbol: String, interval: String, timestamp: Int64 = 1) -> RealtimeServerMessage {
        let data = Data("""
        {"version":1,"type":"ack","timestamp":\(timestamp),"data":{"subscriptions":[{"channel":"market.history","filters":{"symbols":["\(symbol)"],"intervals":["\(interval)"]}}]}}
        """.utf8)
        return try! JSONDecoder().decode(RealtimeServerMessage.self, from: data)
    }

    private func ready() -> RealtimeServerMessage {
        RealtimeServerMessage(version: 1, type: "ready", requestId: nil, channel: nil,
            event: nil, key: nil, sequence: nil, timestamp: 1, data: nil, error: nil)
    }

    private func waitForReads(_ expected: Int, _ api: GatedChartHistoryAPI) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await api.reads < expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reads = await api.reads
        XCTAssertEqual(reads, expected)
    }

    private func waitForFullReads(_ expected: Int, _ api: GatedChartHistoryAPI) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await api.limits.filter({ $0 == 1500 }).count < expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let count = await api.limits.filter { $0 == 1500 }.count
        XCTAssertEqual(count, expected)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate())
    }
}

private actor GatedChartRecoveryWait {
    private(set) var durations: [Duration] = []
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]

    // Intentionally ignore cancellation to verify obsolete timer completions.
    func wait(_ duration: Duration) async throws {
        durations.append(duration)
        let id = durations.count
        await withCheckedContinuation { waiting[id] = $0 }
    }

    func waitForCount(_ count: Int) async {
        for _ in 0..<1_000 {
            if durations.count >= count { return }
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(durations.count, count)
    }

    func fire(_ id: Int) { waiting.removeValue(forKey: id)?.resume() }
    func fireAll() {
        let continuations = waiting.values
        waiting.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private actor PendingChartAPI: APIClient {
    private(set) var latestReads = 0
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        guard request.path == "/api/market/klines" else { throw APIError.invalidResponse }
        let before = request.queryItems.first { $0.name == "beforeOpenTime" }?.value.flatMap(Int64.init)
        if before == nil { latestReads += 1 }
        let width: Int64 = 3_600_000
        let now = Int64(Date().timeIntervalSince1970 * 1000) / width * width
        let end = before ?? now
        let rows = (1...32).reversed().map { index in
            MarketCandle(openTime: end - Int64(index) * width,
                closeTime: end - Int64(index - 1) * width - 1,
                openPrice: 100, highPrice: 110, lowPrice: 99, closePrice: Double(100 + latestReads), volume: 1, quoteVolume: 100)
        }
        return MarketKlineHistoryResponse(symbol: "BTCUSDT", interval: "1h", items: rows,
            historyPending: before != nil, statisticsPending: before == nil, hasMoreHistory: true) as! Response
    }
}

private actor EmptyPendingChartAPI: APIClient {
    private(set) var reads = 0
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        reads += 1
        return MarketKlineHistoryResponse(symbol: "BTCUSDT", interval: "1h", items: [],
            historyPending: true, hasMoreHistory: true) as! Response
    }
}

private actor GatedChartHistoryAPI: APIClient {
    private(set) var reads = 0
    private(set) var limits: [Int] = []
    private(set) var requestDiagnostics: [RequestDiagnostics?] = []
    private var closedPrices: [String: Double] = [:]
    private var isOpen = false
    private var waiting: [Int: CheckedContinuation<Void, Error>] = [:]
    private let ignoresCancellation: Bool
    private let onFirstRead: @Sendable () -> Void
    private let onCancelled: @Sendable () -> Void
    private var serverTime: Int64?
    private var statisticsPending = false
    private var includeTradingData = false

    func setServerTime(_ value: Int64?) { serverTime = value }
    func setStatisticsPending(_ value: Bool) { statisticsPending = value }
    func setIncludeTradingData(_ value: Bool) { includeTradingData = value }

    init(onFirstRead: @escaping @Sendable () -> Void = {}, onCancelled: @escaping @Sendable () -> Void = {},
         ignoresCancellation: Bool = false) {
        self.ignoresCancellation = ignoresCancellation
        self.onFirstRead = onFirstRead
        self.onCancelled = onCancelled
    }

    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        guard request.path == "/api/market/klines" else { throw APIError.invalidResponse }
        reads += 1
        requestDiagnostics.append(request.diagnostics)
        let read = reads
        let limit = request.queryItems.first { $0.name == "limit" }?.value.flatMap(Int.init) ?? 1500
        limits.append(limit)
        if read == 1 { onFirstRead() }
        if !isOpen {
            let id = read
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { waiting[id] = $0 }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }
        if !ignoresCancellation { try Task.checkCancellation() }
        let interval = request.queryItems.first { $0.name == "interval" }?.value ?? "1h"
        let before = request.queryItems.first { $0.name == "beforeOpenTime" }?.value.flatMap(Int64.init)
        let width = Int64((MarketKlineInterval(rawValue: interval) ?? .oneHour).duration * 1000)
        let end = before ?? Int64(Date().timeIntervalSince1970 * 1000) / width * width
        if limit == 2 {
            let rows = [
                MarketCandle(openTime: end - width, closeTime: end - 1, openPrice: 100,
                    highPrice: 110, lowPrice: 99, closePrice: closedPrices[interval] ?? 101,
                    volume: 1, quoteVolume: 100),
                MarketCandle(openTime: end, closeTime: end + width - 1, openPrice: 100,
                    highPrice: 120, lowPrice: 90, closePrice: 109, volume: 20, quoteVolume: 2000)
            ]
            return MarketKlineHistoryResponse(symbol: "BTCUSDT", interval: interval, items: rows,
                historyPending: false, statisticsPending: statisticsPending,
                hasMoreHistory: false, serverTime: serverTime) as! Response
        }
        if before == nil { closedPrices[interval] = Double(100 + read) }
        let rows = (1...32).reversed().map { index in
            MarketCandle(openTime: end - Int64(index) * width,
                closeTime: end - Int64(index - 1) * width - 1,
                openPrice: 100, highPrice: 110, lowPrice: 99, closePrice: Double(100 + read), volume: 1, quoteVolume: 100,
                tradingData: includeTradingData ? MarketChartTradingData(openInterest: 100) : nil)
        }
        return MarketKlineHistoryResponse(symbol: "BTCUSDT", interval: interval, items: rows,
            historyPending: before != nil && !isOpen, statisticsPending: statisticsPending,
            hasMoreHistory: true, serverTime: serverTime) as! Response
    }

    func releaseCurrentRead() {
        guard let id = waiting.keys.min(),
              let continuation = waiting.removeValue(forKey: id) else { return }
        continuation.resume()
    }

    func finishRead(_ read: Int, error: Error? = nil) {
        guard let continuation = waiting.removeValue(forKey: read) else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func openGate() {
        isOpen = true
        let continuations = waiting.values
        waiting.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    func closeGate() { isOpen = false }

    private func cancel(_ id: Int) {
        guard waiting[id] != nil else { return }
        if !isOpen { onCancelled() }
        if !ignoresCancellation { finishRead(id, error: CancellationError()) }
    }
}

final class ChartLoadDiagnosticsTests: XCTestCase {
    func testReportKeepsWallTimesMonotonicDurationsAndBoundedEvents() throws {
        let trace = ChartLoadDiagnostics(symbol: "BTCUSDT", interval: "1h")
        let request = try XCTUnwrap(trace.request())
        request.received(HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 200,
            httpVersion: "HTTP/2", headerFields: ["Server-Timing": "history;dur=12.5, statistics_cache;dur=0.1",
            "X-Chart-Server-Received-At": "1793520000010", "X-Chart-Server-Ready-At": "1793520000020"]), bytes: 400000)
        request.mark("decode_started")
        request.mark("decode_finished")
        request.finished()
        for _ in 0..<100 { trace.record("scene_ready") }
        let data = try XCTUnwrap(trace.report(outcome: "displayed",
            presentedAt: ProcessInfo.processInfo.systemUptime, completionKind: "gpu_completion_proxy"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(payload["completedAtMs"] as? Int64),
                                  try XCTUnwrap(payload["startedAtMs"] as? Int64))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(payload["durationMs"] as? Double), 0)
        let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 64)
        XCTAssertEqual(events.last?["stage"] as? String, "first_frame")
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        let saved = try XCTUnwrap((payload["requests"] as? [[String: Any]])?.first)
        XCTAssertEqual(saved["serverHistoryMs"] as? Double, 12.5)
        XCTAssertEqual(saved["result"] as? String, "success")
        XCTAssertNil(trace.report(outcome: "cancelled"), "A displayed load must never report twice")
        XCTAssertLessThan(data.count, 24 * 1024)
    }

    func testOptInAPITracingUsesHeadersAndRecordsDecoding() async throws {
        let session = diagnosticSession()
        defer { session.invalidateAndCancel() }
        let trace = ChartLoadDiagnostics(symbol: "BTCUSDT", interval: "1h")
        let request = try XCTUnwrap(trace.request())
        let api = URLSessionAPIClient(baseURL: URL(string: "https://example.invalid")!, session: session)
        let _: EmptyResponse = try await api.send(APIRequest(path: "/history", diagnostics: request))
        let data = try XCTUnwrap(trace.report(outcome: "cancelled"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stages = try XCTUnwrap(payload["events"] as? [[String: Any]]).compactMap { $0["stage"] as? String }
        XCTAssertEqual(stages, ["load_started", "request_started", "request_adapted", "response_received",
                                "decode_started", "decode_finished", "load_cancelled"])
        XCTAssertEqual(request.snapshot()["statusCode"] as? Int, 200)
    }

    func testDiagnosticUnauthorizedDoesNotExpireSessionButNormalRequestDoes() async throws {
        let session = diagnosticSession()
        defer { session.invalidateAndCancel() }
        let center = NotificationCenter()
        let expired = expectation(description: "Only a normal API request expires the session")
        expired.expectedFulfillmentCount = 1
        let observer = center.addObserver(forName: .apiSessionUnauthorized, object: nil, queue: nil) { _ in expired.fulfill() }
        defer { center.removeObserver(observer) }
        let api = URLSessionAPIClient(baseURL: URL(string: "https://example.invalid")!, session: session,
            notificationCenter: center)
        for invalidates in [false, true] {
            do {
                let _: EmptyResponse = try await api.send(APIRequest(path: "/unauthorized",
                    showsErrorToast: false, invalidatesSessionOnUnauthorized: invalidates))
                XCTFail("Expected unauthorized")
            } catch {
                guard case .unauthorized = error as? APIError else { return XCTFail("Expected unauthorized") }
            }
        }
        await fulfillment(of: [expired], timeout: 1)
    }

    func testPresentationObserverIgnoresZeroAndCallsOnceOutsideHealthLock() async {
        let health = MetalRendererHealth()
        let presented = expectation(description: "First valid presentation")
        presented.expectedFulfillmentCount = 1
        health.observeFirstPresentation { time in
            XCTAssertEqual(time, 10)
            XCTAssertEqual(health.snapshot().presentedFrames, 1, "Callback may safely read health")
            presented.fulfill()
        }
        for time in [0.0, 10.0, 11.0] {
            health.recordPresented(revision: 1, liveRevision: 1, liveReadyTime: 1,
                presentedTime: time, readyTime: 1, submittedTime: 2)
        }
        await fulfillment(of: [presented], timeout: 1)
    }

    private func diagnosticSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChartDiagnosticURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ChartDiagnosticURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.url?.path == "/unauthorized" ? 401 : 200
        if status == 200 {
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Chart-Trace-ID").flatMap(UUID.init(uuidString:)))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Chart-Request-ID").flatMap(UUID.init(uuidString:)))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"code\":\(status),\"data\":{}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class WatchlistInteractionTests: XCTestCase {
    func testServerFavoritesRestoreBeforeMarketCapOrderedRemainder() async throws {
        let client = WatchlistFixtureAPI(saved: ["SOLUSDT", "ADAUSDT"],
            catalog: ["BTCUSDT", "ETHUSDT", "SOLUSDT", "ADAUSDT"])
        let realtime = RealtimeClient(baseURL: URL(string: "https://example.invalid")!, tokenProvider: { nil })
        let model = DashboardViewModel(apiClient: client, realtimeClient: realtime)
        model.startRealtime(userID: "server-user")
        defer { model.stopRealtime() }
        for _ in 0..<100 {
            if model.containsInWatchlist("ADAUSDT") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.markets(onlyVisible: true).map(\.symbol), ["SOLUSDT", "ADAUSDT"])
        XCTAssertEqual(model.pairPickerSymbols, ["SOLUSDT", "ADAUSDT", "BTCUSDT", "ETHUSDT"])
        await model.loadSymbolCatalog(force: true)
        XCTAssertEqual(model.pairPickerSymbols, ["SOLUSDT", "ADAUSDT", "BTCUSDT", "ETHUSDT"])
    }

    func testOfflineFavoriteEditSurvivesServerRestoreAndRetriesOnCatalogOpen() async throws {
        let suite = "WatchlistSyncTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsMarketWatchlistStore(service: "test", defaults: defaults)
        preferences.save(.init(quoteAsset: "USDT", orderedSymbols: ["BTCUSDT", "ETHUSDT"],
            visibleSymbols: ["BTCUSDT"], pinnedSymbols: [], isCustomized: true, needsSync: true), for: "user")
        let client = WatchlistFixtureAPI(saved: ["ETHUSDT"])
        await client.setSaveFailure(true)
        let realtime = RealtimeClient(baseURL: URL(string: "https://example.invalid")!, tokenProvider: { nil })
        let model = DashboardViewModel(apiClient: client, realtimeClient: realtime, watchlistStore: preferences)
        model.startRealtime(userID: "user")
        defer { model.stopRealtime() }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.markets(onlyVisible: true).map(\.symbol), ["BTCUSDT"])
        XCTAssertEqual(preferences.load(for: "user")?.needsSync, true)
        await client.setSaveFailure(false)
        await model.loadSymbolCatalog(force: true)
        for _ in 0..<100 {
            if preferences.load(for: "user")?.needsSync == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let saved = await client.saved
        XCTAssertEqual(saved, ["BTCUSDT"])
        XCTAssertEqual(preferences.load(for: "user")?.needsSync, false)
    }

    func testFavoriteMembershipReorderAndLegacyPinsPersistAcrossRelaunch() async throws {
        let suite = "WatchlistInteractionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsMarketWatchlistStore(service: "test", defaults: defaults)
        preferences.save(.init(quoteAsset: "USDT", orderedSymbols: ["BTCUSDT", "ADAUSDT", "ETHUSDT", "SOLUSDT"],
            visibleSymbols: ["BTCUSDT", "ETHUSDT", "SOLUSDT"], pinnedSymbols: ["BTCUSDT"], isCustomized: true), for: "user")
        let client = WatchlistFixtureAPI()
        let realtime = RealtimeClient(baseURL: URL(string: "https://example.invalid")!, tokenProvider: { nil })
        let model = DashboardViewModel(apiClient: client, realtimeClient: realtime, watchlistStore: preferences)
        model.startRealtime(userID: "user")
        defer { model.stopRealtime() }
        await model.loadSymbolCatalog()
        XCTAssertFalse(model.markets.contains(where: \.isPinned))
        model.moveVisibleMarkets(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(model.markets(onlyVisible: true).map(\.symbol), ["ETHUSDT", "SOLUSDT", "BTCUSDT"])
        XCTAssertFalse(model.containsInWatchlist("ADAUSDT"))
        model.addToWatchlist("ADAUSDT")
        XCTAssertTrue(model.containsInWatchlist("ADAUSDT"))
        model.hideMarkets(["ETHUSDT"])
        model.moveMarketToTop("ADAUSDT")
        let saved = try XCTUnwrap(preferences.load(for: "user"))
        XCTAssertEqual(saved.visibleSymbols, ["SOLUSDT", "BTCUSDT", "ADAUSDT"])
        XCTAssertTrue(saved.pinnedSymbols.isEmpty)
        let restored = DashboardViewModel(realtimeClient: realtime, watchlistStore: preferences)
        restored.startRealtime(userID: "user")
        defer { restored.stopRealtime() }
        XCTAssertEqual(restored.markets(onlyVisible: true).map(\.symbol), ["ADAUSDT", "SOLUSDT", "BTCUSDT"])
    }

    func testCatalogIsSharedCachedAndDoesNotResetFavoritesOnRefreshFailure() async {
        let client = WatchlistFixtureAPI()
        let model = DashboardViewModel(markets: [MarketSnapshot(symbol: "BTCUSDT", quoteAsset: "USDT", price: 68000,
            changePercent24h: 0, updatedAt: .now)], apiClient: client)
        await model.loadSymbolCatalog()
        XCTAssertEqual(model.catalogSymbols, ["ADAUSDT", "BTCUSDT", "ETHUSDT", "SOLUSDT"])
        XCTAssertFalse(model.containsInWatchlist("ADAUSDT"))
        model.addToWatchlist("ADAUSDT")
        await model.loadSymbolCatalog()
        let calls = await client.catalogCalls
        XCTAssertEqual(calls, 1, "Opening another entry point should reuse the directory")
        await client.failCatalog()
        await model.loadSymbolCatalog(force: true)
        XCTAssertTrue(model.catalogLoadFailed)
        XCTAssertEqual(model.catalogSymbols.count, 4)
        XCTAssertTrue(model.containsInWatchlist("ADAUSDT"))
        XCTAssertEqual(model.tradeQuote(for: "BTCUSDT"), "68000")
    }
}

private actor WatchlistFixtureAPI: APIClient {
    private(set) var catalogCalls = 0
    private var fail = false
    private(set) var saved: [String]?
    private let catalog: [String]
    private var saveFailure = false
    init(saved: [String]? = nil, catalog: [String] = ["ADAUSDT", "BTCUSDT", "ETHUSDT", "SOLUSDT"]) {
        self.saved = saved
        self.catalog = catalog
    }
    func setSaveFailure(_ value: Bool) { saveFailure = value }
    func failCatalog() { fail = true }
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        let value: JSONValue
        switch request.path {
        case "/api/market/symbols":
            catalogCalls += 1
            if fail { throw URLError(.notConnectedToInternet) }
            value = .object(["quoteAsset": .string("USDT"), "symbols": .array(
                catalog.map(JSONValue.string))])
        case "/api/market/watchlist/defaults":
            value = .object(["quoteAsset": .string("USDT"), "symbols": .array((saved ?? ["BTCUSDT"]).map(JSONValue.string)),
                "availableSymbols": .array(catalog.map(JSONValue.string)), "isCustomized": .bool(saved != nil)])
        case "/api/market/watchlist":
            if saveFailure { throw URLError(.notConnectedToInternet) }
            saved = try JSONDecoder().decode([String: [String]].self, from: request.body ?? Data())["symbols"]
            value = .object([:])
        case "/api/market/tickers":
            value = .object(["quoteAsset": .string("USDT"), "tickers": .array([])])
        default: throw URLError(.unsupportedURL)
        }
        return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(value))
    }
}

@MainActor
final class RetainedTradeRiskTests: XCTestCase {
    func testCheckingAccountKeepsCachedRiskAndOnlyPublishesChanges() async {
        let api = RetainedRiskFixtureAPI()
        let store = USDTStore(api: api)
        await store.begin(userID: "retained-risk")
        XCTAssertEqual(store.riskAmount, "10")
        var amounts: [String] = []
        let observation = store.$account.dropFirst().sink { amounts.append($0.value("stop_loss_amount")) }
        defer { observation.cancel() }
        await store.refresh()
        XCTAssertTrue(amounts.isEmpty)
        await api.changeRisk("20")
        let refresh = Task { await store.refresh() }
        await api.waitForRead()
        XCTAssertEqual(store.riskAmount, "10", "Account checks must keep the previous amount visible")
        await api.completeRead()
        await refresh.value
        XCTAssertEqual(store.riskAmount, "20")
        XCTAssertEqual(amounts, ["20"])
    }
}

private actor RetainedRiskFixtureAPI: APIClient {
    private var risk = "10"
    private var gate = false
    private var read: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered = false
    func changeRisk(_ value: String) { risk = value; gate = true }
    func waitForRead() async {
        if entered { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func completeRead() { read?.resume(); read = nil }
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        let value: JSONValue
        switch request.path {
        case "/v1/api/info": value = .object(["id": .number(1)])
        case "/v1/account/info":
            if gate {
                entered = true
                waiting?.resume(); waiting = nil
                await withCheckedContinuation { read = $0 }
            }
            value = .object(["stop_loss_amount": .string(risk)])
        case "/v1/strategy/list": value = .array([])
        default: value = .object([:])
        }
        return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(value))
    }
}

final class ChartOrderTicketTests: XCTestCase {
    func draft(stop: String = "99", entry: String = "100", type: String = "market", fee: Bool = false) -> USDTEntryDraft {
        USDTEntryDraft(symbol: "BTCUSDT", orderType: type, stopLossPrice: stop,
            limitPrice: type == "limit" ? entry : "", currentPrice: entry, riskAmount: "10",
            includeFee: fee, strategy: nil)
    }
    func testChosenLeverageIsPartOfFrozenEntryIntentAndPayload() {
        var first = draft()
        first.leverage = 25
        XCTAssertEqual(first.payload()["leverage"], .number(25))
        var second = first
        second.leverage = 50
        XCTAssertFalse(first.matchesIntent(second))
        XCTAssertNil(draft().payload()["leverage"])
    }

    func testSharedDecimalSizingAndAutomaticDirection() {
        let long = draft()
        XCTAssertTrue(long.isLong)
        XCTAssertEqual(long.positionEstimate, 1000)
        XCTAssertEqual(long.feeText, "1")
        let short = draft(stop: "101")
        XCTAssertFalse(short.isLong)
        XCTAssertEqual(short.positionEstimate, long.positionEstimate)
        XCTAssertEqual(draft(fee: true).positionEstimate, Decimal(10) / Decimal(string: "0.011")!)
        for stop in ["100", "0", "-1", "NaN", "invalid"] {
            XCTAssertFalse(draft(stop: stop).isValid)
            XCTAssertEqual(draft(stop: stop).positionEstimate, 0)
        }
    }
    func testFrozenIntentAndOriginalCommandPayload() {
        let market = draft()
        let payload = market.payload()
        XCTAssertEqual(payload["stop_loss_price"], .string("99"))
        XCTAssertNil(payload["ema_check_id"], "Market entry no longer requires direction screening")
        XCTAssertNil(payload["strategy_id"], "No saved strategy means manual take-profit")
        XCTAssertNil(payload["strategy_config"])
        XCTAssertNil(payload["limit_price"])
        XCTAssertFalse(market.matchesIntent(draft(stop: "98")))
        XCTAssertFalse(market.matchesIntent(draft(stop: "99", entry: "98")))
        XCTAssertTrue(market.matchesIntent(draft(entry: "100.01")))
        let limit = draft(stop: "99", entry: "101", type: "limit")
        XCTAssertEqual(limit.payload()["limit_price"], .string("101"))
        XCTAssertNil(limit.payload()["ema_check_id"])
        XCTAssertEqual(payload["symbol"], .string("BTCUSDT"), "Editing another draft must not change the frozen request")
    }
    func testAutomaticTakeProfitSnapshotDoesNotLeakIntoManualDraft() {
        let strategy: JSONValue = .object(["id": .string("7"), "name": .string("长名称策略"),
            "levels": .array([.object(["profitRR": .string("2"), "reducePosition": .string("100")])])])
        let automatic = USDTEntryDraft(symbol: "BTCUSDT", orderType: "market", stopLossPrice: "99",
            limitPrice: "", currentPrice: "100", riskAmount: "10", includeFee: false, strategy: strategy)
        XCTAssertEqual(automatic.payload()["strategy_id"], .string("7"))
        XCTAssertEqual(automatic.payload()["strategy_config"], strategy["levels"])
        XCTAssertFalse(automatic.matchesIntent(draft()))
        XCTAssertNil(draft().payload()["strategy_id"])
        XCTAssertNil(draft(type: "limit").payload()["strategy_config"])
    }
    func testLimitDrawingCanCrossAndInferBothDirections() throws {
        var drawing = try XCTUnwrap(ChartOrderDrawingState.make(side: .long, entryOrderType: .limit, referencePrice: 100))
        drawing.allowsSideChange = true
        drawing.move(.entry, to: 100, within: 90...110)
        drawing.move(.stopLoss, to: 105, within: 90...110)
        XCTAssertEqual(drawing.inferredSide, .short)
        drawing.move(.stopLoss, to: 95, within: 90...110)
        XCTAssertEqual(drawing.inferredSide, .long)
        drawing.move(.entry, to: 94, within: 90...110)
        XCTAssertEqual(drawing.inferredSide, .short)
    }
    func testSubmittedLimitCannotMoveEitherPriceWithAnyDragMode() throws {
        for offscreen in [false, true] {
            for side in [ChartOrderSide.long, .short] {
                var drawing = try XCTUnwrap(ChartOrderDrawingState.make(side: side,
                    entryOrderType: .limit, referencePrice: 100))
                drawing.allowsSideChange = true
                drawing.isEditable = false
                let submitted = drawing
                for line in [ChartOrderLineKind.entry, .stopLoss] {
                    for price in [50.0, 95, 105, 150] {
                        drawing.move(line, to: price, within: 90...110, allowsOffscreenStopLoss: offscreen)
                        XCTAssertEqual(drawing, submitted, "A submitted price must not become a local draft edit")
                    }
                }
            }
        }
    }
    func testSquarePlotAndCompactPanelsAtAllScales() throws {
        for width in [320.0, 390, 440, 820] {
            for count in [0, 1, 2, 5] {
                for scale in [1.0, 2, 3] {
                    let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: width,
                        heightPoints: ChartPanelLayout.squareViewportHeightPoints(widthPoints: width, indicatorPanelCount: count),
                        displayScale: scale))
                    let layout = try XCTUnwrap(ChartPanelLayout.make(viewport: viewport,
                        indicatorPanelIDs: Array(["volume", "macd", "rsi", "obv", "atr"].prefix(count))))
                    let plot = try XCTUnwrap(layout.pricePanel?.plot)
                    XCTAssertEqual(plot.height, plot.width, accuracy: 0.001)
                    for panel in layout.indicatorPanels { XCTAssertEqual(panel.frame.height, Float(72 * scale)) }
                    XCTAssertEqual(layout.indicatorPanels.last?.frame.bottom ?? layout.timeAxisBottom, Float(viewport.heightPixels), accuracy: 0.001)
                }
            }
        }
    }
    func testIntervalFavoritesKeepDefaultsAndNormalizeStoredValues() {
        XCTAssertEqual(ChartIntervalPreferences.favorites(ChartIntervalPreferences.defaultValue).map(\.rawValue), ["3m", "5m", "15m", "1h", "4h", "1d"])
        XCTAssertEqual(ChartIntervalPreferences.toggling(.oneMinute, in: "1h"), "1m,1h")
        XCTAssertEqual(ChartIntervalPreferences.favorites("bad,1h,1h"), [.oneHour])
        XCTAssertEqual(ChartIntervalPreferences.favorites("bad"), ChartIntervalPreferences.favorites(ChartIntervalPreferences.defaultValue))
        XCTAssertEqual(MarketKlineInterval.threeMinutes.duration, 180)
    }

    func testIntervalFavoritesCanRemoveTheLastShortcutWithoutRestoringDefaults() {
        XCTAssertEqual(ChartIntervalPreferences.toggling(.oneHour, in: "1h"), "")
        XCTAssertTrue(ChartIntervalPreferences.favorites("").isEmpty)
        XCTAssertEqual(ChartIntervalPreferences.toggling(.oneMinute, in: ""), "1m")
    }

    func testIntervalShortcutsAllowSevenAndRejectTheEighth() {
        let defaults = ChartIntervalPreferences.defaultValue
        let seven = ChartIntervalPreferences.toggling(.oneMinute, in: defaults)
        XCTAssertEqual(ChartIntervalPreferences.favorites(seven).count, 7)
        XCTAssertTrue(ChartIntervalPreferences.favorites(seven).contains(.oneMinute))
        XCTAssertEqual(ChartIntervalPreferences.toggling(.thirtyMinutes, in: seven), seven)
        let removed = ChartIntervalPreferences.toggling(.oneDay, in: seven)
        let replaced = ChartIntervalPreferences.toggling(.thirtyMinutes, in: removed)
        XCTAssertEqual(ChartIntervalPreferences.favorites(replaced).count, 7)
        XCTAssertTrue(ChartIntervalPreferences.favorites(replaced).contains(.thirtyMinutes))
        XCTAssertFalse(ChartIntervalPreferences.favorites(replaced).contains(.oneDay))
    }

    func testIntervalFavoriteAndAlternativeGroupsMoveTogether() {
        let before = "3m,1h"
        let added = ChartIntervalPreferences.toggling(.oneMinute, in: before)
        let shown = ChartIntervalPreferences.favorites(added)
        let alternatives = MarketKlineInterval.allCases.filter { !shown.contains($0) }
        XCTAssertEqual(shown, [.oneMinute, .threeMinutes, .oneHour])
        XCTAssertFalse(alternatives.contains(.oneMinute))
        XCTAssertEqual(Set(shown).union(alternatives), Set(MarketKlineInterval.allCases))
        XCTAssertTrue(Set(shown).isDisjoint(with: alternatives))
        let removed = ChartIntervalPreferences.toggling(.threeMinutes, in: added)
        XCTAssertEqual(ChartIntervalPreferences.favorites(removed), [.oneMinute, .oneHour])
        XCTAssertFalse(ChartIntervalPreferences.favorites(removed).contains(.threeMinutes), "The current chart interval must not be silently inserted back into its shortcut list")
    }

    func testLegacyIntervalShortcutsAreLimitedToSevenWithoutLosingSupportedIntervals() {
        let legacy = MarketKlineInterval.allCases.map(\.rawValue).joined(separator: ",")
        XCTAssertEqual(ChartIntervalPreferences.favorites(legacy), Array(MarketKlineInterval.allCases.prefix(7)))
        for (interval, seconds) in [(MarketKlineInterval.thirtyMinutes, 1800), (.twoHours, 7200),
            (.eightHours, 28800), (.sixteenHours, 57600), (.threeDays, 259200), (.oneWeek, 604800)] {
            XCTAssertEqual(interval.duration, Double(seconds))
        }
    }
}

final class StrategyDraftEditingTests: XCTestCase {
    func testClearingReductionKeepsSelectionAndIndependentStopDrafts() {
        var level = USDTStrategyLevel()
        level.reduce = ""
        XCTAssertTrue(level.reduceEnabled)
        XCTAssertEqual(level.payload["reducePosition"], .string(""))
        level.absoluteStop = "2"
        level.trailingStop = "1.5"
        level.stopType = "fixedRR"
        XCTAssertEqual(level.absoluteStop, "2")
        XCTAssertEqual(level.payload["stopLossRR"], .string("1.5"))
        XCTAssertNil(level.payload["stopLossAbsoluteRR"])
        level.stopType = "absoluteRR"
        XCTAssertEqual(level.payload["stopLossAbsoluteRR"], .string("2"))
        XCTAssertNil(level.payload["stopLossRR"])
        level.reduceEnabled = false
        XCTAssertEqual(level.payload["reducePosition"], .string("0"))
    }

    func testStrategySummaryPreservesValueWithoutMoneyPrecisionOrTrailingZeros() {
        let level: JSONValue = .object(["profitRR": .string("1.5000"), "reducePosition": .string("20.000"),
            "stopLossType": .string("absoluteRR"), "stopLossAbsoluteRR": .string("0.25000")])
        XCTAssertEqual(WebStrategyText.level(level, index: 0), "L1：当 RR≥1.5，卖出 20%，止损位移动到 0.25R 处")
        XCTAssertEqual(WebStrategyText.wholePercent(80), "80")
        XCTAssertFalse(WebStrategyText.isWhole(Decimal(string: "20.5")!))
    }

    @MainActor
    func testBackendMaximumIsShownByDefaultAndExplicitChoiceWinsUntilScopeReset() async {
        let store = USDTStore(api: LeverageDefaultTestAPI())
        await store.loadDefaultLeverage(for: "BTCUSDT")
        XCTAssertEqual(store.displayedLeverage(for: "BTCUSDT"), 125)
        XCTAssertNil(store.selectedLeverage(for: "BTCUSDT"), "The default keeps backend automatic maximum selection")
        store.selectLeverage(25, for: "BTCUSDT")
        await store.loadDefaultLeverage(for: "BTCUSDT")
        XCTAssertEqual(store.displayedLeverage(for: "BTCUSDT"), 25)
        store.invalidate()
        XCTAssertNil(store.displayedLeverage(for: "BTCUSDT"))
    }
}

private actor LeverageDefaultTestAPI: APIClient {
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        let value: JSONValue = .object(["max_leverage": .number(125)])
        return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(value))
    }
}

@MainActor
final class StrategySelectionReloadTests: XCTestCase {
    func testSelectionReloadWinsOverAnEarlierPageRefresh() async throws {
        let api = GatedStrategySelectionAPI()
        let store = USDTStore(api: api)
        store.prepareSession(userID: UUID().uuidString)
        let initial = Task { await store.refresh(includeAccount: false) }
        await api.waitForFirstRead()
        try await store.reloadStrategies()
        XCTAssertEqual(store.activeStrategy?.value("id"), "2")
        await api.completeFirstRead()
        await initial.value
        XCTAssertEqual(store.activeStrategy?.value("id"), "2", "An older page response must not undo the new selection")
    }

    func testSelectionReloadCannotPopulateAnotherAccount() async throws {
        let api = GatedStrategySelectionAPI()
        let store = USDTStore(api: api)
        store.prepareSession(userID: UUID().uuidString)
        let pending = Task { try await store.reloadStrategies() }
        await api.waitForFirstRead()
        store.prepareSession(userID: UUID().uuidString)
        await api.completeFirstRead()
        do {
            try await pending.value
            XCTFail("The previous account's response must be rejected")
        } catch is CancellationError { }
        XCTAssertTrue(store.strategies.isEmpty)
    }
}

private actor GatedStrategySelectionAPI: APIClient {
    private var reads = 0
    private var firstRead: CheckedContinuation<Void, Never>?
    private var readStarted: CheckedContinuation<Void, Never>?
    func waitForFirstRead() async {
        if firstRead != nil { return }
        await withCheckedContinuation { readStarted = $0 }
    }
    func completeFirstRead() { firstRead?.resume(); firstRead = nil }
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        let value: JSONValue
        if request.path == "/v1/strategy/list" {
            reads += 1
            let id = reads == 1 ? 1 : 2
            if reads == 1 {
                await withCheckedContinuation {
                    firstRead = $0
                    readStarted?.resume(); readStarted = nil
                }
            }
            value = .array([.object(["id": .number(Double(id)), "is_active": .bool(true)])])
        } else {
            value = .object([:])
        }
        return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(value))
    }
}

@MainActor
final class SignalUnreadBadgeTests: XCTestCase {
    func testUnreadAndReadCursorsSurviveRelaunchWithoutAReadEndpoint() async throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = SignalBadgeFixtureAPI(id: 100)
        let store = USDTStore(api: api, signalReadDefaults: defaults)
        store.prepareSession(userID: "badge-user", signalReadNamespace: "server-a")
        await store.refreshSignalBadge()
        XCTAssertTrue(store.hasUnreadSignals)
        let recordedRequest = await api.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.0, "/v1/trade/tradingview/signals")
        XCTAssertEqual(request.1, [.init(name: "source", value: "internal"), .init(name: "limit", value: "1")])

        let relaunched = USDTStore(api: api, signalReadDefaults: defaults)
        relaunched.prepareSession(userID: "badge-user", signalReadNamespace: "server-a")
        XCTAssertTrue(relaunched.hasUnreadSignals, "An offline relaunch must retain the red dot")
        relaunched.setSignalPageVisible(true)
        XCTAssertFalse(relaunched.hasUnreadSignals)
        relaunched.setSignalPageVisible(false)

        let readAgain = USDTStore(api: api, signalReadDefaults: defaults)
        readAgain.prepareSession(userID: "badge-user", signalReadNamespace: "server-a")
        await readAgain.refreshSignalBadge()
        XCTAssertFalse(readAgain.hasUnreadSignals, "The same message must stay read")
        await api.setID(101)
        await readAgain.refreshSignalBadge()
        XCTAssertTrue(readAgain.hasUnreadSignals)
    }

    func testVisibleArrivalsAreReadAndOlderSnapshotsDoNotRestoreTheDot() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = USDTStore(api: SignalBadgeFixtureAPI(), signalReadDefaults: defaults)
        store.prepareSession(userID: "badge-user")
        store.recordSignalSnapshot(rows(10))
        XCTAssertTrue(store.hasUnreadSignals)
        store.setSignalPageVisible(true)
        store.recordSignalSnapshot(rows(12))
        XCTAssertFalse(store.hasUnreadSignals)
        store.setSignalPageVisible(false)
        store.recordSignalSnapshot(rows(11))
        XCTAssertFalse(store.hasUnreadSignals)
        store.recordSignalSnapshot(rows(13))
        XCTAssertTrue(store.hasUnreadSignals)
        store.recordSignalSnapshot(rows(12), markRead: true)
        XCTAssertFalse(store.hasUnreadSignals, "Reading the page acknowledges arrivals discovered by the badge probe too")
    }

    func testReadStateIsIsolatedByUserAndServerAndSurvivesLeadMode() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = USDTStore(api: SignalBadgeFixtureAPI(), signalReadDefaults: defaults)
        store.prepareSession(userID: "user-a", signalReadNamespace: "server-a")
        store.recordSignalSnapshot(rows(10), markRead: true)
        store.prepareSession(userID: "user-b", signalReadNamespace: "server-a")
        store.recordSignalSnapshot(rows(10))
        XCTAssertTrue(store.hasUnreadSignals)
        store.prepareSession(userID: "user-a", signalReadNamespace: "server-b")
        XCTAssertFalse(store.hasUnreadSignals)
        store.recordSignalSnapshot(rows(10))
        XCTAssertTrue(store.hasUnreadSignals)
        store.prepareSession(userID: "user-a", signalReadNamespace: "server-a")
        XCTAssertFalse(store.hasUnreadSignals)
        store.recordSignalSnapshot(rows(11))
        store.mode = "lead"
        store.recordSignalSnapshot(rows(12), markRead: true)
        store.mode = "ordinary"
        XCTAssertTrue(store.hasUnreadSignals, "Lead mode must not erase the ordinary account's unread cursor")
        store.setSignalPageVisible(true)
        store.setSignalPageVisible(false)
        store.prepareSession(userID: "user-b", signalReadNamespace: "server-a")
        XCTAssertTrue(store.hasUnreadSignals, "Reading user-a must not acknowledge user-b")
    }

    func testLateBadgeResponseCannotWriteAnotherAccountOrItsPreviousCursor() async {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = GatedSignalBadgeAPI()
        let store = USDTStore(api: api, signalReadDefaults: defaults)
        store.prepareSession(userID: "old-user")
        let pending = Task { await store.refreshSignalBadge() }
        await api.waitForRead()
        store.prepareSession(userID: "new-user")
        await api.completeRead()
        await pending.value
        XCTAssertFalse(store.hasUnreadSignals)
        store.prepareSession(userID: "old-user")
        XCTAssertFalse(store.hasUnreadSignals, "A response rejected after switching must not persist under either account")
    }

    func testCancelledAndMalformedReadsDoNotCreateUnreadState() async {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = GatedSignalBadgeAPI()
        let store = USDTStore(api: api, signalReadDefaults: defaults)
        store.prepareSession(userID: "badge-user")
        let pending = Task { await store.refreshSignalBadge() }
        await api.waitForRead()
        pending.cancel()
        await api.completeRead()
        await pending.value
        store.recordSignalSnapshot([.object(["id": .string("not-an-integer")]),
            .object(["id": .string("9223372036854775808")]),
            .object(["id": .number(99), "source": .string("external")])])
        XCTAssertFalse(store.hasUnreadSignals)
        store.recordSignalSnapshot([.object(["id": .string("9223372036854775806")])])
        XCTAssertTrue(store.hasUnreadSignals, "IDs must use Int64 rather than a rounded floating-point cursor")
    }

    private func rows(_ id: Int) -> [JSONValue] { [.object(["id": .number(Double(id)), "source": .string("internal")])] }
    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "SignalUnreadBadgeTests." + UUID().uuidString
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

private actor SignalBadgeFixtureAPI: APIClient {
    private var id: Int
    private var request: (String, [URLQueryItem])?
    init(id: Int = 1) { self.id = id }
    func setID(_ id: Int) { self.id = id }
    func lastRequest() -> (String, [URLQueryItem])? { request }
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        self.request = (request.path, request.queryItems)
        let value: JSONValue = .array([.object(["id": .number(Double(id)), "source": .string("internal")])])
        return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(value))
    }
}

private actor GatedSignalBadgeAPI: APIClient {
    private var pending: CheckedContinuation<Void, Never>?
    private var readStarted: CheckedContinuation<Void, Never>?
    func waitForRead() async {
        if pending != nil { return }
        await withCheckedContinuation { readStarted = $0 }
    }
    func completeRead() { pending?.resume(); pending = nil }
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        await withCheckedContinuation {
            pending = $0
            readStarted?.resume(); readStarted = nil
        }
        let value: JSONValue = .array([.object(["id": .number(99), "source": .string("internal")])])
        return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(value))
    }
}

@MainActor
final class ProfileRefreshCancellationTests: XCTestCase {
    func testCancellationFormsKeepCachedBalanceWithoutAnErrorNotice() async {
        for failure in [ProfileRefreshFixtureAPI.Failure.taskCancelled, .urlCancelled, .apiCancelled] {
            let api = ProfileRefreshFixtureAPI()
            let store = USDTStore(api: api)
            store.prepareSession(userID: UUID().uuidString)
            await store.refresh()
            let cached = store.account
            await api.failNextRead(failure)
            await store.refresh()
            XCTAssertEqual(store.account, cached)
            XCTAssertEqual(store.notice, "", "Cancelling a page read is not a user-facing failure")
            XCTAssertFalse(store.isLoading)
        }
    }

    func testRealFailureRemainsVisibleAndSuccessfulRetryClearsIt() async {
        let api = ProfileRefreshFixtureAPI()
        let store = USDTStore(api: api)
        store.prepareSession(userID: UUID().uuidString)
        await store.refresh()
        await api.failNextRead(.timeout)
        await store.refresh()
        XCTAssertEqual(store.notice, APIError.timeout.userMessage)
        XCTAssertEqual(store.account.value("balance"), "100")
        await store.refresh()
        XCTAssertEqual(store.notice, "")
    }

    func testCancelledRefreshRejectsAResponseThatIgnoresTransportCancellation() async {
        let api = ProfileRefreshFixtureAPI()
        let store = USDTStore(api: api)
        store.prepareSession(userID: UUID().uuidString)
        await store.refresh()
        await api.gateNextRead(balance: "200")
        let pending = Task { await store.refresh() }
        await api.waitForRead()
        pending.cancel()
        await api.completeRead()
        await pending.value
        XCTAssertEqual(store.account.value("balance"), "100")
        XCTAssertEqual(store.notice, "")
        XCTAssertFalse(store.isLoading)
    }
}

private actor ProfileRefreshFixtureAPI: APIClient {
    enum Failure {
        case taskCancelled, urlCancelled, apiCancelled, timeout
        var error: Error {
            switch self {
            case .taskCancelled: CancellationError()
            case .urlCancelled: URLError(.cancelled)
            case .apiCancelled: APIError.cancelled
            case .timeout: APIError.timeout
            }
        }
    }
    private var nextFailure: Failure?
    private var balance = "100"
    private var gated = false
    private var pending: CheckedContinuation<Void, Never>?
    private var readStarted: CheckedContinuation<Void, Never>?
    func failNextRead(_ failure: Failure) { nextFailure = failure }
    func gateNextRead(balance: String) { self.balance = balance; gated = true }
    func waitForRead() async {
        if pending != nil { return }
        await withCheckedContinuation { readStarted = $0 }
    }
    func completeRead() { pending?.resume(); pending = nil }
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        let value: JSONValue
        switch request.path {
        case "/v1/api/info": value = .object(["id": .number(1)])
        case "/v1/account/info":
            if let failure = nextFailure { nextFailure = nil; throw failure.error }
            if gated {
                gated = false
                await withCheckedContinuation {
                    pending = $0
                    readStarted?.resume(); readStarted = nil
                }
            }
            value = .object(["balance": .string(balance)])
        case "/v1/strategy/list": value = .array([])
        default: value = .object([:])
        }
        return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(value))
    }
}

@MainActor
final class OrderCardPresentationTests: XCTestCase {
    private func row(kind: String = "maker", status: JSONValue? = .number(0),
                     source: JSONValue? = .number(42), request: String = "maker-original-request",
                     filled: JSONValue = .string("0"), amount: JSONValue = .string("0"),
                     average: JSONValue = .null) -> JSONValue {
        var fields: [String: JSONValue] = ["id": .string("\(kind):42"), "record_key": .string("\(kind):42"),
            "order_kind": .string(kind), "client_request_id": .string(request), "symbol": .string("SOLUSDT"),
            "can_cancel": .bool(true), "can_chase": .bool(true), "limit_price": .string("100"),
            "size": .string("1"), "filled_size": filled, "filled_amount": amount,
            "average_price": average, "position_amount": .string("100")]
        fields["status"] = status; fields["source_id"] = source
        return .object(fields)
    }
    func testMakerUsesOriginalRequestIdentityForCancelOnly() {
        let value = OrderCardPresentation(row: row())
        XCTAssertEqual(value.recordKey, "maker:42")
        XCTAssertEqual(value.kindText, "Maker")
        XCTAssertTrue(value.canCancel)
        XCTAssertFalse(value.canChase)
        XCTAssertEqual(value.cancelAction, "maker-fallback")
        XCTAssertEqual(value.cancelPayload?["client_request_id"], .string("maker-original-request"))
        XCTAssertEqual(value.cancelPayload?["cancel_only"], .bool(true))
        XCTAssertNil(value.cancelPayload?["limit_order_id"])
    }
    func testLimitActionsUseSourceNumberInsteadOfNamespacedRecordID() {
        let value = OrderCardPresentation(row: row(kind: "limit"))
        XCTAssertTrue(value.canCancel); XCTAssertTrue(value.canChase)
        XCTAssertEqual(value.kindText, "限价")
        XCTAssertEqual(value.cancelAction, "limit-cancel")
        XCTAssertEqual(value.cancelPayload?["limit_order_id"], .number(42))
        XCTAssertEqual(value.chasePayload?["limit_order_id"], .number(42))
    }
    func testFilledCancelledExpiredUnknownAndMissingStatesCannotMutateEvenWithFlags() {
        for kind in ["maker", "limit"] {
            for state: JSONValue? in [.number(1), .number(2), .number(3), .number(4), .number(99), .null, nil] {
                let value = OrderCardPresentation(row: row(kind: kind, status: state))
                XCTAssertFalse(value.canCancel, "\(kind) \(String(describing: state))")
                XCTAssertFalse(value.canChase)
                XCTAssertNil(value.cancelPayload)
                XCTAssertNil(value.chasePayload)
            }
        }
    }
    func testPartialQuantityHasBaseAssetUnitsAndMoneyHasQuoteUnits() {
        let value = OrderCardPresentation(row: row(filled: .string("0.5"), amount: .string("50"), average: .string("100")))
        XCTAssertEqual(value.filledQuantityText, "0.5 / 1 SOL")
        XCTAssertEqual(value.filledAmountText, "50U")
        XCTAssertEqual(value.averagePriceText, "100.00")
    }
    func testMissingFillPriceAndAmountRemainUnknownDespiteKnownQuantity() {
        let value = OrderCardPresentation(row: row(status: .number(1), filled: .string("1"), amount: .null))
        XCTAssertEqual(value.filledQuantityText, "1 / 1 SOL")
        XCTAssertEqual(value.filledAmountText, "--")
        XCTAssertEqual(value.averagePriceText, "--")
        XCTAssertFalse(value.canCancel)
    }
    func testZeroUnfilledAmountDoesNotClaimAZeroAveragePrice() {
        let value = OrderCardPresentation(row: row(average: .string("0")))
        XCTAssertEqual(value.filledAmountText, "0U")
        XCTAssertEqual(value.averagePriceText, "--")
    }
    func testUnknownKindOrMissingOperationIdentityCannotMutate() {
        for value in [OrderCardPresentation(row: row(kind: "other")),
                      OrderCardPresentation(row: row(request: "")),
                      OrderCardPresentation(row: row(request: "   ")),
                      OrderCardPresentation(row: row(kind: "limit", source: nil)),
                      OrderCardPresentation(row: row(kind: "limit", source: .string("limit:42"))),
                      OrderCardPresentation(row: row(kind: "limit", source: .number(0))),
                      OrderCardPresentation(row: row(kind: "limit", source: .number(42.5)))] {
            XCTAssertFalse(value.canCancel); XCTAssertFalse(value.canChase)
        }
        for identity: JSONValue? in [.null, .number(42), nil] {
            var fields = row().fields
            fields["client_request_id"] = identity
            let value = OrderCardPresentation(row: .object(fields))
            XCTAssertFalse(value.canCancel); XCTAssertFalse(value.canChase)
        }
    }
    func testExplicitBaseAssetAndInvalidMoneyNeverUseQuantityAsNotional() {
        var fields = row(filled: .string("0.5"), amount: .string("NaN")).fields
        fields["base_asset"] = .string("1000PEPE"); fields["symbol"] = .string("1000PEPEUSDT")
        fields["position_amount"] = .null
        let value = OrderCardPresentation(row: .object(fields))
        XCTAssertEqual(value.filledQuantityText, "0.5 / 1 1000PEPE")
        XCTAssertEqual(value.filledAmountText, "--")
        XCTAssertEqual(value.orderAmountText, "--")
    }
}
