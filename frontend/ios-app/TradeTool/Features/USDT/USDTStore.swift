import Foundation
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

@MainActor
final class USDTStore: ObservableObject {
    let api: any APIClient
    @Published var mode = "ordinary"
    @Published var revision = 0
    @Published var account: JSONValue = .object([:])
    @Published var profile: JSONValue = .object([:])
    @Published var binding: JSONValue = .null
    @Published var strategies: [JSONValue] = []
    @Published private(set) var selectedLeverages: [String: Int] = [:]
    func selectedLeverage(for symbol: String) -> Int? { selectedLeverages[symbol.uppercased()] }
    func selectLeverage(_ leverage: Int, for symbol: String) { selectedLeverages[symbol.uppercased()] = leverage }
    @Published var selectedSymbol = "BTCUSDT"
    @Published var notice = ""
    @Published var isLoading = false
    @Published var liveRevision = 0
    private var userID = ""
    private var refreshScope = ""
    private var eventRefresh: Task<Void, Never>?
    var scope: String { "\(userID):\(mode):\(revision)" }
    var isBound: Bool { if case .null = binding { return false }; return !binding.fields.isEmpty }
    var riskAmount: String { account.value("stop_loss_amount", fallback: "") }
    var activeStrategy: JSONValue? { strategies.first { $0["is_active"]?.flag == true } }

    init(api: any APIClient) { self.api = api }

    func begin(userID: String) async {
        prepareSession(userID: userID)
        await refresh()
    }

    func prepareSession(userID: String) {
        if self.userID != userID { invalidate() }
        self.userID = userID
        NativeTradingMode.userID = userID
        mode = NativeTradingMode.current
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
        revision += 1
        selectedLeverages = [:]
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
            await self.refresh()
            guard eventScope == self.scope, !Task.isCancelled else { return }
            self.liveRevision += 1
        }
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

    func refresh() async {
        let requestScope = scope
        guard !isLoading || refreshScope != requestScope else { return }
        refreshScope = requestScope
        isLoading = true
        defer { if refreshScope == requestScope { isLoading = false } }
        do {
            let latestBinding = try await get("/v1/api/info")
            guard requestScope == scope else { return }
            if binding != latestBinding { binding = latestBinding }
            async let info = get("/v1/account/info")
            async let user = get("/v1/account/profile")
            async let plans = get("/v1/strategy/list")
            let values = try await (info, user, plans)
            guard requestScope == scope else { return }
            if account != values.0 { account = values.0 }
            if profile != values.1 { profile = values.1 }
            if strategies != values.2.rows { strategies = values.2.rows }
        } catch is CancellationError { }
        catch { if requestScope == scope { notice = error.localizedDescription } }
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
    private struct PageSnapshot {
        let value: JSONValue
        let page: Int
        let hasNext: Bool
        var liveRevision: Int?
    }
    private var cachedPages: [String: PageSnapshot] = [:]
    private var cacheScope = ""

    func reset() {
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
        guard !requestInFlight || loadingScope != context else { return }
        if cacheScope != scope { cachedPages = [:]; cacheScope = scope }
        if reuseIfLoaded, let cached = cachedPages[context] {
            if loadingScope != context {
                // A cache hit also supersedes an in-flight read of another tab.
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
        loadID = requestID
        requestInFlight = true
        loading = true
        refreshing = false
        defer {
            if loadID == requestID { loading = false; refreshing = false; requestInFlight = false }
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
        if status == "SUCCEEDED" { return "操作成功" }
        if status == "FAILED" { return result["result"]?.value("message", fallback: "操作失败") ?? "操作失败" }
        return "请求已保存，结果仍在核对。请查看命令记录，勿重复提交。"
    }
}
