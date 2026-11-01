import SwiftUI
import UIKit

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
    @StateObject private var toastCenter = AppToastCenter()

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
        .environmentObject(USDTStore(api: apiClient))
    }
}

private struct ChartCalibrationFixtureAPIClient: APIClient {
    func send<Response: Decodable>(
        _ request: APIRequest<Response>
    ) async throws -> Response {
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
    func next(_ path: String) -> Int {
      counts[path, default: 0] += 1
      return counts[path, default: 0]
    }
  }

  /// Isolated visual states. This API has no network transport; only local precheck / EMA previews allow POST.
  private struct WebParityFixtureAPI: APIClient {
    private let requests = WebParityFixtureRequests()
    static var empty: Bool { ProcessInfo.processInfo.arguments.contains("--fixture-empty") }
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
      if request.path == "/v1/auth/admin-settings",
        ProcessInfo.processInfo.arguments.contains("--fixture-registration-unavailable") {
        throw APIError.business(code: "VISUAL_FIXTURE", message: "注册状态测试不可用")
      }
      guard
        request.method == .get
          || ["/v1/trade/capital/precheck", "/v1/trade/ema-check"].contains(request.path)
      else {
        throw APIError.business(code: "VISUAL_FIXTURE", message: "视觉校准模式不执行写操作")
      }
      let all = try JSONDecoder().decode([String: JSONValue].self, from: Data(Self.payload.utf8))
      var value =
        all[
          request.path == "/v1/trade/capital/precheck"
            ? "/v1/trade/capital/normalize" : request.path] ?? .object([:])
      if ProcessInfo.processInfo.arguments.contains("--fixture-refresh-lists"),
        ["/v1/position/list", "/v1/position/history", "/v1/trade/limit-order/list"].contains(request.path),
        await requests.next(request.path) == 1 {
        value = .array([])
      }
      if request.path == "/v1/auth/admin-settings",
        ProcessInfo.processInfo.arguments.contains("--fixture-registration-open") {
        value = .object(["open_registration": .bool(true)])
      }
      if Self.empty
        && [
          "/v1/position/list", "/v1/position/history", "/v1/trade/limit-order/list",
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
      if request.path == "/v1/trade/ema-check" {
        value = .object([
          "check_id": .string("visual-fixture-only"), "symbol": .string("BTCUSDT"),
          "side": .string("long"), "has_any_matching_interval": .bool(true),
          "expires_at": .string(
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(180))),
          "items": .array(
            ["15m", "1h", "4h", "1d"].map {
              .object([
                "interval": .string($0), "label": .string($0), "supported": .bool(true),
                "matches_direction": .bool(true), "relation": .string("EMA21 > EMA55 > EMA144"),
              ])
            }),
        ])
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

  private struct WebParityFixtureView: View {
    @StateObject private var container = AppContainer(
      baseURL: URL(string: "http://127.0.0.1:1/")!, bundleIdentifier: "com.riskon.visual-fixture")
    @StateObject private var store = USDTStore(api: WebParityFixtureAPI())
    @State private var tab: AppTab = .trade
    @State private var fixtureMarketSearch = false
    @State private var fixtureMarketSettings = false
    @State private var fixtureSelectedMarket: MarketSnapshot?
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
          if ["trade", "positions", "signals", "profile"].contains(page) {
            BottomNavigationBar(
              selection: $tab,
              tabs: [.markets, .positions, .trade] + (store.mode == "lead" ? [] : [.signals]) + [
                .settings
              ])
          }
        }
      }
      .floatingPositionsOverlay()
      .globalAPIToasts(using: container.toastCenter)
      .environmentObject(container).environmentObject(container.authStore).environmentObject(
        container.toastCenter
      ).environmentObject(store)
      .preferredColorScheme(dark ? .dark : .light)
      .task {
        FloatingPositionsPreferences.defaults.set(false, forKey: FloatingPositionsPreferences.enabledKey)
        FloatingPositionsPreferences.defaults.set(1.0, forKey: "integrated.floatingPositions.x")
        FloatingPositionsPreferences.defaults.set(0.22, forKey: "integrated.floatingPositions.y")
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
          page == "positions"
          ? .positions : page == "signals" ? .signals : page == "profile" ? .settings : .trade
      }
    }
    @ViewBuilder private var content: some View {
      switch page {
      case "launch": AppLaunchView()
      case "market":
        DashboardView(viewModel: DashboardViewModel(), apiClient: WebParityFixtureAPI(),
          realtimeClient: container.realtimeClient, isShowingMarketSearch: $fixtureMarketSearch,
          isShowingMarketSettings: $fixtureMarketSettings, selectedMarket: $fixtureSelectedMarket)
      case "login": LoginView()
      case "strategies": USDTStrategiesView()
      case "strategy-editor": USDTStrategyEditor(strategy: nil)
      case "operations": USDTRecordsView(kind: .operations)
      case "transfers": USDTRecordsView(kind: .transfers)
      case "settings": USDTSettingsView()
      case "legal": USDTLegalView()
      case "privacy": USDTLegalView(document: "隐私政策")
      case "binding": USDTBindingView()
      case "stop-loss": USDTStopLossView()
      case "collect": USDTCollectAccountView()
      case "capital": USDTCapitalView()
      case "reminder": USDTCapitalReminderView()
      default:
        switch tab {
        case .positions: USDTPositionsView()
        case .signals: USDTSignalsView(openChart: { _, _ in })
        case .settings: USDTProfileView()
        default: USDTTradeView()
        }
      }
    }
  }
#endif
