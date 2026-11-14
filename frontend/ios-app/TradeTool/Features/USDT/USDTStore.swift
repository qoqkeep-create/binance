import Foundation
import Combine
import SwiftUI

extension JSONValue {
    var text: String {
        switch self {
        case let .string(value): return value
        case let .number(value): return value.rounded() == value ? String(format: "%.0f", value) : String(value)
        case let .bool(value): return value ? "是" : "否"
        case .null: return "--"
        default: return ""
        }
    }
    var rows: [JSONValue] { if case let .array(value) = self { return value }; return [] }
    var fields: [String: JSONValue] { if case let .object(value) = self { return value }; return [:] }
    var flag: Bool { if case let .bool(value) = self { return value }; return false }
    func value(_ key: String, fallback: String = "--") -> String { self[key]?.text ?? fallback }
    var decimal: Decimal? { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) }
}

@MainActor
enum NativeTradingMode {
    static var userID = ""
    static var current: String {
        get { UserDefaults.standard.string(forKey: "integrated.mode.\(userID)") ?? "ordinary" }
        set { UserDefaults.standard.set(newValue, forKey: "integrated.mode.\(userID)") }
    }
}

/// List IDs are the server's monotonically increasing message IDs, not APNs UUIDs.
private struct LocalSignalReadCursor: Codable, Equatable {
    var latestID: Int64 = 0
    var readThroughID: Int64 = 0
    var hasUnread: Bool { latestID > readThroughID }
}

@MainActor
final class USDTStore: ObservableObject {
    let api: any APIClient
    let positionSnapshots = FloatingPositionsModel()
    let positionQuotes = PositionLiveQuotes()
    private var positionObservers: Set<AnyCancellable> = []
    @Published var mode = "ordinary"
    @Published var revision = 0
    @Published var account: JSONValue = .object([:])
    @Published var profile: JSONValue = .object([:])
    @Published var binding: JSONValue = .null
    @Published var strategies: [JSONValue] = []
    @Published private(set) var selectedLeverages: [String: Int] = [:]
    @Published private(set) var defaultLeverages: [String: Int] = [:]
    func selectedLeverage(for symbol: String) -> Int? { selectedLeverages[symbol.uppercased()] }
    func displayedLeverage(for symbol: String) -> Int? {
        selectedLeverage(for: symbol) ?? defaultLeverages[symbol.uppercased()]
    }
    func selectLeverage(_ leverage: Int, for symbol: String) { selectedLeverages[symbol.uppercased()] = leverage }
    func loadDefaultLeverage(for symbol: String) async {
        let key = symbol.uppercased()
        guard defaultLeverages[key] == nil else { return }
        let requestScope = scope
        do {
            let value = try await get("/v1/trade/symbol/info", query: [.init(name: "symbol", value: key)])
            guard requestScope == scope, let maximum = Int(value.value("max_leverage")), maximum > 0 else { return }
            defaultLeverages[key] = maximum
        } catch { }
    }
    @Published var selectedSymbol = "BTCUSDT"
    @Published var notice = ""
    @Published var isLoading = false
    @Published var liveRevision = 0
    @Published private(set) var positionDataRevision = 0
    @Published private(set) var hasUnreadSignals = false
    private var userID = ""
    private let signalReadDefaults: UserDefaults
    private var signalReadNamespace = "default"
    private var signalReadCursor = LocalSignalReadCursor()
    private var signalPageVisible = false
    private var refreshScope = ""
    private var refreshCompletion: SharedReadCompletion?
    private var strategyReadRevision = 0
    private var eventRefresh: Task<Void, Never>?
    var scope: String { "\(userID):\(mode):\(revision)" }
    var isBound: Bool { if case .null = binding { return false }; return !binding.fields.isEmpty }
    var riskAmount: String { account.value("stop_loss_amount", fallback: "") }
    var activeStrategy: JSONValue? { strategies.first { $0["is_active"]?.flag == true } }

