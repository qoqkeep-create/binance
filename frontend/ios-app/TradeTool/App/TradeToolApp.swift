import SwiftUI
import UIKit

// Forward APNs registration events; StrategySignalNotificationManager owns
// notification payload validation and navigation.
final class TradeToolApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(
            name: .apnsDeviceTokenReceived,
            object: token
        )
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationCenter.default.post(
            name: .apnsRegistrationFailed,
            object: error
        )
    }
}

extension Notification.Name {
    static let apnsDeviceTokenReceived = Notification.Name(
        "TradeTool.apnsDeviceTokenReceived"
    )
    static let apnsRegistrationFailed = Notification.Name(
        "TradeTool.apnsRegistrationFailed"
    )
}

@main
struct TradeToolApp: App {
    @UIApplicationDelegateAdaptor(TradeToolApplicationDelegate.self)
    private var appDelegate
    @StateObject private var runtime = AppRuntime()
    @AppStorage(AppAppearance.storageKey)
    private var appearance: AppAppearance = .defaultValue

    init() {
        ChartIndicatorSelectionStore().applyLaunchOverrides(
            arguments: ProcessInfo.processInfo.arguments
        )
        ChartMetricKitSubscriber.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            appContent
        }
    }

    @ViewBuilder
    private var appContent: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--web-parity-fixture") {
            WebParityFixtureView()
        } else if ChartCalibrationLaunchConfiguration.isEnabled {
            ChartCalibrationFixtureView()
                .preferredColorScheme(appearance.colorScheme)
        } else if ChartStressLaunchConfiguration.isEnabled {
            ChartStressHarnessView()
                .preferredColorScheme(.dark)
        } else {
            standardRoot
        }
#else
        standardRoot
#endif
    }

    private var standardRoot: some View {
        let container = runtime.container
        return RootView()
            .id(container.id)
            .environmentObject(runtime)
            .environmentObject(container)
            .environmentObject(container.toastCenter)
            .environmentObject(container.authStore)
            .environmentObject(container.usdt)
            .environmentObject(container.strategySignalNotifications)
            .globalAPIToasts(using: container.toastCenter)
            .tint(BinanceTheme.accentText)
            .preferredColorScheme(appearance.colorScheme)
    }
}

#if DEBUG
private enum ChartCalibrationLaunchConfiguration {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(
            "--chart-calibration-fixture"
        )
    }
}

private struct ChartCalibrationFixtureView: View {
    @StateObject private var container = AppContainer(
        baseURL: URL(string: "http://127.0.0.1:1/")!, bundleIdentifier: "com.riskon.chart-fixture")
    @StateObject private var store = USDTStore(api: WebParityFixtureAPI())
    @StateObject private var toastCenter = AppToastCenter()
    @StateObject private var dashboard = DashboardViewModel(apiClient: ChartCalibrationFixtureAPIClient())
    @StateObject private var livePositions = PositionLiveActivityController()

    private let apiClient = ChartCalibrationFixtureAPIClient()
    private let realtimeClient = RealtimeClient(
        baseURL: URL(string: "http://127.0.0.1")!,
        tokenProvider: { nil }
    )
    private let markets = [
        MarketSnapshot(
            symbol: "BTCUSDC",
            quoteAsset: "USDC",
            price: 64_808,
            quoteVolume24h: 1_230_000_000,
            changePercent24h: -0.18,
            updatedAt: Date(timeIntervalSince1970: 1_786_266_000)
        ),
        MarketSnapshot(
            symbol: "ETHUSDC",
            quoteAsset: "USDC",
            price: 3_428,
            quoteVolume24h: 820_000_000,
            changePercent24h: 0.62,
            updatedAt: Date(timeIntervalSince1970: 1_786_266_000)
        ),
        MarketSnapshot(
            symbol: "SOLUSDC",
            quoteAsset: "USDC",
            price: 142.8,
            quoteVolume24h: 460_000_000,
            changePercent24h: 1.14,
            updatedAt: Date(timeIntervalSince1970: 1_786_266_000)
        ),
    ]

    var body: some View {
        NavigationStack {
            MarketChartView(
                market: markets[0],
                availableMarkets: markets,
                apiClient: apiClient,
                realtimeClient: realtimeClient
            )
        }
        .environmentObject(toastCenter)
        .environmentObject(container)
        .environmentObject(dashboard)
        .environmentObject(store)
        .environmentObject(livePositions)
    }
}

private struct ChartCalibrationFixtureAPIClient: APIClient {
    func send<Response: Decodable>(
        _ request: APIRequest<Response>
    ) async throws -> Response {
        if Response.self == MarketSymbolCatalogResponse.self {
            return MarketSymbolCatalogResponse(
                quoteAsset: "USDC", symbols: ["BTCUSDC", "ETHUSDC", "SOLUSDC"]
            ) as! Response
        }
        if Response.self == MarketKlineHistoryResponse.self {
            let symbol = request.queryItems.first {
                $0.name == "symbol"
            }?.value ?? "BTCUSDC"
            let interval = request.queryItems.first {
                $0.name == "interval"
            }?.value ?? MarketKlineInterval.oneHour.rawValue
            let response = MarketKlineHistoryResponse(
                symbol: symbol,
                interval: interval,
                items: candles(interval: interval)
            )
            return response as! Response
        }

        if Response.self == EmptyResponse.self {
            return EmptyResponse() as! Response
        }

        throw APIError.invalidResponse
    }

