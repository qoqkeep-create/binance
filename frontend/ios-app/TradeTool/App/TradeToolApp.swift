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
        if ChartCalibrationLaunchConfiguration.isEnabled {
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

        if Response.self == [BinanceFuturesAccountSnapshot].self {
            return [] as! Response
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