    init(api: any APIClient, signalReadDefaults: UserDefaults = .standard) {
        self.api = api
        self.signalReadDefaults = signalReadDefaults
        // EnvironmentObject consumers observe the store; forward its shared child publications too.
        positionSnapshots.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &positionObservers)
        positionQuotes.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &positionObservers)
    }

    func begin(userID: String) async {
        prepareSession(userID: userID)
        await refresh()
    }

    func prepareSession(userID: String, signalReadNamespace: String = "default") {
        let identityChanged = self.userID != userID || self.signalReadNamespace != signalReadNamespace
        if identityChanged { invalidate() }
        self.userID = userID
        self.signalReadNamespace = signalReadNamespace
        NativeTradingMode.userID = userID
        mode = NativeTradingMode.current
        if identityChanged {
            signalReadCursor = signalReadDefaults.data(forKey: signalReadStorageKey)
                .flatMap { try? JSONDecoder().decode(LocalSignalReadCursor.self, from: $0) }
                ?? LocalSignalReadCursor()
            hasUnreadSignals = signalReadCursor.hasUnread
        }
    }

    /// Only the latest record is needed for the tab badge; the retained page owns its list.
    func refreshSignalBadge() async {
        guard !userID.isEmpty, mode == "ordinary" else { return }
        let requestScope = scope
        do {
            let result = try await get("/v1/trade/tradingview/signals", query: [
                .init(name: "source", value: "internal"), .init(name: "limit", value: "1"),
            ])
            guard requestScope == scope, !Task.isCancelled else { return }
            recordSignalSnapshot(result.rows)
        } catch { }
    }

    func setSignalPageVisible(_ visible: Bool) {
        signalPageVisible = visible
        if visible { recordSignalSnapshot([], markRead: true) }
    }

    func recordSignalSnapshot(_ rows: [JSONValue], markRead: Bool = false) {
        guard !userID.isEmpty, mode == "ordinary" else { return }
        let previous = signalReadCursor
        let newestID = rows.compactMap { row -> Int64? in
            guard row.value("source", fallback: "internal") == "internal" else { return nil }
            return Int64(row.value("id"))
        }.max() ?? 0
        signalReadCursor.latestID = max(signalReadCursor.latestID, newestID)
        if markRead || signalPageVisible {
            signalReadCursor.readThroughID = signalReadCursor.latestID
        }
        hasUnreadSignals = signalReadCursor.hasUnread
        if previous != signalReadCursor, let data = try? JSONEncoder().encode(signalReadCursor) {
            signalReadDefaults.set(data, forKey: signalReadStorageKey)
        }
    }

    private var signalReadStorageKey: String {
        let identity = Data((signalReadNamespace + "|" + userID).utf8).base64EncodedString()
        return "integrated.signalRead.v1." + identity
    }

    func switchMode(_ value: String) {
        guard value != mode else { return }
        mode = value
        NativeTradingMode.current = value
        invalidate()
        Task { await refresh() }
    }

    func invalidate() {
        stopRealtime()
        refreshCompletion?.finish()
        refreshCompletion = nil
        refreshScope = ""
        isLoading = false
        revision += 1
        positionSnapshots.reset(scope: scope)
        positionQuotes.reset()
        selectedLeverages = [:]
        defaultLeverages = [:]
        account = .object([:]); profile = .object([:]); binding = .null; strategies = []; notice = ""
    }

    func stopRealtime() { eventRefresh?.cancel(); eventRefresh = nil }

    func receive(_ event: RealtimeServerMessage) {
        guard event.type == "ready" || (event.type == "event" && event.channel?.hasPrefix("trading.") == true) else { return }
        guard eventRefresh == nil else { return }
        let eventScope = scope
        eventRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, eventScope == self.scope else { return }
            self.eventRefresh = nil
            // Position/risk reads must not wait for profile and strategy requests.
            self.positionDataRevision += 1
            await self.refresh(includeAccount: false)
            guard eventScope == self.scope, !Task.isCancelled else { return }
            self.liveRevision += 1
        }
    }

    func refreshPositions() async {
        guard isBound else { return }
        if positionSnapshots.scope != scope { positionSnapshots.reset(scope: scope) }
        await positionSnapshots.refresh(self)
    }

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        let requestScope = scope
        let value = try await api.send(APIRequest<JSONValue>(path: path, queryItems: query,
            headers: ["X-Trading-Mode": mode], showsErrorToast: false))
        guard requestScope == scope else { throw CancellationError() }
        return value
    }

    func send(_ path: String, _ body: [String: JSONValue] = [:], method: HTTPMethod = .post) async throws -> JSONValue {
        let requestScope = scope
        let request = try APIRequest<JSONValue>.json(path: path, method: method, body: body,
            headers: ["X-Trading-Mode": mode], showsErrorToast: false, timeoutInterval: 60)
        let result = try await api.send(request)
        guard requestScope == scope else { throw CancellationError() }
        return result
    }

    func refresh(includeAccount: Bool = true, freshBalance: Bool = false) async {
        let requestScope = scope
        if isLoading, refreshScope == requestScope {
            await refreshCompletion?.wait()
            return
        }
        guard !Task.isCancelled else { return }
        let completion = SharedReadCompletion()
        refreshCompletion?.finish()
        refreshCompletion = completion
        refreshScope = requestScope
        isLoading = true
        defer {
            if refreshCompletion === completion { isLoading = false; refreshCompletion = nil }
            completion.finish()
        }
        do {
            let latestBinding = try await get("/v1/api/info")
            guard requestScope == scope, !Task.isCancelled else { return }
            if binding != latestBinding { binding = latestBinding }
            async let info = includeAccount
                ? get("/v1/account/info", query: freshBalance ? [.init(name: "fresh", value: "1")] : [])
                : account
            async let user = get("/v1/account/profile")
            let strategyRevision = strategyReadRevision
            async let plans = get("/v1/strategy/list")
            let values = try await (info, user, plans)
            guard requestScope == scope, !Task.isCancelled else { return }
            if includeAccount, account != values.0 { account = values.0 }
            if profile != values.1 { profile = values.1 }
            if strategyRevision == strategyReadRevision, strategies != values.2.rows { strategies = values.2.rows }
            notice = ""
        } catch {
            guard requestScope == scope, !Task.isCancelled else { return }
            let apiError = APIError.map(error)
            if apiError.shouldPresent { notice = apiError.userMessage }
        }
    }

    /// A saved selection must re-read the list even while the page's initial refresh is in flight.
    func reloadStrategies() async throws {
        let requestScope = scope
        strategyReadRevision += 1
        let readRevision = strategyReadRevision
        let result = try await get("/v1/strategy/list")
        guard requestScope == scope, readRevision == strategyReadRevision else { return }
        strategies = result.rows
    }

    func command(_ action: String, payload: [String: JSONValue], key: String) async throws -> JSONValue {
        let requestScope = scope
        let request = try APIRequest<JSONValue>.json(path: "/api/commands", method: .post,
            body: ["action": JSONValue.string(action), "payload": .object(payload)],
            headers: ["X-Trading-Mode": mode, "Idempotency-Key": key], showsErrorToast: false)
        var result = try await api.send(request)
        let id = result.value("id")
        for _ in 0..<40 {
            guard requestScope == scope else { throw CancellationError() }
            let state = result.value("status")
            if ["SUCCEEDED", "FAILED", "UNKNOWN"].contains(state) { break }
            try await Task.sleep(for: .milliseconds(500))
            result = try await get("/api/commands/\(id)")
        }
        // The command response is the first durable acknowledgement that an
        // order may now exist in the local order projection. Do not depend on
        // a websocket event to invalidate a previously loaded order snapshot;
        // that event can arrive after the user switches tabs or be delayed.
        if ["open", "entry-status", "maker-status", "maker-fallback", "limit-create", "limit-cancel", "limit-chase"].contains(action) {
            liveRevision += 1
        }
        return result
    }
}