    private func candles(interval: String) -> [MarketCandle] {
        let intervalMilliseconds = milliseconds(for: interval)
        let count = 500
        let lastOpenTime: Int64 = 1_786_266_000_000
        let firstOpenTime = lastOpenTime
            - Int64(count - 1) * intervalMilliseconds

        return (0..<count).map { index in
            let phase = Double(index)
            let trend = phase * 1.18
            let primaryWave = sin(phase * 0.105) * 315
            let secondaryWave = sin(phase * 0.037 + 0.8) * 190
            let center = 63_910 + trend + primaryWave + secondaryWave
            let open = center + sin(phase * 0.91) * 58
            let close = center + cos(phase * 0.73) * 64
            let high = max(open, close)
                + 28 + abs(sin(phase * 0.47)) * 82
            let low = min(open, close)
                - 28 - abs(cos(phase * 0.39)) * 76
            let volume = 24
                + abs(sin(phase * 0.31)) * 96
                + Double(index % 17) * 2.4
            let averagePrice = (
                open + high + low + close
            ) / 4 + sin(phase * 1.7) * 5
            let openTime = firstOpenTime
                + Int64(index) * intervalMilliseconds

            return MarketCandle(
                openTime: openTime,
                closeTime: openTime + intervalMilliseconds - 1,
                openPrice: open,
                highPrice: high,
                lowPrice: low,
                closePrice: close,
                volume: volume,
                quoteVolume: averagePrice * volume
            )
        }
    }

    private func milliseconds(for interval: String) -> Int64 {
        guard let value = MarketKlineInterval(rawValue: interval) else {
            return 3_600_000
        }
        return Int64(value.duration * 1_000)
    }
}
#endif

