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

@MainActor
final class MarketFastPathTests: XCTestCase {
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

    private func makeChart(_ api: any APIClient) -> MarketChartViewModel {
        let market = MarketSnapshot(symbol: "BTCUSDT", quoteAsset: "USDT", price: 100,
            changePercent24h: 0, updatedAt: .now)
        return MarketChartViewModel(market: market, apiClient: api,
            realtimeClient: RealtimeClient(baseURL: URL(string: "http://127.0.0.1")!, tokenProvider: { nil }))
    }

    private func liveKline() -> RealtimeServerMessage {
        let at = Int64(Date().timeIntervalSince1970 * 1000) / 3_600_000 * 3_600_000
        let data: JSONValue = .object([
            "symbol": .string("BTCUSDT"), "contractType": .string("PERPETUAL"), "interval": .string("1h"),
            "openTime": .number(Double(at)), "closeTime": .number(Double(at + 3_599_999)),
            "openPrice": .number(100), "highPrice": .number(110), "lowPrice": .number(99),
            "closePrice": .number(105), "volume": .number(1), "quoteVolume": .number(100),
            "closed": .bool(false), "eventTime": .number(Double(at + 1000))])
        return RealtimeServerMessage(version: 1, type: "event", requestId: nil,
            channel: "market.kline", event: "upsert", key: "BTCUSDT:1h", sequence: 1,
            timestamp: at + 1000, data: data, error: nil)
    }

    private func notice(symbol: String, interval: String = "1h") -> RealtimeServerMessage {
        RealtimeServerMessage(version: 1, type: "event", requestId: nil, channel: "market.history",
            event: "upsert", key: nil, sequence: 1, timestamp: 1,
            data: .object(["symbol": .string(symbol), "interval": .string(interval), "kind": .string("history")]), error: nil)
    }

    private func ack(symbol: String, interval: String) -> RealtimeServerMessage {
        let data = Data("""
        {"version":1,"type":"ack","timestamp":1,"data":{"subscriptions":[{"channel":"market.history","filters":{"symbols":["\(symbol)"],"intervals":["\(interval)"]}}]}}
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

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate())
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
    private var isOpen = false
    private var waiting: [Int: CheckedContinuation<Void, Error>] = [:]
    private let ignoresCancellation: Bool
    private let onFirstRead: @Sendable () -> Void
    private let onCancelled: @Sendable () -> Void

    init(onFirstRead: @escaping @Sendable () -> Void = {}, onCancelled: @escaping @Sendable () -> Void = {},
         ignoresCancellation: Bool = false) {
        self.ignoresCancellation = ignoresCancellation
        self.onFirstRead = onFirstRead
        self.onCancelled = onCancelled
    }

    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        guard request.path == "/api/market/klines" else { throw APIError.invalidResponse }
        reads += 1
        let read = reads
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
        let width: Int64 = interval == "5m" ? 300_000 : 3_600_000
        let end = before ?? Int64(Date().timeIntervalSince1970 * 1000) / width * width
        let rows = (1...32).reversed().map { index in
            MarketCandle(openTime: end - Int64(index) * width,
                closeTime: end - Int64(index - 1) * width - 1,
                openPrice: 100, highPrice: 110, lowPrice: 99, closePrice: Double(100 + read), volume: 1, quoteVolume: 100)
        }
        return MarketKlineHistoryResponse(symbol: "BTCUSDT", interval: interval, items: rows,
            historyPending: before != nil && !isOpen, hasMoreHistory: true) as! Response
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
    func testSharedDecimalSizingAndAutomaticDirection() {
        let long = draft()
        XCTAssertTrue(long.isLong)
        XCTAssertEqual(long.positionEstimate, 1000)
        XCTAssertEqual(long.feeText, "1.000")
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
        let payload = market.payload(ema: .object(["check_id": .string("screening")]))
        XCTAssertEqual(payload["stop_loss_price"], .string("99"))
        XCTAssertEqual(payload["ema_check_id"], .string("screening"))
        XCTAssertNil(payload["limit_price"])
        XCTAssertFalse(market.matchesIntent(draft(stop: "98")))
        XCTAssertFalse(market.matchesIntent(draft(stop: "99", entry: "98")))
        XCTAssertTrue(market.matchesIntent(draft(entry: "100.01")))
        let limit = draft(stop: "99", entry: "101", type: "limit")
        XCTAssertEqual(limit.payload(ema: .null)["limit_price"], .string("101"))
        XCTAssertNil(limit.payload(ema: .null)["ema_check_id"])
        XCTAssertEqual(payload["symbol"], .string("BTCUSDT"), "Editing another draft must not change the frozen request")
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
    func testIntervalFavoritesKeepAtLeastOneAndRetainCurrentSelection() {
        XCTAssertEqual(ChartIntervalPreferences.favorites(ChartIntervalPreferences.defaultValue).map(\.rawValue), ["3m", "5m", "15m", "1h", "4h", "1d"])
        XCTAssertEqual(ChartIntervalPreferences.toggling(.oneHour, in: "1h"), "1h")
        XCTAssertEqual(ChartIntervalPreferences.toggling(.oneMinute, in: "1h"), "1m,1h")
        XCTAssertEqual(ChartIntervalPreferences.visible("1h", selected: .threeMinutes).map(\.rawValue), ["3m", "1h"])
        XCTAssertEqual(ChartIntervalPreferences.favorites("bad,1h,1h"), [.oneHour])
        XCTAssertFalse(ChartIntervalPreferences.favorites("").isEmpty)
        XCTAssertEqual(MarketKlineInterval.threeMinutes.duration, 180)
    }
}