/// Read-only chart context. Responses cannot cross an account or view lifetime.
@MainActor
final class USDTChartPositionsModel: ObservableObject {
    @Published private(set) var rows: [JSONValue] = []
    @Published private(set) var ready = false
    @Published private(set) var error = ""
    private var owner = ""
    private var requestID = UUID()
    private var loading = false
    private var monitorID = UUID()

    func reset() {
        requestID = UUID(); loading = false
        owner = ""; rows = []; ready = false; error = ""
    }

    func positions(for symbol: String, scope: String) -> [JSONValue] {
        guard owner == scope else { return [] }
        return ChartPositionLine.positions(in: rows, symbol: symbol)
    }

    func isReady(scope: String) -> Bool { owner == scope && ready }

    func refresh(_ store: USDTStore) async {
        let scope = store.scope
        if owner != scope { reset(); owner = scope }
        guard !loading else { return }
        guard store.isBound else { rows = []; ready = true; error = ""; return }
        let id = UUID(); requestID = id; loading = true
        defer { if requestID == id { loading = false } }
        do {
            let result = try await store.get("/v1/position/list")
            guard requestID == id, scope == store.scope, !Task.isCancelled else { return }
            rows = result.rows; ready = true; error = ""
        } catch is CancellationError { }
        catch {
            guard requestID == id, scope == store.scope, !Task.isCancelled else { return }
            self.error = "持仓状态暂时无法确认，请稍后重试"
            ready = false
        }
    }

    func monitor(_ store: USDTStore) async {
        let scope = store.scope
        let id = UUID(); monitorID = id
        reset(); owner = scope
        defer { if monitorID == id { reset() } }
        while !Task.isCancelled && scope == store.scope {
            await refresh(store)
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
        }
    }
}

@MainActor
final class USDTPageModel: ObservableObject {
    @Published var value: JSONValue = .null
    @Published var error = ""
    @Published var loading = false
    @Published var refreshing = false
    @Published var page = 1
    @Published var hasNext = false
    private var loadingScope = ""
    private var loadID = UUID()
    private var requestInFlight = false
    private var readCompletion: SharedReadCompletion?
    private struct PageSnapshot {
        let value: JSONValue
        let page: Int
        let hasNext: Bool
        var liveRevision: Int?
    }
    private var cachedPages: [String: PageSnapshot] = [:]
    private var cacheScope = ""