#if DEBUG
  private actor WebParityFixtureRequests {
    private var counts: [String: Int] = [:]
    private var registrationEnabled = false
    func next(_ path: String) -> Int {
      counts[path, default: 0] += 1
      return counts[path, default: 0]
    }
    func registration(_ enabled: Bool? = nil) -> Bool {
      if let enabled { registrationEnabled = enabled }
      return registrationEnabled
    }
  }

  /// Isolated visual states with no network transport. Writes only update explicit local previews or operator state.
  private struct WebParityFixtureAPI: APIClient {
    private let requests = WebParityFixtureRequests()
    static var empty: Bool { ProcessInfo.processInfo.arguments.contains("--fixture-empty") }
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
      if request.path == "/v1/auth/admin-settings",
        ProcessInfo.processInfo.arguments.contains("--fixture-registration-unavailable") {
        throw APIError.business(code: "VISUAL_FIXTURE", message: "注册状态测试不可用")
      }
      let savesFixtureRegistration = request.method == .post && request.path == "/v1/auth/admin-settings"
        && ProcessInfo.processInfo.arguments.contains("--fixture-registration-operator")
      // Explicit, transport-free UI fixture. Only limit-create can reach this
      // branch; every other trading write remains rejected by the guard below.
      if request.method == .post, request.path == "/api/commands",
        ProcessInfo.processInfo.arguments.contains("--fixture-limit-submit") {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data())
        if body.value("action") == "limit-create" {
          let status = ProcessInfo.processInfo.arguments.contains("--fixture-limit-unknown") ? "UNKNOWN" : "SUCCEEDED"
          let result: JSONValue = .object(["id": .string("fixture-limit-create"), "status": .string(status),
            "result": .object(["data": .object(["limit_order_id": .number(201)])])])
          return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(result))
        }
      }
      guard
        request.method == .get || savesFixtureRegistration
          || ["/v1/trade/capital/precheck", "/v1/trade/capital/wallet/precheck"].contains(request.path)
      else {
        throw APIError.business(code: "VISUAL_FIXTURE", message: "视觉校准模式不执行写操作")
      }
      if ProcessInfo.processInfo.arguments.contains("--fixture-refresh-delay"),
        ["/api/market/tickers", "/v1/account/info", "/api/commands",
         "/v1/trade/tradingview/signals", "/v1/account/operation-logs",
         "/v1/account/transfer-history", "/v1/strategy/log"].contains(request.path) {
        try await Task.sleep(for: .seconds(4))
      }
      let all = try JSONDecoder().decode([String: JSONValue].self, from: Data(Self.payload.utf8))
      var value =
        all[
          request.path == "/v1/trade/capital/precheck"
            ? "/v1/trade/capital/normalize" : request.path] ?? .object([:])
      if request.path == "/v1/trade/order/list" {
        let sample = all["/v1/trade/limit-order/list"]?.rows.first ?? .object([:])
        var ordinary = sample.fields
        ordinary["id"] = .string("limit:101"); ordinary["record_key"] = .string("limit:101")
        ordinary["source_id"] = .number(101); ordinary["order_kind"] = .string("limit")
        ordinary["status"] = .number(0); ordinary["can_cancel"] = .bool(true)
        ordinary["filled_amount"] = .string("0")
        var records = [JSONValue.object(ordinary)]
        if ProcessInfo.processInfo.arguments.contains("--fixture-unified-orders") {
          let samples: [(String, Int, String, Int, String, String)] = [("limit", 201, "BTCUSDT", 0, "等待成交", "0"),
                     ("maker", 202, "ETHUSDT", 0, "等待成交", "0"),
                     ("maker", 203, "SOLUSDT", 0, "部分成交", "0.5"),
                     ("maker", 204, "ADAUSDT", 1, "已成交", "1"),
                     ("maker", 205, "XRPUSDT", 2, "已撤销", "0"),
                     ("maker", 206, "DOGEUSDT", 4, "待核对", "0.5")]
          records = samples.map { kind, id, symbol, status, text, filled -> JSONValue in
            var row: [String: JSONValue] = ["id": .string("\(kind):\(id)"), "record_key": .string("\(kind):\(id)"),
              "source_id": .number(Double(id)), "order_kind": .string(kind),
              "client_request_id": .string("fixture-maker-\(id)"), "symbol": .string(symbol),
              "side": .number(0), "status": .number(Double(status)), "status_text": .string(text),
              "limit_price": .string("100"), "stop_loss_price": .string("90"),
              "stop_loss_amount": .string("10"), "size": .string("1"), "filled_size": .string(filled),
              "position_amount": .string("100"), "filled_amount": status == 1 ? .null : .string(filled == "0.5" ? "50" : "0"),
              "average_price": status == 1 ? .null : .string("100"), "leverage": .number(10),
              "can_cancel": .bool(status == 0), "can_chase": .bool(kind == "limit" && status == 0),
              "created_at": .string("2026-11-10T10:00:00Z"), "updated_at": .string("2026-11-10T10:02:00Z")]
            row["position_id"] = status == 1 ? .number(204) : .null
            return .object(row)
          }
        }
        value = .object(["items": .array(records), "pagination": .object(["total": .number(Double(records.count)), "has_next": .bool(false)])])
      }
      if request.path == "/v1/position/margin" {
        if ProcessInfo.processInfo.arguments.contains("--fixture-margin-failure") {
          throw APIError.business(code: "VISUAL_FIXTURE", message: "保证金读取替身失败")
        }
        let danger = ProcessInfo.processInfo.arguments.contains("--fixture-margin-danger")
        let caution = ProcessInfo.processInfo.arguments.contains("--fixture-margin-caution")
        value = .object(["supported": .bool(true), "observed_at": .number(Date().timeIntervalSince1970 * 1000),
          "max_age_seconds": .number(20), "currency": .string("USDT"),
          "margin_ratio_percent": .string(danger ? "85" : caution ? "55" : "25"),
          "liquidation_reached": .bool(false), "wallet_balance": .string("1000"),
          "unrealized_profit": .string("-200"), "margin_balance": .string("800"),
          "maintenance_margin": .string(danger ? "680" : caution ? "440" : "200"),
          "initial_margin": .string("400"), "position_initial_margin": .string("350"),
          "open_order_initial_margin": .string("50"), "total_usage_percent": .string("50"),
          "available_balance": .string("400"), "positions": .array([
            .object(["symbol": .string("TESTUSDT"), "side": .string("long"), "quantity": .string("10"),
              "leverage": .string("20"), "position_initial_margin": .string("350"),
              "maintenance_margin": .string(danger ? "680" : caution ? "440" : "200"),
              "unrealized_profit": .string("-200"), "usage_percent": .string("43.75"),
              "open_order_initial_margin": .string("50")])])])
        if Self.empty {
          value = .object(["supported": .bool(true), "observed_at": .number(Date().timeIntervalSince1970 * 1000),
            "max_age_seconds": .number(20), "currency": .string("USDT"), "positions": .array([]),
            "margin_ratio_percent": .null, "liquidation_reached": .bool(false)])
        }
      }
      if ProcessInfo.processInfo.arguments.contains("--fixture-refresh-delay") {
        if request.path == "/api/market/tickers" {
          value = .object(["quoteAsset": .string("USDT"), "tickers": .array([])])
        } else if request.path == "/api/commands" {
          value = .array([.object(["id": .string("fixture-read-only"),
            "action": .string("只读命令列表"), "status": .string("SUCCEEDED")])])
        }
      }
      if request.path == "/v1/trade/capital/precheck",
        ProcessInfo.processInfo.arguments.contains("--fixture-entry-ready") {
        value = .object(["status": .string("ready")])
      }
      if request.path == "/v1/trade/capital/wallet/precheck" {
        let body = try JSONDecoder().decode([String: JSONValue].self, from: request.body ?? Data("{}".utf8))
        let action = body["action"]?.text ?? "to_spot"
        let refill = ProcessInfo.processInfo.arguments.contains("--fixture-capital-refill")
        let emptyWallet = ProcessInfo.processInfo.arguments.contains("--fixture-capital-empty")
        let amount = emptyWallet ? "0" : action == "to_spot" ? (refill ? "40" : "70") : action == "transfer" ? "80" : (refill ? "40" : "0")
        value = .object([
          "operation": .string(action), "status": .string(amount == "0" ? "ready" : "normalization_required"),
          "plan_token": .string("visual-wallet-read-only"), "futures_balance": .string(refill ? "10" : "100"),
          "maximum_futures_balance": .string("50"), "spot_available": .string("80"),
          "funding_available": .string(refill ? "40" : "20"), "operation_amount": .string(amount),
          "futures_collect": .string(emptyWallet || refill ? "0" : "50"), "funding_collect": .string(emptyWallet ? "0" : refill ? "40" : "20"),
          "account_type": .string("master"), "destination_address": .string("0x123456789012345678901234567890123456BEEF"),
          "destination_network": .string("BSC"),
        ])
        if ProcessInfo.processInfo.arguments.contains("--fixture-collection-unconfigured"), action == "transfer" {
          var fields = value.fields
          fields["status"] = .string("blocked")
          fields["destination_address"] = .string("")
          fields["destination_network"] = .string("")
          fields["message"] = .string("请先添加收款账号")
          value = .object(fields)
        }
        if ProcessInfo.processInfo.arguments.contains("--fixture-capital-legacy") {
          var fields = value.fields
          fields["status"] = .string("collection_pending")
          fields["operation"] = .string("")
          fields["collection_id"] = .number(1)
          fields["transfer_amount"] = .string("50")
          fields["message"] = .string("存在之前的归集，请先核对原流水")
          value = .object(fields)
        }
        if ProcessInfo.processInfo.arguments.contains("--fixture-capital-pending") {
          var fields = value.fields
          fields["status"] = .string("collection_pending")
          fields["collection_id"] = .number(1)
          value = .object(fields)
        }
        if ProcessInfo.processInfo.arguments.contains("--fixture-capital-blocked") {
          var fields = value.fields
          fields["status"] = .string("blocked")
          fields["message"] = .string("交易所当前有持仓，持仓期间不能划转或转出资金")
          value = .object(fields)
        }
      }
      if request.path == "/v1/account/capital-collect-account",
        ProcessInfo.processInfo.arguments.contains("--fixture-collection-configured") {
        value = .object(["account_type": .string("master"),
          "capital_collect_address": .string("0x123456789012345678901234567890123456BEEF"),
          "capital_collect_network": .string("BSC")])
      }
      if request.path == "/v1/account/version",
        ProcessInfo.processInfo.arguments.contains("--fixture-lead-disabled") {
        value = .object(["lead_trading_enabled": .bool(false), "lead_trading_bound": .bool(false)])
      }
      if request.path == "/v1/position/history",
        ProcessInfo.processInfo.arguments.contains("--fixture-history-supplement-slow") {
        if request.queryItems.contains(where: { $0.name == "snapshot" && $0.value == "local" }) {
          var fields = value.fields
          fields["exchange_refresh_required"] = .bool(true)
          fields["items"] = .array((fields["items"]?.rows ?? []).map {
            var row = $0.fields
            row["settlement_status"] = .string("pending")
            return .object(row)
          })
          value = .object(fields)
        } else {
          try await Task.sleep(for: .seconds(6))
        }
      }
      if ProcessInfo.processInfo.arguments.contains("--fixture-refresh-lists"),
        ["/v1/position/list", "/v1/position/history", "/v1/trade/limit-order/list", "/v1/trade/order/list"].contains(request.path),
        await requests.next(request.path) == 1 {
        value = .array([])
      }
      if ProcessInfo.processInfo.arguments.contains("--fixture-position-pager"),
        ["/v1/position/list", "/v1/position/history", "/v1/trade/limit-order/list", "/v1/trade/order/list"].contains(request.path),
        let sample = value.rows.first ?? value["items"]?.rows.first {
        let page = Int(request.queryItems.first { $0.name == "page" }?.value ?? "1") ?? 1
        let prefix = request.path == "/v1/position/list" ? "POS" : request.path == "/v1/position/history" ? "HIS" : "LIM"
        let records: [JSONValue] = (1...5).map { offset in
          let index = (page - 1) * 5 + offset
          var fields = sample.fields
          fields["id"] = .number(Double(index))
          if request.path == "/v1/trade/order/list" {
            fields["id"] = .string("limit:\(index)")
            fields["record_key"] = .string("limit:\(index)")
            fields["source_id"] = .number(Double(index))
          }
          fields["symbol"] = .string(prefix + String(format: "%02d", index) + "USDT")
          return .object(fields)
        }
        value = request.path == "/v1/position/list" ? .array(records)
          : .object(["items": .array(records), "pagination": .object([
            "has_next": .bool(page < 2), "total": .number(10)])])
      }
      if request.path == "/v1/auth/admin-settings",
        ProcessInfo.processInfo.arguments.contains("--fixture-registration-open") {
        value = .object(["open_registration": .bool(true)])
      }
      if request.path == "/v1/auth/admin-settings",
        ProcessInfo.processInfo.arguments.contains("--fixture-registration-operator") {
        if savesFixtureRegistration {
          let body = try JSONDecoder().decode([String: Bool].self, from: request.body ?? Data())
          guard let enabled = body["open_registration"] else { throw APIError.invalidResponse }
          _ = await requests.registration(enabled)
        }
        value = .object(["open_registration": .bool(await requests.registration()), "is_admin": .bool(true)])
      }
      if request.path == "/v1/trade/tradingview/signals",
        ProcessInfo.processInfo.arguments.contains("--fixture-page-state"),
        let sample = value.rows.first {
        let read = await requests.next(request.path)
        value = .array((1...20).map { index in
          var fields = sample.fields
          fields["id"] = .number(Double(index))
          fields["comment"] = .string("读取 \(read) · 测试信号 \(index)")
          return .object(fields)
        })
      }
      if Self.empty
        && [
          "/v1/position/list", "/v1/position/history", "/v1/trade/limit-order/list", "/v1/trade/order/list",
          "/v1/trade/tradingview/signals",
          "/v1/strategy/list",
        ].contains(request.path)
      {
        value = .array([])
      }
      if request.path == "/v1/api/info"
        && ProcessInfo.processInfo.arguments.contains("--fixture-unbound")
      {
        value = .null
      }
      if request.path == "/v1/position/list",
        ProcessInfo.processInfo.arguments.contains("--fixture-strategy-idle") {
        value = .array(value.rows.map { row in
          var fields = row.fields
          fields["strategy_status"] = .number(0)
          return .object(fields)
        })
      }
      if request.path == "/v1/position/list",
        ProcessInfo.processInfo.arguments.contains("--fixture-entry-ready") {
        value = .array([])
      }
      if request.path == "/v1/position/list",
        ProcessInfo.processInfo.arguments.contains("--fixture-chart-position") {
        value = .array(value.rows.map { row in
          var fields = row.fields
          fields["exchange_size"] = .string("0.1")
          fields["open_price"] = .string("64400")
          fields["market_stop_set"] = .bool(true)
          fields["market_stop_price"] = .string("64100")
          fields["manual_take_profit_set"] = .bool(true)
          fields["manual_take_profit_price"] = .string("64750")
          fields["manual_take_profit_order_type"] = .string("limit")
          fields["entry_fee_status"] = .string("confirmed")
          fields["entry_realized_fee"] = .string("0.5")
          fields["entry_fee_asset"] = .string("USDT")
          return .object(fields)
        })
      }
      if request.path == "/v1/trade/symbol/info" {
        value = .object(["symbol": .string("BTCUSDT"), "max_leverage": .number(50)])
      }
      if request.path == "/v1/trade/leverage-brackets" {
        var brackets: [JSONValue] = [
          .object(["leverage": .number(50), "max_notional": .string("250000"), "max_open_amount": .string("25000")]),
          .object(["leverage": .number(25), "max_notional": .string("1000000"), "max_open_amount": .string("12500")]),
          .object(["leverage": .number(10), "max_notional": .string("2000000"), "max_open_amount": .string("5000")]),
        ]
        if ProcessInfo.processInfo.arguments.contains("--fixture-extra-leverage") {
          brackets.insert(.object(["leverage": .number(5), "max_notional": .string("3000000"), "max_open_amount": .string("2500")]), at: 0)
        }
        value = .object(["symbol": .string("BTCUSDT"), "brackets": .array(brackets)])
      }
      if request.path == "/v1/position/list",
        ProcessInfo.processInfo.arguments.contains("--fixture-multiple"),
        let first = value.rows.first
      {
        var second = first.fields
        second["id"] = .number(2)
        second["symbol"] = .string("ETHUSDT")
        second["current_price"] = .string("2600.50")
        second["pnl"] = .string("-3.50")
        second["side"] = .number(1)
        value = .array([first, .object(second)])
      }
      if request.path == "/v1/position/list",
        ProcessInfo.processInfo.arguments.contains("--fixture-live-floating") {
        value = .array(value.rows.map { row in
          var fields = row.fields
          if row.value("symbol") == "BTCUSDT" {
            fields["current_price"] = .string(String(68000 + Int(Date().timeIntervalSince1970) % 100))
          }
          return .object(fields)
        })
      }
      if request.path == "/v1/trade/capital/precheck",
        ProcessInfo.processInfo.arguments.contains("--fixture-capital-refill")
      {
        var plan = value.fields
        plan["transfer_amount"] = .string("0")
        plan["futures_collect"] = .string("0")
        plan["funding_to_futures"] = .string("40")
        plan["futures_balance"] = .string("10")
        plan["collection_total"] = .string("0")
        value = .object(plan)
      }
      return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(value))
    }
    static let payload = #"""
      {
        "/v1/api/info": {
          "id": 1,
          "alias": "视觉校准",
          "api_key_masked": "abcde**vwxyz",
          "status": 1
        },
        "/v1/account/info": {
          "balance": "100",
          "spot_balance": "0",
          "funding_balance": "0",
          "stop_loss_amount": "10",
          "pending_capital_collection": false,
          "capital_trigger_multiplier": "1.5",
          "capital_target_multiplier": "5"
        },
        "/v1/account/profile": {
          "display_name": "视觉校准",
          "account_label": "主账户",
          "account_type": "master"
        },
        "/v1/account/version": {
          "version": "1.0.0",
          "lead_trading_enabled": true,
          "lead_trading_bound": false
        },
        "/v1/strategy/list": [
          {
            "id": 1,
            "name": "30-20-50",
            "is_active": true,
            "levels": [
              {
                "profitRR": "1",
                "reducePosition": "30",
                "stopLossType": "absoluteRR",
                "stopLossAbsoluteRR": "0"
              },
              {
                "profitRR": "2",
                "reducePosition": "20",
                "stopLossType": "absoluteRR",
                "stopLossAbsoluteRR": "1"
              },
              {
                "profitRR": "3",
                "reducePosition": "50",
                "stopLossType": "none"
              }
            ]
          }
        ],
        "/api/market/symbols": {
          "quoteAsset": "USDT", "symbols": ["ADAUSDT", "BTCUSDT", "ETHUSDT", "SOLUSDT"]
        },
        "/v1/trade/symbol/info": {
          "symbol": "BTCUSDT",
          "current_price": "68000"
        },
        "/v1/trade/symbols": [
          "BTCUSDT",
          "ETHUSDT",
          "SOLUSDT"
        ],
        "/v1/position/list": [
          {
            "id": 101,
            "symbol": "BTCUSDT",
            "side": 0,
            "leverage": 10,
            "stop_loss_amount": "10",
            "position_amount": "1000.00",
            "pnl": "25.00",
            "open_price": "66341.46",
            "current_price": "68000.00",
            "stop_loss_price": "65678.05",
            "manual_take_profit_price": "未设置",
            "fee": "0.50",
            "opened_at": "2026-10-31T02:00:00Z",
            "created_at": "2026-10-31T02:00:00Z",
            "strategy_name": "30-20-50",
            "strategy_id": 1,
            "has_strategy_logs": true,
            "strategy_status": 1,
            "can_bind_strategy": true,
            "strategy_config": [
              {
                "profitRR": "1",
                "reducePosition": "30",
                "stopLossType": "absoluteRR",
                "stopLossAbsoluteRR": "0"
              },
              {
                "profitRR": "2",
                "reducePosition": "20",
                "stopLossType": "absoluteRR",
                "stopLossAbsoluteRR": "1"
              },
              {
                "profitRR": "3",
                "reducePosition": "50",
                "stopLossType": "none"
              }
            ],
            "strategy_snapshot_id": 1,
            "estimated_total_fee": "1.00",
            "entry_realized_fee": "-0.50",
            "entry_fee_asset": "USDT",
            "entry_fee_status": "confirmed",
            "market_stop_set": true,
            "market_stop_price": "65678.05",
            "manual_take_profit_set": false,
            "stop_protection_status": "complete",
            "position_origin": "web"
          }
        ],
        "/v1/position/history": {
          "items": [
            {
              "id": 101,
              "symbol": "BTCUSDT",
              "side": 0,
              "leverage": 10,
              "stop_loss_amount": "10",
              "position_amount": "1000.00",
              "pnl": "25.00",
              "open_price": "66341.46",
              "current_price": "68000.00",
              "stop_loss_price": "65678.05",
              "manual_take_profit_price": "未设置",
              "fee": "0.50",
              "opened_at": "2026-10-31T02:00:00Z",
              "created_at": "2026-10-31T02:00:00Z",
              "strategy_name": "30-20-50",
              "strategy_id": 1,
              "has_strategy_logs": true,
              "closed_at": "2026-10-31T03:00:00Z",
              "close_price": "68000",
              "settlement_status": "settled"
            }
          ],
          "pagination": {
            "total": 1,
            "has_next": false
          }
        },
        "/v1/trade/limit-order/list": [
          {
            "id": 101,
            "symbol": "BTCUSDT",
            "side": 0,
            "leverage": 10,
            "stop_loss_amount": "10",
            "position_amount": "1000.00",
            "pnl": "25.00",
            "open_price": "66341.46",
            "current_price": "68000.00",
            "stop_loss_price": "65678.05",
            "manual_take_profit_price": "未设置",
            "fee": "0.50",
            "opened_at": "2026-10-31T02:00:00Z",
            "created_at": "2026-10-31T02:00:00Z",
            "strategy_name": "30-20-50",
            "strategy_id": 1,
            "has_strategy_logs": true,
            "limit_price": "67000",
            "size": "0.01",
            "filled_size": "0",
            "status_text": "等待成交",
            "can_chase": true
          }
        ],
        "/v1/trade/tradingview/signals": [
          {
            "id": 1,
            "source": "internal",
            "score": 85,
            "symbol": "BTCUSDT",
            "direction": "LONG",
            "interval": "1h",
            "strategy": "EMA144 回踩",
            "price_display": "68000",
            "comment": "趋势回踩后收回关键位置",
            "signal_time": "2026-10-31T03:00:00Z"
          }
        ],
        "/v1/account/operation-logs": {
          "records": [
            {
              "id": 1,
              "symbol": "BTCUSDT",
              "side": "long",
              "status": "success",
              "source": "strategy",
              "order_id": 101,
              "occurred_at": "2026-10-31T03:00:00Z",
              "message": "已执行 L1 止盈，止损位同步更新。"
            }
          ],
          "has_more": false
        },
        "/v1/account/transfer-history": {
          "start_at": "2026-10-01T00:00:00Z",
          "account_type": "master",
          "net_amount": "50.00",
          "outgoing_total": "100.00",
          "incoming_total": "50.00",
          "pagination": {
            "total": 1,
            "has_next": false
          },
          "records": [
            {
              "id": 1,
              "direction": "outgoing",
              "amount": "100.00",
              "asset": "USDT",
              "route": "合约 → 现货",
              "channel": "内部划转",
              "occurred_at": "2026-10-31T03:00:00Z"
            }
          ]
        },
        "/v1/auth/admin-settings": {
          "open_registration": false
        },
        "/v1/account/capital-collect-account": {
          "account_type": "master",
          "capital_collect_address": "",
          "capital_collect_network": ""
        },
        "/v1/account/stop-loss": {
          "stop_loss_amount": "10",
          "balance": "100",
          "total_balance": "100",
          "current_amount": "10",
          "percentage": 10,
          "pending_amount": null
        },
        "/v1/trade/capital/remind": {
          "status": "shortfall",
          "total_balance": "10",
          "minimum_topup": "5",
          "maximum_topup": "40",
          "account_total": "10",
          "futures_balance": "10",
          "funding_balance": "0",
          "spot_balance": "0",
          "refill_trigger": "15",
          "target": "50",
          "minimum_open_balance": "15",
          "maximum_futures_balance": "50",
          "email_title": "账户补资提醒",
          "email_body": "当前账户总资产低于开仓最低线。建议补充 5 至 40 USDT。",
          "email": "visual@example.invalid"
        },
        "/v1/trade/capital/normalize": {
          "status": "normalization_required",
          "message": "请核对本次资金调整计划",
          "total_balance": "100",
          "account_total": "100",
          "futures_balance": "100",
          "refill_trigger": "15",
          "target": "50",
          "minimum_open_balance": "15",
          "maximum_futures_balance": "50",
          "plan_token": "visual-fixture-plan-only",
          "futures_collect": "50",
            "transfer_amount": "50",
            "collection_total": "50",
            "destination_address": "0x0000000000000000000000000000000000000000",
            "destination_network": "BSC"
        },
        "/api/commands": [],
        "/v1/strategy/log": {
          "strategy_name": "30-20-50",
          "strategy_config": [
            {
              "profitRR": "1",
              "reducePosition": "30",
              "stopLossType": "absoluteRR",
              "stopLossAbsoluteRR": "0"
            },
            {
              "profitRR": "2",
              "reducePosition": "20",
              "stopLossType": "absoluteRR",
              "stopLossAbsoluteRR": "1"
            },
            {
              "profitRR": "3",
              "reducePosition": "50",
              "stopLossType": "none"
            }
          ],
          "logs": [
            {
              "result": "成功",
              "behavior_desc": "已执行 L1 止盈，止损位移动到 0R 处。",
              "error": ""
            }
          ]
        }
      }
      """#
  }

  private struct WebParityFixtureAuthenticationService: AuthenticationService {
    func storedSession() throws -> AuthSession? {
      AuthSession(accessToken: "visual-fixture-only", user: AuthUser(id: "_web_visual_fixture",
        email: ProcessInfo.processInfo.arguments.contains("--fixture-registration-operator")
          ? "qqqqqq@qq.com" : "visual@example.com", displayName: "视觉校准",
        canViewReferenceNotifications: false))
    }
    func refresh(_ session: AuthSession) async throws -> AuthSession { session }
    func clearStoredSession() throws {}
    func login(account: String, password: String) async throws -> AuthSession { throw APIError.invalidResponse }
    func register(account: String, password: String) async throws -> AuthSession { throw APIError.invalidResponse }
    func logout() async {}
  }

  /// Deterministic component probe: no account, exchange or transport writes.
  private struct NativeSheetLockFixture: View {
    @State private var shown = false
    @State private var dismissals = 0
    var body: some View {
      VStack {
        Text("关闭次数：\(dismissals)").accessibilityIdentifier("nativeSheet.dismissals")
        Button("打开测试面板") { shown = true }
      }.nativeTradingSheet(isPresented: $shown, heightFraction: 0.8,
        onDismiss: { dismissals += 1 }) { NativeSheetLockContent() }
    }
  }
  private struct NativeSheetLockContent: View {
    @Environment(\.webDismiss) private var dismiss
    @State private var locked = true
    var body: some View {
      VStack {
        Text("提交锁定测试").frame(maxWidth: .infinity, minHeight: 44)
          .accessibilityIdentifier("nativeSheet.header")
        Toggle("模拟提交中", isOn: $locked).toggleStyle(WebSwitchStyle())
          .accessibilityIdentifier("nativeSheet.lock")
        Button("关闭测试面板") { dismiss() }
        Spacer()
      }.padding(.horizontal, 20).webModalDismissDisabled(locked)
    }
  }

  private struct WebParityFixtureView: View {
    @StateObject private var container = AppContainer(
      baseURL: URL(string: "http://127.0.0.1:1/")!, bundleIdentifier: "com.riskon.visual-fixture")
    @StateObject private var store = USDTStore(api: WebParityFixtureAPI())
    @StateObject private var livePositions = PositionLiveActivityController()
    @StateObject private var fixtureAuth = AuthStore(
      service: WebParityFixtureAuthenticationService(), toastCenter: AppToastCenter())
    @StateObject private var dashboard = DashboardViewModel(markets: [
      MarketSnapshot(symbol: "BTCUSDT", quoteAsset: "USDT", price: 68000, changePercent24h: 1, updatedAt: .now),
      MarketSnapshot(symbol: "ETHUSDT", quoteAsset: "USDT", price: 2600, changePercent24h: 2, updatedAt: .now),
      MarketSnapshot(symbol: "SOLUSDT", quoteAsset: "USDT", price: 150, changePercent24h: 3, updatedAt: .now),
      MarketSnapshot(symbol: "ADAUSDT", quoteAsset: "USDT", price: 0.4, changePercent24h: 0, updatedAt: .now, isVisible: false)
    ], apiClient: WebParityFixtureAPI())
    @State private var tab: AppTab = .markets
    @State private var fixtureMarketSearch = false
    @State private var fixtureMarketSettings = false
    @State private var fixtureSelectedMarket: MarketSnapshot?
    @State private var fixturePositionNavigation: PositionPageRequest?
    private var page: String {
      let args = ProcessInfo.processInfo.arguments
      guard let index = args.firstIndex(of: "--web-parity-fixture"),
        args.indices.contains(index + 1)
      else { return "trade" }
      return args[index + 1]
    }
    private var dark: Bool { ProcessInfo.processInfo.arguments.contains("--fixture-dark") }
    var body: some View {
      NavigationStack {
        VStack(spacing: 0) {
          content.frame(maxWidth: .infinity, maxHeight: .infinity)
          if ["market", "positions", "signals", "profile"].contains(page) {
            BottomNavigationBar(
              selection: $tab)
          }
        }
        .navigationDestination(item: $fixtureSelectedMarket) { market in
          MarketChartView(market: market, availableMarkets: dashboard.markets(onlyVisible: true),
            apiClient: ChartCalibrationFixtureAPIClient(), realtimeClient: container.realtimeClient,
            onStop: { dashboard.restoreRealtimeSubscriptions() },
            onShowPositions: { page in
              fixturePositionNavigation = PositionPageRequest(page: page)
              fixtureSelectedMarket = nil; tab = .positions
            })
        }
      }
      .floatingPositionsOverlay()
      .globalAPIToasts(using: container.toastCenter)
      .environmentObject(container).environmentObject(page == "login" ? container.authStore : fixtureAuth).environmentObject(
        container.toastCenter
      ).environmentObject(store).environmentObject(dashboard)
      .environmentObject(livePositions)
      .environmentObject(container.strategySignalNotifications)
      .preferredColorScheme(dark ? .dark : .light)
      .task {
        if ProcessInfo.processInfo.arguments.contains("--fixture-entry-ready") {
          UserDefaults.standard.set(ProcessInfo.processInfo.arguments.contains("--fixture-maker-entry"),
            forKey: ChartOrderExecutionPreferences.marketEntryMaker)
        }
        if page != "login" { await fixtureAuth.restore() }
        FloatingPositionsPreferences.defaults.set(false, forKey: FloatingPositionsPreferences.enabledKey)
        FloatingPositionsPreferences.defaults.set(1.0, forKey: "integrated.floatingPositions.x")
        FloatingPositionsPreferences.defaults.set(0.22, forKey: "integrated.floatingPositions.y")
        if ProcessInfo.processInfo.arguments.contains("--fixture-refresh-delay") {
          await dashboard.loadSymbolCatalog()
        }
        await store.begin(userID: "_web_visual_fixture")
        if ProcessInfo.processInfo.arguments.contains("--fixture-toast") {
          container.toastCenter.present("网络请求超时，请稍后重试", duration: 30)
        }
        if ProcessInfo.processInfo.arguments.contains("--fixture-lead") {
          store.switchMode("lead")
        } else if store.mode != "ordinary" {
          store.switchMode("ordinary")
        }
        tab =
          page == "market" ? .markets : page == "positions"
          ? .positions : page == "signals" ? .signals : page == "profile" ? .settings : .markets
      }
    }
    @ViewBuilder private var content: some View {
      switch page {
      case "native-sheet": NativeSheetLockFixture()
      case "launch": AppLaunchView()
      case "login": LoginView()
      case "strategies": USDTStrategiesView()
      case "strategy-editor": USDTStrategyEditor(strategy: nil)
      case "operations": USDTRecordsView(kind: .operations)
      case "transfers": USDTRecordsView(kind: .transfers)
      case "strategy-log": USDTRecordsView(kind: .strategyLog("201"))
      case "commands": USDTCommandsView()
      case "embedded-records": USDTRecordsView(kind: .transfers, embedded: true)
      case "settings": USDTSettingsView()
      case "legal": USDTLegalView()
      case "privacy": USDTLegalView(document: "隐私政策")
      case "binding": USDTBindingView()
      case "stop-loss": USDTStopLossView()
      case "collect": USDTCollectAccountView()
      case "capital": USDTCapitalView()
      case "reminder": USDTCapitalReminderView()
      case "trade": USDTTradeView()
      default:
        RetainedTradingPages(selectedTab: tab, isChartOpen: fixtureSelectedMarket != nil,
          openChart: { symbol, _ in
            fixtureSelectedMarket = dashboard.marketSnapshot(forSymbol: symbol)
          }, positionNavigation: fixturePositionNavigation) {
          switch tab {
          case .markets:
            DashboardView(viewModel: dashboard, apiClient: WebParityFixtureAPI(),
              realtimeClient: container.realtimeClient, isShowingMarketSearch: $fixtureMarketSearch,
              isShowingMarketSettings: $fixtureMarketSettings, selectedMarket: $fixtureSelectedMarket)
          case .positions, .signals: Color.clear
          case .settings: USDTProfileView()
          default: USDTTradeView()
          }
        }
      }
    }
  }
#endif