    func reset() {
        readCompletion?.finish()
        readCompletion = nil
        loadID = UUID()
        loadingScope = ""
        cacheScope = ""
        cachedPages = [:]
        requestInFlight = false
        value = .null
        error = ""
        loading = false
        refreshing = false
        page = 1
        hasNext = false
    }

    func load(_ store: USDTStore, path: String, query: [URLQueryItem] = [], append: Bool = false,
              snapshotFirst: Bool = false, reuseIfLoaded: Bool = false) async {
        let scope = store.scope
        let context = scope + path + query.filter { !["page", "cursor"].contains($0.name) }.description
        if requestInFlight, loadingScope == context {
            await readCompletion?.wait()
            return
        }
        guard !Task.isCancelled else { return }
        if cacheScope != scope { cachedPages = [:]; cacheScope = scope }
        if reuseIfLoaded, let cached = cachedPages[context] {
            if loadingScope != context {
                // A cache hit also supersedes an in-flight read of another tab.
                readCompletion?.finish()
                readCompletion = nil
                loadID = UUID()
                requestInFlight = false
                loading = false
                refreshing = false
                value = cached.value
                page = cached.page
                hasNext = cached.hasNext
                error = ""
                loadingScope = context
            }
            if cached.liveRevision == store.liveRevision, error.isEmpty { page = cached.page; return }
        }
        if loadingScope != context { value = .null; error = ""; hasNext = false }
        loadingScope = context
        let revision = store.liveRevision
        let shouldCache = reuseIfLoaded || cachedPages[context] != nil
        let requestedPage = Int(query.first { $0.name == "page" }?.value ?? "1") ?? 1
        func savePage(verified: Bool = true) {
            guard shouldCache else { return }
            page = requestedPage
            cachedPages[context] = PageSnapshot(value: value, page: page, hasNext: hasNext,
                liveRevision: verified ? revision : nil)
        }
        let requestID = UUID()
        let completion = SharedReadCompletion()
        readCompletion?.finish()
        readCompletion = completion
        loadID = requestID
        requestInFlight = true
        loading = true
        refreshing = false
        defer {
            if loadID == requestID {
                loading = false; refreshing = false; requestInFlight = false; readCompletion = nil
            }
            completion.finish()
        }
        let previousItems = items
        do {
            if snapshotFirst {
                let snapshot = try await store.get(path, query: query + [.init(name: "snapshot", value: "local")])
                guard scope == store.scope, loadID == requestID, !Task.isCancelled else { return }
                apply(snapshot, previousItems: append ? previousItems : nil)
                loading = false
                let needsRefresh = snapshot["exchange_refresh_required"]?.flag == true
                savePage(verified: !needsRefresh)
                guard needsRefresh else { return }
                refreshing = true
            }
            let next = try await store.get(path, query: query)
            guard scope == store.scope, loadID == requestID, !Task.isCancelled else { return }
            apply(next, previousItems: append ? previousItems : nil)
            savePage()
        } catch is CancellationError { }
        catch {
            if scope == store.scope, loadID == requestID, !Task.isCancelled {
                self.error = error.localizedDescription
                cachedPages[context]?.liveRevision = nil
            }
        }
    }

    private func apply(_ next: JSONValue, previousItems: [JSONValue]?) {
        if let previousItems {
            var object = next.fields
            let key = object["items"] != nil ? "items" : "records"
            object[key] = .array(previousItems + (next[key]?.rows ?? []))
            value = .object(object)
        } else { value = next }
        error = ""
        hasNext = next["pagination"]?["has_next"]?.flag ?? false
    }
    var items: [JSONValue] { value.rows.isEmpty ? (value["items"]?.rows ?? value["records"]?.rows ?? value["logs"]?.rows ?? []) : value.rows }
}

extension USDTStore {
    func preflight(_ purpose: String = "entry") async throws {
        let result = try await send("/v1/trade/capital/precheck", ["purpose": .string(purpose)])
        guard ["ready", "not_required"].contains(result.value("status")) else {
            throw APIError.business(code: "409", message: result.value("message", fallback: "请先在我的页面处理开仓资金"))
        }
    }
    func commandMessage(_ result: JSONValue) -> String {
        let status = result.value("status")
        let state = result["result"]?["data"]?.value("state") ?? ""
        if state == "PENDING_MAKER" { return "Maker 委托已挂出，等待成交" }
        if state == "PENDING_LIMIT" { return "限价委托已确认，等待成交" }
        if state == "UNKNOWN" { return "开仓结果仍未确认，系统不会重复下单，请点击“核对开仓结果”" }
        if status == "SUCCEEDED" { return result["result"]?.value("message", fallback: "操作成功") ?? "操作成功" }
        if status == "FAILED" { return result["result"]?.value("message", fallback: "操作失败") ?? "操作失败" }
        return "请求结果仍在核对，系统不会重复提交。"
    }
}
