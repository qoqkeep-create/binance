import Metal
import SwiftUI
import UIKit
import XCTest
@testable import TradeTool

final class ChartEngineCoreTests: XCTestCase {
    private let stream = ChartStreamKey(
        symbol: "BTCUSDC",
        interval: "1h"
    )

    @MainActor
    func testBusinessDarkPaletteMatchesMarketPalette() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        for (business, market) in [(WebTheme.page, BinanceTheme.background),
                                   (WebTheme.surface, BinanceTheme.surface),
                                   (WebTheme.border, BinanceTheme.border),
                                   (WebTheme.text, BinanceTheme.primaryText),
                                   (WebTheme.secondary, BinanceTheme.secondaryText)] {
            XCTAssertEqual(UIColor(business).resolvedColor(with: dark), UIColor(market).resolvedColor(with: dark))
        }
    }

    func testRepairSnapshotKeepsNewerSocketTailAndClosedBars() async throws {
        func candle(_ at: Int64, _ price: Double, _ closure: ChartCandleClosure) -> ChartCandle {
            ChartCandle(openTime: at, closeTime: at + 59999, openPrice: 100,
                        highPrice: max(100, price), lowPrice: min(100, price),
                        closePrice: price, volume: 10, quoteVolume: 1000, closure: closure)
        }
        let store = CandleStore()
        _ = await store.installSnapshot(closedCandles: [candle(0, 100, .closed)],
                                        liveCandle: candle(60000, 115, .provisional))
        let repaired = await store.installSnapshot(closedCandles: [candle(0, 100, .closed)],
            liveCandle: candle(60000, 105, .provisional), preservingNewerData: true)
        XCTAssertEqual(repaired.liveTail?.closePrice, 115)
        // A delayed snapshot must not reopen a candle already closed by Socket.
        _ = await store.installSnapshot(closedCandles: [candle(0, 100, .closed), candle(60000, 120, .closed)])
        let delayed = await store.installSnapshot(closedCandles: [candle(0, 100, .closed)],
            liveCandle: candle(60000, 105, .provisional), preservingNewerData: true)
        XCTAssertEqual(delayed.history.candles.last?.closePrice, 120)
        XCTAssertNil(delayed.liveTail)
    }

    func testHistoryPendingMetadataIsOptionalForOriginalServerCompatibility() throws {
        let legacy = try JSONDecoder().decode(MarketKlineHistoryResponse.self,
            from: Data(#"{"symbol":"BTCUSDT","interval":"1h","items":[]}"#.utf8))
        XCTAssertNil(legacy.historyPending)
        let queued = try JSONDecoder().decode(MarketKlineHistoryResponse.self,
            from: Data(#"{"symbol":"BTCUSDT","interval":"1h","items":[],"historyPending":true,"statisticsPending":true,"hasMoreHistory":true}"#.utf8))
        XCTAssertEqual(queued.historyPending, true)
        XCTAssertEqual(queued.statisticsPending, true)
        XCTAssertEqual(queued.hasMoreHistory, true)
    }

    func testChartQuickSwitcherSequenceWrapsAroundSelection() {
        let sequence = ChartQuickSwitcherSequence(
            items: MarketKlineInterval.allCases,
            selectedID: MarketKlineInterval.oneHour.id
        )

        XCTAssertEqual(
            sequence.item(offsetFromSelection: -1),
            .thirtyMinutes
        )
        XCTAssertEqual(
            sequence.item(offsetFromSelection: 1),
            .twoHours
        )
        XCTAssertEqual(
            sequence.item(offsetFromSelection: 8),
            .oneMinute
        )
    }

    func testChartQuickSwitcherSequenceDeduplicatesItems() {
        let sequence = ChartQuickSwitcherSequence(
            items: [
                MarketKlineInterval.oneHour,
                MarketKlineInterval.fourHours,
                MarketKlineInterval.oneHour,
            ],
            selectedID: MarketKlineInterval.oneHour.id
        )

        XCTAssertEqual(sequence.items, [.oneHour, .fourHours])
        XCTAssertEqual(
            sequence.item(offsetFromSelection: -1),
            .fourHours
        )
        XCTAssertNil(ChartQuickSwitcherSequence(
            items: [MarketKlineInterval.oneHour],
            selectedID: MarketKlineInterval.fourHours.id
        ).item(offsetFromSelection: 0))
    }

    func testChartWheelPreviewStateWrapsLabelsAcrossCycles() {
        let state = ChartWheelPreviewState(
            sourceID: "interval",
            accessibilityLabel: "时间间隔",
            labels: ["1分", "5分", "15分"],
            centerPosition: 301.25
        )

        XCTAssertEqual(state.label(at: 300), "1分")
        XCTAssertEqual(state.label(at: 301), "5分")
        XCTAssertEqual(state.label(at: -1), "15分")
        XCTAssertNil(ChartWheelPreviewState(
            sourceID: "empty",
            accessibilityLabel: "空",
            labels: [],
            centerPosition: 0
        ).label(at: 0))
    }

    func testMarketChartRealtimeFeedSubscribesToSelectedAndLivePriceIntervals() {
        for interval in MarketKlineInterval.allCases {
            let subscriptions = MarketChartRealtimeFeedPolicy
                .subscriptionIntervals(for: interval)
            XCTAssertTrue(subscriptions.contains(interval.rawValue))
            XCTAssertTrue(subscriptions.contains(
                MarketKlineInterval.oneMinute.rawValue
            ))
            XCTAssertEqual(
                subscriptions.count,
                interval == .oneMinute ? 1 : 2
            )
        }
    }

    func testOneMinuteKlineSuppliesHigherIntervalLivePrice() {
        for interval in MarketKlineInterval.allCases
            where interval != .oneMinute {
            XCTAssertTrue(
                MarketChartRealtimeFeedPolicy.suppliesLivePrice(
                    sourceInterval:
                        MarketKlineInterval.oneMinute.rawValue,
                    selectedInterval: interval
                )
            )
        }
        XCTAssertFalse(
            MarketChartRealtimeFeedPolicy.suppliesLivePrice(
                sourceInterval: MarketKlineInterval.oneMinute.rawValue,
                selectedInterval: .oneMinute
            )
        )
        XCTAssertFalse(
            MarketChartRealtimeFeedPolicy.suppliesLivePrice(
                sourceInterval: MarketKlineInterval.fiveMinutes.rawValue,
                selectedInterval: .oneHour
            )
        )
    }

    func testStrategyNotificationPayloadRestoresSignal() throws {
        let signal = StrategySignal(
            id: try XCTUnwrap(UUID(
                uuidString: "5D9A41AB-5B6A-4E11-94E5-0FEE84C784EF"
            )),
            symbol: "BTCUSDT",
            interval: "4h",
            strategyName: "EMA144回踩",
            direction: .long,
            triggerPrice: 64_123.45,
            triggeredAt: Date(timeIntervalSince1970: 1_786_156_800)
        )

        let remotePayload: [AnyHashable: Any] = [
            "route": "strategy.signal",
            "id": signal.id.uuidString,
            "symbol": signal.symbol,
            "interval": signal.interval,
            "strategyName": signal.strategyName,
            "direction": signal.direction.rawValue,
            "triggerPrice": signal.triggerPrice,
            "triggeredAt": signal.triggeredAt.timeIntervalSince1970,
        ]
        let restored = try XCTUnwrap(
            StrategySignalNotificationManager.signal(from: remotePayload)
        )

        XCTAssertEqual(restored, signal)
        XCTAssertEqual(
            StrategySignalNotificationManager.destination(from: remotePayload),
            .strategy(signal)
        )
    }

    func testStrategyNotificationPayloadRejectsUnsupportedMarketSymbols() {
        let validPayload: [AnyHashable: Any] = [
            "route": "strategy.signal",
            "id": "5D9A41AB-5B6A-4E11-94E5-0FEE84C784EF",
            "symbol": "BTCUSDT",
            "interval": "4h",
            "strategyName": "EMA144回踩",
            "direction": "LONG",
            "triggerPrice": 64_123.45,
            "triggeredAt": 1_786_156_800.0,
        ]

        for symbol in ["BTCUSDC", "", "../../BTCUSDT", "BTCUSDT?token=fixture"] {
            var payload = validPayload
            payload["symbol"] = symbol
            XCTAssertNil(StrategySignalNotificationManager.signal(from: payload), symbol)
            XCTAssertNil(StrategySignalNotificationManager.destination(from: payload), symbol)
        }

        var normalizedPayload = validPayload
        normalizedPayload["symbol"] = " 1000pepeusdt "
        XCTAssertEqual(
            StrategySignalNotificationManager.signal(from: normalizedPayload)?.symbol,
            "1000PEPEUSDT"
        )
    }

    func testExternalNotificationIsSuppressedWhileAppTradeRoutesToPositions() {
        let remotePayload: [AnyHashable: Any] = [
            "route": "reference.trade.notification",
            "eventId": "trade:open:1001:123456789",
            "type": "OPEN",
        ]

        XCTAssertNil(
            StrategySignalNotificationManager.destination(
                from: remotePayload
            )
        )
        XCTAssertFalse(StrategySignalNotificationManager.allowsPresentation(route: "reference.trade.notification"))
        XCTAssertTrue(StrategySignalNotificationManager.allowsPresentation(route: "strategy.signal"))
        XCTAssertTrue(StrategySignalNotificationManager.allowsPresentation(route: "trade.notification"))
        XCTAssertEqual(StrategySignalNotificationManager.destination(from: ["route": "trade.notification"]), .positions(tradingMode: nil))
        for mode in ["ordinary", "lead"] {
            XCTAssertEqual(StrategySignalNotificationManager.destination(from: ["route": "trade.notification", "tradingMode": mode]),
                .positions(tradingMode: mode), "Trade notifications must open the account mode that generated the event")
        }
        let invalidModes: [Any] = ["", "unknown", "LEAD", 1, NSNull()]
        for invalidMode in invalidModes {
            XCTAssertEqual(StrategySignalNotificationManager.destination(from: ["route": "trade.notification", "tradingMode": invalidMode]),
                .positions(tradingMode: nil), "A missing or invalid mode must preserve the current account mode")
        }
    }

    func testExternalSourcesCannotShowOrNavigateOrdinaryNotificationRoutes() throws {
        let ordinarySignal: [AnyHashable: Any] = [
            "route": "strategy.signal", "id": UUID().uuidString,
            "symbol": "BTCUSDT", "interval": "1h", "strategyName": "自有信号",
            "direction": "LONG", "triggerPrice": 100.0, "triggeredAt": 1_786_156_800.0,
        ]
        XCTAssertNotNil(StrategySignalNotificationManager.destination(from: ordinarySignal),
            "Legacy ordinary payloads without a source remain supported")
        for source in ["external", "tradingview", "tv", " External ", "TRADINGVIEW", " TV "] {
            for route in ["strategy.signal", "trade.notification"] {
                var payload = ordinarySignal
                payload["source"] = source
                payload["route"] = route
                XCTAssertFalse(StrategySignalNotificationManager.allowsPresentation(route: route, source: source))
                XCTAssertNil(StrategySignalNotificationManager.destination(from: payload),
                    "An external source must not navigate through an ordinary notification route")
                XCTAssertNil(StrategySignalNotificationManager.signal(from: payload))
            }
        }
        XCTAssertTrue(StrategySignalNotificationManager.allowsPresentation(route: "strategy.signal", source: "internal"))
        XCTAssertTrue(StrategySignalNotificationManager.allowsPresentation(route: "trade.notification", source: nil))
    }

    func testIntegratedTabsKeepMarketFirstAndUSDTBusinessOrder() {
        XCTAssertEqual(AppTab.availableTabs(canViewReferenceNotifications: true), [.markets, .positions, .signals, .settings])
        XCTAssertEqual(AppTab.availableTabs(canViewReferenceNotifications: false), [.markets, .positions, .signals, .settings])
        XCTAssertEqual(AppTab.settings.title, "我的")
    }

    func testReferenceNotificationEnvelopeDecodesAllFiveTypes() throws {
        let types = [
            "OPEN",
            "STOP_LOSS",
            "STRATEGY_TAKE_PROFIT",
            "MANUAL_TAKE_PROFIT",
            "REDUCTION",
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try types.map { type in
            let data = try XCTUnwrap(
                """
                {
                  "id": "5D9A41AB-5B6A-4E11-94E5-0FEE84C784EF",
                  "eventId": "event-\(type)",
                  "schemaVersion": 1,
                  "type": "\(type)",
                  "title": "测试 \(type)",
                  "content": "> **币种**：BTCUSDT",
                  "occurredAt": "2026-09-04T04:00:00Z",
                  "receivedAt": "2026-09-04T04:00:01Z",
                  "futureField": true
                }
                """.data(using: .utf8)
            )
            return try decoder.decode(
                ReferenceTradeNotification.self,
                from: data
            )
        }

        XCTAssertEqual(decoded.map(\.type), [
            .open,
            .stopLoss,
            .strategyTakeProfit,
            .manualTakeProfit,
            .reduction,
        ])
        XCTAssertEqual(decoded.first?.content, "> **币种**：BTCUSDT")
    }

    func testReferenceNotificationBuildsCompactTradingSummary() {
        let notification = ReferenceTradeNotification(
            id: UUID(),
            eventId: "trade:reduction:1001:1",
            schemaVersion: 1,
            type: .reduction,
            title: "🏹【模板测试】 BTCUSDT 多单 减仓",
            content: """
                > **测试说明**：仅验证通知样式，不对应真实交易
                > **币种**：BTCUSDT
                > **订单方向**：多单
                > **减仓百分比**：30%
                > **减仓价格**：112000
                > **减仓时间**：2026-09-04 13:00:00
                """,
            occurredAt: Date(timeIntervalSince1970: 1_788_494_400),
            receivedAt: Date(timeIntervalSince1970: 1_788_494_405)
        )

        XCTAssertEqual(notification.summary.sourceSymbol, "BTCUSDT")
        XCTAssertEqual(notification.summary.usdcSymbol, "BTCUSDC")
        XCTAssertEqual(notification.summary.direction, .long)
        XCTAssertEqual(notification.summary.details, [
            .init(label: "减仓比例", value: "30%"),
            .init(label: "减仓价格", value: "112000"),
        ])
    }

    @MainActor
    func testReferenceNotificationLinksOnlyToAvailableUSDCMarket() {
        let availableMarket = MarketSnapshot(
            symbol: "BTCUSDC",
            quoteAsset: "USDC",
            price: 112_000,
            changePercent24h: 1.2,
            updatedAt: .now
        )
        let viewModel = DashboardViewModel(markets: [availableMarket])
        let availableNotification = ReferenceTradeNotification(
            id: UUID(),
            eventId: "available",
            schemaVersion: 1,
            type: .manualTakeProfit,
            title: "BTCUSDT 空单 手动止盈",
            content: "> **止盈价**：106500",
            occurredAt: .now,
            receivedAt: .now
        )
        let unavailableNotification = ReferenceTradeNotification(
            id: UUID(),
            eventId: "unavailable",
            schemaVersion: 1,
            type: .manualTakeProfit,
            title: "UNKNOWNUSDT 空单 手动止盈",
            content: "> **止盈价**：1",
            occurredAt: .now,
            receivedAt: .now
        )

        XCTAssertEqual(
            viewModel.usdcMarket(for: availableNotification),
            availableMarket
        )
        XCTAssertEqual(availableNotification.summary.direction, .short)
        XCTAssertEqual(availableNotification.summary.details, [
            .init(label: "止盈价格", value: "106500"),
        ])
        XCTAssertNil(viewModel.usdcMarket(for: unavailableNotification))
    }

    func testAPNsEnvironmentComesFromExpandedSigningSetting() {
        XCTAssertEqual(
            PushInstallationIdentity.normalizedAPNsEnvironment(
                "development"
            ),
            "sandbox"
        )
        XCTAssertEqual(
            PushInstallationIdentity.normalizedAPNsEnvironment(
                "production"
            ),
            "production"
        )
        XCTAssertNil(
            PushInstallationIdentity.normalizedAPNsEnvironment(
                "$(APS_ENVIRONMENT)"
            )
        )
        XCTAssertNil(
            PushInstallationIdentity.normalizedAPNsEnvironment(nil)
        )
    }

    func testStrategyHistorySignalDecodesUnreadState() throws {
        let data = try XCTUnwrap(
            """
            {
              "id": "5D9A41AB-5B6A-4E11-94E5-0FEE84C784EF",
              "symbol": "BTCUSDC",
              "interval": "4h",
              "strategyName": "EMA144回踩",
              "direction": "LONG",
              "triggerPrice": 64123.45,
              "triggeredAt": "2026-08-09T04:00:00.123Z",
              "isRead": false,
              "reversalAlertState": "ACTIVE",
              "reversalPatternName": null
            }
            """.data(using: .utf8)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let signal = try decoder.decode(StrategySignal.self, from: data)

        XCTAssertEqual(signal.symbol, "BTCUSDC")
        XCTAssertEqual(signal.interval, "4h")
        XCTAssertFalse(signal.isRead)
        XCTAssertEqual(signal.reversalAlertState, .active)
        XCTAssertEqual(
            signal.triggeredAt.timeIntervalSince1970,
            1_786_248_000.123,
            accuracy: 0.001
        )
    }

    func testTriggeredSecondaryAlertDecodesMacdDecayAndCanBeReactivated() throws {
        let data = try XCTUnwrap(
            """
            {
              "id": "5D9A41AB-5B6A-4E11-94E5-0FEE84C784EF",
              "symbol": "BTCUSDC",
              "interval": "1h",
              "strategyName": "EMA144回踩",
              "direction": "LONG",
              "triggerPrice": 64123.45,
              "triggeredAt": "2026-08-09T04:00:00Z",
              "isRead": true,
              "reversalAlertState": "TRIGGERED",
              "reversalPatternName": "MACD能量衰减"
            }
            """.data(using: .utf8)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let signal = try decoder.decode(StrategySignal.self, from: data)

        XCTAssertEqual(signal.reversalAlertState, .triggered)
        XCTAssertEqual(signal.reversalPatternName, "MACD能量衰减")
    }

    @MainActor
    func testSignalCanOpenChartWithoutBeingInWatchlist() {
        let viewModel = DashboardViewModel()
        let signal = StrategySignal(
            id: UUID(),
            symbol: "ETHUSDC",
            strategyName: "EMA144回踩",
            direction: .long,
            triggerPrice: 3_456.7,
            triggeredAt: Date(timeIntervalSince1970: 1_786_156_800)
        )

        let market = viewModel.marketSnapshot(for: signal)

        XCTAssertEqual(market.symbol, "ETHUSDC")
        XCTAssertEqual(market.quoteAsset, "USDC")
        XCTAssertEqual(market.price, signal.triggerPrice)
    }

    func testSwiftCancellationMapsToSilentAPIError() {
        let error = APIError.map(CancellationError())

        XCTAssertFalse(error.shouldPresent)
        XCTAssertEqual(error.localizedDescription, "请求已取消")
    }

    func testMarketEntryDrawingCreatesOnlyStopLossLine() throws {
        let drawing = try XCTUnwrap(ChartOrderDrawingState.make(
            side: .long,
            entryOrderType: .market,
            referencePrice: 100
        ))

        XCTAssertNil(drawing.entryPrice)
        XCTAssertLessThan(drawing.stopLossPrice, drawing.referencePrice)
    }

    func testLimitAndMakerDrawingCreateEntryAndStopLossLines() throws {
        let limit = try XCTUnwrap(ChartOrderDrawingState.make(
            side: .long,
            entryOrderType: .limit,
            referencePrice: 100
        ))
        let maker = try XCTUnwrap(ChartOrderDrawingState.make(
            side: .short,
            entryOrderType: .makerOnly,
            referencePrice: 100
        ))

        XCTAssertNotNil(limit.entryPrice)
        XCTAssertLessThan(limit.stopLossPrice, try XCTUnwrap(limit.entryPrice))
        XCTAssertNotNil(maker.entryPrice)
        XCTAssertGreaterThan(maker.stopLossPrice, try XCTUnwrap(maker.entryPrice))
    }

    func testOrderDrawingPreventsStopLossCrossingEntryLine() throws {
        var long = try XCTUnwrap(ChartOrderDrawingState.make(
            side: .long,
            entryOrderType: .limit,
            referencePrice: 100
        ))
        long.move(.stopLoss, to: 120, within: 80...120)

        XCTAssertLessThan(
            long.stopLossPrice,
            try XCTUnwrap(long.entryPrice)
        )
    }

    func testOffscreenStopDragRequiresManualLimitModeAndKeepsPriceValid() throws {
        let projection = try XCTUnwrap(ChartPriceProjection(lowerBound: 80, upperBound: 120,
            plotLeft: 0, plotTop: 20, plotRight: 320, plotBottom: 220))
        XCTAssertEqual(projection.price(atScreenY: 320), 80)
        XCTAssertEqual(projection.price(atScreenY: 320, clampsToPlot: false), 60)
        for side in [ChartOrderSide.long, .short] {
            var drawing = try XCTUnwrap(ChartOrderDrawingState.make(side: side,
                entryOrderType: .limit, referencePrice: 100))
            let outside = side == .long ? 60.0 : 140.0
            drawing.move(.stopLoss, to: outside, within: 80...120)
            XCTAssertTrue((80...120).contains(drawing.stopLossPrice))
            drawing.move(.stopLoss, to: outside, within: 80...120, allowsOffscreenStopLoss: true)
            XCTAssertEqual(drawing.stopLossPrice, outside)
            drawing.move(.stopLoss, to: -10, within: 80...120, allowsOffscreenStopLoss: true)
            XCTAssertEqual(drawing.stopLossPrice, outside)
            drawing.move(.stopLoss, to: .infinity, within: 80...120, allowsOffscreenStopLoss: true)
            XCTAssertEqual(drawing.stopLossPrice, outside)
            drawing.move(.entry, to: 140, within: 80...120, allowsOffscreenStopLoss: true)
            XCTAssertTrue((80...120).contains(try XCTUnwrap(drawing.entryPrice)))
        }
        var market = try XCTUnwrap(ChartOrderDrawingState.make(side: .long,
            entryOrderType: .market, referencePrice: 100))
        market.move(.stopLoss, to: 60, within: 80...120, allowsOffscreenStopLoss: true)
        XCTAssertEqual(market.stopLossPrice, 80)
    }

    func testOrderDrawingUpdatesPositionAndStopDrawdownFromR() throws {
        var drawing = try XCTUnwrap(ChartOrderDrawingState.make(
            side: .long,
            entryOrderType: .market,
            referencePrice: 100,
            riskAmount: 10
        ))

        drawing.move(.stopLoss, to: 99, within: 80...120)

        XCTAssertEqual(drawing.stopDrawdownPercent, 1, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(drawing.plannedPositionNotional),
            1_000,
            accuracy: 0.000_001
        )
    }

    func testChartPriceProjectionRoundTripsPriceAndScreenY() throws {
        let projection = try XCTUnwrap(ChartPriceProjection(
            lowerBound: 80,
            upperBound: 120,
            plotLeft: 4,
            plotTop: 30,
            plotRight: 332,
            plotBottom: 298
        ))

        let y = try XCTUnwrap(projection.screenY(for: 100))
        XCTAssertEqual(y, 164, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(projection.price(atScreenY: y)),
            100,
            accuracy: 0.000_001
        )
    }

    func testAuthSessionKeychainNamespaceSeparatesAPIOrigins() throws {
        let bundleIdentifier = "com.oovso.tradetool"
        let devAService = AuthSessionKeychainNamespace.service(
            bundleIdentifier: bundleIdentifier,
            baseURL: try XCTUnwrap(
                URL(string: "http://192.168.1.110:8686")
            )
        )
        let devBService = AuthSessionKeychainNamespace.service(
            bundleIdentifier: bundleIdentifier,
            baseURL: try XCTUnwrap(
                URL(string: "http://192.168.31.99:8686")
            )
        )
        let releaseService = AuthSessionKeychainNamespace.service(
            bundleIdentifier: bundleIdentifier,
            baseURL: try XCTUnwrap(
                URL(string: "https://binance.oovso.com:8443")
            )
        )

        XCTAssertEqual(
            releaseService,
            "com.oovso.tradetool.auth-session.https."
                + "binance.oovso.com.8443"
        )
        XCTAssertEqual(Set([
            devAService,
            devBService,
            releaseService,
        ]).count, 3)
    }

    func testAuthSessionKeychainNamespaceNormalizesDefaultPorts()
        throws {
        let implicitPort = AuthSessionKeychainNamespace.service(
            bundleIdentifier: "com.oovso.tradetool",
            baseURL: try XCTUnwrap(
                URL(string: "HTTPS://BINANCE.OOVSO.COM")
            )
        )
        let explicitPort = AuthSessionKeychainNamespace.service(
            bundleIdentifier: "com.oovso.tradetool",
            baseURL: try XCTUnwrap(
                URL(string: "https://binance.oovso.com:443")
            )
        )

        XCTAssertEqual(implicitPort, explicitPort)
    }

    @MainActor
    func testToastVariantsDefaultToNoIconAndFifteenHundredMilliseconds() {
        let center = AppToastCenter()

        center.present("普通提示")
        XCTAssertNil(center.activeToast?.iconSystemName)
        XCTAssertEqual(center.activeToast?.duration, 1.5)

        center.success("成功提示")
        XCTAssertNil(center.activeToast?.iconSystemName)
        XCTAssertEqual(center.activeToast?.duration, 1.5)

        center.warning("警告提示")
        XCTAssertNil(center.activeToast?.iconSystemName)
        XCTAssertEqual(center.activeToast?.duration, 1.5)

        center.error("失败提示")
        XCTAssertNil(center.activeToast?.iconSystemName)
        XCTAssertEqual(center.activeToast?.duration, 1.5)

        center.dismiss()
    }

    @MainActor
    func testToastCanExplicitlyOptIntoIconAndCustomDuration() {
        let center = AppToastCenter()

        center.present(
            "需要强调的提示",
            iconSystemName: "exclamationmark.triangle.fill",
            duration: 2.25
        )

        XCTAssertEqual(
            center.activeToast?.iconSystemName,
            "exclamationmark.triangle.fill"
        )
        XCTAssertEqual(center.activeToast?.duration, 2.25)

        center.dismiss()
    }

    func testTrustedCloseReplacesPendingLiveUpdates() {
        let epoch = KlineStreamEpoch(generation: 1)
        var state = KlineIngressState()
        state.beginEpoch(epoch, stream: stream)
        state.completeRecovery(newestOpenTime: nil)

        XCTAssertEqual(
            state.accept(event(
                epoch: epoch,
                sequence: 1,
                openTime: 0,
                closePrice: 100,
                closure: .provisional
            )),
            .accepted
        )
        XCTAssertEqual(
            state.accept(event(
                epoch: epoch,
                sequence: 2,
                openTime: 0,
                closePrice: 101,
                closure: .provisional
            )),
            .coalesced
        )
        XCTAssertEqual(
            state.accept(event(
                epoch: epoch,
                sequence: 3,
                openTime: 0,
                closePrice: 102,
                closure: .closed
            )),
            .accepted
        )

        let drain = state.drain()
        XCTAssertEqual(drain.mutations.count, 1)
        XCTAssertEqual(
            drain.mutations[0].candle.closure,
            .closed
        )
        XCTAssertEqual(
            drain.mutations[0].candle.closePrice,
            102
        )
        XCTAssertEqual(state.lastReceivedSequence, 3)
        XCTAssertEqual(state.lastAppliedRevision, 0)

        state.confirmApplied(
            revision: drain.mutations[0].revision
        )
        XCTAssertEqual(state.lastAppliedRevision, 1)
    }

    func testNewOpenTimeAfterDrainMarksPreviousUnverified() {
        let epoch = KlineStreamEpoch(generation: 1)
        var state = KlineIngressState()
        state.beginEpoch(epoch, stream: stream)
        state.completeRecovery(newestOpenTime: nil)

        _ = state.accept(event(
            epoch: epoch,
            sequence: 1,
            openTime: 0,
            closePrice: 100,
            closure: .provisional
        ))
        XCTAssertEqual(
            state.drain().mutations.map(\.candle.closure),
            [.provisional]
        )

        let disposition = state.accept(event(
            epoch: epoch,
            sequence: 2,
            openTime: 3_600_000,
            closePrice: 101,
            closure: .provisional
        ))
        XCTAssertEqual(
            disposition,
            .recoveryRequired(
                .missingTrustedClose(openTime: 0)
            )
        )

        let drain = state.drain()
        XCTAssertEqual(
            drain.mutations.map(\.candle.closure),
            [.unverifiedClosed, .provisional]
        )
        XCTAssertEqual(
            drain.mutations.map(\.candle.openTime),
            [0, 3_600_000]
        )
    }

    func testLateTrustedCloseReplacesQueuedUnverifiedBar() {
        let epoch = KlineStreamEpoch(generation: 1)
        var state = KlineIngressState()
        state.beginEpoch(epoch, stream: stream)
        state.completeRecovery(newestOpenTime: nil)

        _ = state.accept(event(
            epoch: epoch,
            sequence: 1,
            openTime: 0,
            closePrice: 100,
            closure: .provisional
        ))
        _ = state.accept(event(
            epoch: epoch,
            sequence: 2,
            openTime: 3_600_000,
            closePrice: 101,
            closure: .provisional
        ))
        _ = state.accept(event(
            epoch: epoch,
            sequence: 3,
            openTime: 0,
            closePrice: 99,
            closure: .closed
        ))

        let drain = state.drain()
        XCTAssertEqual(drain.mutations.count, 2)
        XCTAssertEqual(
            drain.mutations[0].candle.closure,
            .closed
        )
        XCTAssertEqual(
            drain.mutations[0].candle.closePrice,
            99
        )
        XCTAssertEqual(
            drain.mutations[1].candle.openTime,
            3_600_000
        )
    }

    func testSequenceGapRequestsRecoveryWithoutCommitting() {
        let epoch = KlineStreamEpoch(generation: 1)
        var state = KlineIngressState()
        state.beginEpoch(epoch, stream: stream)
        state.completeRecovery(newestOpenTime: nil)

        _ = state.accept(event(
            epoch: epoch,
            sequence: 10,
            openTime: 0,
            closePrice: 100,
            closure: .provisional
        ))
        _ = state.drain()

        XCTAssertEqual(
            state.accept(event(
                epoch: epoch,
                sequence: 12,
                openTime: 0,
                closePrice: 102,
                closure: .provisional
            )),
            .recoveryRequired(
                .sequenceGap(expected: 11, received: 12)
            )
        )
        XCTAssertEqual(state.lastReceivedSequence, 12)
        XCTAssertEqual(state.lastAppliedRevision, 0)
        XCTAssertEqual(
            state.drain().mutations.last?.candle.closure,
            .provisional
        )
    }

    func testBarrierOverflowIsBoundedAndRequestsSnapshot() {
        let epoch = KlineStreamEpoch(generation: 1)
        var state = KlineIngressState(barrierCapacity: 1)
        state.beginEpoch(epoch, stream: stream)
        state.completeRecovery(newestOpenTime: nil)

        _ = state.accept(event(
            epoch: epoch,
            sequence: 1,
            openTime: 0,
            closePrice: 100,
            closure: .closed
        ))
        XCTAssertEqual(
            state.accept(event(
                epoch: epoch,
                sequence: 2,
                openTime: 3_600_000,
                closePrice: 101,
                closure: .closed
            )),
            .recoveryRequired(
                .barrierOverflow(capacity: 1)
            )
        )

        let drain = state.drain()
        XCTAssertEqual(drain.mutations.count, 1)
        XCTAssertEqual(
            drain.mutations[0].candle.closure,
            .unverifiedClosed
        )
    }

    func testEpochChangeRejectsLateConnectionEvents() {
        let oldEpoch = KlineStreamEpoch(generation: 1)
        let newEpoch = KlineStreamEpoch(generation: 2)
        var state = KlineIngressState()
        state.beginEpoch(newEpoch, stream: stream)

        XCTAssertEqual(
            state.accept(event(
                epoch: oldEpoch,
                sequence: 100,
                openTime: 0,
                closePrice: 100,
                closure: .provisional
            )),
            .ignoredWrongEpochOrStream
        )
        XCTAssertEqual(
            state.recoveryRequest?.reason,
            .epochChanged
        )
    }

    func testTenThousandLiveUpdatesReuseHistoryStorage() async {
        let initial = (0..<3_000).map { index in
            candle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 100 + Double(index),
                closure: .closed
            )
        }
        let store = CandleStore(initialClosed: initial)
        let first = await store.snapshot()

        for revision in 1...10_000 {
            let live = candle(
                openTime: 3_000 * 3_600_000,
                closePrice: 3_100 + Double(revision) / 10_000,
                closure: .provisional
            )
            _ = await store.apply(
                KlineIngressMutation(
                    revision: UInt64(revision),
                    candle: live
                )
            )
        }

        let last = await store.snapshot()
        XCTAssertTrue(first.history === last.history)
        XCTAssertEqual(last.history.candles.count, 3_000)
        XCTAssertEqual(last.revision, 10_000)
    }

    func testTenThousandSameBarEventsCoalesceToNewest() {
        let epoch = KlineStreamEpoch(generation: 1)
        var state = KlineIngressState()
        state.beginEpoch(epoch, stream: stream)
        state.completeRecovery(newestOpenTime: nil)

        for sequence in 1...10_000 {
            _ = state.accept(event(
                epoch: epoch,
                sequence: Int64(sequence),
                openTime: 0,
                closePrice: 100 + Double(sequence) / 10_000,
                closure: .provisional
            ))
        }

        let drain = state.drain()
        XCTAssertEqual(drain.mutations.count, 1)
        XCTAssertEqual(
            drain.mutations[0].candle.closePrice,
            101,
            accuracy: 0.000_001
        )
        XCTAssertNil(drain.recoveryRequest)
    }

    func testResourceRingRejectsStaleLeaseAndQuarantinesError()
        throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ring = try XCTUnwrap(MetalResourceRing(
            device: device,
            slotCount: 1,
            capacityPerSlot: 64
        ))

        let staleLease = try XCTUnwrap(
            ring.acquire(requiredBytes: 64)
        )
        ring.releaseWithoutSubmission(staleLease)

        let currentLease = try XCTUnwrap(
            ring.acquire(requiredBytes: 64)
        )
        ring.releaseWithoutSubmission(staleLease)
        XCTAssertEqual(ring.availableSlotCount, 0)
        XCTAssertNil(ring.acquire(requiredBytes: 1))

        ring.complete(currentLease, succeeded: false)
        XCTAssertEqual(ring.availableSlotCount, 0)
        XCTAssertEqual(ring.quarantinedSlotCount, 1)
        XCTAssertNil(ring.acquire(requiredBytes: 1))
    }

    func testPolylineCompilerPreservesValidityGaps() {
        let spans = [
            [
                ChartPolylinePoint(x: 0, y: 10),
                ChartPolylinePoint(x: 10, y: 20),
            ],
            [
                ChartPolylinePoint(x: 30, y: 15),
                ChartPolylinePoint(x: 40, y: 25),
                ChartPolylinePoint(x: 50, y: 20),
            ],
        ]
        let segments = ChartBatchCompiler.lineSegments(
            spans: spans,
            width: 1,
            color: .neutral
        )

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].end.x, 10)
        XCTAssertEqual(segments[1].start.x, 30)
        XCTAssertFalse(segments.contains {
            $0.start.x == 10 && $0.end.x == 30
        })

        let invalid = ChartLineSegmentInstance(
            start: ChartPolylinePoint(x: .nan, y: 0),
            end: ChartPolylinePoint(x: 1, y: 1),
            width: 1,
            dashLength: 0,
            gapLength: 0,
            dashPhase: 0,
            color: .neutral
        )
        let batch = ChartRenderBatch(
            candleInstances: [
                ChartCandleInstance(
                    x: .infinity,
                    openY: 0,
                    highY: 0,
                    lowY: 1,
                    closeY: 1,
                    halfBodyWidth: 1,
                    isRising: true
                ),
            ],
            lineSegments: segments + [invalid],
            barInstances: [
                ChartBarInstance(
                    left: 1,
                    top: 1,
                    right: 0,
                    bottom: 2,
                    color: .neutral
                ),
            ],
            glyphInstances: [
                ChartGlyphInstance(
                    left: 0,
                    top: 0,
                    right: 10,
                    bottom: 10,
                    uvLeft: .nan,
                    uvTop: 0,
                    uvRight: 1,
                    uvBottom: 1,
                    color: .neutral
                ),
            ]
        )
        XCTAssertTrue(batch.storage.candleInstances.isEmpty)
        XCTAssertEqual(batch.storage.lineSegments.count, 3)
        XCTAssertTrue(batch.storage.barInstances.isEmpty)
        XCTAssertTrue(batch.storage.glyphInstances.isEmpty)
    }

    func testGlyphAtlasSupportsFallbackFontsAt2xAnd3x()
        throws {
        let text = "最新价格 63,900.8 EMA(21)"
        let builder = MetalGlyphAtlasBuilder()
        let key2x = try XCTUnwrap(ChartGlyphAtlasKey(
            fontName: "HelveticaNeue",
            pointSize: 12,
            displayScale: 2,
            localeIdentifier: "zh-Hans"
        ))
        let key3x = try XCTUnwrap(ChartGlyphAtlasKey(
            fontName: "HelveticaNeue",
            pointSize: 12,
            displayScale: 3,
            localeIdentifier: "zh-Hans"
        ))
        let atlas2x = try builder.build(
            key: key2x,
            seedStrings: [text]
        )
        let atlas3x = try builder.build(
            key: key3x,
            seedStrings: [text]
        )

        XCTAssertLessThanOrEqual(atlas2x.width, 1_024)
        XCTAssertLessThanOrEqual(atlas2x.height, 1_024)
        XCTAssertEqual(
            atlas2x.pixels.count,
            atlas2x.bytesPerRow * atlas2x.height
        )
        XCTAssertTrue(atlas2x.pixels.contains { $0 > 0 })
        XCTAssertTrue(atlas3x.pixels.contains { $0 > 0 })
        XCTAssertGreaterThan(
            Set(atlas2x.entries.keys.map(\.fontName)).count,
            1
        )

        let layout2x = MetalTextLayouter.layout(
            text: text,
            atlas: atlas2x,
            originX: 10,
            baselineY: 40,
            color: .neutral
        )
        let layout3x = MetalTextLayouter.layout(
            text: text,
            atlas: atlas3x,
            originX: 10,
            baselineY: 60,
            color: .neutral
        )
        XCTAssertEqual(layout2x.missingGlyphCount, 0)
        XCTAssertEqual(layout3x.missingGlyphCount, 0)
        XCTAssertFalse(layout2x.instances.isEmpty)
        XCTAssertEqual(
            layout3x.advance / layout2x.advance,
            1.5,
            accuracy: 0.08
        )
    }

    func testGlyphAtlasRejectsConfiguredCapacityOverflow()
        throws {
        let builder = MetalGlyphAtlasBuilder(
            limits: MetalGlyphAtlasLimits(
                maximumDimension: 64,
                maximumGlyphCount: 4,
                maximumBytes: 4_096,
                padding: 2
            )
        )
        let key = try XCTUnwrap(ChartGlyphAtlasKey(
            fontName: "HelveticaNeue",
            pointSize: 12,
            displayScale: 2,
            localeIdentifier: "en_US"
        ))
        XCTAssertThrowsError(
            try builder.build(
                key: key,
                seedStrings: ["0123456789ABCDEF"]
            )
        )
    }

    func testOffscreenSceneIsDeterministicAt2xAnd3x()
        throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try MetalRenderer(
            device: device,
            pixelFormat: .bgra8Unorm_srgb
        )
        let builder = MetalGlyphAtlasBuilder()
        // Verified dark palette (#212731), including anti-aliased glyph edges.
        let expectedHashes: [Int: UInt64] = [
            2: 657_576_939_873_643_382,
            3: 4_642_307_546_264_608_884,
        ]

        for scale in [2, 3] {
            let state = try makeOffscreenState(
                scale: scale,
                builder: builder
            )
            let width = 160 * scale
            let height = 80 * scale
            let glyphs = state.staticScene.batches.flatMap {
                $0.storage.glyphInstances
            }
            XCTAssertFalse(glyphs.isEmpty)
            XCTAssertLessThan(
                glyphs.map(\.top).min() ?? .greatestFiniteMagnitude,
                Float(height)
            )
            XCTAssertGreaterThan(
                glyphs.map(\.bottom).max() ?? -.greatestFiniteMagnitude,
                0
            )
            let first = try XCTUnwrap(renderer.renderOffscreen(
                state: state,
                width: width,
                height: height
            ))
            let second = try XCTUnwrap(renderer.renderOffscreen(
                state: state,
                width: width,
                height: height
            ))

            XCTAssertEqual(
                first.visiblePixelHash,
                second.visiblePixelHash
            )
            XCTAssertGreaterThan(first.coloredPixelCount, 200)
            XCTAssertEqual(
                first.visiblePixelHash,
                expectedHashes[scale]
            )
            if let preview = makePreviewImage(first) {
                let attachment = XCTAttachment(image: preview)
                attachment.name = "KlineMetalGolden-\(scale)x"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testLatestPriceLineMovesOnlyItsTimelineEndpoint()
        throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try MetalRenderer(
            device: device,
            pixelFormat: .bgra8Unorm_srgb
        )
        let history = ChartCandleHistory(candles: [])
        let staticScene = StaticSceneSnapshot(
            revision: 1,
            candleHistory: history,
            batches: [],
            horizontalPlotBounds: ChartHorizontalPlotBounds(
                left: 0,
                right: 200
            )
        )
        let lineBatch = ChartRenderBatch(
            lineSegments: [ChartLineSegmentInstance(
                start: ChartPolylinePoint(x: 80, y: 40),
                end: ChartPolylinePoint(x: 150, y: 40),
                width: 2,
                dashLength: 0,
                gapLength: 0,
                dashPhase: 0,
                color: .latestPriceLine
            )],
            coordinateSpace: .latestPriceTimelineLine
        )
        let liveTail = LiveTailSnapshot(
            revision: 1,
            candle: nil,
            batches: [lineBatch],
            latestPrice: 100
        )
        let baseline = RenderState(
            staticScene: staticScene,
            liveTail: liveTail,
            interaction: InteractionSnapshot(
                revision: 1,
                translationX: 0,
                scaleX: 1,
                crosshair: nil
            ),
            invalidation: .interaction
        )
        let moved = RenderState(
            staticScene: staticScene,
            liveTail: liveTail,
            interaction: InteractionSnapshot(
                revision: 2,
                translationX: -40,
                scaleX: 1,
                crosshair: nil
            ),
            invalidation: .interaction
        )
        let baselineImage = try XCTUnwrap(renderer.renderOffscreen(
            state: baseline,
            width: 200,
            height: 80
        ))
        let movedImage = try XCTUnwrap(renderer.renderOffscreen(
            state: moved,
            width: 200,
            height: 80
        ))

        XCTAssertFalse(isColoredPixel(
            baselineImage,
            x: 60,
            y: 40
        ))
        XCTAssertTrue(isColoredPixel(
            movedImage,
            x: 60,
            y: 40
        ))
        XCTAssertTrue(isColoredPixel(
            baselineImage,
            x: 145,
            y: 40
        ))
        XCTAssertTrue(isColoredPixel(
            movedImage,
            x: 145,
            y: 40
        ))
    }

    func testRelativeCoordinatesPreserveExtremeValues() {
        let originTime: Int64 = 1_780_000_000_000
        let originPrice = 999_999.875
        let space = RelativeChartCoordinateSpace(
            timeOrigin: originTime,
            priceOrigin: originPrice,
            intervalMilliseconds: 3_600_000,
            pixelsPerSlot: 6.75,
            pixelsPerPriceUnit: 512
        )
        XCTAssertNotNil(space)

        let time = originTime + 2_999 * 3_600_000
        let price = 1_000_000.123_456
        let x = space?.screenX(openTime: time)
        let y = space?.screenY(price: price)
        XCTAssertNotNil(x)
        XCTAssertNotNil(y)

        XCTAssertEqual(space?.openTime(screenX: x ?? 0), time)
        let roundTripPrice = space?.price(screenY: y ?? 0)
        XCTAssertNotNil(roundTripPrice)

        let pixelError = abs(
            (roundTripPrice ?? 0) - price
        ) * 512
        XCTAssertLessThanOrEqual(pixelError, 0.25)
    }

    func testRenderMailboxOnlyKeepsNewestStateAndReferences() {
        let history = ChartCandleHistory(candles: [])
        let staticScene = StaticSceneSnapshot(
            revision: 1,
            candleHistory: history,
            batches: []
        )
        let interaction = InteractionSnapshot(
            revision: 1,
            translationX: 0,
            scaleX: 1,
            crosshair: nil
        )
        let mailbox = LatestRenderStateMailbox()

        for revision in 1...100 {
            mailbox.publish(
                RenderState(
                    staticScene: staticScene,
                    liveTail: LiveTailSnapshot(
                        revision: UInt64(revision),
                        candle: nil,
                        batches: [],
                        latestPrice: nil
                    ),
                    interaction: interaction,
                    invalidation: .data
                )
            )
        }

        let latest = mailbox.consumeLatest()
        XCTAssertEqual(latest?.revision, 100)
        XCTAssertTrue(latest?.staticScene === staticScene)
        XCTAssertFalse(mailbox.hasPendingState)
    }

    func testPresentationLatencyHistogramStaysBoundedAndSubtracts()
        throws {
        var histogram = MetalPresentationLatencyHistogram()
        histogram.record(0.003)
        histogram.record(0.010)
        let baseline = histogram

        histogram.record(0.011)
        histogram.record(0.049)
        histogram.record(0.051)
        histogram.record(0.700)
        histogram.record(.nan)

        let delta = histogram.subtracting(baseline)
        XCTAssertEqual(delta.sampleCount, 4)
        XCTAssertEqual(
            try XCTUnwrap(delta.percentileUpperBound(0.50)),
            0.050,
            accuracy: 0.000_001
        )
        XCTAssertTrue(
            try XCTUnwrap(delta.percentileUpperBound(0.95))
                .isInfinite
        )
        XCTAssertNil(delta.percentileUpperBound(0))
    }

    func testStressRunConfigurationParsesAndClampsInputs() {
        let interaction = ChartStressRunConfiguration.resolve(
            arguments: [
                "TradeTool",
                "--chart-stress",
                "--chart-stress-scenario=interaction",
                "--chart-stress-duration",
                "12.5",
                "--chart-stress-burst-rounds=500",
                "--chart-stress-exit-after-result",
            ],
            environment: [:]
        )
        XCTAssertEqual(interaction.scenario, .interaction)
        XCTAssertEqual(
            interaction.durationSeconds,
            12.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(interaction.burstRounds, 100)
        XCTAssertEqual(interaction.lifecycleCycles, 0)
        XCTAssertEqual(interaction.appLifecycleCycles, 0)
        XCTAssertEqual(interaction.externalLifecycleCycles, 0)
        XCTAssertTrue(interaction.exitAfterResult)

        let soak = ChartStressRunConfiguration.resolve(
            arguments: ["TradeTool"],
            environment: [
                "CHART_STRESS_SCENARIO": "soak",
                "CHART_STRESS_DURATION_SECONDS": "-10",
                "CHART_STRESS_BURST_ROUNDS": "-1",
                "CHART_STRESS_EXIT_AFTER_RESULT": "yes",
            ]
        )
        XCTAssertEqual(soak.scenario, .soak)
        XCTAssertEqual(soak.durationSeconds, 1)
        XCTAssertEqual(soak.burstRounds, 0)
        XCTAssertEqual(soak.lifecycleCycles, 0)
        XCTAssertEqual(soak.appLifecycleCycles, 0)
        XCTAssertEqual(soak.externalLifecycleCycles, 0)
        XCTAssertTrue(soak.exitAfterResult)

        let pipeline = ChartStressRunConfiguration.resolve(
            arguments: ["TradeTool"],
            environment: [
                "CHART_STRESS_SCENARIO": "pipeline",
            ]
        )
        XCTAssertEqual(pipeline.scenario, .pipeline)
        XCTAssertEqual(pipeline.durationSeconds, 60)
        XCTAssertEqual(pipeline.burstRounds, 10)
        XCTAssertEqual(pipeline.lifecycleCycles, 0)
        XCTAssertEqual(pipeline.appLifecycleCycles, 0)
        XCTAssertEqual(pipeline.externalLifecycleCycles, 0)
        XCTAssertFalse(pipeline.exitAfterResult)

        let quick = ChartStressRunConfiguration.resolve(
            arguments: ["TradeTool"],
            environment: [:]
        )
        XCTAssertEqual(quick.scenario, .quick)
        XCTAssertEqual(quick.durationSeconds, 0)
        XCTAssertEqual(quick.burstRounds, 0)
        XCTAssertEqual(quick.lifecycleCycles, 0)
        XCTAssertEqual(quick.appLifecycleCycles, 0)
        XCTAssertEqual(quick.externalLifecycleCycles, 0)
        XCTAssertFalse(quick.exitAfterResult)

        let lifecycle = ChartStressRunConfiguration.resolve(
            arguments: [
                "TradeTool",
                "--chart-stress-scenario=lifecycle",
                "--chart-stress-lifecycle-cycles",
                "9000",
            ],
            environment: [
                "CHART_STRESS_DURATION_SECONDS": "50",
            ]
        )
        XCTAssertEqual(lifecycle.scenario, .lifecycle)
        XCTAssertEqual(lifecycle.durationSeconds, 0)
        XCTAssertEqual(lifecycle.burstRounds, 0)
        XCTAssertEqual(lifecycle.lifecycleCycles, 5_000)
        XCTAssertEqual(lifecycle.appLifecycleCycles, 0)
        XCTAssertEqual(lifecycle.externalLifecycleCycles, 0)
        XCTAssertFalse(lifecycle.exitAfterResult)

        let appLifecycle = ChartStressRunConfiguration.resolve(
            arguments: [
                "TradeTool",
                "--chart-stress-scenario=app-lifecycle",
                "--chart-stress-app-lifecycle-cycles=500",
                "--chart-stress-external-lifecycle-cycles",
                "50",
            ],
            environment: [:]
        )
        XCTAssertEqual(appLifecycle.scenario, .appLifecycle)
        XCTAssertEqual(appLifecycle.durationSeconds, 0)
        XCTAssertEqual(appLifecycle.burstRounds, 0)
        XCTAssertEqual(appLifecycle.lifecycleCycles, 0)
        XCTAssertEqual(appLifecycle.appLifecycleCycles, 100)
        XCTAssertEqual(appLifecycle.externalLifecycleCycles, 10)
        XCTAssertFalse(appLifecycle.exitAfterResult)

        let explicitFalse = ChartStressRunConfiguration.resolve(
            arguments: [
                "TradeTool",
                "--chart-stress-exit-after-result=false",
            ],
            environment: [
                "CHART_STRESS_EXIT_AFTER_RESULT": "true",
            ]
        )
        XCTAssertFalse(explicitFalse.exitAfterResult)
    }

    func testStressIngressPipelineIsBoundedAndRecovers()
        async throws {
        let initial = (0..<200).map { index in
            candle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 60_000 + Double(index),
                closure: .closed
            )
        }
        let pipeline = try XCTUnwrap(
            ChartStressIngressPipeline(
                initialClosed: initial
            )
        )

        let first = await pipeline.nextFrame(
            updatesPerDrain: 4,
            readyTime: 1
        )
        XCTAssertEqual(first?.emaValues.count, 3)
        XCTAssertEqual(first?.candleSnapshot.liveTail?.closure, .provisional)

        let recoveryFrames = await pipeline.injectFaultRound(
            readyTime: 2
        )
        XCTAssertEqual(recoveryFrames.count, 4)

        let health = await pipeline.health()
        let counters = health.counters
        XCTAssertEqual(counters.upstreamEvents, 8)
        XCTAssertEqual(counters.acceptedEvents, 1)
        XCTAssertEqual(counters.coalescedEvents, 3)
        XCTAssertEqual(
            counters.ignoredDuplicateOrLateEvents,
            1
        )
        XCTAssertEqual(counters.recoveryRequests, 4)
        XCTAssertEqual(counters.recoveryCompletions, 4)
        XCTAssertEqual(counters.sequenceGaps, 1)
        XCTAssertEqual(counters.invalidCandles, 1)
        XCTAssertEqual(counters.outOfOrderOpenTimes, 1)
        XCTAssertEqual(counters.upstreamBufferDrops, 1)
        XCTAssertEqual(counters.appliedMutations, 1)
        XCTAssertEqual(counters.provisionalEMAFrames, 5)
        XCTAssertEqual(counters.invalidEMAFrames, 0)
        XCTAssertEqual(
            counters.liveHistoryCopyViolations,
            0
        )
        XCTAssertEqual(counters.maximumPendingLiveUpserts, 1)
        XCTAssertEqual(counters.maximumPendingBarriers, 0)
        XCTAssertFalse(health.hasPendingLiveUpsert)
        XCTAssertEqual(health.pendingBarrierCount, 0)
        XCTAssertFalse(health.hasPendingRecovery)
        XCTAssertEqual(health.historyCount, 200)
    }

    func testCancelledSnapshotAndPageCannotMutateThePipeline() async throws {
        let epoch = KlineStreamEpoch(generation: 1)
        let pipeline = try XCTUnwrap(ChartDataPipeline(stream: stream,
            intervalMilliseconds: 3_600_000, epoch: epoch))
        let rows = (20..<40).map { marketCandle(openTime: Int64($0) * 3_600_000, closePrice: 100) }
        let installed = await pipeline.installSnapshot(rows, fetchedAtMilliseconds: 40 * 3_600_000, epoch: epoch)
        let original = try XCTUnwrap(installed.frame)
        let older = (0..<20).map { marketCandle(openTime: Int64($0) * 3_600_000, closePrice: 105) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let snapshot = await pipeline.installSnapshot(older,
                fetchedAtMilliseconds: 40 * 3_600_000, epoch: epoch)
            let page = await pipeline.prependHistory(older, epoch: epoch)
            return (snapshot.frame == nil, page.frame == nil)
        }
        let rejected = await task.value
        XCTAssertTrue(rejected.0 && rejected.1)
        let current = await pipeline.currentFrame()
        XCTAssertTrue(current.candles.history === original.candles.history)
        XCTAssertTrue(current.indicators.history === original.indicators.history)
    }

    func testConcurrentSnapshotPageAndConfigurationKeepFramesConsistent() async throws {
        let epoch = KlineStreamEpoch(generation: 1)
        let pipeline = try XCTUnwrap(ChartDataPipeline(stream: stream,
            intervalMilliseconds: 3_600_000, epoch: epoch))
        let older = (0..<20).map { marketCandle(openTime: Int64($0) * 3_600_000, closePrice: 100) }
        let rows = (20..<40).map { marketCandle(openTime: Int64($0) * 3_600_000, closePrice: 100) }
        _ = await pipeline.installSnapshot(rows, fetchedAtMilliseconds: 40 * 3_600_000, epoch: epoch)
        await withTaskGroup(of: ChartDataFrame?.self) { group in
            for index in 0..<20 {
                group.addTask {
                    switch index % 3 {
                    case 0:
                        return await pipeline.installSnapshot(rows, fetchedAtMilliseconds: 40 * 3_600_000,
                            epoch: epoch, preservingNewerData: true).frame
                    case 1:
                        return await pipeline.prependHistory(older, epoch: epoch).frame
                    default:
                        return await pipeline.updateIndicatorConfiguration(selection: .standard,
                            parameters: .standard, revision: UInt64(index + 1))?.frame
                    }
                }
            }
            for await frame in group {
                if let frame {
                    XCTAssertTrue(frame.indicators.history.series.allSatisfy {
                        $0.points.count == frame.candles.history.candles.count
                    })
                    XCTAssertEqual(frame.epoch, epoch)
                }
            }
        }
        let current = await pipeline.currentFrame()
        XCTAssertEqual(current.candles.history.candles.count, 40)
    }

    func testReconciliationReusesUnchangedHistoryAndIndicators() async throws {
        let epoch = KlineStreamEpoch(generation: 1)
        let pipeline = try XCTUnwrap(ChartDataPipeline(stream: stream,
            intervalMilliseconds: 3_600_000, epoch: epoch))
        let rows = (0..<40).map { marketCandle(openTime: Int64($0) * 3_600_000, closePrice: 100) }
        let firstResult = await pipeline.installSnapshot(rows, fetchedAtMilliseconds: 40 * 3_600_000,
            epoch: epoch, preservingNewerData: true)
        let first = try XCTUnwrap(firstResult.frame)
        let repeatedResult = await pipeline.installSnapshot(rows, fetchedAtMilliseconds: 40 * 3_600_000,
            epoch: epoch, preservingNewerData: true)
        let repeated = try XCTUnwrap(repeatedResult.frame)
        XCTAssertTrue(first.candles.history === repeated.candles.history)
        XCTAssertTrue(first.indicators.history === repeated.indicators.history)
        XCTAssertEqual(first.candles.revision, repeated.candles.revision)
    }

    func testReconciliationKeepsOlderPagesAndAppliesCorrections() async throws {
        let epoch = KlineStreamEpoch(generation: 1)
        let pipeline = try XCTUnwrap(ChartDataPipeline(stream: stream,
            intervalMilliseconds: 3_600_000, epoch: epoch))
        let older = (0..<20).map { marketCandle(openTime: Int64($0) * 3_600_000, closePrice: 100) }
        let latest = (20..<40).map { marketCandle(openTime: Int64($0) * 3_600_000, closePrice: 100) }
        _ = await pipeline.installSnapshot(latest, fetchedAtMilliseconds: 40 * 3_600_000, epoch: epoch)
        _ = await pipeline.prependHistory(older, epoch: epoch)
        var corrected = latest
        corrected[0] = marketCandle(openTime: 20 * 3_600_000, closePrice: 105)
        let result = await pipeline.installSnapshot(corrected, fetchedAtMilliseconds: 40 * 3_600_000,
            epoch: epoch, preservingNewerData: true)
        let frame = try XCTUnwrap(result.frame)
        XCTAssertEqual(frame.candles.history.candles.count, 40)
        XCTAssertEqual(frame.candles.history.candles.first?.openTime, 0)
        XCTAssertEqual(frame.candles.history.candles.first { $0.openTime == 20 * 3_600_000 }?.closePrice, 105)
        XCTAssertTrue(frame.indicators.history.series.allSatisfy { $0.points.count == 40 })
    }

    func testChartDataPipelineCoalescesLiveTailWithoutCopyingHistory()
        async throws {
        let epoch = KlineStreamEpoch(generation: 1)
        let pipeline = try XCTUnwrap(
            ChartDataPipeline(
                stream: stream,
                intervalMilliseconds: 3_600_000,
                epoch: epoch
            )
        )
        let history = (0..<200).map { index in
            marketCandle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 60_000 + Double(index)
            )
        }
        let installed = await pipeline.installSnapshot(
            history,
            fetchedAtMilliseconds: 200 * 3_600_000,
            epoch: epoch
        )
        let initial = try XCTUnwrap(installed.frame)
        XCTAssertNil(installed.recoveryRequest)
        XCTAssertEqual(
            initial.candles.history.candles.count,
            200
        )
        XCTAssertEqual(initial.indicators.history.series.count, 11)
        XCTAssertTrue(
            initial.indicators.history.series.allSatisfy {
                $0.points.count == 200
            }
        )
        let historyIdentity = initial.candles.history
        let indicatorIdentity = initial.indicators.history

        for sequence in 1...4 {
            let ingress = await pipeline.accept(
                payload: realtimePayload(
                    sequence: sequence,
                    openTime: 200 * 3_600_000,
                    closePrice: 60_200
                        + Double(sequence),
                    closed: false
                ),
                sequence: Int64(sequence),
                epoch: epoch
            )
            XCTAssertEqual(
                ingress.disposition,
                sequence == 1 ? .accepted : .coalesced
            )
        }

        let drained = await pipeline.drain()
        let frame = try XCTUnwrap(drained.frame)
        XCTAssertTrue(
            frame.candles.history === historyIdentity
        )
        XCTAssertTrue(
            frame.indicators.history === indicatorIdentity
        )
        XCTAssertEqual(
            frame.candles.liveTail?.closePrice,
            60_204
        )
        XCTAssertEqual(frame.indicators.livePoints.count, 11)
        for instanceID in ["ema.21", "ema.55", "ema.144"] {
            XCTAssertEqual(
                frame.indicators.livePoints.first {
                    $0.key.instanceID == instanceID
                }?.point.validity,
                .valid
            )
        }
        XCTAssertEqual(frame.indicators.legends.count, 10)
        let health = await pipeline.health()
        XCTAssertEqual(health.pendingLiveCount, 0)
        XCTAssertEqual(health.pendingBarrierCount, 0)
        XCTAssertNil(health.recoveryRequest)
    }

    func testChartDataPipelineDrainsEveryIncomingLiveKline()
        async throws {
        let epoch = KlineStreamEpoch(generation: 1)
        let pipeline = try XCTUnwrap(ChartDataPipeline(
            stream: stream,
            intervalMilliseconds: 3_600_000,
            epoch: epoch
        ))
        let history = (0..<200).map { index in
            marketCandle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 60_000 + Double(index)
            )
        }
        _ = await pipeline.installSnapshot(
            history,
            fetchedAtMilliseconds: 200 * 3_600_000,
            epoch: epoch
        )

        for sequence in 1...3 {
            let ingress = await pipeline.accept(
                payload: realtimePayload(
                    sequence: sequence,
                    openTime: 200 * 3_600_000,
                    closePrice: 60_200 + Double(sequence),
                    closed: false
                ),
                sequence: Int64(sequence),
                epoch: epoch
            )
            XCTAssertTrue(ingress.shouldDrain)
            let drained = await pipeline.drain()
            XCTAssertEqual(
                drained.frame?.candles.liveTail?.closePrice,
                60_200 + Double(sequence)
            )
        }
    }

    func testChartDataPipelineMergesTickerIntoCurrentCandleAndIndicators()
        async throws {
        let epoch = KlineStreamEpoch(generation: 2)
        let pipeline = try XCTUnwrap(ChartDataPipeline(
            stream: stream,
            intervalMilliseconds: 3_600_000,
            epoch: epoch
        ))
        let snapshot = (0...200).map { index in
            marketCandle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 60_000 + Double(index)
            )
        }
        let installed = await pipeline.installSnapshot(
            snapshot,
            fetchedAtMilliseconds:
                200 * 3_600_000 + 1_800_000,
            epoch: epoch
        )
        let initial = try XCTUnwrap(installed.frame)
        let historyIdentity = initial.candles.history
        let indicatorIdentity = initial.indicators.history
        let initialEMA21 = try XCTUnwrap(
            initial.indicators.legends.first {
                $0.instanceID == "ema.21"
            }?.value
        )

        let rising = await pipeline.mergeLatestPrice(
            60_500,
            eventTimeMilliseconds:
                200 * 3_600_000 + 1_900_000,
            epoch: epoch
        )
        let risingFrame = try XCTUnwrap(rising.frame)
        XCTAssertTrue(risingFrame.candles.history === historyIdentity)
        XCTAssertTrue(
            risingFrame.indicators.history === indicatorIdentity
        )
        XCTAssertEqual(
            risingFrame.candles.liveTail?.openTime,
            200 * 3_600_000
        )
        XCTAssertEqual(
            risingFrame.candles.liveTail?.closePrice,
            60_500
        )
        XCTAssertEqual(
            risingFrame.candles.liveTail?.highPrice,
            60_500
        )
        XCTAssertEqual(
            risingFrame.candles.liveTail?.lowPrice,
            60_199
        )
        let risingEMA21 = try XCTUnwrap(
            risingFrame.indicators.legends.first {
                $0.instanceID == "ema.21"
            }?.value
        )
        XCTAssertNotEqual(risingEMA21, initialEMA21)
        let superTrendLegend = try XCTUnwrap(
            risingFrame.indicators.legends.first {
                $0.instanceID.hasPrefix("supertrend.")
            }
        )
        let superTrendLivePoint = try XCTUnwrap(
            risingFrame.indicators.livePoints.first {
                $0.key.instanceID.hasPrefix("supertrend.")
                    && $0.point.validity == .valid
            }?.point
        )
        XCTAssertEqual(superTrendLegend.value, superTrendLivePoint.value)
        XCTAssertEqual(
            superTrendLivePoint.openTime,
            risingFrame.candles.liveTail?.openTime
        )

        let falling = await pipeline.mergeLatestPrice(
            59_000,
            eventTimeMilliseconds:
                200 * 3_600_000 + 2_000_000,
            epoch: epoch
        )
        let fallingFrame = try XCTUnwrap(falling.frame)
        XCTAssertEqual(
            fallingFrame.candles.liveTail?.closePrice,
            59_000
        )
        XCTAssertEqual(
            fallingFrame.candles.liveTail?.highPrice,
            60_500
        )
        XCTAssertEqual(
            fallingFrame.candles.liveTail?.lowPrice,
            59_000
        )

        let stale = await pipeline.mergeLatestPrice(
            61_000,
            eventTimeMilliseconds:
                200 * 3_600_000 + 1_950_000,
            epoch: epoch
        )
        XCTAssertNil(stale.frame)
        let health = await pipeline.health()
        XCTAssertNil(health.lastReceivedSequence)
        XCTAssertNil(health.recoveryRequest)
    }

    func testChartDataPipelineKeepsPreviousCandleVisibleWhenTickerRollsOver() async throws {
        let epoch = KlineStreamEpoch(generation: 31)
        let width: Int64 = 3_600_000
        let pipeline = try XCTUnwrap(ChartDataPipeline(stream: stream,
            intervalMilliseconds: width, epoch: epoch))
        let candles = (0...1).map { marketCandle(openTime: Int64($0) * width,
            closePrice: 60_000 + Double($0)) }
        let initial = await pipeline.installSnapshot(candles,
            fetchedAtMilliseconds: 1 * width + 1, epoch: epoch)
        let previous = try XCTUnwrap(initial.frame?.candles.liveTail)

        let rolled = await pipeline.mergeLatestPrice(60_250,
            eventTimeMilliseconds: 2 * width + 1, epoch: epoch)
        let frame = try XCTUnwrap(rolled.frame)
        let visible = frame.candles.history.candles + [try XCTUnwrap(frame.candles.liveTail)]
        XCTAssertEqual(visible.map(\.openTime), (0...2).map { Int64($0) * width },
            "The previous live bar must remain visible before its trusted close or HTTP repair arrives")
        XCTAssertEqual(visible.first { $0.openTime == previous.openTime }?.closePrice, previous.closePrice)
        XCTAssertEqual(frame.candles.liveTail?.openTime, 2 * width)
    }

    func testChartDataPipelineKeepsPreviousCandleVisibleWhenSocketRollsOver() async throws {
        let epoch = KlineStreamEpoch(generation: 32)
        let width: Int64 = 3_600_000
        let pipeline = try XCTUnwrap(ChartDataPipeline(stream: stream,
            intervalMilliseconds: width, epoch: epoch))
        let candles = (0...1).map { marketCandle(openTime: Int64($0) * width,
            closePrice: 60_000 + Double($0)) }
        _ = await pipeline.installSnapshot(candles,
            fetchedAtMilliseconds: 1 * width + 1, epoch: epoch)
        _ = await pipeline.accept(payload: realtimePayload(sequence: 1,
            openTime: 1 * width, closePrice: 60_210, closed: false), sequence: 1, epoch: epoch)
        _ = await pipeline.drain()
        _ = await pipeline.accept(payload: realtimePayload(sequence: 2,
            openTime: 2 * width, closePrice: 60_250, closed: false), sequence: 2, epoch: epoch)
        let rolled = await pipeline.drain()
        let frame = try XCTUnwrap(rolled.frame)
        let visible = frame.candles.history.candles + [try XCTUnwrap(frame.candles.liveTail)]
        XCTAssertEqual(visible.map(\.openTime), (0...2).map { Int64($0) * width },
            "A missing close must request recovery without removing the previous candle")
        XCTAssertEqual(visible.first { $0.openTime == 1 * width }?.closePrice, 60_210)
        XCTAssertEqual(rolled.recoveryRequest?.reason, .missingTrustedClose(openTime: 1 * width))
    }

    func testChartDataPipelineRolloverKeepsIndicatorsAndLateCloseConsistent() async throws {
        let epoch = KlineStreamEpoch(generation: 33)
        let width: Int64 = 3_600_000
        let pipeline = try XCTUnwrap(ChartDataPipeline(stream: stream,
            intervalMilliseconds: width, epoch: epoch))
        let history = (0...200).map { marketCandle(openTime: Int64($0) * width,
            closePrice: 60_000 + Double($0)) }
        _ = await pipeline.installSnapshot(history, fetchedAtMilliseconds: 200 * width + 1, epoch: epoch)
        let rolled = await pipeline.mergeLatestPrice(60_250,
            eventTimeMilliseconds: 201 * width + 1, epoch: epoch)
        let preview = try XCTUnwrap(rolled.frame)
        XCTAssertEqual(preview.candles.history.candles.last?.closure, .unverifiedClosed)
        XCTAssertTrue(preview.indicators.history.series.allSatisfy { $0.points.count == 201 },
            "Display indicators must keep their time slots aligned with the retained rollover candle")
        XCTAssertNotNil(preview.indicators.legends.first { $0.instanceID == "ema.21" }?.value)
        let next = await pipeline.mergeLatestPrice(60_251,
            eventTimeMilliseconds: 201 * width + 2, epoch: epoch)
        XCTAssertTrue(next.frame?.indicators.history === preview.indicators.history,
            "Ticks while awaiting the close must reuse the display history")

        _ = await pipeline.accept(payload: realtimePayload(sequence: 1,
            openTime: 200 * width, closePrice: 60_220, closed: true), sequence: 1, epoch: epoch)
        let closed = await pipeline.drain()
        let confirmed = try XCTUnwrap(closed.frame)
        XCTAssertNil(closed.recoveryRequest, "An unverified display bar must not be committed to the real indicator engine")
        XCTAssertEqual(confirmed.candles.history.candles.last?.closure, .closed)
        XCTAssertEqual(confirmed.candles.history.candles.last?.closePrice, 60_220)
        XCTAssertEqual(confirmed.candles.liveTail?.openTime, 201 * width)
        XCTAssertEqual(confirmed.candles.history.candles.filter { $0.openTime == 200 * width }.count, 1)
        let reference = try XCTUnwrap(ChartDataPipeline(stream: stream,
            intervalMilliseconds: width, epoch: epoch))
        let corrected = Array(history.dropLast()) + [marketCandle(openTime: 200 * width, closePrice: 60_220)]
        _ = await reference.installSnapshot(corrected, fetchedAtMilliseconds: 201 * width + 1, epoch: epoch)
        let expected = await reference.mergeLatestPrice(60_251,
            eventTimeMilliseconds: 201 * width + 2, epoch: epoch)
        XCTAssertEqual(confirmed.indicators.history.series.map(\.points), expected.frame?.indicators.history.series.map(\.points))
        XCTAssertEqual(confirmed.indicators.legends.first { $0.instanceID == "ema.21" }?.value,
            expected.frame?.indicators.legends.first { $0.instanceID == "ema.21" }?.value)
    }

    func testChartDataPipelineRolloverStaysVisibleAcrossIntervalsAndStaleSnapshots() async throws {
        for (interval, width) in [("1m", Int64(60_000)), ("5m", 300_000), ("1h", 3_600_000), ("1w", 604_800_000)] {
            let base: Int64 = interval == "1w" ? 345_600_000 : 0
            let epoch = KlineStreamEpoch(generation: 34)
            let pipeline = try XCTUnwrap(ChartDataPipeline(stream: ChartStreamKey(symbol: "BTCUSDT", interval: interval),
                intervalMilliseconds: width, epoch: epoch))
            let history = (0...1).map { index in
                MarketCandle(openTime: base + Int64(index) * width, closeTime: base + Int64(index + 1) * width - 1,
                    openPrice: 100, highPrice: 110, lowPrice: 99, closePrice: 105, volume: 10, quoteVolume: 1000)
            }
            _ = await pipeline.installSnapshot(history, fetchedAtMilliseconds: base + width + 1, epoch: epoch)
            let result = await pipeline.mergeLatestPrice(106, eventTimeMilliseconds: base + 2 * width + 1, epoch: epoch)
            let frame = try XCTUnwrap(result.frame)
            XCTAssertEqual(frame.candles.history.candles.map(\.openTime), [base, base + width], interval)
            XCTAssertEqual(frame.candles.history.candles.last?.closure, .unverifiedClosed, interval)
            XCTAssertEqual(frame.candles.liveTail?.openTime, base + 2 * width, interval)
            XCTAssertEqual(frame.candles.liveTail?.openPrice, 105, "The new quote-only bar starts at the previous bar's close")
            let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 396, displayScale: 3))
            let scene = try await ChartSceneBuilder().build(frame: frame, viewport: viewport)
            XCTAssertEqual(scene.renderState.staticScene.batches.flatMap { $0.storage.candleInstances }.count, 2, interval)
            XCTAssertEqual(scene.renderState.liveTail.batches.flatMap { $0.storage.candleInstances }.count, 1, interval)

            let delayed = await pipeline.installSnapshot(history, fetchedAtMilliseconds: base + width + 2,
                epoch: epoch, preservingNewerData: true)
            XCTAssertEqual(delayed.frame?.candles.history.candles.last?.closure, .unverifiedClosed, interval)
            XCTAssertEqual(delayed.frame?.candles.liveTail?.openTime, base + 2 * width, interval)
            XCTAssertEqual(delayed.frame?.candles.history.candles.count, 2, interval)
        }
    }

    func testChartDataPipelineRolloverSnapshotAndPaginationKeepUnverifiedClosure() async throws {
        let width: Int64 = 3_600_000
        let epoch = KlineStreamEpoch(generation: 35)
        let pipeline = try XCTUnwrap(ChartDataPipeline(stream: stream,
            intervalMilliseconds: width, epoch: epoch))
        let initial = [marketCandle(openTime: 10 * width, closePrice: 110),
            marketCandle(openTime: 11 * width, closePrice: 111)]
        _ = await pipeline.installSnapshot(initial, fetchedAtMilliseconds: 11 * width + 1, epoch: epoch)
        let ahead = await pipeline.installSnapshot([initial[0], marketCandle(openTime: 12 * width, closePrice: 112)],
            fetchedAtMilliseconds: 12 * width + 1, epoch: epoch, preservingNewerData: true)
        XCTAssertEqual(ahead.frame?.candles.history.candles.map(\.openTime), [10 * width, 11 * width])
        XCTAssertEqual(ahead.frame?.candles.history.candles.last?.closure, .unverifiedClosed)
        let page = await pipeline.prependHistory([marketCandle(openTime: 9 * width, closePrice: 109)], epoch: epoch)
        XCTAssertEqual(page.frame?.candles.history.candles.map(\.openTime), [9 * width, 10 * width, 11 * width])
        XCTAssertEqual(page.frame?.candles.history.candles.last?.closure, .unverifiedClosed,
            "Pagination must not turn a display-only rollover bar into a trusted close")
        _ = await pipeline.accept(payload: realtimePayload(sequence: 1,
            openTime: 11 * width, closePrice: 111.5, closed: true), sequence: 1, epoch: epoch)
        let confirmed = await pipeline.drain()
        XCTAssertNil(confirmed.recoveryRequest)
        XCTAssertEqual(confirmed.frame?.candles.history.candles.last?.closure, .closed)
        XCTAssertEqual(confirmed.frame?.candles.liveTail?.openTime, 12 * width)
    }

    func testChartDataPipelineRolloverDefersOutOfOrderClosesUntilSnapshotRecovery() async throws {
        let width: Int64 = 3_600_000
        let epoch = KlineStreamEpoch(generation: 36)
        let pipeline = try XCTUnwrap(ChartDataPipeline(stream: stream,
            intervalMilliseconds: width, epoch: epoch, historyLimit: 3))
        _ = await pipeline.installSnapshot([marketCandle(openTime: 0, closePrice: 100),
            marketCandle(openTime: width, closePrice: 101)], fetchedAtMilliseconds: width + 1, epoch: epoch)
        for index in 2...4 {
            _ = await pipeline.mergeLatestPrice(100 + Double(index),
                eventTimeMilliseconds: Int64(index) * width + 1, epoch: epoch)
        }
        let pending = await pipeline.currentFrame()
        XCTAssertEqual(pending.candles.history.candles.map(\.openTime), [width, 2 * width, 3 * width])
        XCTAssertTrue(pending.candles.history.candles.allSatisfy { $0.closure == .unverifiedClosed })
        _ = await pipeline.accept(payload: realtimePayload(sequence: 1,
            openTime: 3 * width, closePrice: 103.5, closed: true), sequence: 1, epoch: epoch)
        let outOfOrder = await pipeline.drain()
        XCTAssertNotNil(outOfOrder.recoveryRequest)
        XCTAssertEqual(outOfOrder.frame?.candles.history.candles.count, 3)
        XCTAssertEqual(outOfOrder.frame?.candles.history.candles.first?.closure, .unverifiedClosed)

        // The bounded snapshot contains all three closed bars; preserve the
        // newer quote tail separately instead of exceeding the response limit.
        let snapshot = (1...3).map { marketCandle(openTime: Int64($0) * width,
            closePrice: 100 + Double($0) + 0.5) }
        let repaired = await pipeline.installSnapshot(snapshot,
            fetchedAtMilliseconds: 4 * width + 2, epoch: epoch, preservingNewerData: true)
        XCTAssertNil(repaired.recoveryRequest)
        XCTAssertEqual(repaired.frame?.candles.history.candles.map(\.closure), [.closed, .closed, .closed])
        XCTAssertEqual(repaired.frame?.candles.history.candles.count, 3)
        XCTAssertTrue(repaired.frame?.indicators.history.series.allSatisfy { $0.points.count == 3 } == true)
        XCTAssertEqual(repaired.frame?.candles.liveTail?.openTime, 4 * width)
    }

    func testChartDataPipelineCreatesLiveTailImmediatelyAfterClosedSnapshot()
        async throws {
        let epoch = KlineStreamEpoch(generation: 22)
        let intervalMilliseconds: Int64 = 3_600_000
        let pipeline = try XCTUnwrap(ChartDataPipeline(
            stream: stream,
            intervalMilliseconds: intervalMilliseconds,
            epoch: epoch
        ))
        let history = (0..<200).map { index in
            marketCandle(
                openTime: Int64(index) * intervalMilliseconds,
                closePrice: 60_000 + Double(index)
            )
        }
        let currentOpenTime = Int64(200) * intervalMilliseconds
        let installed = await pipeline.installSnapshot(
            history,
            fetchedAtMilliseconds: currentOpenTime + 1,
            epoch: epoch
        )
        XCTAssertNil(installed.frame?.candles.liveTail)

        let seeded = await pipeline.mergeLatestPrice(
            60_250,
            eventTimeMilliseconds: currentOpenTime + 2,
            epoch: epoch
        )

        let live = try XCTUnwrap(seeded.frame?.candles.liveTail)
        XCTAssertEqual(live.openTime, currentOpenTime)
        XCTAssertEqual(live.closePrice, 60_250)
        XCTAssertEqual(live.openPrice, 60_199, "A quote-only tail must start from the adjacent closed candle")
        XCTAssertEqual(live.lowPrice, 60_199)
        XCTAssertEqual(live.closure, .provisional)
    }

    func testWeeklyQuoteTailUsesMondayBucketAndKeepsSnapshotOHLC() async throws {
        let epoch = KlineStreamEpoch(generation: 1)
        let width: Int64 = 604_800_000
        let monday: Int64 = 1_793_577_600_000 // 2026-11-02 00:00 UTC
        let pipeline = try XCTUnwrap(ChartDataPipeline(stream: ChartStreamKey(symbol: "BTCUSDT", interval: "1w"),
            intervalMilliseconds: width, epoch: epoch))
        let history = MarketCandle(openTime: monday - width, closeTime: monday - 1,
            openPrice: 100, highPrice: 105, lowPrice: 99, closePrice: 102, volume: 10, quoteVolume: 1000)
        _ = await pipeline.installSnapshot([history], fetchedAtMilliseconds: monday + 1, epoch: epoch)
        let result = await pipeline.mergeLatestPrice(103,
            eventTimeMilliseconds: monday + 86_400_000, epoch: epoch)
        let live = try XCTUnwrap(result.frame?.candles.liveTail)
        XCTAssertEqual(live.openTime, monday)
        XCTAssertEqual(live.closeTime, monday + width - 1)
        XCTAssertEqual(live.openPrice, 102)
        XCTAssertEqual(live.closePrice, 103)
    }

    func testRepairSnapshotCorrectsQuoteOnlyOpenWithoutLosingLatestClose() async throws {
        let epoch = KlineStreamEpoch(generation: 23)
        let pipeline = try XCTUnwrap(ChartDataPipeline(stream: stream,
            intervalMilliseconds: 3_600_000, epoch: epoch))
        _ = await pipeline.installSnapshot([marketCandle(openTime: 0, closePrice: 100)],
            fetchedAtMilliseconds: 3_600_001, epoch: epoch)
        _ = await pipeline.mergeLatestPrice(140, eventTimeMilliseconds: 3_600_001, epoch: epoch)
        _ = await pipeline.mergeLatestPrice(120, eventTimeMilliseconds: 3_600_002, epoch: epoch)
        let authoritative = MarketCandle(openTime: 3_600_000, closeTime: 7_199_999,
            openPrice: 111, highPrice: 130, lowPrice: 108, closePrice: 110,
            volume: 30, quoteVolume: 3300)
        let repaired = await pipeline.installSnapshot([authoritative],
            fetchedAtMilliseconds: 3_600_003, epoch: epoch, preservingNewerData: true)
        let live = try XCTUnwrap(repaired.frame?.candles.liveTail)
        XCTAssertEqual(live.openPrice, 111)
        XCTAssertEqual(live.closePrice, 120)
        XCTAssertEqual(live.highPrice, 140)
        XCTAssertEqual(live.lowPrice, 108, "The seeded previous close must not survive as a false low after the real OHLC arrives")
        XCTAssertEqual(live.volume, 30)
    }

    func testChartDataPipelineSwitchesIndicatorsWithoutLosingIngress()
        async throws {
        let epoch = KlineStreamEpoch(generation: 20)
        let pipeline = try XCTUnwrap(
            ChartDataPipeline(
                stream: stream,
                intervalMilliseconds: 3_600_000,
                epoch: epoch
            )
        )
        let history = (0..<200).map { index in
            marketCandle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 55_000 + Double(index)
            )
        }
        let installed = await pipeline.installSnapshot(
            history,
            fetchedAtMilliseconds: 200 * 3_600_000,
            epoch: epoch
        )
        let initial = try XCTUnwrap(installed.frame)
        let candleHistory = initial.candles.history

        let accepted = await pipeline.accept(
            payload: realtimePayload(
                sequence: 1,
                openTime: 200 * 3_600_000,
                closePrice: 55_201,
                closed: false
            ),
            sequence: 1,
            epoch: epoch
        )
        XCTAssertEqual(accepted.disposition, .accepted)

        let volumeSelection = try XCTUnwrap(
            ChartIndicatorSelection(activeIndicatorsInOrder: [
                .ema,
                .superTrend,
                .volume,
            ])
        )
        let switchedResult = await pipeline.updateIndicatorConfiguration(
            selection: volumeSelection,
            parameters: .standard,
            revision: 1
        )
        let switched = try XCTUnwrap(switchedResult)
        let volumeFrame = try XCTUnwrap(switched.frame)
        XCTAssertTrue(
            volumeFrame.candles.history === candleHistory
        )
        XCTAssertTrue(
            volumeFrame.indicators.history.series.contains {
                $0.placement == .panel(ChartPanelID.volume)
            }
        )
        XCTAssertFalse(
            volumeFrame.indicators.history.series.contains {
                $0.placement == .panel(ChartPanelID.macd)
            }
        )
        let healthWhilePending = await pipeline.health()
        XCTAssertEqual(healthWhilePending.pendingLiveCount, 1)
        XCTAssertEqual(
            healthWhilePending.indicatorSelection,
            volumeSelection
        )
        XCTAssertEqual(
            healthWhilePending.indicatorConfigurationRevision,
            1
        )
        XCTAssertEqual(
            healthWhilePending.indicatorParameters,
            .standard
        )
        let stale = await pipeline.updateIndicatorConfiguration(
            selection: .standard,
            parameters: .standard,
            revision: 1
        )
        XCTAssertNil(stale)

        let builder = ChartSceneBuilder()
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: 396,
            displayScale: 3
        ))
        let volumeScene = try await builder.build(
            frame: volumeFrame,
            viewport: viewport
        )
        XCTAssertEqual(
            volumeScene.panelLayout.indicatorPanels.map(\.id),
            [ChartPanelID.volume]
        )
        XCTAssertEqual(
            volumeScene.renderState.liveTail.displayedLegends.filter {
                $0.placement == .panel(ChartPanelID.volume)
            }.map(\.label),
            ["VOL(BTC):", "VOL(USDC):", "MA(5):", "MA(10):"]
        )
        XCTAssertEqual(
            volumeScene.renderState.liveTail.displayedLegends.first {
                $0.label == "VOL(USDC):"
            }?.value,
            history.last?.quoteVolume
        )
        let crosshairData = try XCTUnwrap(
            volumeScene.renderState.staticScene.crosshairData
        )
        let volumePanel = try XCTUnwrap(
            crosshairData.panelLayout.panel(
                id: ChartPanelID.volume
            )
        )
        let selectedIndex = history.count - 1
        let volumeHit = try XCTUnwrap(
            ChartCrosshairResolver.resolve(
                screenX: try XCTUnwrap(
                    crosshairData.baselineX(
                        globalSlot: selectedIndex
                    )
                ),
                screenY: Double(
                    (volumePanel.plot.top
                        + volumePanel.plot.bottom) / 2
                ),
                transform: .identity,
                data: crosshairData,
                liveData: volumeScene.renderState.liveTail
                    .crosshairLiveData,
                preferredOpenTime: history[selectedIndex]
                    .openTime,
                preferredPanelID: ChartPanelID.volume,
                clampsToPlot: true
            )
        )
        let crosshairVolumeValues = volumeHit.indicatorValues.filter {
            $0.placement == .panel(ChartPanelID.volume)
        }
        XCTAssertEqual(
            crosshairVolumeValues.map(\.label),
            ["VOL(BTC):", "VOL(USDC):", "MA(5):", "MA(10):"]
        )
        XCTAssertEqual(
            crosshairVolumeValues.first {
                $0.label == "VOL(USDC):"
            }?.value,
            history[selectedIndex].quoteVolume
        )

        let drained = await pipeline.drain()
        let liveFrame = try XCTUnwrap(drained.frame)
        XCTAssertEqual(
            liveFrame.candles.liveTail?.closePrice,
            55_201
        )
        XCTAssertTrue(
            liveFrame.indicators.livePoints.contains {
                $0.key.instanceID == "volume.5.10"
            }
        )

        let customParameters = try XCTUnwrap(
            ChartIndicatorParameters(
                emaPeriods: [8, 21, 55],
                superTrendATRPeriod: 14,
                superTrendMultiplier: 3.5,
                volumeFastPeriod: 7,
                volumeSlowPeriod: 20,
                macdFastPeriod: 8,
                macdSlowPeriod: 21,
                macdSignalPeriod: 5
            )
        )
        let parameterResult = await pipeline
            .updateIndicatorConfiguration(
                selection: volumeSelection,
                parameters: customParameters,
                revision: 2
            )
        let parameterFrame = try XCTUnwrap(parameterResult?.frame)
        XCTAssertTrue(
            parameterFrame.candles.history === candleHistory
        )
        XCTAssertTrue(
            parameterFrame.indicators.history.series.contains {
                $0.key.instanceID == "volume.7.20"
            }
        )

        let noPanelSelection = volumeSelection.toggling(.volume)
        let noPanelResult = await pipeline.updateIndicatorConfiguration(
            selection: noPanelSelection,
            parameters: customParameters,
            revision: 3
        )
        let noPanel = try XCTUnwrap(noPanelResult?.frame)
        XCTAssertEqual(noPanel.indicators.history.series.count, 5)
        let noPanelScene = try await builder.build(
            frame: noPanel,
            viewport: viewport
        )
        XCTAssertTrue(noPanelScene.panelLayout.indicatorPanels.isEmpty)

        let emptySelection = try XCTUnwrap(
            ChartIndicatorSelection(activeIndicatorsInOrder: [])
        )
        let emptyResult = await pipeline.updateIndicatorConfiguration(
            selection: emptySelection,
            parameters: customParameters,
            revision: 4
        )
        let empty = try XCTUnwrap(emptyResult?.frame)
        XCTAssertTrue(empty.indicators.history.series.isEmpty)
        XCTAssertTrue(empty.indicators.legends.isEmpty)
        let finalHealth = await pipeline.health()
        XCTAssertEqual(
            finalHealth.pendingLiveCount,
            0
        )
    }

    func testChartDataPipelineSequenceGapRecoversFromSnapshot()
        async throws {
        let epoch = KlineStreamEpoch(generation: 7)
        let pipeline = try XCTUnwrap(
            ChartDataPipeline(
                stream: stream,
                intervalMilliseconds: 3_600_000,
                epoch: epoch
            )
        )
        let history = (0..<160).map { index in
            marketCandle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 50_000 + Double(index)
            )
        }
        _ = await pipeline.installSnapshot(
            history,
            fetchedAtMilliseconds: 160 * 3_600_000,
            epoch: epoch
        )

        _ = await pipeline.accept(
            payload: realtimePayload(
                sequence: 10,
                openTime: 160 * 3_600_000,
                closePrice: 50_160,
                closed: false
            ),
            sequence: 10,
            epoch: epoch
        )
        _ = await pipeline.drain()
        let gap = await pipeline.accept(
            payload: realtimePayload(
                sequence: 12,
                openTime: 160 * 3_600_000,
                closePrice: 50_162,
                closed: false
            ),
            sequence: 12,
            epoch: epoch
        )
        XCTAssertEqual(
            gap.disposition,
            .recoveryRequired(
                .sequenceGap(expected: 11, received: 12)
            )
        )

        let snapshotWithLive = history + [
            marketCandle(
                openTime: 160 * 3_600_000,
                closePrice: 50_161
            ),
        ]
        let recovered = await pipeline.installSnapshot(
            snapshotWithLive,
            fetchedAtMilliseconds:
                160 * 3_600_000 + 1,
            epoch: epoch
        )
        let frame = try XCTUnwrap(recovered.frame)
        XCTAssertNil(recovered.recoveryRequest)
        XCTAssertEqual(
            frame.candles.history.candles.count,
            160
        )
        XCTAssertEqual(
            frame.candles.liveTail?.closePrice,
            50_162
        )
        let health = await pipeline.health()
        XCTAssertEqual(health.lastReceivedSequence, 12)
        XCTAssertNil(health.recoveryRequest)
    }

    func testChartDataPipelineRejectsStaleEpochAfterReconnect()
        async throws {
        let firstEpoch = KlineStreamEpoch(generation: 1)
        let secondEpoch = KlineStreamEpoch(generation: 2)
        let pipeline = try XCTUnwrap(
            ChartDataPipeline(
                stream: stream,
                intervalMilliseconds: 3_600_000,
                epoch: firstEpoch
            )
        )
        let history = (0..<150).map { index in
            marketCandle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 40_000 + Double(index)
            )
        }
        _ = await pipeline.installSnapshot(
            history,
            fetchedAtMilliseconds: 150 * 3_600_000,
            epoch: firstEpoch
        )

        let request = await pipeline.beginEpoch(secondEpoch)
        XCTAssertEqual(request?.reason, .epochChanged)
        let stale = await pipeline.accept(
            payload: realtimePayload(
                sequence: 1,
                openTime: 150 * 3_600_000,
                closePrice: 40_150,
                closed: false
            ),
            sequence: 1,
            epoch: firstEpoch
        )
        XCTAssertEqual(
            stale.disposition,
            .ignoredWrongEpochOrStream
        )
        let staleSnapshot = await pipeline.installSnapshot(
            history,
            fetchedAtMilliseconds: 150 * 3_600_000,
            epoch: firstEpoch
        )
        XCTAssertNil(staleSnapshot.frame)
        XCTAssertEqual(
            staleSnapshot.recoveryRequest?.epoch,
            secondEpoch
        )

        let recovered = await pipeline.installSnapshot(
            history,
            fetchedAtMilliseconds: 150 * 3_600_000,
            epoch: secondEpoch
        )
        XCTAssertNotNil(recovered.frame)
        XCTAssertNil(recovered.recoveryRequest)
        let health = await pipeline.health()
        XCTAssertEqual(health.epoch, secondEpoch)
    }

    func testChartDataPipelineEmptySnapshotKeepsRecoveryAndVisibleData()
        async throws {
        let epoch = KlineStreamEpoch(generation: 3)
        let pipeline = try XCTUnwrap(
            ChartDataPipeline(
                stream: stream,
                intervalMilliseconds: 3_600_000,
                epoch: epoch
            )
        )
        let history = (0..<150).map { index in
            marketCandle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 30_000 + Double(index)
            )
        }
        let installed = await pipeline.installSnapshot(
            history,
            fetchedAtMilliseconds: 150 * 3_600_000,
            epoch: epoch
        )
        let visibleHistory = try XCTUnwrap(
            installed.frame?.candles.history
        )

        _ = await pipeline.beginEpoch(
            KlineStreamEpoch(generation: 4)
        )
        let healthBefore = await pipeline.health()
        let empty = await pipeline.installSnapshot(
            [],
            fetchedAtMilliseconds: 151 * 3_600_000,
            epoch: healthBefore.epoch
        )
        XCTAssertNil(empty.frame)
        XCTAssertEqual(
            empty.recoveryRequest?.reason,
            .epochChanged
        )
        let current = await pipeline.currentFrame()
        XCTAssertTrue(
            current.candles.history === visibleHistory
        )
        XCTAssertEqual(
            current.candles.history.candles.count,
            150
        )
    }

    func testChartDataPipelineCommitsCloseAndRecoversCorrection()
        async throws {
        let epoch = KlineStreamEpoch(generation: 5)
        let pipeline = try XCTUnwrap(
            ChartDataPipeline(
                stream: stream,
                intervalMilliseconds: 3_600_000,
                epoch: epoch
            )
        )
        let history = (0..<150).map { index in
            marketCandle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 20_000 + Double(index)
            )
        }
        let installed = await pipeline.installSnapshot(
            history,
            fetchedAtMilliseconds: 150 * 3_600_000,
            epoch: epoch
        )
        let priorHistory = try XCTUnwrap(
            installed.frame?.candles.history
        )
        let priorIndicators = try XCTUnwrap(
            installed.frame?.indicators.history
        )

        let accepted = await pipeline.accept(
            payload: realtimePayload(
                sequence: 1,
                openTime: 150 * 3_600_000,
                closePrice: 20_150,
                closed: true
            ),
            sequence: 1,
            epoch: epoch
        )
        XCTAssertEqual(accepted.disposition, .accepted)
        let committed = await pipeline.drain()
        let frame = try XCTUnwrap(committed.frame)
        XCTAssertNil(committed.recoveryRequest)
        XCTAssertEqual(
            frame.candles.history.candles.count,
            151
        )
        XCTAssertNil(frame.candles.liveTail)
        XCTAssertFalse(
            frame.candles.history === priorHistory
        )
        XCTAssertFalse(
            frame.indicators.history === priorIndicators
        )
        XCTAssertTrue(
            frame.indicators.history.series.allSatisfy {
                $0.points.count == 151
            }
        )

        _ = await pipeline.accept(
            payload: realtimePayload(
                sequence: 2,
                openTime: 150 * 3_600_000,
                closePrice: 20_151,
                closed: true
            ),
            sequence: 2,
            epoch: epoch
        )
        let corrected = await pipeline.drain()
        XCTAssertEqual(
            corrected.recoveryRequest?.reason,
            .downstreamStateInvalid(
                openTime: 150 * 3_600_000
            )
        )
        XCTAssertEqual(
            corrected.frame?.candles.history.candles
                .last?.closePrice,
            20_151
        )
    }

    func testTimelineViewportUsesFractionalPanAndLatestBounds()
        throws {
        let metrics = ChartInteractionMetrics.standard
        let latest = ChartTimelineViewport.latest(
            totalWidthPoints: 390,
            metrics: metrics
        )
        let plotWidth = metrics.plotWidth(totalWidthPoints: 390)
        let halfSlotPan = latest.panned(
            translationPoints: metrics.defaultPointsPerSlot / 2,
            plotWidthPoints: plotWidth,
            totalSlotCount: 500,
            metrics: metrics
        )

        XCTAssertEqual(
            halfSlotPan.trailingOffsetSlots,
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertFalse(halfSlotPan.followsLatest)
        XCTAssertTrue(halfSlotPan.containsLatestSlot)
        XCTAssertFalse(
            latest.panned(
                translationPoints:
                    metrics.defaultPointsPerSlot * 0.6,
                plotWidthPoints: plotWidth,
                totalSlotCount: 500,
                metrics: metrics
            ).containsLatestSlot
        )
        let maximumFutureBlank = latest.panned(
            translationPoints: -1_000,
            plotWidthPoints: plotWidth,
            totalSlotCount: 500,
            metrics: metrics
        )
        XCTAssertFalse(maximumFutureBlank.followsLatest)
        let expectedLatestBoundaryOffset =
            metrics.latestBoundaryVisibleCandleCount
            - maximumFutureBlank.visibleSlotCount
        XCTAssertEqual(
            maximumFutureBlank.trailingOffsetSlots,
            expectedLatestBoundaryOffset,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            maximumFutureBlank.visibleSlotCount
                - 0.5
                + maximumFutureBlank.trailingOffsetSlots,
            metrics.latestBoundaryVisibleCandleCount - 0.5,
            accuracy: 0.000_001
        )
        XCTAssertTrue(maximumFutureBlank.containsLatestSlot)
        XCTAssertNil(ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: -60
        ))
        XCTAssertTrue(
            maximumFutureBlank.returningToLatest(
                totalSlotCount: 500,
                metrics: metrics
            ).followsLatest
        )

        let oldest = latest.panned(
            translationPoints: 1_000_000,
            plotWidthPoints: plotWidth,
            totalSlotCount: 500,
            metrics: metrics
        )
        XCTAssertEqual(
            oldest.trailingOffsetSlots,
            500 - oldest.visibleSlotCount,
            accuracy: 0.000_001
        )
        XCTAssertTrue(
            oldest.returningToLatest(
                totalSlotCount: 500,
                metrics: metrics
            ).followsLatest
        )
        XCTAssertEqual(
            halfSlotPan.preservingVisibleContent(
                appendedSlotCount: 2,
                totalSlotCount: 502,
                metrics: metrics
            ).trailingOffsetSlots,
            2.5,
            accuracy: 0.000_001
        )
        XCTAssertTrue(
            latest.preservingVisibleContent(
                appendedSlotCount: 2,
                totalSlotCount: 502,
                metrics: metrics
            ).followsLatest
        )
    }

    func testTimelinePinchPreservesTouchAnchor() throws {
        let baseline = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: 20
        ))
        let anchor = 0.25
        let anchoredDistance = baseline.trailingOffsetSlots
            + baseline.visibleSlotCount * (1 - anchor)
        let zoomed = baseline.pinched(
            scale: 2,
            anchorFraction: anchor,
            totalSlotCount: 500
        )

        XCTAssertEqual(
            zoomed.visibleSlotCount,
            30,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            zoomed.trailingOffsetSlots
                + zoomed.visibleSlotCount * (1 - anchor),
            anchoredDistance,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            baseline.pinched(
                scale: 100,
                anchorFraction: 1,
                totalSlotCount: 500
            ).visibleSlotCount,
            ChartInteractionMetrics.standard
                .minimumVisibleSlotCount
        )
    }

    func testTimelineInteractionTransformMatchesLogicalViewport()
        throws {
        let metrics = ChartInteractionMetrics.standard
        let baseline = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: 12
        ))
        let current = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 40,
            trailingOffsetSlots: 21
        ))
        let displayScale = 3.0
        let widthPoints = 390.0
        let transform = ChartTimelineInteractionTransform.mapping(
            from: baseline,
            to: current,
            totalWidthPoints: widthPoints,
            displayScale: displayScale,
            metrics: metrics
        )
        let plotLeft = metrics.plotLeftPixels(
            displayScale: displayScale
        )
        let plotWidth = metrics.plotWidthPixels(
            totalWidthPoints: widthPoints,
            displayScale: displayScale
        )
        let relativeSlot = -25.0
        let baselineX = plotLeft
            + (baseline.visibleSlotCount
                - 0.5
                + baseline.trailingOffsetSlots
                + relativeSlot)
                * plotWidth / baseline.visibleSlotCount
        let expectedCurrentX = plotLeft
            + (current.visibleSlotCount
                - 0.5
                + current.trailingOffsetSlots
                + relativeSlot)
                * plotWidth / current.visibleSlotCount

        XCTAssertEqual(
            baselineX * transform.scaleX
                + transform.translationPixels,
            expectedCurrentX,
            accuracy: 0.000_001
        )
        XCTAssertFalse(transform.isIdentity)
        XCTAssertTrue(
            ChartTimelineInteractionTransform.mapping(
                from: baseline,
                to: baseline,
                totalWidthPoints: widthPoints,
                displayScale: displayScale,
                metrics: metrics
            ).isIdentity
        )
    }

    func testTimelineGuardBandCoversZoomAndBoundsPanRebase()
        throws {
        let baseline = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: 80
        ))
        let zoomedOut = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 120,
            trailingOffsetSlots: 50
        ))
        let insidePan = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: 127.9
        ))
        let outsidePan = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: 128.1
        ))
        let guardCount = ChartInteractionMetrics.standard
            .guardBandSlotCount

        XCTAssertTrue(zoomedOut.isRenderable(
            from: baseline,
            guardBandSlotCount: guardCount
        ))
        XCTAssertTrue(insidePan.isRenderable(
            from: baseline,
            guardBandSlotCount: guardCount
        ))
        XCTAssertFalse(outsidePan.isRenderable(
            from: baseline,
            guardBandSlotCount: guardCount
        ))
    }

    func testTimelinePanUsesBoundedRubberBandAtBothEdges()
        throws {
        let interactionMetrics = ChartInteractionMetrics.standard
        let motionMetrics = ChartTimelineMotionMetrics.standard
        let plotWidth = interactionMetrics.plotWidth(
            totalWidthPoints: 390
        )
        let latest = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: -55
        ))
        let latestSample = latest.pannedWithBoundaryResistance(
            translationPoints: -400,
            plotWidthPoints: plotWidth,
            totalSlotCount: 500
        )

        XCTAssertEqual(latestSample.boundary, .latest)
        XCTAssertFalse(latestSample.viewport.followsLatest)
        XCTAssertEqual(
            latestSample.viewport.trailingOffsetSlots,
            -55,
            accuracy: 0.000_001
        )
        XCTAssertTrue(latestSample.viewport.containsLatestSlot)
        XCTAssertLessThan(latestSample.boundaryTranslationPoints, 0)
        XCTAssertLessThanOrEqual(
            abs(latestSample.boundaryTranslationPoints),
            motionMetrics.maximumBoundaryTranslationPoints
        )

        let oldest = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: 440
        ))
        let oldestSample = oldest.pannedWithBoundaryResistance(
            translationPoints: 400,
            plotWidthPoints: plotWidth,
            totalSlotCount: 500
        )
        XCTAssertEqual(oldestSample.boundary, .oldest)
        XCTAssertEqual(
            oldestSample.viewport.trailingOffsetSlots,
            440,
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(
            oldestSample.boundaryTranslationPoints,
            0
        )
        XCTAssertLessThanOrEqual(
            oldestSample.boundaryTranslationPoints,
            motionMetrics.maximumBoundaryTranslationPoints
        )

        let latestViewport = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: 0
        ))
        let interiorSample = latestViewport.pannedWithBoundaryResistance(
            translationPoints: plotWidth / 6,
            plotWidthPoints: plotWidth,
            totalSlotCount: 500
        )
        XCTAssertEqual(interiorSample.boundary, .none)
        XCTAssertEqual(
            interiorSample.viewport.trailingOffsetSlots,
            10,
            accuracy: 0.000_001
        )
        XCTAssertEqual(interiorSample.boundaryTranslationPoints, 0)
    }

    func testTimelineMotionDeceleratesAndSettlesWithinBound()
        throws {
        let interactionMetrics = ChartInteractionMetrics.standard
        let plotWidth = interactionMetrics.plotWidth(
            totalWidthPoints: 390
        )
        var viewport = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: 100
        ))
        var motion = ChartTimelineMotion()
        XCTAssertFalse(motion.begin(
            velocityPointsPerSecond: 250,
            boundaryTranslationPoints: 0
        ))
        XCTAssertTrue(motion.begin(
            velocityPointsPerSecond: 1_200,
            boundaryTranslationPoints: 0
        ))
        XCTAssertEqual(motion.phase, .decelerating)

        for _ in 0..<300 where motion.isActive {
            let step = motion.advance(
                from: viewport,
                deltaTimeSeconds: 1.0 / 120.0,
                plotWidthPoints: plotWidth,
                totalSlotCount: 500
            )
            viewport = step.viewport
        }

        XCTAssertFalse(motion.isActive)
        XCTAssertEqual(motion.phase, .idle)
        XCTAssertGreaterThan(viewport.trailingOffsetSlots, 100)
        XCTAssertLessThan(viewport.trailingOffsetSlots, 440)
        XCTAssertEqual(motion.boundaryTranslationPoints, 0)
    }

    func testTimelineMotionSpringsBackAtFutureBlankBoundary()
        throws {
        let interactionMetrics = ChartInteractionMetrics.standard
        let plotWidth = interactionMetrics.plotWidth(
            totalWidthPoints: 390
        )
        var viewport = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: -55
        ))
        var motion = ChartTimelineMotion()
        XCTAssertTrue(motion.begin(
            velocityPointsPerSecond: -1_200,
            boundaryTranslationPoints: 0
        ))

        let boundaryStep = motion.advance(
            from: viewport,
            deltaTimeSeconds: 1.0 / 60.0,
            plotWidthPoints: plotWidth,
            totalSlotCount: 500
        )
        viewport = boundaryStep.viewport
        XCTAssertEqual(motion.phase, .springing)
        XCTAssertLessThan(boundaryStep.boundaryTranslationPoints, 0)
        XCTAssertFalse(viewport.followsLatest)
        XCTAssertEqual(
            viewport.trailingOffsetSlots,
            -55,
            accuracy: 0.000_001
        )

        for _ in 0..<300 where motion.isActive {
            let step = motion.advance(
                from: viewport,
                deltaTimeSeconds: 1.0 / 120.0,
                plotWidthPoints: plotWidth,
                totalSlotCount: 500
            )
            viewport = step.viewport
        }

        XCTAssertFalse(motion.isActive)
        XCTAssertFalse(viewport.followsLatest)
        XCTAssertEqual(
            viewport.trailingOffsetSlots,
            -55,
            accuracy: 0.000_001
        )
        XCTAssertEqual(motion.boundaryTranslationPoints, 0)
    }

    func testPanDirectionAndInteractionStateMachine() {
        XCTAssertEqual(
            ChartPanDirectionResolver.ownership(
                velocityX: 500,
                velocityY: 100,
                initialX: 80
            ),
            .chart
        )
        XCTAssertEqual(
            ChartPanDirectionResolver.ownership(
                velocityX: 100,
                velocityY: 500,
                initialX: 80
            ),
            .parentScrollView
        )
        XCTAssertEqual(
            ChartPanDirectionResolver.ownership(
                velocityX: 500,
                velocityY: 0,
                initialX: 10
            ),
            .systemNavigation
        )
        // Match the 50 pt navigation start zone, including its boundary.
        for initialX in [40.0, 50.0] {
            XCTAssertEqual(
                ChartPanDirectionResolver.ownership(
                    velocityX: 500,
                    velocityY: 0,
                    initialX: initialX
                ),
                .systemNavigation
            )
        }
        XCTAssertEqual(
            ChartPanDirectionResolver.ownership(
                velocityX: 500,
                velocityY: 0,
                initialX: 51
            ),
            .chart
        )

        var machine = ChartInteractionStateMachine()
        XCTAssertTrue(machine.beginPan())
        XCTAssertFalse(machine.beginPinch())
        XCTAssertEqual(machine.state, .panningTimeline)
        machine.finishInteraction()
        XCTAssertTrue(machine.beginPinch())
        XCTAssertEqual(machine.state, .pinchingTimeline)
        machine.finishInteraction()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(machine.beginCrosshair())
        XCTAssertEqual(machine.state, .trackingCrosshair)
        XCTAssertFalse(machine.beginPan())
        XCTAssertTrue(machine.beginPinch())
        XCTAssertEqual(machine.state, .pinchingTimeline)
        XCTAssertFalse(machine.beginCrosshair())
        machine.finishInteraction()
        XCTAssertEqual(machine.state, .idle)
    }

    func testCrosshairPinchTransitionKeepsSingleTouchOwnership() {
        var machine = ChartInteractionStateMachine()
        XCTAssertTrue(machine.beginCrosshair())
        XCTAssertFalse(machine.beginPan(), "A single-touch drag must keep moving its creating crosshair")
        XCTAssertTrue(machine.beginPinch(), "A second finger must be able to hand the chart to pinch zoom")
        XCTAssertEqual(machine.state, .pinchingTimeline)
        XCTAssertFalse(machine.beginCrosshair(), "The old contact cannot recreate a cursor during pinch")
        machine.finishInteraction()
        XCTAssertTrue(machine.beginPan())
        XCTAssertFalse(machine.beginPinch(), "An active one-finger pan keeps its existing ownership")
    }

    func testCrosshairDisplayPercentUsesLatestPriceAndAmplitudeUsesOpen()
        throws {
        func candle(
            open: Double,
            high: Double,
            low: Double
        ) -> ChartCandle {
            ChartCandle(
                openTime: 0,
                closeTime: 3_599_999,
                openPrice: open,
                highPrice: high,
                lowPrice: low,
                closePrice: open,
                volume: 0,
                quoteVolume: 0,
                closure: .closed
            )
        }
        XCTAssertEqual(
            try XCTUnwrap(
                ChartCrosshairDisplaySemantics.relativePriceRate(
                    crosshairPrice: 65_290,
                    latestPrice: 62_832.6
                )
            ),
            0.039_110_270_783,
            accuracy: 0.000_000_000_1
        )
        XCTAssertNil(
            ChartCrosshairDisplaySemantics.relativePriceRate(
                crosshairPrice: 65_290,
                latestPrice: 0
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(
                ChartCrosshairDisplaySemantics.amplitudeRate(
                    for: candle(
                        open: 62_500,
                        high: 64_000,
                        low: 62_000
                    )
                )
            ),
            0.032,
            accuracy: 0.000_000_001
        )
        XCTAssertNil(
            ChartCrosshairDisplaySemantics.amplitudeRate(
                for: candle(
                    open: 0,
                    high: 64_000,
                    low: 62_000
                )
            )
        )
    }

    func testCrosshairSnapsThroughFractionalInteractionTransform()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let builder = ChartSceneBuilder()

        for displayScale in [2.0, 3.0] {
            let viewport = try XCTUnwrap(ChartSceneViewport(
                widthPoints: 390,
                heightPoints: 396,
                displayScale: displayScale
            ))
            let baseline = try XCTUnwrap(ChartTimelineViewport(
                visibleSlotCount: 60,
                trailingOffsetSlots: 40
            ))
            let current = try XCTUnwrap(ChartTimelineViewport(
                visibleSlotCount: 42.5,
                trailingOffsetSlots: 53.25
            ))
            let output = try await builder.build(
                frame: fixture.frame,
                viewport: viewport,
                timelineViewport: baseline
            )
            let data = try XCTUnwrap(
                output.renderState.staticScene.crosshairData
            )
            let transform = ChartTimelineInteractionTransform.mapping(
                from: baseline,
                to: current,
                totalWidthPoints: 390,
                displayScale: displayScale
            )
            let targetIndex = 150
            let baselineX = try XCTUnwrap(
                data.baselineX(globalSlot: targetIndex)
            )
            let screenX = transform.screenX(
                baselineX: baselineX
            )
            let pricePanel = try XCTUnwrap(
                data.panelLayout.pricePanel
            )
            let y = Double(
                (pricePanel.plot.top + pricePanel.plot.bottom) / 2
            )
            let hit = try XCTUnwrap(ChartCrosshairResolver.resolve(
                screenX: screenX + 0.19,
                screenY: y,
                transform: transform,
                data: data,
                liveData: output.renderState.liveTail
                    .crosshairLiveData
            ))

            XCTAssertEqual(
                hit.selection.openTime,
                data.history.candles[targetIndex].openTime
            )
            XCTAssertEqual(
                Double(hit.selection.snappedX),
                screenX,
                accuracy: 0.001
            )
            XCTAssertEqual(
                try XCTUnwrap(
                    transform.baselineX(screenX: screenX)
                ),
                baselineX,
                accuracy: 0.000_001
            )
        }
    }

    func testCrosshairRejectsFutureBlankAndMapsPanelDomain()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let builder = ChartSceneBuilder()
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: 396,
            displayScale: 3
        ))
        let timeline = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: 0
        ))
        let output = try await builder.build(
            frame: fixture.frame,
            viewport: viewport,
            timelineViewport: timeline
        )
        let data = try XCTUnwrap(
            output.renderState.staticScene.crosshairData
        )
        let pricePanel = try XCTUnwrap(
            data.panelLayout.pricePanel
        )

        XCTAssertNil(ChartCrosshairResolver.resolve(
            screenX: Double(data.panelLayout.plotRight),
            screenY: Double(
                (pricePanel.plot.top + pricePanel.plot.bottom) / 2
            ),
            // Move the last candle away from the edge, creating real future blank
            // rather than depending on rounding exactly halfway between two slots.
            transform: ChartTimelineInteractionTransform(
                translationPixels: -2 * Double(data.slotWidthPixels), scaleX: 1),
            data: data,
            liveData: output.renderState.liveTail
                .crosshairLiveData
        ))
        XCTAssertNil(ChartCrosshairResolver.resolve(
            screenX: Double(data.panelLayout.plotLeft - 1),
            screenY: Double(pricePanel.plot.top),
            transform: .identity,
            data: data,
            liveData: output.renderState.liveTail
                .crosshairLiveData
        ))

        let macdPanel = try XCTUnwrap(
            data.panelLayout.panel(id: ChartPanelID.macd)
        )
        let liveX = try XCTUnwrap(
            data.baselineX(globalSlot: data.historyCount)
        )
        let macdY = Double(
            (macdPanel.plot.top + macdPanel.plot.bottom) / 2
        )
        let hit = try XCTUnwrap(ChartCrosshairResolver.resolve(
            screenX: liveX,
            screenY: macdY,
            transform: .identity,
            data: data,
            liveData: output.renderState.liveTail
                .crosshairLiveData
        ))
        let macdDomain = try XCTUnwrap(
            data.panelDomains[ChartPanelID.macd]
        )

        XCTAssertEqual(hit.selection.panelID, ChartPanelID.macd)
        XCTAssertEqual(
            hit.selection.panelValue,
            (macdDomain.lower + macdDomain.upper) / 2,
            accuracy: 0.000_001
        )
        XCTAssertTrue(hit.indicatorValues.contains {
            $0.placement == .panel(ChartPanelID.macd)
        })
    }

    func testCrosshairPreservesOpenTimeAcrossSceneRebaseAndLiveUpdates()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let builder = ChartSceneBuilder()
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: 396,
            displayScale: 3
        ))
        let firstTimeline = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: 40
        ))
        let secondTimeline = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 52,
            trailingOffsetSlots: 44
        ))
        let first = try await builder.build(
            frame: fixture.frame,
            viewport: viewport,
            timelineViewport: firstTimeline
        )
        let firstData = try XCTUnwrap(
            first.renderState.staticScene.crosshairData
        )
        let selectedOpenTime = firstData.history.candles[150]
            .openTime
        let pricePanel = try XCTUnwrap(
            firstData.panelLayout.pricePanel
        )
        let firstHit = try XCTUnwrap(ChartCrosshairResolver.resolve(
            screenX: try XCTUnwrap(
                firstData.baselineX(globalSlot: 150)
            ),
            screenY: Double(
                (pricePanel.plot.top + pricePanel.plot.bottom) / 2
            ),
            transform: .identity,
            data: firstData,
            liveData: first.renderState.liveTail.crosshairLiveData
        ))
        let firstValues = firstHit.indicatorValues

        let second = try await builder.build(
            frame: fixture.frame,
            viewport: viewport,
            timelineViewport: secondTimeline
        )
        let secondData = try XCTUnwrap(
            second.renderState.staticScene.crosshairData
        )
        let restored = try XCTUnwrap(ChartCrosshairResolver.resolve(
            screenX: Double(secondData.panelLayout.plotLeft),
            screenY: Double(firstHit.selection.fingerY),
            transform: .identity,
            data: secondData,
            liveData: second.renderState.liveTail.crosshairLiveData,
            preferredOpenTime: selectedOpenTime,
            preferredPanelID: ChartPanelID.price,
            clampsToPlot: true
        ))

        XCTAssertEqual(restored.selection.openTime, selectedOpenTime)
        XCTAssertEqual(restored.indicatorValues, firstValues)

        let liveData = try XCTUnwrap(
            second.renderState.liveTail.crosshairLiveData
        )
        let liveCandle = try XCTUnwrap(liveData.candle)
        let updatedCandle = ChartCandle(
            openTime: liveCandle.openTime,
            closeTime: liveCandle.closeTime,
            openPrice: liveCandle.openPrice,
            highPrice: liveCandle.highPrice + 10,
            lowPrice: liveCandle.lowPrice,
            closePrice: liveCandle.closePrice + 5,
            volume: liveCandle.volume + 1,
            quoteVolume: liveCandle.quoteVolume + 1,
            closure: .provisional
        )
        let updatedLiveData = ChartCrosshairLiveData(
            candle: updatedCandle,
            indicatorPoints: liveData.indicatorPoints,
            legends: liveData.legends
        )
        let latestTimeline = ChartTimelineViewport.latest(
            totalWidthPoints: viewport.widthPoints
        ).clamped(totalSlotCount: secondData.totalSlotCount)
        let latestScene = try await builder.build(
            frame: fixture.frame,
            viewport: viewport,
            timelineViewport: latestTimeline
        )
        let latestData = try XCTUnwrap(
            latestScene.renderState.staticScene.crosshairData
        )
        let liveHit = try XCTUnwrap(ChartCrosshairResolver.resolve(
            screenX: try XCTUnwrap(latestData.baselineX(
                globalSlot: latestData.historyCount
            )),
            screenY: Double(firstHit.selection.fingerY),
            transform: .identity,
            data: latestData,
            liveData: updatedLiveData
        ))

        XCTAssertEqual(liveHit.selection.openTime, liveCandle.openTime)
        XCTAssertEqual(
            liveHit.candle.closePrice,
            updatedCandle.closePrice
        )
        XCTAssertEqual(
            restored.candle.closePrice,
            firstHit.candle.closePrice
        )
    }

    @MainActor
    func testCrosshairOverlayStaysBoundedOnTenThousandMoves()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let sceneBuilder = ChartSceneBuilder()
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: 396,
            displayScale: 3
        ))
        let output = try await sceneBuilder.build(
            frame: fixture.frame,
            viewport: viewport
        )
        let state = output.renderState
        let data = try XCTUnwrap(state.staticScene.crosshairData)
        let pricePanel = try XCTUnwrap(data.panelLayout.pricePanel)
        let overlayBuilder = ChartCrosshairOverlayBuilder()
        let staticRevision = state.staticScene.revision
        let staticIdentity = ObjectIdentifier(state.staticScene)
        var latestSnapshot: CrosshairSnapshot?

        for index in 0..<10_000 {
            let fraction = Double(index % 997) / 996
            let x = Double(data.panelLayout.plotLeft)
                + fraction
                    * Double(
                        data.panelLayout.plotRight
                            - data.panelLayout.plotLeft
                            - data.slotWidthPixels * 0.51
                    )
            let y = Double(pricePanel.plot.top)
                + Double(index % 101) / 100
                    * Double(pricePanel.plot.height)
            guard let hit = ChartCrosshairResolver.resolve(
                screenX: x,
                screenY: y,
                transform: .identity,
                data: data,
                liveData: state.liveTail.crosshairLiveData,
                clampsToPlot: true
            ) else {
                continue
            }
            latestSnapshot = overlayBuilder.makeSnapshot(
                hit: hit,
                data: data,
                latestPrice: 62_832.6
            )
        }

        let snapshot = try XCTUnwrap(latestSnapshot)
        let withCandleCard = ChartCrosshairOverlayBuilder(showsCandleCard: true).makeSnapshot(
            hit: snapshot.hit, data: data, latestPrice: 62_832.6)
        let hiddenCardStorage = try XCTUnwrap(snapshot.batches.first?.storage)
        let visibleCardStorage = try XCTUnwrap(withCandleCard.batches.first?.storage)
        let cardColors: [ChartColor] = [.crosshairLabelBorder, .crosshairLabelBackground]
        XCTAssertFalse(hiddenCardStorage.barInstances.contains { cardColors.contains($0.color) },
            "Selected-candle details stay hidden by default")
        XCTAssertEqual(visibleCardStorage.barInstances.filter { cardColors.contains($0.color) }.count, 2,
            "The existing detail-card renderer remains available")
        XCTAssertEqual(hiddenCardStorage.barInstances,
            visibleCardStorage.barInstances.filter { !cardColors.contains($0.color) })
        XCTAssertEqual(hiddenCardStorage.lineSegments, visibleCardStorage.lineSegments)
        XCTAssertEqual(hiddenCardStorage.glyphInstances.filter { $0.color == .crosshairAxisLabelText },
            visibleCardStorage.glyphInstances.filter { $0.color == .crosshairAxisLabelText },
            "Hiding candle details must retain the price and time labels")
        XCTAssertEqual(snapshot.hit, withCandleCard.hit)
        XCTAssertEqual(snapshot.renderedIndicatorKeys, withCandleCard.renderedIndicatorKeys)
        XCTAssertEqual(snapshot.axisPriceChangeRate, withCandleCard.axisPriceChangeRate)
        XCTAssertEqual(state.staticScene.revision, staticRevision)
        XCTAssertEqual(
            ObjectIdentifier(state.staticScene),
            staticIdentity
        )
        XCTAssertLessThanOrEqual(
            snapshot.lineCount,
            CrosshairSnapshot.maximumLineCount
        )
        XCTAssertLessThanOrEqual(
            snapshot.barCount,
            CrosshairSnapshot.maximumBarCount
        )
        XCTAssertLessThanOrEqual(
            snapshot.glyphCount,
            CrosshairSnapshot.maximumGlyphCount
        )
        XCTAssertEqual(
            try XCTUnwrap(snapshot.axisPriceChangeRate),
            snapshot.hit.selection.panelValue / 62_832.6 - 1,
            accuracy: 0.000_000_001
        )
        XCTAssertTrue(snapshot.batches.contains { batch in
            batch.storage.barInstances.contains {
                $0.cornerRadius > 0
            }
        })
        for batch in snapshot.batches {
            XCTAssertEqual(batch.coordinateSpace, .fixed)
            XCTAssertTrue(batch.storage.barInstances.allSatisfy {
                $0.left >= 0
                    && $0.top >= 0
                    && $0.right <= data.widthPixels
                    && $0.bottom <= data.heightPixels
            })
            XCTAssertTrue(batch.storage.glyphInstances.allSatisfy {
                $0.left >= 0
                    && $0.top >= 0
                    && $0.right <= data.widthPixels
                    && $0.bottom <= data.heightPixels
            })
        }

        let extremeSelection = ChartCrosshairSelection(
            openTime: snapshot.hit.selection.openTime,
            panelID: snapshot.hit.selection.panelID,
            snappedX: Float(data.panelLayout.plotRight),
            fingerY: data.panelLayout.pricePanel?.plot.top ?? 0,
            panelValue: 1_234_567_890_123
        )
        let extremeHit = ChartCrosshairHit(
            selection: extremeSelection,
            candle: snapshot.hit.candle,
            priceChange: snapshot.hit.priceChange,
            priceChangeRate: snapshot.hit.priceChangeRate,
            indicatorValues: snapshot.hit.indicatorValues
        )
        let extremeSnapshot = overlayBuilder.makeSnapshot(
            hit: extremeHit,
            data: data
        )
        XCTAssertTrue(extremeSnapshot.batches.allSatisfy { batch in
            batch.storage.glyphInstances.allSatisfy {
                $0.left >= 0
                    && $0.top >= 0
                    && $0.right <= data.widthPixels
                    && $0.bottom <= data.heightPixels
            }
        })
    }

    @MainActor
    func testCrosshairReplacesLiveIndicatorLegendsWithoutOverdraw()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let sceneBuilder = ChartSceneBuilder()
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: 396,
            displayScale: 3
        ))
        let output = try await sceneBuilder.build(
            frame: fixture.frame,
            viewport: viewport
        )
        let state = output.renderState
        let data = try XCTUnwrap(state.staticScene.crosshairData)
        let pricePanel = try XCTUnwrap(data.panelLayout.pricePanel)
        let hit = try XCTUnwrap(ChartCrosshairResolver.resolve(
            screenX: Double(data.panelLayout.plotLeft + 180),
            screenY: Double(pricePanel.plot.top + 120),
            transform: .identity,
            data: data,
            liveData: state.liveTail.crosshairLiveData,
            clampsToPlot: true
        ))
        let liveData = try XCTUnwrap(
            state.liveTail.crosshairLiveData
        )
        let crosshair = ChartCrosshairOverlayBuilder().makeSnapshot(
            hit: hit,
            data: data
        )
        let activeState = RenderState(
            staticScene: state.staticScene,
            liveTail: state.liveTail,
            interaction: InteractionSnapshot(
                revision: state.interaction.revision + 1,
                translationX: state.interaction.translationX,
                scaleX: state.interaction.scaleX,
                candleHalfBodyWidthPixels:
                    state.interaction.candleHalfBodyWidthPixels,
                crosshair: crosshair
            ),
            invalidation: .interaction,
            readyTime: state.readyTime
        )

        let idleBatches = MetalRenderer.dynamicBatches(for: state)
        let activeBatches = MetalRenderer.dynamicBatches(
            for: activeState
        )
        let liveLegends = state.liveTail.batches.filter {
            $0.interactionVisibility
                == .hiddenWhileCrosshairIsActive
        }

        XCTAssertEqual(
            hit.indicatorValues.count,
            liveData.legends.count
        )
        XCTAssertTrue(hit.indicatorValues.contains {
            $0.label.hasPrefix("SUPERTREND")
        })
        XCTAssertEqual(
            Set(crosshair.renderedIndicatorKeys),
            Set(hit.indicatorValues.map(\.key))
        )
        XCTAssertEqual(liveLegends.count, 1)
        XCTAssertTrue(idleBatches.contains {
            $0.interactionVisibility
                == .hiddenWhileCrosshairIsActive
        })
        XCTAssertFalse(activeBatches.contains {
            $0.interactionVisibility
                == .hiddenWhileCrosshairIsActive
        })
        XCTAssertTrue(activeBatches.contains {
            $0.storage === crosshair.batches[0].storage
        })
    }

    @MainActor
    func testIndicatorLegendsPreserveEveryValueAcrossWidthsAndDisplayScales()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let timeline = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 40,
            trailingOffsetSlots: 0
        ))
        for scale in [2.0, 3.0] {
            var wideLiveGlyphCount: Int?
            var wideSelectedFooterCounts: [String: Int] = [:]
            for width in [600.0, 390.0, 320.0] {
                let viewport = try XCTUnwrap(ChartSceneViewport(
                    widthPoints: width,
                    heightPoints: 396,
                    displayScale: scale
                ))
                let state = try await ChartSceneBuilder().build(
                    frame: fixture.frame, viewport: viewport,
                    timelineViewport: timeline
                ).renderState
                let data = try XCTUnwrap(state.staticScene.crosshairData)
                let price = try XCTUnwrap(data.panelLayout.pricePanel)
                let hit = try XCTUnwrap(ChartCrosshairResolver.resolve(
                    screenX: try XCTUnwrap(data.baselineX(globalSlot: 200)),
                    screenY: Double(price.plot.top + 20),
                    transform: .identity, data: data,
                    liveData: state.liveTail.crosshairLiveData
                ))
                let selected = ChartCrosshairOverlayBuilder().makeSnapshot(hit: hit, data: data)
                XCTAssertEqual(Set(selected.renderedIndicatorKeys), Set(hit.indicatorValues.map(\.key)),
                    "Missing indicator at \(width)pt / \(scale)x")
                XCTAssertEqual(selected.renderedIndicatorKeys.count, hit.indicatorValues.count)
                let liveGlyphs = state.liveTail.batches.filter {
                    $0.interactionVisibility == .hiddenWhileCrosshairIsActive
                }.flatMap { $0.storage.glyphInstances }
                let selectedGlyphs = selected.batches.flatMap { $0.storage.glyphInstances }
                for panel in data.panelLayout.indicatorPanels {
                    for glyphs in [liveGlyphs, selectedGlyphs] {
                        let footer = glyphs.filter {
                            $0.top >= panel.plot.bottom && $0.bottom <= panel.frame.bottom
                        }
                        XCTAssertFalse(footer.isEmpty)
                        XCTAssertTrue(footer.allSatisfy {
                            $0.left >= data.panelLayout.plotLeft - 0.001
                                && $0.right <= data.panelLayout.plotRight + 0.001
                        }, "Legend exceeded plot at \(width)pt / \(scale)x")
                    }
                    let selectedFooterCount = selectedGlyphs.filter {
                        $0.top >= panel.plot.bottom && $0.bottom <= panel.frame.bottom
                    }.count
                    if let wideCount = wideSelectedFooterCounts[panel.id] {
                        XCTAssertEqual(selectedFooterCount, wideCount,
                            "Narrow layout dropped selected legend glyphs")
                    } else {
                        wideSelectedFooterCounts[panel.id] = selectedFooterCount
                    }
                }
                if let wideLiveGlyphCount {
                    XCTAssertEqual(liveGlyphs.count, wideLiveGlyphCount,
                        "Narrow layout dropped live legend glyphs")
                } else {
                    wideLiveGlyphCount = liveGlyphs.count
                }
            }
        }
    }

    func testTimelineRenderingContinuesTransparentlyBehindThePriceAxis() async throws {
        let fixture = try await makeChartSceneFixture()
        for width in [320.0, 390.0, 440.0] {
            for scale in [2.0, 3.0] {
                let viewport = try XCTUnwrap(ChartSceneViewport(
                    widthPoints: width, heightPoints: 396, displayScale: scale))
                let output = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport)
                let clip = try XCTUnwrap(output.renderState.staticScene.horizontalPlotBounds)
                XCTAssertEqual(clip.left, output.panelLayout.plotLeft)
                XCTAssertEqual(clip.right, Float(viewport.widthPixels))
                XCTAssertGreaterThan(clip.right, output.panelLayout.plotRight)
                // Static candles, live candles and indicator paths share this clip;
                // fixed axis glyphs and current-price labels must remain untransformed.
                XCTAssertTrue(output.renderState.staticScene.batches.contains { $0.coordinateSpace == .timeline })
                XCTAssertTrue(output.renderState.liveTail.batches.contains { $0.coordinateSpace == .timeline })
                XCTAssertEqual(output.renderState.staticScene.batches.last?.coordinateSpace, .fixed)
            }
        }
    }

    func testOffscreenPriceMarkerStaysOnPriceAxisAcrossDisplayScales()
        async throws {
        let fixture = try await makeChartSceneFixture()
        for scale in [2.0, 3.0] {
            let viewport = try XCTUnwrap(ChartSceneViewport(
                widthPoints: 390, heightPoints: 396, displayScale: scale
            ))
            for offset in [40.0, 50.0] {
                let timeline = try XCTUnwrap(ChartTimelineViewport(
                    visibleSlotCount: 40, trailingOffsetSlots: offset
                ))
                let output = try await ChartSceneBuilder().build(
                    frame: fixture.frame, viewport: viewport, timelineViewport: timeline
                )
                let marker = try XCTUnwrap(output.renderState.liveTail.latestPriceMarker)
                XCTAssertTrue(marker.returnsToLatest)
                XCTAssertGreaterThanOrEqual(marker.left, output.panelLayout.plotRight)
                XCTAssertLessThanOrEqual(marker.right, Float(viewport.widthPixels))
                let priceBatch = try XCTUnwrap(output.renderState.liveTail.batches.first {
                    $0.coordinateSpace == .latestPrice
                })
                XCTAssertTrue(priceBatch.storage.lineSegments.filter { $0.dashLength > 0 }.allSatisfy {
                    min($0.start.x, $0.end.x) >= output.panelLayout.plotLeft
                        && max($0.start.x, $0.end.x) <= output.panelLayout.plotRight
                }, "The price reference line must stay inside the plot")
            }
        }
    }

    @MainActor
    func testCrosshairPriceLabelCoversLatestPriceMarkerAt2xAnd3x()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try MetalRenderer(
            device: device,
            pixelFormat: .bgra8Unorm_srgb
        )

        for scale in [2, 3] {
            let viewport = try XCTUnwrap(ChartSceneViewport(
                widthPoints: 390,
                heightPoints: 396,
                displayScale: Double(scale)
            ))
            let output = try await ChartSceneBuilder().build(
                frame: fixture.frame,
                viewport: viewport
            )
            let state = output.renderState
            let data = try XCTUnwrap(state.staticScene.crosshairData)
            let marker = try XCTUnwrap(state.liveTail.latestPriceMarker)
            let hit = try XCTUnwrap(ChartCrosshairResolver.resolve(
                screenX: Double(data.panelLayout.plotLeft + 180),
                screenY: Double((marker.top + marker.bottom) / 2),
                transform: .identity,
                data: data,
                liveData: state.liveTail.crosshairLiveData,
                clampsToPlot: true
            ))
            let crosshair = ChartCrosshairOverlayBuilder().makeSnapshot(
                hit: hit,
                data: data,
                latestPrice: state.liveTail.latestPrice
            )
            let interaction = InteractionSnapshot(
                revision: state.interaction.revision + 1,
                translationX: 0,
                scaleX: 1,
                crosshair: crosshair
            )
            let activeState = RenderState(
                staticScene: state.staticScene,
                liveTail: state.liveTail,
                interaction: interaction,
                invalidation: .interaction
            )
            let referenceState = RenderState(
                staticScene: state.staticScene,
                liveTail: LiveTailSnapshot(
                    revision: state.liveTail.revision,
                    candle: nil,
                    batches: [],
                    latestPrice: state.liveTail.latestPrice
                ),
                interaction: interaction,
                invalidation: .interaction
            )
            XCTAssertTrue(MetalRenderer.dynamicBatches(
                for: activeState
            ).contains { $0.coordinateSpace == .latestPrice })

            let actual = try XCTUnwrap(renderer.renderOffscreen(
                state: activeState,
                width: 390 * scale,
                height: 396 * scale
            ))
            let reference = try XCTUnwrap(renderer.renderOffscreen(
                state: referenceState,
                width: actual.width,
                height: actual.height
            ))
            let label = try XCTUnwrap(crosshair.batches.flatMap {
                $0.storage.barInstances
            }.first { $0.color == .crosshairAxisLabelBackground })
            let left = Int(ceil(label.left + label.cornerRadius))
            let right = Int(floor(label.right - label.cornerRadius))
            let top = Int(ceil(max(label.top + label.cornerRadius, marker.top)))
            let bottom = Int(floor(min(label.bottom - label.cornerRadius, marker.bottom)))
            XCTAssertLessThan(left, right)
            XCTAssertLessThan(top, bottom)
            for row in top..<bottom {
                let start = row * actual.bytesPerRow + left * 4
                let end = row * actual.bytesPerRow + right * 4
                XCTAssertEqual(
                    actual.bgra8UnormSRGB[start..<end],
                    reference.bgra8UnormSRGB[start..<end],
                    "Latest-price content covered the crosshair label at \(scale)x, row \(row)"
                )
            }
        }
    }

    func testChartSceneBuilderShowsFullPriceReferenceInHistoricalViewport()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let builder = ChartSceneBuilder()
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: 396,
            displayScale: 3
        ))
        let timeline = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 40,
            trailingOffsetSlots: 50
        ))
        let output = try await builder.build(
            frame: fixture.frame,
            viewport: viewport,
            timelineViewport: timeline
        )
        let staticBatch = try XCTUnwrap(
            output.renderState.staticScene.batches.first {
                $0.coordinateSpace == .timeline
            }
        )
        XCTAssertEqual(output.visibleClosedCandleCount, 40)
        XCTAssertEqual(
            staticBatch.storage.candleInstances.count,
            output.renderedClosedCandleCount
        )
        XCTAssertGreaterThan(output.renderedClosedCandleCount, 40)
        XCTAssertLessThanOrEqual(
            output.renderedClosedCandleCount,
            40 + 2 * ChartInteractionMetrics.standard
                .guardBandSlotCount
        )
        XCTAssertFalse(output.renderState.liveTail.batches.contains {
            !$0.storage.candleInstances.isEmpty
        })
        let priceReference = try XCTUnwrap(
            output.renderState.liveTail.batches.first {
                $0.coordinateSpace == .latestPrice
            }
        )
        let marker = try XCTUnwrap(
            priceReference.storage.barInstances.first
        )
        let priceLines = priceReference.storage.lineSegments.filter {
            $0.dashLength > 0
        }
        try assertPriceReferenceCoversPlot(
            priceLines, marker: marker,
            plotLeft: output.panelLayout.plotLeft,
            plotRight: output.panelLayout.plotRight
        )
        XCTAssertFalse(priceReference.storage.glyphInstances.isEmpty)
        let fixedLegend = try XCTUnwrap(
            output.renderState.liveTail.batches.first {
                $0.coordinateSpace == .fixed
                    && $0.interactionVisibility
                        == .hiddenWhileCrosshairIsActive
            }
        )
        XCTAssertFalse(fixedLegend.storage.glyphInstances.isEmpty)
        let rightmostVisibleIndex = 170
        let ema21 = try XCTUnwrap(
            output.renderState.liveTail.displayedLegends.first {
                $0.instanceID == "ema.21"
            }
        )
        let ema21Series = try XCTUnwrap(
            fixture.frame.indicators.history.series.first {
                $0.key.instanceID == "ema.21"
            }
        )
        XCTAssertEqual(
            ema21.value,
            ema21Series.points[rightmostVisibleIndex].value
        )
        XCTAssertNotEqual(
            ema21.value,
            fixture.frame.indicators.legends.first {
                $0.instanceID == "ema.21"
            }?.value
        )
        XCTAssertTrue(
            output.renderState.liveTail.latestPriceMarker?
                .returnsToLatest == true
        )
        XCTAssertTrue(
            output.renderState.liveTail.batches.contains {
                $0.coordinateSpace == .timeline
                    && $0.storage.lineSegments.count == 2
                    && !$0.storage.glyphInstances.isEmpty
            }
        )
    }

    func testChartSceneBuilderBuffersNearLiveTailWithOffscreenMarker()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let builder = ChartSceneBuilder()
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: 396,
            displayScale: 3
        ))
        let timeline = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 40,
            trailingOffsetSlots: 40
        ))
        let output = try await builder.build(
            frame: fixture.frame,
            viewport: viewport,
            timelineViewport: timeline
        )
        let liveBatch = try XCTUnwrap(
            output.renderState.liveTail.batches.first
        )
        let liveCandle = try XCTUnwrap(
            liveBatch.storage.candleInstances.first
        )

        XCTAssertEqual(liveBatch.coordinateSpace, .timeline)
        XCTAssertGreaterThan(
            liveCandle.x,
            output.panelLayout.plotRight
        )
        let priceReference = try XCTUnwrap(
            output.renderState.liveTail.batches.first {
                $0.coordinateSpace == .latestPrice
            }
        )
        let marker = try XCTUnwrap(
            priceReference.storage.barInstances.first
        )
        let priceLines = priceReference.storage.lineSegments.filter {
            $0.dashLength > 0
        }
        try assertPriceReferenceCoversPlot(
            priceLines, marker: marker,
            plotLeft: output.panelLayout.plotLeft,
            plotRight: output.panelLayout.plotRight
        )
        XCTAssertGreaterThanOrEqual(
            marker.left,
            output.panelLayout.plotRight
        )
        XCTAssertTrue(liveBatch.storage.glyphInstances.isEmpty)
    }

    func testPriceViewportDragDirectionClampingAndSceneDomain()
        async throws {
        let automatic = ChartPriceViewport.automatic
        let draggedUp = automatic.adjusted(
            verticalTranslationPoints: -90
        )
        let draggedDown = automatic.adjusted(
            verticalTranslationPoints: 110
        )
        XCTAssertGreaterThan(draggedUp.magnification, 1)
        XCTAssertLessThan(draggedDown.magnification, 1)
        XCTAssertEqual(
            automatic.adjusted(
                verticalTranslationPoints: -10_000
            ).magnification,
            ChartPriceViewport.maximumMagnification
        )
        XCTAssertEqual(
            automatic.adjusted(
                verticalTranslationPoints: 10_000
            ).magnification,
            ChartPriceViewport.minimumMagnification
        )

        let fixture = try await makeChartSceneFixture()
        let builder = ChartSceneBuilder()
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: 396,
            displayScale: 3
        ))
        let baseline = try await builder.build(
            frame: fixture.frame,
            viewport: viewport
        )
        let magnified = try await builder.build(
            frame: fixture.frame,
            viewport: viewport,
            priceViewport: try XCTUnwrap(
                ChartPriceViewport(magnification: 2)
            )
        )
        let baselineSpan = baseline.priceUpperBound
            - baseline.priceLowerBound
        let magnifiedSpan = magnified.priceUpperBound
            - magnified.priceLowerBound
        XCTAssertEqual(
            magnifiedSpan,
            baselineSpan / 2,
            accuracy: baselineSpan * 0.000_001
        )
        XCTAssertFalse(magnified.staticSceneReused)
        XCTAssertTrue(
            baseline.renderState.liveTail.latestPriceMarker?
                .returnsToLatest == false
        )
    }

    func testManualPriceDomainSurvivesHorizontalNavigationAndAnchoredZoom() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
        let builder = ChartSceneBuilder()
        let timeline = try XCTUnwrap(ChartTimelineViewport(visibleSlotCount: 20, trailingOffsetSlots: 20))
        let first = try await builder.build(frame: fixture.frame, viewport: viewport, timelineViewport: timeline)
        let manual = try XCTUnwrap(ChartPriceViewport(fixedRange: first.priceLowerBound...first.priceUpperBound))
        let otherTimeline = try XCTUnwrap(ChartTimelineViewport(visibleSlotCount: 80, trailingOffsetSlots: 100))
        let moved = try await builder.build(frame: fixture.frame, viewport: viewport,
            timelineViewport: otherTimeline, priceViewport: manual)
        XCTAssertEqual(moved.priceLowerBound, first.priceLowerBound, accuracy: 0.000001)
        XCTAssertEqual(moved.priceUpperBound, first.priceUpperBound, accuracy: 0.000001)
        let span = first.priceUpperBound - first.priceLowerBound
        let panned = manual.panned(verticalTranslationPoints: 50, plotHeightPoints: 200)
        let pannedScene = try await builder.build(frame: fixture.frame, viewport: viewport,
            timelineViewport: otherTimeline, priceViewport: panned)
        XCTAssertEqual(pannedScene.priceUpperBound, first.priceUpperBound + span / 4, accuracy: 0.000001)
        XCTAssertEqual(pannedScene.priceUpperBound - pannedScene.priceLowerBound, span, accuracy: 0.000001)
        let zoomed = manual.pinched(scale: 2, anchorFraction: 0.25)
        let zoomedScene = try await builder.build(frame: fixture.frame, viewport: viewport,
            timelineViewport: otherTimeline, priceViewport: zoomed)
        XCTAssertEqual(zoomedScene.priceUpperBound - zoomedScene.priceLowerBound, span / 2, accuracy: 0.000001)
        XCTAssertEqual(zoomedScene.priceUpperBound - span / 2 * 0.25,
            first.priceUpperBound - span * 0.25, accuracy: 0.000001)
        XCTAssertEqual(manual.panned(verticalTranslationPoints: .nan, plotHeightPoints: 200), manual)
        XCTAssertEqual(manual.pinched(scale: .infinity, anchorFraction: 0.5), manual)
    }

    @MainActor
    func testAutoPriceSwitchCapturesCurrentDomainAndRestoresFitting() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
        let controller = KlineChartSceneController()
        controller.setAutomaticPriceFitting(false)
        controller.requestRender(frame: fixture.frame, viewport: viewport,
            proposedTimelineViewport: nil, proposedPriceViewport: controller.priceViewport)
        await controller.diagnosticWaitForRenderIdle()
        let initial = try XCTUnwrap(controller.priceProjection)
        XCTAssertEqual(controller.priceViewport.fixedRange, initial.priceRange,
            "Opening with auto disabled must capture the first valid domain")
        let manual = controller.priceViewport.panned(verticalTranslationPoints: 80, plotHeightPoints: 200)
        controller.updatePriceViewport(manual)
        controller.requestRender(frame: fixture.frame, viewport: viewport,
            proposedTimelineViewport: controller.timelineViewport, proposedPriceViewport: manual)
        await controller.diagnosticWaitForRenderIdle()
        XCTAssertNotEqual(controller.priceProjection?.priceRange, initial.priceRange)
        controller.setAutomaticPriceFitting(true)
        XCTAssertEqual(controller.priceViewport, .automatic)
        controller.requestRender(frame: fixture.frame, viewport: viewport,
            proposedTimelineViewport: controller.timelineViewport, proposedPriceViewport: controller.priceViewport)
        await controller.diagnosticWaitForRenderIdle()
        XCTAssertEqual(controller.priceProjection, initial)
        controller.setAutomaticPriceFitting(false)
        XCTAssertEqual(controller.priceViewport.fixedRange, initial.priceRange)
    }

    @MainActor
    func testManualPriceDomainIsRecapturedForAnotherStream() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
        let controller = KlineChartSceneController()
        controller.setAutomaticPriceFitting(false)
        controller.requestRender(frame: fixture.frame, viewport: viewport,
            proposedTimelineViewport: nil, proposedPriceViewport: .automatic)
        await controller.diagnosticWaitForRenderIdle()
        let first = try XCTUnwrap(controller.priceProjection)
        let displaced = controller.priceViewport.panned(verticalTranslationPoints: 120, plotHeightPoints: 200)
        controller.updatePriceViewport(displaced)
        let other = ChartDataFrame(stream: ChartStreamKey(symbol: "ETHUSDT", interval: "4h"),
            epoch: KlineStreamEpoch(generation: 50), candles: fixture.frame.candles,
            indicators: fixture.frame.indicators, recoveryRequest: nil, readyTime: fixture.frame.readyTime)
        controller.requestRender(frame: other, viewport: viewport,
            proposedTimelineViewport: controller.timelineViewport, proposedPriceViewport: displaced)
        await controller.diagnosticWaitForRenderIdle()
        XCTAssertEqual(controller.priceViewport.fixedRange, first.priceRange)
        XCTAssertEqual(controller.priceProjection, first)
        XCTAssertNotEqual(controller.priceViewport, displaced)
    }

    @MainActor
    func testManualChartPanAndPinchUpdatePriceWhileAutoLeavesItAutomatic() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
        let timeline = try XCTUnwrap(ChartTimelineViewport(visibleSlotCount: 20, trailingOffsetSlots: 20))
        let output = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport, timelineViewport: timeline)
        let manual = try XCTUnwrap(ChartPriceViewport(fixedRange: output.priceLowerBound...output.priceUpperBound))
        let host = KlineChartHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        defer { host.dispose() }
        var changes: [ChartPriceViewport] = []
        host.configureTimelineInteraction(viewport: timeline, totalSlotCount: 221) { _ in }
        host.configurePriceInteraction(viewport: manual, automaticallyFitsPrice: false) { changes.append($0) }
        host.submit(output.renderState)
        let pan = ContinuousScaleTestPan()
        pan.point = CGPoint(x: 168, y: 120)
        pan.phase = .began
        host.perform(NSSelectorFromString("handleTimelinePan:"), with: pan)
        pan.translationY = 60
        pan.phase = .changed
        host.perform(NSSelectorFromString("handleTimelinePan:"), with: pan)
        let plot = try XCTUnwrap(output.panelLayout.pricePanel?.plot)
        XCTAssertEqual(changes.last, manual.panned(verticalTranslationPoints: 60,
            plotHeightPoints: Double(plot.height) / 3))
        pan.phase = .ended
        host.perform(NSSelectorFromString("handleTimelinePan:"), with: pan)
        let panned = try XCTUnwrap(changes.last)
        let pinch = ContinuousScaleTestPinch()
        pinch.phase = .began
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: pinch)
        pinch.scale = 2
        pinch.phase = .changed
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: pinch)
        XCTAssertEqual(changes.last, panned.pinched(scale: 2,
            anchorFraction: (120 * 3 - Double(plot.top)) / Double(plot.height)))
        pinch.phase = .ended
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: pinch)

        let autoHost = KlineChartHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        defer { autoHost.dispose() }
        autoHost.configureTimelineInteraction(viewport: timeline, totalSlotCount: 221) { _ in }
        autoHost.configurePriceInteraction(viewport: .automatic, automaticallyFitsPrice: true) { changes.append($0) }
        autoHost.submit(output.renderState)
        let count = changes.count
        pan.phase = .began
        autoHost.perform(NSSelectorFromString("handleTimelinePan:"), with: pan)
        pan.phase = .changed
        autoHost.perform(NSSelectorFromString("handleTimelinePan:"), with: pan)
        pan.phase = .ended
        autoHost.perform(NSSelectorFromString("handleTimelinePan:"), with: pan)
        XCTAssertEqual(changes.count, count, "Auto mode must not install a manual price domain")
    }

    func testTallerPricePlotUsesAvailableHeightAndPreservesZoom() async throws {
        let fixture = try await makeChartSceneFixture()
        let panelCount = ChartPanelLayout.indicatorPanelIDs(
            series: fixture.frame.indicators.history.series
        ).count
        for scale in [2.0, 3.0] {
            let builder = ChartSceneBuilder()
            let originalHeight = ChartPanelLayout.preferredViewportHeightPoints(
                indicatorPanelCount: panelCount
            )
            let originalViewport = try XCTUnwrap(ChartSceneViewport(
                widthPoints: 390,
                heightPoints: originalHeight,
                displayScale: scale
            ))
            let tallerViewport = try XCTUnwrap(ChartSceneViewport(
                widthPoints: 390,
                heightPoints: ChartPanelLayout.scrollContentHeightPoints(
                    availableHeightPoints: 640,
                    indicatorPanelCount: panelCount
                ),
                displayScale: scale
            ))
            let original = try await builder.build(
                frame: fixture.frame,
                viewport: originalViewport
            )
            let taller = try await builder.build(
                frame: fixture.frame,
                viewport: tallerViewport
            )
            let originalPlot = try XCTUnwrap(original.panelLayout.pricePanel?.plot)
            let tallerPlot = try XCTUnwrap(taller.panelLayout.pricePanel?.plot)
            let originalSpan = original.priceUpperBound - original.priceLowerBound
            let tallerSpan = taller.priceUpperBound - taller.priceLowerBound
            XCTAssertGreaterThan(tallerPlot.height, originalPlot.height)
            XCTAssertEqual(tallerSpan, originalSpan, accuracy: 0.000_001)
            let heightRatio = tallerPlot.height / originalPlot.height
            let originalCandles = try XCTUnwrap(
                original.renderState.staticScene.batches.first {
                    $0.coordinateSpace == .timeline
                }?.storage.candleInstances
            )
            let tallerCandles = try XCTUnwrap(
                taller.renderState.staticScene.batches.first {
                    $0.coordinateSpace == .timeline
                }?.storage.candleInstances
            )
            XCTAssertFalse(originalCandles.isEmpty)
            XCTAssertEqual(tallerCandles.count, originalCandles.count)
            for (before, after) in zip(originalCandles, tallerCandles) {
                XCTAssertEqual(after.x, before.x, accuracy: 0.001)
                XCTAssertEqual(after.halfBodyWidth, before.halfBodyWidth)
                XCTAssertEqual(
                    after.closeY - after.openY,
                    (before.closeY - before.openY) * heightRatio,
                    accuracy: 0.002
                )
                XCTAssertEqual(
                    after.lowY - after.highY,
                    (before.lowY - before.highY) * heightRatio,
                    accuracy: 0.002
                )
            }
            let zoomed = try await builder.build(
                frame: fixture.frame,
                viewport: tallerViewport,
                priceViewport: try XCTUnwrap(ChartPriceViewport(magnification: 2))
            )
            XCTAssertEqual(
                zoomed.priceUpperBound - zoomed.priceLowerBound,
                tallerSpan / 2,
                accuracy: tallerSpan * 0.000_001
            )
        }
    }

    func testChartSceneBuilderMovesContinuouslyForFractionalOffset()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let builder = ChartSceneBuilder()
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: 396,
            displayScale: 2
        ))
        let baseline = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 40,
            trailingOffsetSlots: 10
        ))
        let shifted = try XCTUnwrap(ChartTimelineViewport(
            visibleSlotCount: 40,
            trailingOffsetSlots: 10.5
        ))
        let first = try await builder.build(
            frame: fixture.frame,
            viewport: viewport,
            timelineViewport: baseline
        )
        let second = try await builder.build(
            frame: fixture.frame,
            viewport: viewport,
            timelineViewport: shifted
        )
        let firstLastX = try XCTUnwrap(
            first.renderState.staticScene.batches.first {
                $0.coordinateSpace == .timeline
            }?
                .storage.candleInstances.last?.x
        )
        let secondLastX = try XCTUnwrap(
            second.renderState.staticScene.batches.first {
                $0.coordinateSpace == .timeline
            }?
                .storage.candleInstances.last?.x
        )
        let plotWidthPixels = Double(
            first.panelLayout.plotRight
                - first.panelLayout.plotLeft
        )

        XCTAssertEqual(
            Double(secondLastX - firstLastX),
            plotWidthPixels / 40 / 2,
            accuracy: 0.001
        )
        XCTAssertFalse(second.staticSceneReused)
    }

    func testGridCellsStayHorizontalAcrossViewportSizes() async throws {
        let fixture = try await makeChartSceneFixture()
        for (width, height) in [(320.0, 396.0), (390.0, 700.0), (844.0, 396.0)] {
            let viewport = try XCTUnwrap(ChartSceneViewport(
                widthPoints: width, heightPoints: height, displayScale: 2
            ))
            let output = try await ChartSceneBuilder().build(
                frame: fixture.frame, viewport: viewport
            )
            let grid = try XCTUnwrap(output.renderState.staticScene.batches.first)
                .storage.barInstances
            for panel in output.panelLayout.panels {
                let vertical = grid.filter {
                    $0.bottom - $0.top > $0.right - $0.left
                        && abs($0.top - panel.plot.top) < 0.01
                        && abs($0.bottom - panel.plot.bottom) < 0.01
                }.map { ($0.left + $0.right) / 2 }.sorted()
                let horizontal = grid.filter {
                    let y = ($0.top + $0.bottom) / 2
                    return $0.right - $0.left > $0.bottom - $0.top
                        && y >= panel.plot.top - 0.01
                        && y <= panel.plot.bottom + 0.01
                }.map { ($0.top + $0.bottom) / 2 }.sorted()
                XCTAssertGreaterThanOrEqual(vertical.count, 2)
                XCTAssertGreaterThanOrEqual(horizontal.count, 3)
                let x = [panel.plot.left] + vertical + [panel.plot.right]
                for cellWidth in zip(x, x.dropFirst()).map({ $1 - $0 }) {
                    for cellHeight in zip(horizontal, horizontal.dropFirst()).map({ $1 - $0 }) {
                        XCTAssertGreaterThanOrEqual(
                            cellWidth / cellHeight, 1.79,
                            "Grid cells must be wider than tall: \(width)x\(height), \(panel.id)"
                        )
                    }
                }
            }
        }
    }

    func testChartSceneBuilderCompilesProductionScene()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let builder = ChartSceneBuilder()
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: 396,
            displayScale: 2
        ))
        let output = try await builder.build(
            frame: fixture.frame,
            viewport: viewport
        )
        let state = output.renderState
        let gridStaticBatch = try XCTUnwrap(
            state.staticScene.batches.first
        )
        let staticBatch = try XCTUnwrap(
            state.staticScene.batches.first {
                $0.coordinateSpace == .timeline
            }
        )
        let fixedStaticBatch = try XCTUnwrap(
            state.staticScene.batches.last
        )
        let liveBatch = try XCTUnwrap(
            state.liveTail.batches.first
        )
        let latestPriceBatch = try XCTUnwrap(
            state.liveTail.batches.first {
                $0.coordinateSpace == .latestPrice
            }
        )
        XCTAssertFalse(state.liveTail.batches.contains {
            $0.coordinateSpace == .latestPriceTimelineLine
        })
        let fixedLiveBatch = try XCTUnwrap(
            state.liveTail.batches.first {
                $0.coordinateSpace == .fixed
            }
        )

        XCTAssertFalse(output.staticSceneReused)
        XCTAssertGreaterThan(output.visibleClosedCandleCount, 40)
        XCTAssertEqual(
            staticBatch.storage.candleInstances.count,
            output.renderedClosedCandleCount
        )
        XCTAssertGreaterThan(
            output.renderedClosedCandleCount,
            output.visibleClosedCandleCount
        )
        XCTAssertGreaterThan(
            gridStaticBatch.storage.barInstances.count,
            8
        )
        XCTAssertGreaterThan(
            staticBatch.storage.lineSegments.count,
            output.visibleClosedCandleCount
        )
        XCTAssertFalse(fixedStaticBatch.storage.glyphInstances.isEmpty)
        XCTAssertNotNil(fixedStaticBatch.storage.glyphAtlas)
        XCTAssertEqual(gridStaticBatch.coordinateSpace, .fixed)
        XCTAssertTrue(gridStaticBatch.storage.glyphInstances.isEmpty)
        XCTAssertEqual(staticBatch.coordinateSpace, .timeline)
        XCTAssertEqual(fixedStaticBatch.coordinateSpace, .fixed)
        XCTAssertFalse(staticBatch.storage.barInstances.isEmpty)
        XCTAssertFalse(
            staticBatch.storage.barInstances.filter {
                abs($0.color.alpha - Float(ChartIndicatorParameters.standard.superTrendFillAlpha)) < 0.000_1
            }.isEmpty
        )
        XCTAssertEqual(liveBatch.storage.candleInstances.count, 1)
        XCTAssertGreaterThanOrEqual(
            liveBatch.storage.lineSegments.count,
            3
        )
        XCTAssertEqual(latestPriceBatch.storage.barInstances.count, 1)
        XCTAssertEqual(latestPriceBatch.storage.lineSegments.count, 22)
        XCTAssertEqual(latestPriceBatch.storage.barInstances.first?.color, .latestPriceMarkerBackground)
        let referenceLine = try XCTUnwrap(latestPriceBatch.storage.lineSegments.first)
        XCTAssertEqual(referenceLine.color, .latestPriceLine)
        XCTAssertGreaterThan(referenceLine.dashLength, 0)
        XCTAssertEqual(referenceLine.start.x, output.panelLayout.plotLeft, accuracy: 0.001)
        XCTAssertEqual(referenceLine.end.x, output.panelLayout.plotRight, accuracy: 0.001)
        let marker = try XCTUnwrap(state.liveTail.latestPriceMarker)
        XCTAssertLessThanOrEqual(marker.right, Float(viewport.widthPixels))
        XCTAssertLessThanOrEqual(marker.bottom - marker.top, 16 * Float(viewport.displayScale))
        for glyph in latestPriceBatch.storage.glyphInstances {
            XCTAssertGreaterThanOrEqual(glyph.left, marker.left)
            XCTAssertLessThanOrEqual(glyph.right, marker.right)
        }
        XCTAssertEqual(
            state.staticScene.horizontalPlotBounds,
            ChartHorizontalPlotBounds(
                left: output.panelLayout.plotLeft,
                right: Float(viewport.widthPixels)
            )
        )
        let roundedMarkerBorder = Array(
            latestPriceBatch.storage.lineSegments.dropFirst(2)
        )
        XCTAssertEqual(roundedMarkerBorder.count, 20)
        XCTAssertTrue(roundedMarkerBorder.allSatisfy {
            $0.dashLength == 0 && $0.gapLength == 0
        })
        XCTAssertGreaterThan(
            Set(roundedMarkerBorder.map { $0.start.x }).count,
            4
        )
        XCTAssertFalse(
            latestPriceBatch.storage.glyphInstances.isEmpty
        )
        let extremaBatch = try XCTUnwrap(
            state.liveTail.batches.first {
                $0.coordinateSpace == .timeline
                    && !$0.storage.glyphInstances.isEmpty
            }
        )
        XCTAssertEqual(extremaBatch.storage.lineSegments.count, 2)
        XCTAssertTrue(extremaBatch.storage.glyphInstances.allSatisfy {
            $0.timelineAnchorX != nil
        })
        XCTAssertFalse(fixedLiveBatch.storage.glyphInstances.isEmpty)
        XCTAssertEqual(
            state.liveTail.latestPrice,
            fixture.frame.candles.liveTail?.closePrice
        )
        XCTAssertLessThan(
            output.priceLowerBound,
            fixture.frame.candles.liveTail?.lowPrice ?? 0
        )
        XCTAssertGreaterThan(
            output.priceUpperBound,
            fixture.frame.candles.liveTail?.highPrice ?? 0
        )
        XCTAssertEqual(
            output.panelLayout.indicatorPanels.map(\.id),
            [ChartPanelID.macd, ChartPanelID.volume]
        )
        let pricePanel = try XCTUnwrap(
            output.panelLayout.pricePanel
        )
        let macdPanel = try XCTUnwrap(
            output.panelLayout.panel(id: ChartPanelID.macd)
        )
        let volumePanel = try XCTUnwrap(
            output.panelLayout.panel(id: ChartPanelID.volume)
        )
        XCTAssertLessThan(
            pricePanel.plot.bottom,
            macdPanel.plot.top
        )
        XCTAssertLessThan(
            macdPanel.plot.bottom,
            volumePanel.plot.top
        )
        XCTAssertEqual(
            pricePanel.plot.bottom,
            output.panelLayout.timeAxisTop
        )
        XCTAssertGreaterThan(macdPanel.frame.top, output.panelLayout.timeAxisBottom)
        XCTAssertEqual(volumePanel.frame.bottom, Float(viewport.heightPixels))
    }

    func testChartSceneBuilderReusesStaticSceneForLiveUpdates()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let builder = ChartSceneBuilder()
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: 396,
            displayScale: 3
        ))
        let first = try await builder.build(
            frame: fixture.frame,
            viewport: viewport
        )
        let firstLiveCandle = try XCTUnwrap(
            first.renderState.liveTail.batches.first?
                .storage.candleInstances.first
        )
        let firstEMA21 = try XCTUnwrap(
            fixture.frame.indicators.legends.first {
                $0.instanceID == "ema.21"
            }?.value
        )

        _ = await fixture.pipeline.accept(
            payload: realtimePayload(
                sequence: 2,
                openTime: 220 * 3_600_000,
                closePrice: 60_300,
                closed: false
            ),
            sequence: 2,
            epoch: fixture.epoch
        )
        let nextDrain = await fixture.pipeline.drain()
        let nextFrame = try XCTUnwrap(nextDrain.frame)
        let second = try await builder.build(
            frame: nextFrame,
            viewport: viewport
        )

        XCTAssertTrue(second.staticSceneReused)
        XCTAssertTrue(
            first.renderState.staticScene
                === second.renderState.staticScene
        )
        XCTAssertTrue(
            first.renderState.staticScene.candleHistory
                === second.renderState.staticScene.candleHistory
        )
        XCTAssertGreaterThan(
            second.renderState.liveTail.revision,
            first.renderState.liveTail.revision
        )
        XCTAssertEqual(
            second.renderState.liveTail.latestPrice,
            60_300
        )
        let secondLiveCandle = try XCTUnwrap(
            second.renderState.liveTail.batches.first?
                .storage.candleInstances.first
        )
        XCTAssertNotEqual(
            secondLiveCandle.closeY,
            firstLiveCandle.closeY
        )
        let secondEMA21 = try XCTUnwrap(
            nextFrame.indicators.legends.first {
                $0.instanceID == "ema.21"
            }?.value
        )
        XCTAssertNotEqual(secondEMA21, firstEMA21)
        let superTrendLegend = try XCTUnwrap(
            nextFrame.indicators.legends.first {
                $0.instanceID.hasPrefix("supertrend.")
            }
        )
        let superTrendLiveValue = try XCTUnwrap(
            nextFrame.indicators.livePoints.first {
                $0.key.instanceID.hasPrefix("supertrend.")
                    && $0.point.validity == .valid
            }?.point.value
        )
        XCTAssertEqual(superTrendLegend.value, superTrendLiveValue)
    }

    func testCandleBodiesGrowWithZoomWhileGapStaysFixed() {
        let metrics = ChartInteractionMetrics.standard
        let scale = 3.0
        let totalWidth = 390.0
        XCTAssertEqual(metrics.minimumVisibleSlotCount, 10)
        XCTAssertEqual(metrics.maximumVisibleSlotCount, 164)
        XCTAssertEqual(metrics.candleGapPoints, 1)
        XCTAssertEqual(
            metrics.candleHalfWickWidthPixels(displayScale: scale),
            1.5
        )
        let plotWidth = metrics.plotWidthPixels(
            totalWidthPoints: totalWidth,
            displayScale: scale
        )
        let slotCounts = [10.0, 30.0, 60.0, 120.0, 164.0]
        let halfBodyWidths = slotCounts.map { slotCount in
            metrics.candleHalfBodyWidthPixels(
                visibleSlotCount: slotCount,
                totalWidthPoints: totalWidth,
                displayScale: scale
            )
        }

        XCTAssertGreaterThan(halfBodyWidths[0], halfBodyWidths[1])
        XCTAssertGreaterThan(halfBodyWidths[1], halfBodyWidths[2])
        for (slotCount, halfBodyWidth) in zip(
            slotCounts,
            halfBodyWidths
        ) {
            let gap = plotWidth / slotCount - halfBodyWidth * 2
            XCTAssertEqual(
                gap,
                metrics.candleGapPoints * scale,
                accuracy: 0.000_001
            )
        }
        XCTAssertEqual(
            plotWidth / metrics.maximumVisibleSlotCount,
            6,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            halfBodyWidths[4],
            1.5,
            accuracy: 0.000_001
        )
    }

    func testChartSceneBuilderRebasesWhenLiveLeavesPriceDomain()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let builder = ChartSceneBuilder()
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: 396,
            displayScale: 2
        ))
        let first = try await builder.build(
            frame: fixture.frame,
            viewport: viewport
        )

        _ = await fixture.pipeline.accept(
            payload: realtimePayload(
                sequence: 2,
                openTime: 220 * 3_600_000,
                closePrice: 70_000,
                closed: false
            ),
            sequence: 2,
            epoch: fixture.epoch
        )
        let nextDrain = await fixture.pipeline.drain()
        let nextFrame = try XCTUnwrap(nextDrain.frame)
        let second = try await builder.build(
            frame: nextFrame,
            viewport: viewport
        )

        XCTAssertFalse(second.staticSceneReused)
        XCTAssertFalse(
            first.renderState.staticScene
                === second.renderState.staticScene
        )
        XCTAssertGreaterThan(second.priceUpperBound, 70_001)
        let liveCandle = try XCTUnwrap(
            second.renderState.liveTail.batches.first?
                .storage.candleInstances.first
        )
        XCTAssertGreaterThanOrEqual(liveCandle.highY, 0)
        XCTAssertLessThanOrEqual(
            liveCandle.lowY,
            Float(viewport.heightPixels)
        )
    }

    func testChartSceneBuilderRendersDeterministicallyOffscreen()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try MetalRenderer(
            device: device,
            pixelFormat: .bgra8Unorm_srgb
        )
        let builder = ChartSceneBuilder()

        for scale in [2.0, 3.0] {
            let viewport = try XCTUnwrap(ChartSceneViewport(
                widthPoints: 390,
                heightPoints: 396,
                displayScale: scale
            ))
            let output = try await builder.build(
                frame: fixture.frame,
                viewport: viewport
            )
            let first = try XCTUnwrap(renderer.renderOffscreen(
                state: output.renderState,
                width: viewport.widthPixels,
                height: viewport.heightPixels
            ))
            let second = try XCTUnwrap(renderer.renderOffscreen(
                state: output.renderState,
                width: viewport.widthPixels,
                height: viewport.heightPixels
            ))

            XCTAssertEqual(
                first.visiblePixelHash,
                second.visiblePixelHash
            )
            XCTAssertGreaterThan(first.coloredPixelCount, 5_000)
            if let preview = makePreviewImage(first) {
                let attachment = XCTAttachment(image: preview)
                attachment.name =
                    "ProductionKlineScene-\(Int(scale))x"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testStressPresentationBudgetKeepsTargetAndBoundedTolerance() {
        XCTAssertEqual(
            ChartStressPerformanceBudget.presentationP95Target,
            0.050,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            ChartStressPerformanceBudget
                .histogramUpperBoundTolerance,
            0.000_250,
            accuracy: 0.000_001
        )
        XCTAssertTrue(
            ChartStressPerformanceBudget
                .acceptsPresentationP95(0.050_250)
        )
        XCTAssertFalse(
            ChartStressPerformanceBudget
                .acceptsPresentationP95(0.050_251)
        )
        XCTAssertFalse(
            ChartStressPerformanceBudget
                .acceptsPresentationP95(.infinity)
        )
        XCTAssertTrue(
            ChartStressPerformanceBudget
                .acceptsLongRunDroppedPresentations(0)
        )
        XCTAssertFalse(
            ChartStressPerformanceBudget
                .acceptsLongRunDroppedPresentations(1)
        )
    }

    func testStressResultStoreAtomicallyReplacesBoundedFiles()
        throws {
        ChartStressResultStore.prepareForRun()
        defer {
            ChartStressResultStore.prepareForRun()
        }

        ChartStressResultStore.writeProgress("RUNNING first")
        ChartStressResultStore.writeProgress("RUNNING second")
        ChartStressResultStore.writeResult("PASS final")

        let progressURL = try XCTUnwrap(
            ChartStressResultStore.progressURL
        )
        let resultURL = try XCTUnwrap(
            ChartStressResultStore.resultURL
        )
        XCTAssertEqual(
            try String(contentsOf: progressURL, encoding: .utf8),
            "CHART_STRESS_PROGRESS RUNNING second\n"
        )
        XCTAssertEqual(
            try String(contentsOf: resultURL, encoding: .utf8),
            "CHART_STRESS_RESULT PASS final\n"
        )
    }

    func testEMAProvisionalTailNeverMutatesCommittedState()
        throws {
        var calculator = try XCTUnwrap(
            EMAIndicatorCalculator(
                period: 3,
                intervalMilliseconds: 3_600_000
            )
        )
        XCTAssertEqual(
            calculator.commit(candle(
                openTime: 0,
                closePrice: 1,
                closure: .closed
            )).validity,
            .warmup
        )
        XCTAssertEqual(
            calculator.commit(candle(
                openTime: 3_600_000,
                closePrice: 2,
                closure: .closed
            )).validity,
            .warmup
        )
        let seeded = calculator.commit(candle(
            openTime: 7_200_000,
            closePrice: 3,
            closure: .closed
        ))
        XCTAssertEqual(seeded.validity, .valid)
        XCTAssertEqual(seeded.value ?? .nan, 2, accuracy: 0.000_001)

        let committedBeforeLiveUpdates = calculator.committed
        var lastProvisional: IndicatorPoint?
        for update in 1...10_000 {
            lastProvisional = calculator.provisional(candle(
                openTime: 10_800_000,
                closePrice: 10 + Double(update) / 10_000,
                closure: .provisional
            ))
        }

        XCTAssertEqual(
            calculator.committed,
            committedBeforeLiveUpdates
        )
        XCTAssertEqual(lastProvisional?.validity, .valid)
        XCTAssertEqual(
            lastProvisional?.value ?? .nan,
            6.5,
            accuracy: 0.000_001
        )

        let committed = calculator.commit(candle(
            openTime: 10_800_000,
            closePrice: 11,
            closure: .closed
        ))
        XCTAssertEqual(committed, lastProvisional)
        let afterTrustedClose = calculator.committed
        XCTAssertEqual(
            calculator.commit(candle(
                openTime: 10_800_000,
                closePrice: 12,
                closure: .closed
            )).validity,
            .invalid
        )
        XCTAssertEqual(calculator.committed, afterTrustedClose)
    }

    func testEMAGapRestartsWarmupWithoutBridgingMissingBars()
        throws {
        var calculator = try XCTUnwrap(
            EMAIndicatorCalculator(
                period: 3,
                intervalMilliseconds: 3_600_000
            )
        )
        _ = calculator.commit(candle(
            openTime: 0,
            closePrice: 1,
            closure: .closed
        ))
        _ = calculator.commit(candle(
            openTime: 3_600_000,
            closePrice: 2,
            closure: .closed
        ))
        let gap = calculator.commit(candle(
            openTime: 10_800_000,
            closePrice: 10,
            closure: .closed
        ))

        XCTAssertEqual(gap.validity, .dataGap)
        XCTAssertNil(gap.value)
        XCTAssertEqual(calculator.committed.sampleCount, 1)
        XCTAssertNil(calculator.committed.value)
        XCTAssertEqual(
            calculator.provisional(candle(
                openTime: 14_400_000,
                closePrice: 11,
                closure: .provisional
            ))?.validity,
            .warmup
        )
        XCTAssertEqual(calculator.committed.sampleCount, 1)
    }

    func testEMAArithmeticOverflowDoesNotPoisonCommittedState()
        throws {
        var calculator = try XCTUnwrap(
            EMAIndicatorCalculator(
                period: 2,
                intervalMilliseconds: 3_600_000
            )
        )
        _ = calculator.commit(candle(
            openTime: 0,
            closePrice: Double.greatestFiniteMagnitude,
            closure: .closed
        ))
        let beforeOverflow = calculator.committed

        let overflow = calculator.commit(candle(
            openTime: 3_600_000,
            closePrice: Double.greatestFiniteMagnitude,
            closure: .closed
        ))

        XCTAssertEqual(overflow.validity, .invalid)
        XCTAssertNil(overflow.value)
        XCTAssertEqual(calculator.committed, beforeOverflow)
    }

    func testIndicatorRegistryBuildsProductionOverlayInstances()
        throws {
        XCTAssertNil(ChartIndicatorRegistry([
            EMAChartIndicatorPlugin(),
            EMAChartIndicatorPlugin(),
        ]))

        let registry = try XCTUnwrap(ChartIndicatorRegistry.standard)
        XCTAssertEqual(
            registry.descriptors.map(\.id),
            [
                "atr",
                "average-price",
                "basis",
                "bollinger",
                "buy-sell-volume",
                "ema",
                "global-account-ratio",
                "kdj",
                "macd",
                "obv",
                "open-interest",
                "parabolic-sar",
                "rsi",
                "sma",
                "stochastic-rsi",
                "supertrend",
                "top-account-ratio",
                "top-position-ratio",
                "volume",
                "williams-r",
            ]
        )
        let configurations = try XCTUnwrap(
            ChartIndicatorEngine
                .productionPriceOverlayConfigurations()
        )
        var engine = try XCTUnwrap(ChartIndicatorEngine(
            registry: registry,
            configurations: configurations,
            intervalMilliseconds: 3_600_000,
            historyLimit: 1_500
        ))
        let history = (0..<20).map { index in
            candle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 100 + Double(index),
                closure: .closed
            )
        }

        let health = engine.installHistory(history)
        let snapshot = engine.snapshot(provisional: nil)

        XCTAssertFalse(health.requiresRecovery)
        XCTAssertEqual(snapshot.history.series.count, 5)
        XCTAssertEqual(
            Set(snapshot.history.series.map(\.key.instanceID)),
            Set([
                "supertrend.10.6",
                "ema.21",
                "ema.55",
                "ema.144",
            ])
        )
        XCTAssertTrue(
            snapshot.history.series.allSatisfy {
                $0.points.count == history.count
            }
        )
        XCTAssertEqual(snapshot.legends.count, 4)
        let superTrendLegend = try XCTUnwrap(
            snapshot.legends.first {
                $0.instanceID == "supertrend.10.6"
            }
        )
        XCTAssertEqual(
            superTrendLegend.labelColorToken,
            .neutral
        )
        XCTAssertEqual(superTrendLegend.colorToken, .positive)
    }

    func testBinancePrimaryIndicatorCalculatorsAndLiveValues()
        throws {
        let interval: Int64 = 3_600_000
        var sma = try XCTUnwrap(
            SimpleMovingAverageIndicatorCalculator(
                period: 3,
                intervalMilliseconds: interval
            )
        )
        let smaPoints = (1...3).map { index in
            sma.commit(candle(
                openTime: Int64(index - 1) * interval,
                closePrice: Double(index),
                closure: .closed
            ))
        }
        XCTAssertEqual(
            smaPoints.map(\.validity),
            [.warmup, .warmup, .valid]
        )
        XCTAssertEqual(smaPoints.last?.value, 2)
        XCTAssertEqual(
            sma.provisional(candle(
                openTime: 3 * interval,
                closePrice: 4,
                closure: .provisional
            ))?.value,
            3
        )
        XCTAssertEqual(sma.committed.lastOpenTime, 2 * interval)

        var bollinger = try XCTUnwrap(
            BollingerBandsIndicatorCalculator(
                period: 4,
                multiplier: 2,
                intervalMilliseconds: interval
            )
        )
        var bollingerPoint: BollingerBandsPoint?
        for index in 1...4 {
            bollingerPoint = bollinger.commit(candle(
                openTime: Int64(index - 1) * interval,
                closePrice: Double(index),
                closure: .closed
            ))
        }
        let resolvedBollinger = try XCTUnwrap(bollingerPoint)
        XCTAssertEqual(resolvedBollinger.middle, 2.5)
        XCTAssertEqual(
            try XCTUnwrap(resolvedBollinger.upper),
            2.5 + 2 * sqrt(1.25),
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(resolvedBollinger.lower),
            2.5 - 2 * sqrt(1.25),
            accuracy: 0.000_000_001
        )

        var averagePrice = try XCTUnwrap(
            AveragePriceIndicatorCalculator(
                intervalMilliseconds: interval
            )
        )
        let averageCandle = ChartCandle(
            openTime: 0,
            closeTime: interval - 1,
            openPrice: 100,
            highPrice: 125,
            lowPrice: 95,
            closePrice: 120,
            volume: 10,
            quoteVolume: 1_200,
            closure: .closed
        )
        XCTAssertEqual(averagePrice.commit(averageCandle).value, 120)
        let provisionalAverage = ChartCandle(
            openTime: interval,
            closeTime: 2 * interval - 1,
            openPrice: 120,
            highPrice: 130,
            lowPrice: 118,
            closePrice: 128,
            volume: 10,
            quoteVolume: 1_275,
            closure: .provisional
        )
        XCTAssertEqual(
            averagePrice.provisional(provisionalAverage)?.value,
            127.5
        )
        XCTAssertEqual(averagePrice.lastCommittedOpenTime, 0)
    }

    func testParabolicSARMatchesStandardAccelerationAndReversal()
        throws {
        let interval: Int64 = 3_600_000
        func sarCandle(
            index: Int,
            high: Double,
            low: Double,
            close: Double
        ) -> ChartCandle {
            ChartCandle(
                openTime: Int64(index) * interval,
                closeTime: Int64(index + 1) * interval - 1,
                openPrice: close,
                highPrice: high,
                lowPrice: low,
                closePrice: close,
                volume: 1,
                quoteVolume: close,
                closure: .closed
            )
        }
        var calculator = try XCTUnwrap(
            ParabolicSARIndicatorCalculator(
                start: 0.02,
                maximum: 0.2,
                intervalMilliseconds: interval
            )
        )
        let values = [
            calculator.commit(sarCandle(
                index: 0, high: 10, low: 8, close: 9
            )),
            calculator.commit(sarCandle(
                index: 1, high: 11, low: 9, close: 10
            )),
            calculator.commit(sarCandle(
                index: 2, high: 12, low: 10, close: 11
            )),
            calculator.commit(sarCandle(
                index: 3, high: 13, low: 11, close: 12
            )),
            calculator.commit(sarCandle(
                index: 4, high: 9, low: 7, close: 8
            )),
        ]
        XCTAssertEqual(values[0].validity, .warmup)
        XCTAssertEqual(values[1].value, 8)
        XCTAssertEqual(values[2].value, 8)
        XCTAssertEqual(
            try XCTUnwrap(values[3].value),
            8.16,
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(values[4].value, 13)
        XCTAssertEqual(calculator.committed.isRising, false)
    }

    func testBinancePrimaryIndicatorsProduceExpectedConfigurations()
        throws {
        let selection = try XCTUnwrap(
            ChartIndicatorSelection(activeIndicatorsInOrder: [
                .movingAverage,
                .bollingerBands,
                .parabolicSAR,
                .averagePrice,
            ])
        )
        let configurations = try XCTUnwrap(
            ChartIndicatorEngine.productionConfigurations(
                selection: selection,
                parameters: .standard
            )
        )
        XCTAssertEqual(
            configurations.map(\.instanceID),
            [
                "sma.7",
                "sma.25",
                "sma.99",
                "bollinger.20.2",
                "parabolic-sar.0.02.0.2",
                "average-price",
            ]
        )
        XCTAssertEqual(
            configurations.map(\.legendRow),
            [0, 0, 0, 1, 2, 3]
        )
        let registry = try XCTUnwrap(ChartIndicatorRegistry.standard)
        var engine = try XCTUnwrap(ChartIndicatorEngine(
            registry: registry,
            configurations: configurations,
            intervalMilliseconds: 3_600_000,
            historyLimit: 200
        ))
        let history = (0..<120).map { index in
            candle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 100 + sin(Double(index) / 5) * 10,
                volume: 10,
                closure: .closed
            )
        }
        XCTAssertFalse(engine.installHistory(history).requiresRecovery)
        let snapshot = engine.snapshot(provisional: nil)
        XCTAssertEqual(snapshot.history.series.count, 8)
        let sarSeries = try XCTUnwrap(
            snapshot.history.series.first {
                $0.key.instanceID == "parabolic-sar.0.02.0.2"
            }
        )
        XCTAssertEqual(
            sarSeries.figureStyle,
            .hollowSquareMarker(sizePoints: 2.7)
        )
    }

    func testMarketKlineDecodesProductionTradingData() throws {
        let data = try XCTUnwrap(
            """
            {
              "symbol": "BTCUSDC",
              "interval": "1h",
              "items": [{
                "openTime": 0,
                "closeTime": 3599999,
                "openPrice": 100,
                "highPrice": 102,
                "lowPrice": 99,
                "closePrice": 101,
                "volume": 12,
                "quoteVolume": 1212,
                "tradingData": {
                  "openInterest": 18500,
                  "openInterestNotional": 1200000000,
                  "topLongAccount": 0.5733,
                  "topShortAccount": 0.4267,
                  "topLongShortAccountRatio": 1.3435,
                  "takerBuyVolume": 320,
                  "takerSellVolume": 280,
                  "basis": -2.5,
                  "basisRate": -0.000025,
                  "futuresPrice": 100.5,
                  "indexPrice": 103
                }
              }]
            }
            """.data(using: .utf8)
        )

        let response = try JSONDecoder().decode(
            MarketKlineHistoryResponse.self,
            from: data
        )
        let tradingData = try XCTUnwrap(
            response.items.first?.tradingData
        )
        XCTAssertEqual(tradingData.openInterest, 18_500)
        XCTAssertEqual(
            tradingData.openInterestNotional,
            1_200_000_000
        )
        XCTAssertEqual(tradingData.topLongAccount, 0.5733)
        XCTAssertEqual(
            tradingData.topLongShortAccountRatio,
            1.3435
        )
        XCTAssertEqual(tradingData.takerBuyVolume, 320)
        XCTAssertEqual(tradingData.basis, -2.5)
    }

    func testAllBinancePanelIndicatorsRegisterAndCalculate()
        throws {
        let indicators: [ChartBuiltInIndicator] = [
            .kdj,
            .obv,
            .williamsR,
            .stochasticRSI,
            .atr,
        ]
        let configurations = try XCTUnwrap(
            ChartIndicatorEngine.productionConfigurations(
                selection: try XCTUnwrap(
                    ChartIndicatorSelection(
                        activeIndicatorsInOrder: indicators
                    )
                ),
                parameters: .standard
            )
        )
        XCTAssertEqual(configurations.count, indicators.count)
        let registry = try XCTUnwrap(ChartIndicatorRegistry.standard)
        var engine = try XCTUnwrap(ChartIndicatorEngine(
            registry: registry,
            configurations: configurations,
            intervalMilliseconds: 3_600_000,
            historyLimit: 200
        ))
        var history: [ChartCandle] = []
        history.reserveCapacity(60)
        for index in 0..<60 {
            let wave = sin(Double(index) / 3) * 8
            let trend = Double(index) / 10
            history.append(candle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 100 + wave + trend,
                volume: 10 + Double(index),
                closure: .closed
            ))
        }

        XCTAssertFalse(engine.installHistory(history).requiresRecovery)
        let snapshot = engine.snapshot(provisional: nil)
        XCTAssertEqual(snapshot.history.series.count, 8)
        XCTAssertTrue(snapshot.history.series.allSatisfy {
            $0.points.last?.validity == .valid
        })
        XCTAssertEqual(
            Set(snapshot.history.series.compactMap { series in
                guard case .panel(let id) = series.placement else {
                    return nil
                }
                return id
            }),
            Set([
                ChartPanelID.kdj,
                ChartPanelID.obv,
                ChartPanelID.williamsR,
                ChartPanelID.stochasticRSI,
                ChartPanelID.atr,
            ])
        )
    }

    func testKDJWilliamsROBVAndATRMatchReferenceValues()
        throws {
        let selected = try XCTUnwrap(ChartIndicatorSelection(
            activeIndicatorsInOrder: [.kdj, .obv, .williamsR, .atr]
        ))
        let configurations = try XCTUnwrap(
            ChartIndicatorEngine.productionConfigurations(
                selection: selected,
                parameters: .standard
            )
        )
        var engine = try XCTUnwrap(ChartIndicatorEngine(
            registry: try XCTUnwrap(ChartIndicatorRegistry.standard),
            configurations: configurations,
            intervalMilliseconds: 3_600_000,
            historyLimit: 100
        ))
        let history = (1...14).map { value in
            candle(
                openTime: Int64(value - 1) * 3_600_000,
                closePrice: Double(value),
                volume: 10,
                closure: .closed
            )
        }
        XCTAssertFalse(engine.installHistory(history).requiresRecovery)
        let series = engine.snapshot(provisional: nil).history.series
        func latest(_ instanceID: String, _ outputID: String) -> Double? {
            series.first {
                $0.key == ChartIndicatorSeriesKey(
                    instanceID: instanceID,
                    outputID: outputID
                )
            }?.points.last?.value
        }

        XCTAssertEqual(
            try XCTUnwrap(latest("obv", "value")),
            140,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(latest("williams-r.14", "value")),
            -100 / 15,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(latest("atr.14", "value")),
            2,
            accuracy: 0.000_001
        )
        for outputID in ["k", "d", "j"] {
            XCTAssertNotNil(latest("kdj.9.3.3", outputID))
        }
    }

    func testTradingDataPanelsHideMissingValuesWithoutRecovery()
        throws {
        let selected = try XCTUnwrap(ChartIndicatorSelection(
            activeIndicatorsInOrder: [
                .openInterest,
                .topAccountRatio,
                .buySellVolume,
                .basis,
            ]
        ))
        let configurations = try XCTUnwrap(
            ChartIndicatorEngine.productionConfigurations(
                selection: selected,
                parameters: .standard
            )
        )
        var engine = try XCTUnwrap(ChartIndicatorEngine(
            registry: try XCTUnwrap(ChartIndicatorRegistry.standard),
            configurations: configurations,
            intervalMilliseconds: 3_600_000,
            historyLimit: 20
        ))

        let missing = candle(
            openTime: 0,
            closePrice: 100,
            closure: .closed
        )
        XCTAssertFalse(engine.commit(missing).requiresRecovery)
        XCTAssertTrue(
            engine.snapshot(provisional: nil).history.series
                .allSatisfy { $0.points.last?.validity == .hidden }
        )

        let tradingData = MarketChartTradingData(
            openInterest: 18_500,
            openInterestNotional: 1_850_000,
            topLongAccount: 0.5733,
            topShortAccount: 0.4267,
            topLongShortAccountRatio: 1.3435,
            takerBuyVolume: 320,
            takerSellVolume: 280,
            basis: -2.5,
            basisRate: -0.025,
            futuresPrice: 100.5,
            indexPrice: 103
        )
        let enriched = ChartCandle(
            openTime: 3_600_000,
            closeTime: 7_199_999,
            openPrice: 100,
            highPrice: 102,
            lowPrice: 99,
            closePrice: 101,
            volume: 12,
            quoteVolume: 1_212,
            tradingData: tradingData,
            closure: .closed
        )
        XCTAssertFalse(engine.commit(enriched).requiresRecovery)
        let snapshot = engine.snapshot(provisional: nil)
        XCTAssertEqual(
            snapshot.history.series.first {
                $0.key.instanceID == "open-interest"
                    && $0.key.outputID == "openInterest"
            }?.points.last?.value,
            18_500
        )
        XCTAssertEqual(
            snapshot.history.series.first {
                $0.key.instanceID == "top-account-ratio"
                    && $0.key.outputID == "ratio"
            }?.points.last?.value,
            1.3435
        )
        let longLegend = try XCTUnwrap(snapshot.legends.first {
            $0.label == "L:"
        })
        XCTAssertEqual(
            try XCTUnwrap(longLegend.value),
            57.33,
            accuracy: 0.000_001
        )
    }

    func testCandleStorePreservesTradingDataAcrossPriceTicks()
        async throws {
        let tradingData = MarketChartTradingData(
            openInterest: 18_500,
            openInterestNotional: 1_850_000
        )
        let enrichedClosed = ChartCandle(
            openTime: 0,
            closeTime: 3_599_999,
            openPrice: 100,
            highPrice: 102,
            lowPrice: 99,
            closePrice: 101,
            volume: 12,
            quoteVolume: 1_212,
            tradingData: tradingData,
            closure: .closed
        )
        let store = CandleStore(initialClosed: [enrichedClosed])
        let priceTick = ChartCandle(
            openTime: 3_600_000,
            closeTime: 7_199_999,
            openPrice: 101,
            highPrice: 103,
            lowPrice: 100,
            closePrice: 102,
            volume: 13,
            quoteVolume: 1_326,
            closure: .provisional
        )
        _ = await store.apply(KlineIngressMutation(
            revision: 1,
            candle: priceTick
        ))

        let snapshot = await store.snapshot()
        let liveTail = try XCTUnwrap(snapshot.liveTail)
        XCTAssertEqual(liveTail.closePrice, 102)
        XCTAssertEqual(liveTail.tradingData, tradingData)
    }

    func testSuperTrendMatchesTa4jWarmupAndBandRules()
        throws {
        var calculator = try XCTUnwrap(
            SuperTrendIndicatorCalculator(
                atrPeriod: 3,
                multiplier: 2,
                intervalMilliseconds: 3_600_000
            )
        )
        var points: [SuperTrendPoint] = []
        for index in 0..<5 {
            points.append(calculator.commit(candle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 10 + Double(index),
                closure: .closed
            )))
        }

        XCTAssertEqual(
            points.prefix(3).map(\.validity),
            [.warmup, .warmup, .warmup]
        )
        XCTAssertEqual(points[3].validity, .valid)
        XCTAssertEqual(points[3].direction, .up)
        XCTAssertEqual(
            points[3].value ?? .nan,
            9,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            points[4].value ?? .nan,
            10,
            accuracy: 0.000_001
        )

        let committedBeforeLiveUpdate = calculator.committed
        let provisionalCandle = candle(
            openTime: 5 * 3_600_000,
            closePrice: 0,
            closure: .provisional
        )
        let provisional = try XCTUnwrap(
            calculator.provisional(provisionalCandle)
        )
        XCTAssertEqual(provisional.direction, .down)
        XCTAssertEqual(
            provisional.value ?? .nan,
            12.666_666_666_7,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            calculator.committed,
            committedBeforeLiveUpdate
        )

        let committed = calculator.commit(
            provisionalCandle.withClosure(.closed)
        )
        XCTAssertEqual(committed, provisional)
    }

    func testSuperTrendGapRestartsWithoutBridgingState()
        throws {
        var calculator = try XCTUnwrap(
            SuperTrendIndicatorCalculator(
                atrPeriod: 3,
                multiplier: 2,
                intervalMilliseconds: 3_600_000
            )
        )
        _ = calculator.commit(candle(
            openTime: 0,
            closePrice: 100,
            closure: .closed
        ))
        let gap = calculator.commit(candle(
            openTime: 7_200_000,
            closePrice: 101,
            closure: .closed
        ))

        XCTAssertEqual(gap.validity, .dataGap)
        XCTAssertNil(gap.value)
        XCTAssertEqual(calculator.committed.sampleCount, 1)
        XCTAssertNil(calculator.committed.atr)
        XCTAssertEqual(
            calculator.provisional(candle(
                openTime: 10_800_000,
                closePrice: 102,
                closure: .provisional
            ))?.validity,
            .warmup
        )
        XCTAssertEqual(calculator.committed.sampleCount, 1)
    }

    func testPanelLayoutSupportsMultipleIndependentPanels()
        throws {
        let panelCount = 3
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: ChartPanelLayout
                .preferredViewportHeightPoints(
                    indicatorPanelCount: panelCount
                ),
            displayScale: 3
        ))
        let layout = try XCTUnwrap(ChartPanelLayout.make(
            viewport: viewport,
            indicatorPanelIDs: [
                ChartPanelID.volume,
                ChartPanelID.macd,
                ChartPanelID.rsi,
            ]
        ))

        XCTAssertEqual(
            layout.panels.map(\.id),
            [
                ChartPanelID.price,
                ChartPanelID.volume,
                ChartPanelID.macd,
                ChartPanelID.rsi,
            ]
        )
        let price = try XCTUnwrap(layout.pricePanel)
        let volume = try XCTUnwrap(
            layout.panel(id: ChartPanelID.volume)
        )
        let macd = try XCTUnwrap(
            layout.panel(id: ChartPanelID.macd)
        )
        let rsi = try XCTUnwrap(
            layout.panel(id: ChartPanelID.rsi)
        )
        XCTAssertGreaterThanOrEqual(price.plot.height, 120 * 3)
        XCTAssertEqual(price.frame.height, 298 * 3)
        XCTAssertEqual(volume.frame.height, 72 * 3)
        XCTAssertEqual(macd.frame.height, 72 * 3)
        XCTAssertEqual(rsi.frame.height, 72 * 3)
        XCTAssertLessThan(price.plot.bottom, volume.plot.top)
        XCTAssertLessThan(volume.plot.bottom, macd.plot.top)
        XCTAssertLessThan(macd.plot.bottom, rsi.plot.top)
        XCTAssertEqual(price.frame.bottom, layout.timeAxisTop)
        XCTAssertGreaterThan(volume.frame.top, layout.timeAxisBottom)
        XCTAssertEqual(rsi.frame.bottom, Float(viewport.heightPixels))
        let priceOnlyViewport = try XCTUnwrap(
            ChartSceneViewport(
                widthPoints: 390,
                heightPoints: ChartPanelLayout
                    .preferredViewportHeightPoints(
                        indicatorPanelCount: 0
                    ),
                displayScale: 3
            )
        )
        let priceOnlyLayout = try XCTUnwrap(
            ChartPanelLayout.make(
                viewport: priceOnlyViewport,
                indicatorPanelIDs: []
            )
        )
        XCTAssertEqual(
            priceOnlyLayout.pricePanel?.frame.height,
            price.frame.height
        )
        XCTAssertNil(ChartPanelLayout.make(
            viewport: viewport,
            indicatorPanelIDs: [ChartPanelID.macd, ChartPanelID.macd]
        ))
    }

    func testPanelLayoutGivesExtraHeightToPricePanel() throws {
        let panelConfigurations = [
            [],
            [ChartPanelID.macd],
            [ChartPanelID.macd, ChartPanelID.volume],
        ]
        for scale in [1.0, 2.0, 3.0] {
            for panelIDs in panelConfigurations {
                for extraHeight in [0.0, 120.0, 300.0] {
                    let height = ChartPanelLayout.preferredViewportHeightPoints(
                        indicatorPanelCount: panelIDs.count
                    ) + extraHeight
                    let viewport = try XCTUnwrap(ChartSceneViewport(
                        widthPoints: 390,
                        heightPoints: height,
                        displayScale: scale
                    ))
                    let layout = try XCTUnwrap(ChartPanelLayout.make(
                        viewport: viewport,
                        indicatorPanelIDs: panelIDs
                    ))
                    let pricePanel = try XCTUnwrap(layout.pricePanel)
                    XCTAssertEqual(
                        pricePanel.frame.height,
                        Float((298 + extraHeight) * scale)
                    )
                    for panel in layout.indicatorPanels {
                        XCTAssertEqual(panel.frame.height, Float(72 * scale))
                        XCTAssertEqual(panel.plot.top, panel.frame.top)
                        XCTAssertEqual(
                            panel.frame.bottom - panel.plot.bottom,
                            Float(16 * scale)
                        )
                        XCTAssertGreaterThan(panel.legendBaseline, panel.plot.bottom)
                        XCTAssertLessThan(panel.legendBaseline, panel.frame.bottom)
                    }
                    XCTAssertEqual(pricePanel.frame.bottom, layout.timeAxisTop)
                    XCTAssertEqual(
                        layout.indicatorPanels.last?.frame.bottom ?? layout.timeAxisBottom,
                        Float(viewport.heightPixels)
                    )
                    XCTAssertEqual(
                        layout.timeAxisBottom - layout.timeAxisTop,
                        Float(24 * scale)
                    )
                }
            }
        }
    }

    func testChartFirstScreenContainsOnlyOneIndicatorPanel() throws {
        let panelIDs = [ChartPanelID.macd, ChartPanelID.volume, ChartPanelID.rsi]
        for count in 0...panelIDs.count {
            for availableHeight in [500.0, 640.0, 800.0] {
                for scale in [1.0, 2.0, 3.0] {
                    let contentHeight = ChartPanelLayout.scrollContentHeightPoints(
                        availableHeightPoints: availableHeight,
                        indicatorPanelCount: count
                    )
                    let layout = try XCTUnwrap(ChartPanelLayout.make(
                        viewport: try XCTUnwrap(ChartSceneViewport(
                            widthPoints: 390,
                            heightPoints: contentHeight,
                            displayScale: scale
                        )),
                        indicatorPanelIDs: Array(panelIDs.prefix(count))
                    ))
                    let screenBottom = Float(availableHeight * scale)
                    XCTAssertEqual(layout.indicatorPanels.count, count)
                    XCTAssertEqual(layout.pricePanel?.frame.bottom, layout.timeAxisTop)
                    XCTAssertLessThanOrEqual(layout.timeAxisBottom, screenBottom)
                    let visiblePanels = layout.indicatorPanels.filter {
                        $0.frame.top < screenBottom
                    }
                    XCTAssertEqual(visiblePanels.count, min(1, count))
                    if let first = visiblePanels.first {
                        XCTAssertLessThanOrEqual(first.frame.bottom, screenBottom)
                        XCTAssertEqual(first.frame.height, Float(72 * scale))
                        XCTAssertGreaterThan(first.frame.top, layout.timeAxisBottom)
                        XCTAssertGreaterThan(first.legendBaseline, first.plot.bottom)
                    }
                    if count > 1 {
                        XCTAssertEqual(visiblePanels.first?.frame.bottom, screenBottom)
                        XCTAssertGreaterThan(layout.indicatorPanels[1].frame.top, screenBottom)
                        XCTAssertGreaterThan(contentHeight, availableHeight)
                    } else {
                        XCTAssertEqual(contentHeight, availableHeight)
                    }
                }
            }
        }
        for invalidHeight in [0.0, -1.0, .nan, .infinity] {
            XCTAssertEqual(
                ChartPanelLayout.scrollContentHeightPoints(
                    availableHeightPoints: invalidHeight,
                    indicatorPanelCount: 2
                ),
                ChartPanelLayout.preferredViewportHeightPoints(indicatorPanelCount: 2)
            )
        }
    }

    @MainActor
    func testCrosshairLabelsFitTimeAndPriceAxesWithoutActionIcon() async throws {
        let fixture = try await makeChartSceneFixture()
        for width in [320.0, 390.0, 440.0] {
            for scale in [2.0, 3.0] {
                let viewport = try XCTUnwrap(ChartSceneViewport(
                    widthPoints: width, heightPoints: 396, displayScale: scale))
                let output = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport)
                let data = try XCTUnwrap(output.renderState.staticScene.crosshairData)
                let layout = output.panelLayout
                let pricePanel = try XCTUnwrap(layout.pricePanel)
                for panel in [pricePanel] + layout.indicatorPanels {
                    let hit = try XCTUnwrap(ChartCrosshairResolver.resolve(
                        screenX: Double(layout.plotLeft + 180),
                        screenY: Double((panel.plot.top + panel.plot.bottom) / 2),
                        transform: .identity, data: data,
                        liveData: output.renderState.liveTail.crosshairLiveData, clampsToPlot: false))
                    let snapshot = ChartCrosshairOverlayBuilder().makeSnapshot(
                        hit: hit, data: data, latestPrice: hit.selection.panelValue / 1.1)
                    let storage = try XCTUnwrap(snapshot.batches.first?.storage)
                    let axisBars = storage.barInstances.filter { $0.left >= layout.plotRight }
                    XCTAssertEqual(axisBars.count, 1, "Price label must have no action icon or divider")
                    let label = try XCTUnwrap(axisBars.first)
                    XCTAssertEqual(label.cornerRadius, Float(4 * scale))
                    XCTAssertEqual(label.right, Float(viewport.widthPixels) - Float(scale))
                    let axisGlyphs = storage.glyphInstances.filter {
                        $0.color == .crosshairAxisLabelText && $0.left >= layout.plotRight
                            && $0.top >= label.top && $0.bottom <= label.bottom
                    }
                    let texts = [DisplayNumber.text(hit.selection.panelValue, grouped: true)]
                        + (panel.isPricePanel ? ["+10.00%"] : [])
                    let expectedCount = texts.reduce(0) { total, text in
                        total + MetalTextLayouter.layout(text: text, atlas: data.glyphAtlas,
                            originX: 0, baselineY: 0, color: .crosshairAxisLabelText).instances.count
                    }
                    XCTAssertEqual(axisGlyphs.count, expectedCount, "Keep every digit when fitting the axis")
                    XCTAssertTrue(axisGlyphs.allSatisfy { $0.left >= label.left && $0.right <= label.right })
                    let anchor = Float(viewport.widthPixels) - Float(4 * scale)
                    let rows = Dictionary(grouping: axisGlyphs) { Int((($0.top + $0.bottom) / 2 - label.top) / Float(16 * scale)) }
                    for row in rows.values {
                        let right = try XCTUnwrap(row.map(\.right).max())
                        XCTAssertLessThanOrEqual(right, label.right)
                        XCTAssertGreaterThanOrEqual(right, anchor - Float(2 * scale), "Use the original price-axis text anchor")
                    }
                    let timeLabel = try XCTUnwrap(storage.barInstances.first {
                        $0.color == .crosshairAxisLabelBackground && $0.top >= layout.timeAxisTop
                            && $0.bottom <= layout.timeAxisBottom
                    })
                    XCTAssertEqual(timeLabel.bottom - timeLabel.top, Float(20 * scale), accuracy: 0.01)
                    XCTAssertEqual(timeLabel.top + timeLabel.bottom, layout.timeAxisTop + layout.timeAxisBottom, accuracy: 0.01)
                    let timeGlyphs = storage.glyphInstances.filter {
                        $0.color == .crosshairAxisLabelText && $0.top >= layout.timeAxisTop && $0.bottom <= layout.timeAxisBottom
                    }
                    XCTAssertFalse(timeGlyphs.isEmpty)
                    let glyphTop = try XCTUnwrap(timeGlyphs.map(\.top).min())
                    let glyphBottom = try XCTUnwrap(timeGlyphs.map(\.bottom).max())
                    XCTAssertEqual((glyphTop + glyphBottom) / 2, (timeLabel.top + timeLabel.bottom) / 2, accuracy: 0.01)
                }
            }
        }
    }

    @MainActor
    func testTimeAxisAndPanelFootersKeepCrosshairInSync() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: ChartPanelLayout.scrollContentHeightPoints(
                availableHeightPoints: 640,
                indicatorPanelCount: 2
            ),
            displayScale: 3
        ))
        let output = try await ChartSceneBuilder().build(
            frame: fixture.frame,
            viewport: viewport
        )
        let layout = output.panelLayout
        let data = try XCTUnwrap(output.renderState.staticScene.crosshairData)
        let firstPanel = try XCTUnwrap(layout.indicatorPanels.first)
        let x = Double(layout.plotLeft + 180)
        XCTAssertNil(ChartCrosshairResolver.resolve(
            screenX: x,
            screenY: Double((layout.timeAxisTop + layout.timeAxisBottom) / 2),
            transform: .identity,
            data: data,
            liveData: nil,
            clampsToPlot: false
        ))
        XCTAssertNil(ChartCrosshairResolver.resolve(
            screenX: x,
            screenY: Double(firstPanel.legendBaseline),
            transform: .identity,
            data: data,
            liveData: nil,
            clampsToPlot: false
        ))
        let hit = try XCTUnwrap(ChartCrosshairResolver.resolve(
            screenX: x,
            screenY: Double((firstPanel.plot.top + firstPanel.plot.bottom) / 2),
            transform: .identity,
            data: data,
            liveData: output.renderState.liveTail.crosshairLiveData,
            clampsToPlot: false
        ))
        XCTAssertEqual(hit.selection.panelID, firstPanel.id)
        let snapshot = ChartCrosshairOverlayBuilder().makeSnapshot(hit: hit, data: data)
        let storage = try XCTUnwrap(snapshot.batches.first?.storage)
        let verticalLines = storage.lineSegments.filter { $0.start.x == $0.end.x }
        XCTAssertEqual(verticalLines.count, layout.panels.count)
        for (line, panel) in zip(verticalLines, layout.panels) {
            XCTAssertEqual(line.start.y, panel.plot.top)
            XCTAssertEqual(line.end.y, panel.plot.bottom)
        }
        let timeLabels = storage.barInstances.filter {
            $0.color == .crosshairAxisLabelBackground
                && $0.top >= layout.timeAxisTop
                && $0.bottom <= layout.timeAxisBottom
        }
        let timeLabel = try XCTUnwrap(timeLabels.first)
        XCTAssertEqual(timeLabels.count, 1)
        XCTAssertLessThan(timeLabel.bottom - timeLabel.top, layout.timeAxisBottom - layout.timeAxisTop)
        XCTAssertEqual(timeLabel.top + timeLabel.bottom, layout.timeAxisTop + layout.timeAxisBottom, accuracy: 0.01)
        for panel in layout.indicatorPanels {
            XCTAssertTrue(storage.barInstances.contains {
                $0.color == .chartBackground
                    && $0.top == panel.plot.bottom
                    && $0.bottom == panel.frame.bottom
            })
        }
        let fixedGlyphs = try XCTUnwrap(
            output.renderState.staticScene.batches.last?.storage.glyphInstances
        )
        XCTAssertFalse(fixedGlyphs.filter {
            $0.top >= layout.timeAxisTop && $0.bottom <= layout.timeAxisBottom
                && $0.right <= layout.plotRight
        }.isEmpty)
        let legendGlyphs = output.renderState.liveTail.batches.filter {
            $0.interactionVisibility == .hiddenWhileCrosshairIsActive
        }.flatMap { $0.storage.glyphInstances }
        for panel in layout.indicatorPanels {
            XCTAssertFalse(fixedGlyphs.contains {
                $0.top >= panel.plot.bottom && $0.bottom <= panel.frame.bottom
            })
            let footerGlyphs = legendGlyphs.filter {
                $0.top >= panel.frame.top && $0.bottom <= panel.frame.bottom
            }
            XCTAssertFalse(footerGlyphs.isEmpty)
            XCTAssertTrue(footerGlyphs.allSatisfy { $0.top >= panel.plot.bottom })
        }
    }

    func testIndicatorSelectionSupportsMultiplePanelsAndPersistsSafely()
        throws {
        XCTAssertTrue(
            ChartIndicatorSelection.standard.contains(.volume)
        )
        XCTAssertEqual(
            ChartIndicatorSelection.standard
                .activePanelIndicatorsInOrder,
            [.macd, .volume]
        )
        XCTAssertTrue(
            ChartIndicatorSelection.standard
                .requestedTradingDataSeries.isEmpty
        )

        let tradingPanels = try XCTUnwrap(
            ChartIndicatorSelection(activeIndicatorsInOrder: [
                .basis,
                .openInterest,
                .topAccountRatio,
                .topPositionRatio,
                .globalAccountRatio,
                .buySellVolume,
            ])
        )
        XCTAssertEqual(
            tradingPanels.requestedTradingDataSeries,
            [
                .basis,
                .openInterest,
                .topAccountRatio,
                .topPositionRatio,
                .globalAccountRatio,
                .buySellVolume,
            ]
        )

        let withoutVolume = ChartIndicatorSelection
            .standard
            .toggling(.volume)
        XCTAssertFalse(withoutVolume.contains(.volume))
        XCTAssertTrue(withoutVolume.contains(.macd))
        let volume = withoutVolume.toggling(.volume)
        XCTAssertTrue(volume.contains(.volume))
        XCTAssertEqual(
            volume.activePanelIndicatorsInOrder,
            [.macd, .volume]
        )
        let multiplePanels = try XCTUnwrap(
            ChartIndicatorSelection(activeIndicatorsInOrder: [
            .volume,
            .macd,
            .rsi,
        ]))
        XCTAssertTrue(multiplePanels.contains(.volume))
        XCTAssertTrue(multiplePanels.contains(.macd))
        XCTAssertTrue(multiplePanels.contains(.rsi))

        let suiteName =
            "ChartIndicatorSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let key = "selection"
        let store = ChartIndicatorSelectionStore(
            defaults: defaults,
            key: key
        )
        store.save(volume)
        XCTAssertEqual(store.load(), volume)
        XCTAssertEqual(
            defaults.stringArray(forKey: key),
            ["EMA", "SUPER", "MACD", "VOL"]
        )

        defaults.set(["VOL", "MACD"], forKey: key)
        XCTAssertEqual(
            store.load(),
            ChartIndicatorSelection(activeIndicatorsInOrder: [
                .volume,
                .macd,
            ])
        )
        defaults.set(["EMA", "UNKNOWN"], forKey: key)
        XCTAssertEqual(store.load(), .standard)
    }

    func testPanelActivationOrderPersistsWithoutCatalogSorting() throws {
        let suiteName = "ChartPanelOrderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ChartIndicatorSelectionStore(defaults: defaults)
        var selection = ChartIndicatorSelection.priceOverlays
        for indicator in [ChartBuiltInIndicator.atr, .rsi, .obv] {
            selection = selection.toggling(indicator)
        }
        XCTAssertEqual(selection.activePanelIndicatorsInOrder, [.atr, .rsi, .obv])
        selection = selection.toggling(.ema)
        XCTAssertEqual(selection.activePanelIndicatorsInOrder, [.atr, .rsi, .obv])
        selection = selection.toggling(.atr).toggling(.atr)
        XCTAssertEqual(selection.activePanelIndicatorsInOrder, [.rsi, .obv, .atr])
        store.save(selection)
        XCTAssertEqual(store.load(), selection)
        XCTAssertEqual(
            ChartIndicatorSelectionStore(defaults: defaults).load()
                .activePanelIndicatorsInOrder,
            [.rsi, .obv, .atr]
        )
        XCTAssertNil(ChartIndicatorSelection(activeIndicatorsInOrder: [.rsi, .rsi]))
        XCTAssertNil(ChartIndicatorSelection(persistedRawValues: ["RSI", "RSI"]))

        store.applyLaunchOverrides(arguments: ["--chart-calibration-panel", "RSI"])
        XCTAssertEqual(store.load().activePanelIndicatorsInOrder, [.macd, .volume, .rsi])
        store.save(selection)
        for _ in 0..<3 {
            XCTAssertEqual(store.load(), selection)
        }
        store.applyLaunchOverrides(arguments: [])
        XCTAssertEqual(store.load(), selection)
    }

    func testPanelActivationOrderReachesPipelineAndScene() async throws {
        let fixture = try await makeChartSceneFixture()
        let initial = ChartIndicatorSelection.priceOverlays
            .toggling(.atr).toggling(.rsi).toggling(.obv)
        let withoutATR = initial.toggling(.atr)
        let reopenedATR = withoutATR.toggling(.atr)
        let selections = [initial, withoutATR, reopenedATR]
        let expectedPanelIDs = [
            [ChartPanelID.atr, ChartPanelID.rsi, ChartPanelID.obv],
            [ChartPanelID.rsi, ChartPanelID.obv],
            [ChartPanelID.rsi, ChartPanelID.obv, ChartPanelID.atr],
        ]
        for (index, selection) in selections.enumerated() {
            let result = await fixture.pipeline.updateIndicatorConfiguration(
                selection: selection,
                parameters: .standard,
                revision: UInt64(index + 1)
            )
            let frame = try XCTUnwrap(result?.frame)
            let expected = expectedPanelIDs[index]
            XCTAssertEqual(
                ChartPanelLayout.indicatorPanelIDs(series: frame.indicators.history.series),
                expected
            )
            let viewport = try XCTUnwrap(ChartSceneViewport(
                widthPoints: 390,
                heightPoints: ChartPanelLayout.scrollContentHeightPoints(
                    availableHeightPoints: 640,
                    indicatorPanelCount: expected.count
                ),
                displayScale: 3
            ))
            let output = try await ChartSceneBuilder().build(frame: frame, viewport: viewport)
            XCTAssertEqual(output.panelLayout.indicatorPanels.map(\.id), expected)
        }
    }

    func testIndicatorParametersValidatePersistAndDriveConfigurations()
        throws {
        let parameters = try XCTUnwrap(
            ChartIndicatorParameters(
                emaPeriods: [8, 21, 55],
                superTrendATRPeriod: 14,
                superTrendMultiplier: 3.5,
                volumeFastPeriod: 7,
                volumeSlowPeriod: 20,
                macdFastPeriod: 8,
                macdSlowPeriod: 21,
                macdSignalPeriod: 5
            )
        )
        XCTAssertNil(ChartIndicatorParameters(
            emaPeriods: [21, 8, 55],
            superTrendATRPeriod: 14,
            superTrendMultiplier: 3.5,
            volumeFastPeriod: 7,
            volumeSlowPeriod: 20,
            macdFastPeriod: 8,
            macdSlowPeriod: 21,
            macdSignalPeriod: 5
        ))
        XCTAssertNil(ChartIndicatorParameters(
            emaPeriods: [8, 21, 55],
            superTrendATRPeriod: 14,
            superTrendMultiplier: 3.55,
            volumeFastPeriod: 7,
            volumeSlowPeriod: 20,
            macdFastPeriod: 8,
            macdSlowPeriod: 21,
            macdSignalPeriod: 5
        ))
        XCTAssertNil(ChartIndicatorParameters(
            emaPeriods: [8, 21, 55],
            superTrendATRPeriod: 14,
            superTrendMultiplier: 3.5,
            volumeFastPeriod: 21,
            volumeSlowPeriod: 20,
            macdFastPeriod: 8,
            macdSlowPeriod: 21,
            macdSignalPeriod: 5
        ))
        XCTAssertNil(ChartIndicatorParameters(
            emaPeriods: [8, 21, 55],
            superTrendATRPeriod: 14,
            superTrendMultiplier: 3.5,
            volumeFastPeriod: 7,
            volumeSlowPeriod: 20,
            macdFastPeriod: 21,
            macdSlowPeriod: 21,
            macdSignalPeriod: 5
        ))

        let suiteName =
            "ChartIndicatorParametersTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let key = "parameters"
        let store = ChartIndicatorParametersStore(
            defaults: defaults,
            key: key
        )
        store.save(parameters)
        XCTAssertEqual(store.load(), parameters)
        let futurePayload = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 99,
                "emaPeriods": [8, 21, 55],
                "superTrendATRPeriod": 14,
                "superTrendMultiplier": 3.5,
                "volumeFastPeriod": 7,
                "volumeSlowPeriod": 20,
                "macdFastPeriod": 8,
                "macdSlowPeriod": 21,
                "macdSignalPeriod": 5,
            ]
        )
        defaults.set(futurePayload, forKey: key)
        XCTAssertEqual(store.load(), .standard)
        defaults.set(Data([0xFF]), forKey: key)
        XCTAssertEqual(store.load(), .standard)

        let configurations = try XCTUnwrap(
            ChartIndicatorEngine.productionConfigurations(
                selection: try XCTUnwrap(
                    ChartIndicatorSelection(activeIndicatorsInOrder: [
                        .ema,
                        .superTrend,
                        .volume,
                        .macd,
                        .rsi,
                    ])
                ),
                parameters: parameters
            )
        )
        XCTAssertEqual(
            Set(configurations.map(\.instanceID)),
            Set([
                "supertrend.14.3.5",
                "ema.8",
                "ema.21",
                "ema.55",
                "volume.7.20",
                "macd.8.21.5",
                "rsi.14",
            ])
        )
        XCTAssertEqual(
            configurations.first {
                $0.pluginID == "supertrend"
            }?.legendLabel,
            "SUPERTREND(14,3.500)"
        )
        XCTAssertEqual(
            configurations.first {
                $0.pluginID == "supertrend"
            }?.legendRow,
            1
        )
        XCTAssertEqual(
            configurations.filter { $0.pluginID == "ema" }
                .map(\.legendRow),
            [0, 0, 0]
        )
    }

    func testEMAUsesReferenceColorsWithoutChangingOtherIndicatorPalettes() throws {
        let configurations = try XCTUnwrap(ChartIndicatorEngine.productionConfigurations(
            selection: .priceOverlays, parameters: .standard
        ))
        let ema = configurations.filter { $0.pluginID == "ema" }
        XCTAssertEqual(ema.map(\.instanceID), ["ema.21", "ema.55", "ema.144"])
        XCTAssertEqual(ema.compactMap { $0.outputColorOverrides["value"] },
                       [.emaShort, .emaMedium, .emaLong])
        XCTAssertEqual(ChartColor.emaShort.green, 189 / 255, accuracy: 0.000001)
        XCTAssertEqual(ChartColor.emaMedium.blue, 246 / 255, accuracy: 0.000001)
        XCTAssertEqual(ChartColor.emaLong.red, 113 / 255, accuracy: 0.000001)
        XCTAssertNotEqual(ChartColor.ema21, .emaShort)
        XCTAssertNotEqual(ChartColor.ema55, .emaMedium)
    }

    func testBollingerBandWidthIsStableUnderLargePriceTranslation() throws {
        var small = try XCTUnwrap(BollingerBandsIndicatorCalculator(
            period: 20, multiplier: 2, intervalMilliseconds: 60_000
        ))
        var large = small
        for index in 0..<240 {
            let price = 100 + sin(Double(index) * 0.21) * 0.01
            func input(_ value: Double) -> ChartCandle {
                ChartCandle(
                    openTime: Int64(index) * 60_000,
                    closeTime: Int64(index + 1) * 60_000 - 1,
                    openPrice: value, highPrice: value, lowPrice: value,
                    closePrice: value, volume: 1, quoteVolume: value, closure: .closed
                )
            }
            let first = small.commit(input(price))
            let second = large.commit(input(price + 100_000_000))
            if first.validity == .valid {
                let width = try XCTUnwrap(first.upper) - XCTUnwrap(first.middle)
                let translated = try XCTUnwrap(second.upper) - XCTUnwrap(second.middle)
                XCTAssertEqual(translated, width, accuracy: 0.0000001)
            }
        }
        let committed = large.committed
        _ = large.provisional(ChartCandle(
            openTime: 240 * 60_000, closeTime: 241 * 60_000 - 1,
            openPrice: 100_000_100, highPrice: 100_000_100, lowPrice: 100_000_100,
            closePrice: 100_000_100, volume: 1, quoteVolume: 100_000_100, closure: .provisional
        ))
        XCTAssertEqual(large.committed, committed)
    }

    func testMetalIndicatorLinesHaveAntialiasedEdgesAt2xAnd3x() throws {
        let renderer = try MetalRenderer(
            device: XCTUnwrap(MTLCreateSystemDefaultDevice()), pixelFormat: .bgra8Unorm_srgb
        )
        for scale: Float in [2, 3] {
            let lines = ChartBatchCompiler.lineSegments(
                spans: [[.init(x: 8 * scale, y: 25 * scale),
                         .init(x: 40 * scale, y: 8 * scale),
                         .init(x: 75 * scale, y: 35 * scale)]],
                width: 0.85 * scale, color: .primaryText, antialias: true
            )
            let state = RenderState(
                staticScene: StaticSceneSnapshot(
                    revision: 1, candleHistory: ChartCandleHistory(candles: []),
                    batches: [ChartRenderBatch(lineSegments: lines, coordinateSpace: .fixed)]
                ),
                liveTail: LiveTailSnapshot(revision: 1, candle: nil, batches: [], latestPrice: nil),
                interaction: InteractionSnapshot(revision: 1, translationX: 0, scaleX: 1, crosshair: nil),
                invalidation: .full
            )
            let image = try XCTUnwrap(renderer.renderOffscreen(
                state: state, width: Int(80 * scale), height: Int(40 * scale)
            ))
            var edgePixels = 0
            for row in 0..<image.height {
                for column in 0..<image.width {
                    let value = image.bgra8UnormSRGB[row * image.bytesPerRow + column * 4]
                    if value > 10 && value < 200 { edgePixels += 1 }
                }
            }
            XCTAssertGreaterThan(edgePixels, 50)
        }
    }

    func testSuperFillUsesTheSameEndpointsAsHistoryAndLiveTrendLines() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
        let output = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport)
        let pricePanel = try XCTUnwrap(output.panelLayout.pricePanel)
        for batches in [output.renderState.staticScene.batches, output.renderState.liveTail.batches] {
            let allBars: [ChartBarInstance] = batches.flatMap { $0.storage.barInstances }
            let bars = allBars.filter { abs($0.color.alpha - Float(0.16)) < Float(0.0001) }
            let allLines: [ChartLineSegmentInstance] = batches.flatMap { $0.storage.lineSegments }
            let lines = allLines.filter { line in
                let isTrendColor = line.color == ChartColor.positive || line.color == ChartColor.negative
                return isTrendColor && line.start.y <= pricePanel.plot.bottom && line.end.y <= pricePanel.plot.bottom
            }
            var matched = 0
            for line in lines {
                let matching = bars.first { bar in
                    let startMatches = abs(bar.left - line.start.x) < Float(0.001)
                    let endMatches = abs(bar.right - line.end.x) < Float(0.001)
                    return startMatches && endMatches
                }
                guard let bar = matching else { continue }
                XCTAssertLessThan(min(abs(bar.top - line.start.y), abs(bar.bottom - line.start.y)), 0.001)
                XCTAssertLessThan(min(abs(bar.rightTop - line.end.y), abs(bar.rightBottom - line.end.y)), 0.001)
                matched += 1
            }
            XCTAssertGreaterThan(matched, 0, "History and live fills must meet the exact sloping trend-line endpoints")
        }
    }

    func testSuperFillClipsToPricePanelWhenPriceAxisIsMagnified() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
        for magnification in [2.0, 4.0] {
            let output = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport,
                priceViewport: try XCTUnwrap(ChartPriceViewport(magnification: magnification)))
            let plot = try XCTUnwrap(output.panelLayout.pricePanel).plot
            let batches = output.renderState.staticScene.batches + output.renderState.liveTail.batches
            let bands = batches.flatMap { $0.storage.barInstances }.filter { abs($0.color.alpha - 0.16) < 0.0001 }
            XCTAssertFalse(bands.isEmpty)
            XCTAssertTrue(bands.allSatisfy { min($0.top, $0.rightTop) >= plot.top - 0.001 },
                "Magnifying the price axis must not draw Super fill into the legend")
            XCTAssertTrue(bands.allSatisfy { max($0.bottom, $0.rightBottom) <= plot.bottom + 0.001 },
                "Magnifying the price axis must not draw Super fill into lower panels")
        }
    }

    func testSlopingBandPixelsStayInsideCurveDuringPan() throws {
        let renderer = try MetalRenderer(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), pixelFormat: .bgra8Unorm_srgb)
        let band = ChartBarInstance(left: 20, top: 10, right: 100, bottom: 60,
            color: .positive.withAlpha(0.16), rightTop: 40, rightBottom: 60)
        for appearance in [ChartAppearance.light, .dark] {
            func render(_ translation: Double) throws -> MetalOffscreenImage {
                let state = RenderState(staticScene: StaticSceneSnapshot(revision: 1,
                    candleHistory: ChartCandleHistory(candles: []), batches: [ChartRenderBatch(barInstances: [band])],
                    horizontalPlotBounds: ChartHorizontalPlotBounds(left: 0, right: 160)),
                    liveTail: LiveTailSnapshot(revision: 1, candle: nil, batches: [], latestPrice: nil),
                    interaction: InteractionSnapshot(revision: 1, translationX: translation, scaleX: 1, crosshair: nil),
                    invalidation: .full, appearance: appearance)
                return try XCTUnwrap(renderer.renderOffscreen(state: state, width: 160, height: 80))
            }
            let idle = try render(0), moving = try render(8)
            func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                let offset = y * idle.bytesPerRow + x * 4
                return Array(idle.bgra8UnormSRGB[offset..<offset + 4])
            }
            XCTAssertEqual(pixel(90, 25), pixel(5, 25), "The far end must leave the area above the sloping line empty")
            XCTAssertNotEqual(pixel(30, 25), pixel(5, 25), "The near end must remain filled up to the line")
            for y in 0..<80 { for x in 0..<140 {
                let a = y * idle.bytesPerRow + x * 4, b = y * moving.bytesPerRow + (x + 8) * 4
                XCTAssertEqual(Array(idle.bgra8UnormSRGB[a..<a+4]), Array(moving.bgra8UnormSRGB[b..<b+4]))
            } }
        }
    }

    func testSuperTransparencySliderSpansOnlyEightyToOneHundredPercent() {
        XCTAssertEqual(SuperTrendFillTransparency.alpha(sliderValue: 0, appearance: .light), 0.6, accuracy: 0.000001)
        XCTAssertEqual(SuperTrendFillTransparency.alpha(sliderValue: 0.5, appearance: .light), 0.5, accuracy: 0.000001)
        XCTAssertEqual(SuperTrendFillTransparency.alpha(sliderValue: 1, appearance: .light), 0.4, accuracy: 0.000001)
        XCTAssertEqual(SuperTrendFillTransparency.alpha(sliderValue: 0), 0.2, accuracy: 0.000001)
        XCTAssertEqual(SuperTrendFillTransparency.alpha(sliderValue: 0.5), 0.1, accuracy: 0.000001)
        XCTAssertEqual(SuperTrendFillTransparency.alpha(sliderValue: 1), 0, accuracy: 0.000001)
        XCTAssertEqual(SuperTrendFillTransparency.sliderValue(alpha: 0.16), 0.2, accuracy: 0.000001)
        XCTAssertEqual(SuperTrendFillTransparency.sliderValue(alpha: 0.8), 0, accuracy: 0.000001)
        for step in 0...100 {
            let value = Double(step) / 100
            let alpha = SuperTrendFillTransparency.alpha(sliderValue: value)
            XCTAssertTrue((0...0.2).contains(alpha))
            XCTAssertEqual(SuperTrendFillTransparency.sliderValue(alpha: alpha), value, accuracy: 0.000001)
            for color in [ChartColor.positive, .negative] {
                let fill = SuperTrendFillTransparency.color(color, storedAlpha: Float(alpha))
                XCTAssertEqual(fill.resolved(for: .dark).alpha, Float(alpha), accuracy: 0.000001)
                XCTAssertEqual(fill.resolved(for: .light).alpha, Float(0.6 - 0.2 * value), accuracy: 0.000001)
                XCTAssertEqual(color.resolved(for: .light).alpha, 1, "Only Super fills use the theme alpha range")
            }
        }
    }

    func testSuperFillUsesThemeRangesForHistoryAndLive() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 396, displayScale: 3))
        let output = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport)
        for batches in [output.renderState.staticScene.batches, output.renderState.liveTail.batches] {
            let fills = batches.flatMap { $0.storage.barInstances }.filter { abs($0.color.alpha - 0.16) < 0.0001 }
            XCTAssertFalse(fills.isEmpty)
            for fill in fills {
                XCTAssertEqual(fill.color.resolved(for: .light).alpha, 0.56, accuracy: 0.00001)
                XCTAssertEqual(fill.color.resolved(for: .dark).alpha, 0.16, accuracy: 0.00001)
            }
        }
    }

    func testSuperOpacityPersistsAndReachesHistoryAndLiveStyles() async throws {
        let standard = ChartIndicatorParameters.standard
        let parameters = try XCTUnwrap(ChartIndicatorParameters(emaPeriods: standard.emaPeriods,
            superTrendATRPeriod: standard.superTrendATRPeriod, superTrendMultiplier: standard.superTrendMultiplier,
            volumeFastPeriod: standard.volumeFastPeriod, volumeSlowPeriod: standard.volumeSlowPeriod,
            macdFastPeriod: standard.macdFastPeriod, macdSlowPeriod: standard.macdSlowPeriod,
            macdSignalPeriod: standard.macdSignalPeriod, superTrendFillAlpha: 0.35))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SuperOpacity.\(UUID().uuidString)"))
        let store = ChartIndicatorParametersStore(defaults: defaults, key: "test")
        defer { defaults.removeObject(forKey: "test") }
        store.save(parameters)
        XCTAssertEqual(store.load(), parameters)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "test"))) as? [String: Any])
        old["schemaVersion"] = 4; old.removeValue(forKey: "superTrendFillAlpha")
        defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: "test")
        XCTAssertEqual(store.load().superTrendFillAlpha, 0.16, accuracy: 0.0001)
        let fixture = try await makeChartSceneFixture()
        let update = await fixture.pipeline.updateIndicatorConfiguration(selection: .standard, parameters: parameters, revision: 2)
        let frame = try XCTUnwrap(update?.frame)
        let styles = frame.indicators.history.series.filter { $0.key.instanceID.hasPrefix("supertrend.") }
        XCTAssertEqual(styles.count, 2)
        for style in styles { XCTAssertEqual(style.figureStyle, .lineWithCandleCloseBand(fillAlpha: 0.35)) }
    }

    func testMetalPanPreservesHollowMACDAndContinuousSuperFill() throws {
        let renderer = try MetalRenderer(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            pixelFormat: .bgra8Unorm_srgb)
        let bars: [ChartBarInstance] = [
            .init(left: 20, top: 10, right: 40, bottom: 12, color: .positive),
            .init(left: 20, top: 28, right: 40, bottom: 30, color: .positive),
            .init(left: 20, top: 12, right: 22, bottom: 28, color: .positive),
            .init(left: 38, top: 12, right: 40, bottom: 28, color: .positive),
            .init(left: 60, top: 40, right: 80, bottom: 60, color: .positive.withAlpha(0.2)),
            .init(left: 80, top: 40, right: 100, bottom: 60, color: .positive.withAlpha(0.2)),
        ]
        for appearance in [ChartAppearance.light, .dark] {
            let scene = StaticSceneSnapshot(revision: 1, candleHistory: ChartCandleHistory(candles: []),
                batches: [ChartRenderBatch(barInstances: bars)],
                horizontalPlotBounds: ChartHorizontalPlotBounds(left: 0, right: 160))
            func state(_ moving: Bool) -> RenderState {
                RenderState(staticScene: scene,
                    liveTail: LiveTailSnapshot(revision: 1, candle: nil, batches: [], latestPrice: nil),
                    interaction: InteractionSnapshot(revision: moving ? 2 : 1,
                        translationX: moving ? 8 : 0, scaleX: 1,
                        candleHalfBodyWidthPixels: moving ? 5 : 0, crosshair: nil),
                    invalidation: .full, appearance: appearance)
            }
            let idle = try XCTUnwrap(renderer.renderOffscreen(state: state(false), width: 160, height: 80))
            let moving = try XCTUnwrap(renderer.renderOffscreen(state: state(true), width: 160, height: 80))
            // Compare every pixel after a pure pan, including the hollow center and band seams.
            var changed = 0
            for y in 0..<80 {
                for x in 0..<140 {
                    let a = y * idle.bytesPerRow + x * 4
                    let b = y * moving.bytesPerRow + (x + 8) * 4
                    if idle.bgra8UnormSRGB[a..<a+4] != moving.bgra8UnormSRGB[b..<b+4] { changed += 1 }
                }
            }
            XCTAssertEqual(changed, 0, "Pan must preserve rectangle coverage in \(appearance)")
        }
    }

    func testChartColorLinearizesSRGBForMetalTarget() throws {
        let positive = ChartColor.positive.linearRGBA
        XCTAssertEqual(positive.x, 0.021_219, accuracy: 0.000_001)
        XCTAssertEqual(positive.y, 0.371_238, accuracy: 0.000_001)
        XCTAssertEqual(positive.z, 0.171_441, accuracy: 0.000_001)
        XCTAssertEqual(positive.w, 1, accuracy: 0.000_001)

        XCTAssertEqual(ChartColor.positive.red, 40.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(ChartColor.positive.green, 164.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(ChartColor.positive.blue, 115.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(ChartColor.negative.red, 246.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(ChartColor.negative.green, 60.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(ChartColor.negative.blue, 85.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(ChartColor.ema55.red, 232.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(ChartColor.ema144.blue, 196.0 / 255.0, accuracy: 0.000_001)

        let translucent = try XCTUnwrap(ChartColor(
            red: 0.5,
            green: 0.04045,
            blue: 0,
            alpha: 0.82
        ))
        XCTAssertEqual(translucent.linearRGBA.x, 0.214_041, accuracy: 0.000_001)
        XCTAssertEqual(translucent.linearRGBA.y, 0.003_131, accuracy: 0.000_001)
        XCTAssertEqual(translucent.linearRGBA.z, 0, accuracy: 0.000_001)
        XCTAssertEqual(translucent.linearRGBA.w, 0.82, accuracy: 0.000_001)
    }

    func testVolumeIncrementalAveragesAndProvisionalBranch()
        throws {
        var calculator = try XCTUnwrap(
            VolumeIndicatorCalculator(
                fastPeriod: 2,
                slowPeriod: 3,
                intervalMilliseconds: 3_600_000
            )
        )
        let first = calculator.commit(candle(
            openTime: 0,
            closePrice: 10,
            volume: 3,
            closure: .closed
        ))
        let second = calculator.commit(candle(
            openTime: 3_600_000,
            closePrice: 11,
            volume: 6,
            closure: .closed
        ))
        let third = calculator.commit(candle(
            openTime: 7_200_000,
            closePrice: 12,
            volume: 9,
            closure: .closed
        ))

        XCTAssertEqual(first.volumeValidity, .valid)
        XCTAssertEqual(first.fastAverageValidity, .warmup)
        XCTAssertEqual(
            second.fastAverage ?? .nan,
            4.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            third.slowAverage ?? .nan,
            6,
            accuracy: 0.000_001
        )

        let committedBeforeLive = calculator.committed
        let liveCandle = candle(
            openTime: 10_800_000,
            closePrice: 13,
            volume: 12,
            closure: .provisional
        )
        let provisional = try XCTUnwrap(
            calculator.provisional(liveCandle)
        )
        XCTAssertEqual(
            provisional.fastAverage ?? .nan,
            10.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            provisional.slowAverage ?? .nan,
            9,
            accuracy: 0.000_001
        )
        XCTAssertEqual(calculator.committed, committedBeforeLive)
        XCTAssertEqual(
            calculator.commit(liveCandle.withClosure(.closed)),
            provisional
        )
    }

    func testRSIWilderSeedProvisionalAndGapReset() throws {
        var calculator = try XCTUnwrap(
            RSIIndicatorCalculator(
                period: 3,
                intervalMilliseconds: 3_600_000
            )
        )
        let closes = [1.0, 2.0, 3.0, 2.0]
        var points: [IndicatorPoint] = []
        for (index, close) in closes.enumerated() {
            points.append(calculator.commit(candle(
                openTime: Int64(index) * 3_600_000,
                closePrice: close,
                closure: .closed
            )))
        }

        XCTAssertEqual(
            points.prefix(3).map(\.validity),
            [.warmup, .warmup, .warmup]
        )
        XCTAssertEqual(points[3].validity, .valid)
        XCTAssertEqual(
            points[3].value ?? .nan,
            66.666_666,
            accuracy: 0.000_001
        )

        let committed = calculator.committed
        let provisional = try XCTUnwrap(calculator.provisional(candle(
            openTime: 4 * 3_600_000,
            closePrice: 4,
            closure: .provisional
        )))
        XCTAssertEqual(provisional.validity, .valid)
        XCTAssertEqual(
            provisional.value ?? .nan,
            83.333_333,
            accuracy: 0.000_001
        )
        XCTAssertEqual(calculator.committed, committed)

        let gap = calculator.commit(candle(
            openTime: 6 * 3_600_000,
            closePrice: 5,
            closure: .closed
        ))
        XCTAssertEqual(gap.validity, .dataGap)
        XCTAssertNil(gap.value)
        XCTAssertEqual(calculator.committed.changeCount, 0)
        XCTAssertEqual(calculator.committed.previousClose, 5)
    }

    func testMACDMatchesSeededEMAAndKeepsLiveStateProvisional()
        throws {
        var calculator = try XCTUnwrap(
            MACDIndicatorCalculator(
                fastPeriod: 2,
                slowPeriod: 3,
                signalPeriod: 2,
                intervalMilliseconds: 3_600_000
            )
        )
        let closes = [1.0, 2, 4, 8]
        var points: [MACDIndicatorPoint] = []
        for (index, close) in closes.enumerated() {
            points.append(calculator.commit(candle(
                openTime: Int64(index) * 3_600_000,
                closePrice: close,
                closure: .closed
            )))
        }

        XCTAssertEqual(points[0].difValidity, .warmup)
        XCTAssertEqual(points[2].difValidity, .valid)
        XCTAssertEqual(points[2].deaValidity, .warmup)
        XCTAssertEqual(points[3].deaValidity, .valid)
        XCTAssertEqual(
            points[3].dif ?? .nan,
            1.222_222_222_2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            points[3].dea ?? .nan,
            1.027_777_777_8,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            points[3].histogram ?? .nan,
            0.388_888_888_9,
            accuracy: 0.000_001
        )

        let committedOpenTime = calculator.lastCommittedOpenTime
        let liveCandle = candle(
            openTime: 4 * 3_600_000,
            closePrice: 16,
            closure: .provisional
        )
        let provisional = try XCTUnwrap(
            calculator.provisional(liveCandle)
        )
        XCTAssertEqual(
            calculator.provisional(liveCandle),
            provisional
        )
        XCTAssertEqual(
            calculator.lastCommittedOpenTime,
            committedOpenTime
        )
        XCTAssertEqual(
            calculator.commit(liveCandle.withClosure(.closed)),
            provisional
        )
    }

    func testMACDGapRestartsAllRecursiveState()
        throws {
        var calculator = try XCTUnwrap(
            MACDIndicatorCalculator(
                fastPeriod: 2,
                slowPeriod: 3,
                signalPeriod: 2,
                intervalMilliseconds: 3_600_000
            )
        )
        _ = calculator.commit(candle(
            openTime: 0,
            closePrice: 1,
            closure: .closed
        ))
        let gap = calculator.commit(candle(
            openTime: 7_200_000,
            closePrice: 3,
            closure: .closed
        ))

        XCTAssertEqual(gap.difValidity, .dataGap)
        XCTAssertEqual(gap.deaValidity, .dataGap)
        XCTAssertEqual(gap.histogramValidity, .dataGap)
        XCTAssertEqual(calculator.lastCommittedOpenTime, 7_200_000)
        XCTAssertEqual(
            calculator.provisional(candle(
                openTime: 10_800_000,
                closePrice: 4,
                closure: .provisional
            ))?.difValidity,
            .warmup
        )
    }

    func testMACDSignalSeedOverflowDoesNotPoisonCommittedState()
        throws {
        var calculator = try XCTUnwrap(
            MACDIndicatorCalculator(
                fastPeriod: 1,
                slowPeriod: 500,
                signalPeriod: 2,
                intervalMilliseconds: 3_600_000
            )
        )
        for index in 0..<499 {
            let point = calculator.commit(extremeCandle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 0
            ))
            XCTAssertNotEqual(point.difValidity, .invalid)
        }
        let firstDIF = calculator.commit(extremeCandle(
            openTime: 499 * 3_600_000,
            closePrice: .greatestFiniteMagnitude
        ))
        XCTAssertEqual(firstDIF.difValidity, .valid)
        XCTAssertEqual(firstDIF.deaValidity, .warmup)

        let committedOpenTime = calculator.lastCommittedOpenTime
        let overflow = calculator.commit(extremeCandle(
            openTime: 500 * 3_600_000,
            closePrice: .greatestFiniteMagnitude
        ))
        XCTAssertEqual(overflow.difValidity, .invalid)
        XCTAssertEqual(overflow.deaValidity, .invalid)
        XCTAssertEqual(
            calculator.lastCommittedOpenTime,
            committedOpenTime
        )
    }

    func testIndicatorEngineAcceptsNewPluginWithoutCoreChanges()
        throws {
        let registry = try XCTUnwrap(ChartIndicatorRegistry([
            TestConstantIndicatorPlugin()
        ]))
        let configuration = try XCTUnwrap(
            ChartIndicatorInstanceConfiguration(
                instanceID: "test.constant.42",
                pluginID: "test.constant",
                parameters: ["value": 42],
                legendLabel: "TEST:",
                legendRow: 0,
                legendOrder: 0
            )
        )
        var engine = try XCTUnwrap(ChartIndicatorEngine(
            registry: registry,
            configurations: [configuration],
            intervalMilliseconds: 3_600_000,
            historyLimit: 100
        ))

        let health = engine.installHistory([
            candle(
                openTime: 0,
                closePrice: 100,
                closure: .closed
            ),
            candle(
                openTime: 3_600_000,
                closePrice: 101,
                closure: .closed
            ),
        ])
        let snapshot = engine.snapshot(provisional: nil)

        XCTAssertFalse(health.requiresRecovery)
        XCTAssertEqual(snapshot.history.series.count, 1)
        XCTAssertEqual(
            snapshot.history.series[0].points.compactMap(\.value),
            [42, 42]
        )
        XCTAssertEqual(snapshot.legends.count, 1)
        XCTAssertEqual(snapshot.legends[0].value, 42)
    }

    func testMetalFailurePolicyRebuildsTwiceThenStops() {
        var policy = MetalRendererFailurePolicy()

        XCTAssertEqual(policy.recordFailure(at: 100), .rebuild)
        XCTAssertEqual(policy.recordFailure(at: 110), .rebuild)
        XCTAssertEqual(policy.recordFailure(at: 120), .stop)
        XCTAssertEqual(policy.consecutiveFailureTimes.count, 3)
    }

    func testMetalFailurePolicySuccessAndWindowResetSequence() {
        var policy = MetalRendererFailurePolicy(
            failureWindow: 60,
            maximumConsecutiveFailures: 3
        )

        XCTAssertEqual(policy.recordFailure(at: 100), .rebuild)
        policy.recordSuccess()
        XCTAssertEqual(policy.recordFailure(at: 110), .rebuild)
        XCTAssertEqual(policy.recordFailure(at: 180), .rebuild)
        XCTAssertEqual(policy.consecutiveFailureTimes, [180])
    }

    @MainActor
    func testHostSimulatedFailuresRebuildTwiceThenStop()
        throws {
#if DEBUG
        try XCTSkipIf(
            MTLCreateSystemDefaultDevice() == nil,
            "Metal is unavailable in this test environment."
        )
        let host = KlineChartHostView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 300)
        )
        host.diagnosticInjectCommandFailure()
        host.diagnosticInjectCommandFailure()
        host.diagnosticInjectCommandFailure()

        let snapshot = host.diagnosticHealthSnapshot()
        XCTAssertEqual(snapshot.simulatedCommandBufferErrors, 3)
        XCTAssertEqual(snapshot.commandBufferErrors, 0)
        XCTAssertTrue(snapshot.recentCommandBufferFailures.isEmpty)
        XCTAssertEqual(snapshot.rendererRebuildAttempts, 2)
        XCTAssertEqual(snapshot.rendererRebuildSuccesses, 2)
        XCTAssertEqual(snapshot.rendererCircuitBreakerStops, 1)
        XCTAssertTrue(host.diagnosticIsRendererStopped)

        let submittedBeforeStop = snapshot.submittedFrames
        host.diagnosticDraw()
        XCTAssertEqual(
            host.diagnosticHealthSnapshot().submittedFrames,
            submittedBeforeStop
        )
        host.diagnosticDispose()
#endif
    }

    func testCommandBufferFailureSummariesAreBoundedAndOrdered() {
        let health = MetalRendererHealth()

        for index in 1...20 {
            health.recordSubmitted()
            health.recordCommandCompleted(
                succeeded: false,
                failure: MetalCommandBufferFailureSummary(
                    status: "error-\(index)",
                    errorDomain: "ChartTestDomain",
                    errorCode: index,
                    message: String(repeating: "x", count: 300)
                )
            )
        }

        let snapshot = health.snapshot()
        XCTAssertEqual(snapshot.submittedFrames, 20)
        XCTAssertEqual(snapshot.completedFrames, 20)
        XCTAssertEqual(snapshot.commandBufferErrors, 20)
        XCTAssertEqual(snapshot.currentInFlightFrames, 0)
        XCTAssertEqual(
            snapshot.recentCommandBufferFailures.count,
            16
        )
        XCTAssertEqual(
            snapshot.recentCommandBufferFailures.first?.status,
            "error-5"
        )
        XCTAssertEqual(
            snapshot.recentCommandBufferFailures.last?.status,
            "error-20"
        )
        XCTAssertEqual(
            snapshot.recentCommandBufferFailures.last?.errorCode,
            20
        )
        XCTAssertEqual(
            snapshot.recentCommandBufferFailures.last?.message?
                .count,
            240
        )
    }

    func testPresentationHealthRingIsFixedAndOrdered() {
        let health = MetalRendererHealth()
        for revision in UInt64(1)...300 {
            health.recordSubmitted()
            health.recordPresented(
                revision: revision,
                liveRevision: revision,
                liveReadyTime: Double(revision),
                presentedTime: Double(revision) + 0.01,
                readyTime: Double(revision),
                submittedTime: Double(revision) + 0.004
            )
            health.recordCommandCompleted(succeeded: true)
        }

        let snapshot = health.snapshot()
        XCTAssertEqual(snapshot.submittedFrames, 300)
        XCTAssertEqual(snapshot.completedFrames, 300)
        XCTAssertEqual(snapshot.currentInFlightFrames, 0)
        XCTAssertEqual(snapshot.peakInFlightFrames, 1)
        XCTAssertEqual(snapshot.recentPresentations.count, 256)
        XCTAssertEqual(
            snapshot.recentPresentations.first?.revision,
            45
        )
        XCTAssertEqual(
            snapshot.recentPresentations.last?.revision,
            300
        )
        XCTAssertEqual(
            snapshot.recentPresentations.last?
                .readyToPresentDuration ?? .nan,
            0.01,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapshot.recentPresentations.last?
                .readyToSubmitDuration ?? .nan,
            0.004,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapshot.recentPresentations.last?
                .submitToPresentDuration ?? .nan,
            0.006,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapshot.readyToSubmitLatency.sampleCount,
            300
        )
        XCTAssertEqual(
            snapshot.submitToPresentLatency.sampleCount,
            300
        )
        XCTAssertEqual(
            snapshot.livePresentationLatency.sampleCount,
            300
        )
        XCTAssertEqual(
            snapshot.liveReadyToSubmitLatency.sampleCount,
            300
        )
        XCTAssertEqual(
            snapshot.liveSubmitToPresentLatency.sampleCount,
            300
        )
    }

    func testDroppedPresentationDiagnosticsAreBoundedAndOrdered() {
        let health = MetalRendererHealth()
        health.recordRendererSuspend()
        health.recordRendererResume()
        health.updateHostPresentationContext(
            applicationActivity: .active,
            isAttachedToWindow: true,
            isHostVisible: true,
            isWindowVisible: true
        )
        health.updateRendererPresentationContext(
            isSuspended: false,
            isInteractionActive: true
        )

        for revision in UInt64(1)...20 {
            health.updateHostPresentationContext(
                applicationActivity: .active,
                isAttachedToWindow: true,
                isHostVisible: true,
                isWindowVisible: true
            )
            health.updateRendererPresentationContext(
                isSuspended: false,
                isInteractionActive: true
            )
            let submissionContext = health.recordSubmitted()
            health.updateHostPresentationContext(
                applicationActivity: .inactive,
                isAttachedToWindow: true,
                isHostVisible: true,
                isWindowVisible: true
            )
            health.updateRendererPresentationContext(
                isSuspended: true,
                isInteractionActive: false
            )
            health.recordPresented(
                revision: revision,
                liveRevision: revision + 100,
                liveReadyTime: Double(revision),
                presentedTime: 0,
                readyTime: Double(revision) + 0.001,
                submittedTime: Double(revision) + 0.004,
                submissionContext: submissionContext,
                callbackTime: Double(revision) + 0.010
            )
            health.recordCommandCompleted(succeeded: true)
        }

        let snapshot = health.snapshot()
        XCTAssertEqual(snapshot.submittedFrames, 20)
        XCTAssertEqual(snapshot.completedFrames, 20)
        XCTAssertEqual(snapshot.presentedFrames, 0)
        XCTAssertEqual(snapshot.droppedPresentations, 20)
        XCTAssertEqual(snapshot.currentInFlightFrames, 0)
        XCTAssertEqual(
            snapshot.recentDroppedPresentations.count,
            16
        )
        XCTAssertEqual(
            snapshot.recentDroppedPresentations.first?.revision,
            5
        )
        let last = snapshot.recentDroppedPresentations.last
        XCTAssertEqual(last?.revision, 20)
        XCTAssertEqual(last?.liveRevision, 120)
        XCTAssertEqual(last?.submittedFrames, 20)
        XCTAssertEqual(last?.completedFrames, 19)
        XCTAssertEqual(last?.currentInFlightFrames, 1)
        XCTAssertEqual(last?.rendererSuspends, 1)
        XCTAssertEqual(last?.rendererResumes, 1)
        XCTAssertEqual(
            last?.submissionContext.applicationActivity,
            .active
        )
        XCTAssertEqual(
            last?.callbackContext.applicationActivity,
            .inactive
        )
        XCTAssertEqual(
            last?.callbackContext.isHostAttachedToWindow,
            true
        )
        XCTAssertEqual(last?.callbackContext.isHostVisible, true)
        XCTAssertEqual(last?.callbackContext.isWindowVisible, true)
        XCTAssertEqual(
            last?.submissionContext.isRendererSuspended,
            false
        )
        XCTAssertEqual(
            last?.callbackContext.isRendererSuspended,
            true
        )
        XCTAssertEqual(
            last?.submissionContext.isInteractionActive,
            true
        )
        XCTAssertEqual(
            last?.callbackContext.isInteractionActive,
            false
        )
        XCTAssertEqual(
            last?.submitToCallbackDuration ?? .nan,
            0.006,
            accuracy: 0.000_001
        )
    }

    func testHistoryPrependPreservesTailAndRebuildsAllPanels() async {
        let epoch = KlineStreamEpoch(generation: 31)
        let selection = ChartIndicatorSelection(activeIndicatorsInOrder: [
            .ema, .superTrend, .volume, .macd, .rsi,
        ])!
        let pipeline = ChartDataPipeline(
            stream: stream,
            intervalMilliseconds: 3_600_000,
            epoch: epoch,
            indicatorSelection: selection,
            historyLimit: 10
        )!
        let initial = (3...6).map {
            marketCandle(
                openTime: Int64($0) * 3_600_000,
                closePrice: 100 + Double($0)
            )
        }
        let installed = await pipeline.installSnapshot(
            initial,
            fetchedAtMilliseconds: 100_000_000,
            epoch: epoch
        )
        let older = (1...3).map {
            marketCandle(
                openTime: Int64($0) * 3_600_000,
                closePrice: 100 + Double($0)
            )
        }
        let prepended = await pipeline.prependHistory(
            older,
            epoch: epoch
        )

        XCTAssertEqual(
            installed.frame?.candles.history.candles.map(\.openTime),
            initial.map(\.openTime)
        )
        XCTAssertEqual(
            prepended.frame?.candles.history.candles.map(\.openTime),
            (1...6).map { Int64($0) * 3_600_000 }
        )
        let panelIDs: [String] = prepended.frame.map { frame in
            frame.indicators.history.series.compactMap {
                if case let .panel(panelID) = $0.placement {
                    return panelID
                }
                return nil
            }
        } ?? []
        let panels = Set(panelIDs)
        XCTAssertTrue(panels.contains(ChartPanelID.volume))
        XCTAssertTrue(panels.contains(ChartPanelID.macd))
        XCTAssertTrue(panels.contains(ChartPanelID.rsi))
    }

    func testHistoryPaginationPolicyDistinguishesPrependFromAppend() {
        XCTAssertEqual(
            KlineChartSceneController.appendedSlotCount(
                previousNewestOpenTime: 7_200_000,
                newestOpenTime: 7_200_000,
                previousTotalSlotCount: 3,
                totalSlotCount: 6
            ),
            0
        )
        XCTAssertEqual(
            KlineChartSceneController.appendedSlotCount(
                previousNewestOpenTime: 7_200_000,
                newestOpenTime: 10_800_000,
                previousTotalSlotCount: 6,
                totalSlotCount: 6
            ),
            1
        )
        let nearOldest = ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: 1_430
        )!
        let latest = ChartTimelineViewport(
            visibleSlotCount: 60,
            trailingOffsetSlots: 0
        )!
        XCTAssertTrue(
            KlineChartSceneController.shouldRequestOlderHistory(
                viewport: nearOldest,
                totalSlotCount: 1_500
            )
        )
        XCTAssertFalse(
            KlineChartSceneController.shouldRequestOlderHistory(
                viewport: latest,
                totalSlotCount: 1_500
            )
        )
    }

    @MainActor
    func testSceneControllerCoalescesRapidPriceViewportRenders()
        async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(
            widthPoints: 390,
            heightPoints: 396,
            displayScale: 3
        ))
        let controller = KlineChartSceneController()

        controller.requestRender(
            frame: fixture.frame,
            viewport: viewport,
            proposedTimelineViewport: nil,
            proposedPriceViewport: .automatic
        )
        await controller.diagnosticWaitForRenderIdle()
        let baselineProjection = try XCTUnwrap(
            controller.priceProjection
        )
        let baselineSpan = baselineProjection.upperBound
            - baselineProjection.lowerBound

        for step in 1...24 {
            let magnification = 1 + Double(step) / 24
            let priceViewport = try XCTUnwrap(ChartPriceViewport(
                magnification: magnification
            ))
            controller.updatePriceViewport(priceViewport)
            controller.requestRender(
                frame: fixture.frame,
                viewport: viewport,
                proposedTimelineViewport: controller.timelineViewport,
                proposedPriceViewport: priceViewport
            )
        }
        await controller.diagnosticWaitForRenderIdle()

        let finalProjection = try XCTUnwrap(
            controller.priceProjection
        )
        XCTAssertEqual(controller.priceViewport.magnification, 2)
        XCTAssertEqual(
            controller.renderState?.staticScene.timelineViewport,
            controller.timelineViewport
        )
        XCTAssertEqual(
            finalProjection.upperBound - finalProjection.lowerBound,
            baselineSpan / 2,
            accuracy: baselineSpan * 0.000_001
        )
    }

    @MainActor
    func testTimelinePinchUpdatesPriceAndMACDDuringGestureAndCoalescesFrames() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
        let baseline = try XCTUnwrap(ChartTimelineViewport(visibleSlotCount: 20, trailingOffsetSlots: 20))
        let builder = ChartSceneBuilder()
        let initial = try await builder.build(frame: fixture.frame, viewport: viewport, timelineViewport: baseline)
        let host = KlineChartHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        defer { host.dispose() }
        var requested: [ChartTimelineViewport] = []
        host.configureTimelineInteraction(viewport: baseline, totalSlotCount: 221) { requested.append($0) }
        host.submit(initial.renderState)
        let gesture = ContinuousScaleTestPinch()
        gesture.phase = .began
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: gesture)
        gesture.phase = .changed
        gesture.scale = 0.5
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: gesture)
        XCTAssertTrue(requested.isEmpty, "Gesture callbacks must wait for the display frame")
        host.diagnosticInteractionFrame(at: 10)
        XCTAssertEqual(requested.count, 1, "Vertical fitting must start before the fingers lift")
        guard let first = requested.first else { return }

        gesture.scale = 0.4
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: gesture)
        gesture.scale = 0.3
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: gesture)
        host.diagnosticInteractionFrame(at: 10.016)
        XCTAssertEqual(requested.count, 1, "Keep only the latest viewport while a scene is in flight")
        let fitted = try await builder.build(frame: fixture.frame, viewport: viewport, timelineViewport: first)
        XCTAssertNotEqual(fitted.priceLowerBound, initial.priceLowerBound)
        XCTAssertNotEqual(fitted.renderState.staticScene.crosshairData?.panelDomains[ChartPanelID.macd],
                          initial.renderState.staticScene.crosshairData?.panelDomains[ChartPanelID.macd])
        XCTAssertEqual(fitted.renderState.staticScene.crosshairData?.priceDomain.lower, fitted.priceLowerBound)
        host.submit(fitted.renderState)
        host.diagnosticInteractionFrame(at: 10.033)
        XCTAssertEqual(requested.count, 2)
        XCTAssertEqual(requested.last, baseline.pinched(scale: 0.3, anchorFraction: 0.5, totalSlotCount: 221),
                       "Receiving a fitted scene must preserve the original finger anchor")
        gesture.phase = .ended
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: gesture)
    }

    @MainActor
    func testTimelinePinchReturningToStartSupersedesPendingScene() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
        let baseline = try XCTUnwrap(ChartTimelineViewport(visibleSlotCount: 40, trailingOffsetSlots: 30))
        let builder = ChartSceneBuilder()
        let initial = try await builder.build(frame: fixture.frame, viewport: viewport, timelineViewport: baseline)
        let host = KlineChartHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        defer { host.dispose() }
        var requested: [ChartTimelineViewport] = []
        host.configureTimelineInteraction(viewport: baseline, totalSlotCount: 221) { requested.append($0) }
        host.submit(initial.renderState)
        let gesture = ContinuousScaleTestPinch()
        gesture.phase = .began
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: gesture)
        gesture.phase = .changed
        gesture.scale = 0.7
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: gesture)
        host.diagnosticInteractionFrame(at: 10)
        XCTAssertEqual(requested.count, 1)
        gesture.scale = 1
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: gesture)
        gesture.phase = .ended
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: gesture)
        XCTAssertEqual(requested.last, baseline, "The final viewport must supersede a scene still being prepared, even after returning to the starting position")
    }

    @MainActor
    func testCrosshairCanBecomePanWithoutAnExtraTap() async throws {
        for sameContact in [false, true] {
            let fixture = try await makeChartSceneFixture()
            let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
            let baseline = try XCTUnwrap(ChartTimelineViewport(visibleSlotCount: 40, trailingOffsetSlots: 30))
            let scene = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport,
                timelineViewport: baseline)
            let host = KlineChartHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
            defer { host.dispose() }
            var requested: [ChartTimelineViewport] = []
            host.configureTimelineInteraction(viewport: baseline, totalSlotCount: 221) { requested.append($0) }
            host.submit(scene.renderState)
            var dismissed = false
            host.onCrosshairDismiss = { dismissed = true }
            let press = ContinuousScaleTestLongPress()
            press.phase = .began
            host.perform(NSSelectorFromString("handleCrosshair:"), with: press)
            if sameContact {
                press.phase = .changed
                press.point.x += 60
                host.perform(NSSelectorFromString("handleCrosshair:"), with: press)
            } else {
                press.phase = .ended
                host.perform(NSSelectorFromString("handleCrosshair:"), with: press)
                let pan = ContinuousScaleTestPan()
                pan.phase = .began
                host.perform(NSSelectorFromString("handleTimelinePan:"), with: pan)
                pan.phase = .changed; pan.translationX = 60
                host.perform(NSSelectorFromString("handleTimelinePan:"), with: pan)
            }
            host.diagnosticInteractionFrame(at: 10)
            await Task.yield()
            if sameContact {
                XCTAssertFalse(dismissed, "The creating long press must keep tracking the crosshair")
                XCTAssertTrue(requested.isEmpty, "Moving the creating contact must not pan the timeline")
            } else {
                XCTAssertTrue(dismissed, "A new drag must dismiss the retained crosshair")
                XCTAssertNotEqual(try XCTUnwrap(requested.last), baseline)
            }
        }
    }

    @MainActor
    func testPinchDismissesActiveAndRetainedCrosshairWithoutAnotherTap() async throws {
        for keepsCreatingContact in [false, true] {
            let fixture = try await makeChartSceneFixture()
            let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
            let baseline = try XCTUnwrap(ChartTimelineViewport(visibleSlotCount: 40, trailingOffsetSlots: 30))
            let scene = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport,
                timelineViewport: baseline)
            let host = KlineChartHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
            defer { host.dispose() }
            var requested: [ChartTimelineViewport] = []
            host.configureTimelineInteraction(viewport: baseline, totalSlotCount: 221) { requested.append($0) }
            host.submit(scene.renderState)
            var dismissed = false
            host.onCrosshairDismiss = { dismissed = true }
            let press = ContinuousScaleTestLongPress()
            press.phase = .began
            host.perform(NSSelectorFromString("handleCrosshair:"), with: press)
            if !keepsCreatingContact {
                press.phase = .ended
                host.perform(NSSelectorFromString("handleCrosshair:"), with: press)
            }
            let nativePinch = try XCTUnwrap(host.gestureRecognizers?.compactMap { $0 as? UIPinchGestureRecognizer }.first)
            let nativePress = try XCTUnwrap(host.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first)
            XCTAssertTrue(host.gestureRecognizerShouldBegin(nativePinch), "Cursor tracking must allow a second finger to start pinch")
            XCTAssertTrue(host.gestureRecognizer(nativePinch, shouldRecognizeSimultaneouslyWith: nativePress))
            let pinch = ContinuousScaleTestPinch()
            pinch.phase = .began
            host.perform(NSSelectorFromString("handleTimelinePinch:"), with: pinch)
            // UIKit can deliver the cancelled long press after the pinch starts.
            // It must not restore the cursor or reset the zoom state.
            press.phase = .cancelled
            host.perform(NSSelectorFromString("handleCrosshair:"), with: press)
            pinch.phase = .changed
            pinch.scale = 1.25
            host.perform(NSSelectorFromString("handleTimelinePinch:"), with: pinch)
            host.diagnosticInteractionFrame(at: 10)
            await Task.yield()
            XCTAssertTrue(dismissed, "Pinch must dismiss the active or retained cursor immediately")
            XCTAssertLessThan(try XCTUnwrap(requested.last).visibleSlotCount, baseline.visibleSlotCount,
                "The same pinch must zoom rather than requiring another gesture")
            pinch.phase = .ended
            host.perform(NSSelectorFromString("handleTimelinePinch:"), with: pinch)
        }
    }

    @MainActor
    func testTimelinePanPreservesTranslationAndCommitsLatestAfterCancel() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
        let baseline = try XCTUnwrap(ChartTimelineViewport(visibleSlotCount: 40, trailingOffsetSlots: 30))
        let builder = ChartSceneBuilder()
        let initial = try await builder.build(frame: fixture.frame, viewport: viewport, timelineViewport: baseline)
        let host = KlineChartHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        defer { host.dispose() }
        var requested: [ChartTimelineViewport] = []
        host.configureTimelineInteraction(viewport: baseline, totalSlotCount: 221) { requested.append($0) }
        host.submit(initial.renderState)
        let gesture = ContinuousScaleTestPan()
        gesture.phase = .began
        host.perform(NSSelectorFromString("handleTimelinePan:"), with: gesture)
        gesture.phase = .changed
        gesture.translationX = 60
        host.perform(NSSelectorFromString("handleTimelinePan:"), with: gesture)
        host.diagnosticInteractionFrame(at: 10)
        let first = try XCTUnwrap(requested.first)
        let fitted = try await builder.build(frame: fixture.frame, viewport: viewport, timelineViewport: first)
        host.submit(fitted.renderState)
        gesture.translationX = 90
        host.perform(NSSelectorFromString("handleTimelinePan:"), with: gesture)
        host.diagnosticInteractionFrame(at: 10.016)
        let final = baseline.panned(translationPoints: 90, plotWidthPoints: 328, totalSlotCount: 221)
        XCTAssertEqual(requested.count, 2)
        XCTAssertEqual(requested.last, final, "Cumulative translation must still use the original gesture baseline")

        gesture.phase = .cancelled
        host.perform(NSSelectorFromString("handleTimelinePan:"), with: gesture)
        XCTAssertEqual(requested.last, final)
        let countAfterCancel = requested.count
        host.diagnosticInteractionFrame(at: 10.033)
        XCTAssertEqual(requested.count, countAfterCancel, "Cancellation must stop continuous fitting")
        let committed = try await builder.build(frame: fixture.frame, viewport: viewport, timelineViewport: final)
        host.submit(committed.renderState)
        host.diagnosticInteractionFrame(at: 10.05)
        XCTAssertEqual(requested.count, countAfterCancel)
    }

    @MainActor
    func testTimelineInertiaContinuesWhileSceneIsPendingAndAfterRebase() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
        let baseline = try XCTUnwrap(ChartTimelineViewport(visibleSlotCount: 40, trailingOffsetSlots: 30))
        let builder = ChartSceneBuilder()
        let initial = try await builder.build(frame: fixture.frame, viewport: viewport, timelineViewport: baseline)
        let host = KlineChartHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        defer { host.dispose() }
        var requested: [ChartTimelineViewport] = []
        host.configureTimelineInteraction(viewport: baseline, totalSlotCount: 221) { requested.append($0) }
        host.submit(initial.renderState)
        let gesture = ContinuousScaleTestPan()
        gesture.phase = .began
        host.perform(NSSelectorFromString("handleTimelinePan:"), with: gesture)
        gesture.phase = .ended
        gesture.velocityX = 900
        host.perform(NSSelectorFromString("handleTimelinePan:"), with: gesture)
        var motion = ChartTimelineMotion()
        XCTAssertTrue(motion.begin(velocityPointsPerSecond: 900, boundaryTranslationPoints: 0))
        host.diagnosticInteractionFrame(at: 20)
        host.diagnosticInteractionFrame(at: 20.016)
        let first = try XCTUnwrap(requested.first)
        var expected = motion.advance(from: baseline, deltaTimeSeconds: 0.016, plotWidthPoints: 328, totalSlotCount: 221).viewport
        XCTAssertEqual(first.trailingOffsetSlots, expected.trailingOffsetSlots, accuracy: 0.000_001)
        host.diagnosticInteractionFrame(at: 20.032)
        expected = motion.advance(from: expected, deltaTimeSeconds: 0.016, plotWidthPoints: 328, totalSlotCount: 221).viewport
        XCTAssertEqual(requested.count, 1, "In-flight work must not queue another scene")
        let fitted = try await builder.build(frame: fixture.frame, viewport: viewport, timelineViewport: first)
        host.submit(fitted.renderState)
        host.diagnosticInteractionFrame(at: 20.048)
        expected = motion.advance(from: expected, deltaTimeSeconds: 0.016, plotWidthPoints: 328, totalSlotCount: 221).viewport
        XCTAssertEqual(requested.count, 2)
        XCTAssertEqual(try XCTUnwrap(requested.last).trailingOffsetSlots, expected.trailingOffsetSlots, accuracy: 0.000_001,
                       "Fitting must preserve both the motion clock and movement made while awaiting the scene")
    }

    @MainActor
    func testTimelineFastPinchCoalescesGuardBandRebaseAndPreservesAnchor() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
        let baseline = try XCTUnwrap(ChartTimelineViewport(visibleSlotCount: 20, trailingOffsetSlots: 40))
        let builder = ChartSceneBuilder()
        let initial = try await builder.build(frame: fixture.frame, viewport: viewport, timelineViewport: baseline)
        let host = KlineChartHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        defer { host.dispose() }
        var requested: [ChartTimelineViewport] = []
        host.configureTimelineInteraction(viewport: baseline, totalSlotCount: 221) { requested.append($0) }
        host.submit(initial.renderState)
        let gesture = ContinuousScaleTestPinch()
        gesture.phase = .began
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: gesture)
        gesture.phase = .changed
        gesture.scale = 0.15
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: gesture)
        XCTAssertTrue(requested.isEmpty)
        host.diagnosticInteractionFrame(at: 30)
        let first = try XCTUnwrap(requested.first)
        XCTAssertFalse(first.isRenderable(from: baseline, guardBandSlotCount: 48))
        gesture.scale = 0.12
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: gesture)
        host.diagnosticInteractionFrame(at: 30.016)
        XCTAssertEqual(requested.count, 1)
        let fitted = try await builder.build(frame: fixture.frame, viewport: viewport, timelineViewport: first)
        host.submit(fitted.renderState)
        gesture.scale = 0.2
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: gesture)
        host.diagnosticInteractionFrame(at: 30.032)
        XCTAssertEqual(requested.count, 2)
        XCTAssertEqual(requested.last, baseline.pinched(scale: 0.2, anchorFraction: 0.5, totalSlotCount: 221))
        gesture.phase = .ended
        host.perform(NSSelectorFromString("handleTimelinePinch:"), with: gesture)
        let final = try XCTUnwrap(requested.last)
        let committed = try await builder.build(frame: fixture.frame, viewport: viewport, timelineViewport: final)
        host.submit(committed.renderState)
        let countAfterEnd = requested.count
        host.diagnosticInteractionFrame(at: 30.048)
        XCTAssertEqual(requested.count, countAfterEnd)
    }

    func testBinanceKlineLoadingAnimationUsesMeasuredGeometry() {
        XCTAssertEqual(BinanceKlineLoadingAnimation.barCount, 4)
        XCTAssertEqual(
            BinanceKlineLoadingAnimation.width,
            64 / 3,
            accuracy: 0.000_001
        )

        let heights = BinanceKlineLoadingAnimation.heights(
            elapsed: 0.17
        )
        XCTAssertEqual(heights.count, 4)
        XCTAssertTrue(heights.allSatisfy {
            $0 >= BinanceKlineLoadingAnimation.minimumHeight
                && $0 <= BinanceKlineLoadingAnimation.maximumHeight
        })
        XCTAssertGreaterThan(Set(heights).count, 1)
    }

    func testBinanceKlineLoadingAnimationRepeatsWithoutDrift() {
        let initial = BinanceKlineLoadingAnimation.heights(
            elapsed: 0.23
        )
        let repeated = BinanceKlineLoadingAnimation.heights(
            elapsed: 0.23
                + BinanceKlineLoadingAnimation.cycleDuration
        )
        XCTAssertEqual(initial.count, repeated.count)
        for (lhs, rhs) in zip(initial, repeated) {
            XCTAssertEqual(lhs, rhs, accuracy: 0.000_001)
        }
    }

    private func event(
        epoch: KlineStreamEpoch,
        sequence: Int64,
        openTime: Int64,
        closePrice: Double,
        closure: ChartCandleClosure
    ) -> KlineIngressEvent {
        KlineIngressEvent(
            epoch: epoch,
            stream: stream,
            sequence: sequence,
            eventTime: openTime + 1,
            candle: candle(
                openTime: openTime,
                closePrice: closePrice,
                closure: closure
            )
        )
    }

    private func candle(
        openTime: Int64,
        closePrice: Double,
        closure: ChartCandleClosure
    ) -> ChartCandle {
        ChartCandle(
            openTime: openTime,
            closeTime: openTime + 3_600_000 - 1,
            openPrice: closePrice - 0.5,
            highPrice: closePrice + 1,
            lowPrice: closePrice - 1,
            closePrice: closePrice,
            volume: 10,
            quoteVolume: 1_000,
            closure: closure
        )
    }

    private func candle(
        openTime: Int64,
        closePrice: Double,
        volume: Double,
        closure: ChartCandleClosure
    ) -> ChartCandle {
        ChartCandle(
            openTime: openTime,
            closeTime: openTime + 3_600_000 - 1,
            openPrice: closePrice - 0.5,
            highPrice: closePrice + 1,
            lowPrice: closePrice - 1,
            closePrice: closePrice,
            volume: volume,
            quoteVolume: closePrice * volume,
            closure: closure
        )
    }

    private func extremeCandle(
        openTime: Int64,
        closePrice: Double
    ) -> ChartCandle {
        ChartCandle(
            openTime: openTime,
            closeTime: openTime + 3_600_000 - 1,
            openPrice: closePrice,
            highPrice: closePrice,
            lowPrice: closePrice,
            closePrice: closePrice,
            volume: 0,
            quoteVolume: 0,
            closure: .closed
        )
    }

    private func marketCandle(
        openTime: Int64,
        closePrice: Double
    ) -> MarketCandle {
        MarketCandle(
            openTime: openTime,
            closeTime: openTime + 3_600_000 - 1,
            openPrice: closePrice - 0.5,
            highPrice: closePrice + 1,
            lowPrice: closePrice - 1,
            closePrice: closePrice,
            volume: 10,
            quoteVolume: closePrice * 10,
        )
    }

    private func realtimePayload(
        sequence: Int,
        openTime: Int64,
        closePrice: Double,
        closed: Bool
    ) -> RealtimeKlineEventPayload {
        RealtimeKlineEventPayload(
            symbol: stream.symbol,
            contractType: "PERPETUAL",
            interval: stream.interval,
            eventTime: openTime + Int64(sequence),
            openTime: openTime,
            closeTime: openTime + 3_600_000 - 1,
            openPrice: closePrice - 0.5,
            highPrice: closePrice + 1,
            lowPrice: closePrice - 1,
            closePrice: closePrice,
            volume: 10,
            quoteVolume: closePrice * 10,
            closed: closed
        )
    }

    /// The fixed right-axis marker accompanies a reference line spanning the full plot.
    private func assertPriceReferenceCoversPlot(
        _ lines: [ChartLineSegmentInstance], marker: ChartBarInstance,
        plotLeft: Float, plotRight: Float,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(lines.count, 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(marker.left, plotRight, file: file, line: line)
        let markerY = (marker.top + marker.bottom) / 2
        for segment in lines {
            XCTAssertEqual(segment.start.y, markerY, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(segment.end.y, markerY, accuracy: 0.001, file: file, line: line)
            let left = min(segment.start.x, segment.end.x)
            let right = max(segment.start.x, segment.end.x)
            XCTAssertEqual(left, plotLeft, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(right, plotRight, accuracy: 0.001, file: file, line: line)
        }
    }

    func testLatestPriceMarkerStaysOnRightAxisAcrossHistoryAndFutureScroll() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 396, displayScale: 3))
        for offset: Double in [-35, 0, 50, 150] {
            let timeline = try XCTUnwrap(ChartTimelineViewport(visibleSlotCount: 40, trailingOffsetSlots: offset))
            let output = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport,
                timelineViewport: timeline)
            let marker = try XCTUnwrap(output.renderState.liveTail.latestPriceMarker)
            XCTAssertGreaterThanOrEqual(marker.left, output.panelLayout.plotRight)
            XCTAssertEqual(marker.right, Float(viewport.widthPixels) - 3, accuracy: 0.01)
        }
    }

    func testMACDStrengthBarsAreSolidAndDecayBarsAreHollowForBothSigns() async throws {
        let fixture = try await makeChartSceneFixture()
        let values: [Double] = [1, 3, 2, -1, -4, -2]
        let points = fixture.frame.candles.history.candles.enumerated().map { index, candle in
            IndicatorPoint(openTime: candle.openTime, value: values[index % values.count], validity: .valid)
        }
        let key = ChartIndicatorSeriesKey(instanceID: "macd-test", outputID: "histogram")
        let series = ChartIndicatorSeriesHistory(key: key, points: points,
            placement: .panel(ChartPanelID.macd), yAxisPolicy: .automatic, colorToken: .neutral,
            lineWidthPoints: 1, autoscale: .included, figureStyle: .histogramFromZero(colorStrategy: .valueSign))
        // Last closed value is -1; a provisional -0.5 must also be hollow.
        let live = ChartIndicatorLivePoint(key: key, point: IndicatorPoint(
            openTime: fixture.frame.candles.liveTail!.openTime, value: -0.5, validity: .valid))
        let frame = ChartDataFrame(stream: fixture.frame.stream, epoch: fixture.frame.epoch,
            candles: fixture.frame.candles, indicators: ChartIndicatorSnapshot(
                history: ChartIndicatorHistorySnapshot(series: [series]), livePoints: [live], legends: []),
            recoveryRequest: nil, readyTime: fixture.frame.readyTime)
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 396, displayScale: 3))
        let output = try await ChartSceneBuilder().build(frame: frame, viewport: viewport)
        let batch = try XCTUnwrap(output.renderState.staticScene.batches.first { $0.coordinateSpace == .timeline })
        let candles = batch.storage.candleInstances
        let histogram = batch.storage.barInstances
        for candle in candles {
            let bars = histogram.filter { abs(($0.left + $0.right) / 2 - candle.x) < 0.001 }
            let timeline = try XCTUnwrap(output.renderState.staticScene.timelineViewport)
            let slotWidth = Double(output.panelLayout.plotRight - output.panelLayout.plotLeft) / timeline.visibleSlotCount
            let global = Int((220 + Double(candle.x - output.panelLayout.plotLeft) / slotWidth
                - timeline.visibleSlotCount + 0.5 - timeline.trailingOffsetSlots).rounded())
            // Identify interior coverage directly; a hollow candle has no bar covering its center.
            let all = histogram.filter { $0.left >= candle.x - candle.halfBodyWidth - 0.01 && $0.right <= candle.x + candle.halfBodyWidth + 0.01 }
            guard !all.isEmpty else { continue }
            let top = all.map(\.top).min()!, bottom = all.map(\.bottom).max()!
            let centerY = (top + bottom) / 2
            let coversCenter = all.contains { $0.left < candle.x && $0.right > candle.x && $0.top < centerY && $0.bottom > centerY }
            let expectedHollow = global > 0 && abs(values[global % 6]) < abs(values[(global - 1) % 6])
            XCTAssertEqual(coversCenter, !expectedHollow)
            XCTAssertEqual(bars.count, expectedHollow ? 2 : 1)
            if expectedHollow, all.count == 4 {
                let sides = all.filter { $0.top > top && $0.bottom < bottom }.sorted { $0.left < $1.left }
                XCTAssertEqual(sides.count, 2)
                guard sides.count == 2 else { continue }
                let thickness = sides[0].right - sides[0].left
                XCTAssertEqual(thickness, sides[1].right - sides[1].left, accuracy: 0.0001)
                XCTAssertEqual(thickness, thickness.rounded(), accuracy: 0.0001,
                    "MACD borders must use whole physical pixels, including on 3x screens")
                if all.map(\.right).max()! - all.map(\.left).min()! >= 7 {
                    XCTAssertGreaterThanOrEqual(thickness, 3, "Use a 1pt border when there is room")
                }
                for translation: Float in [0, 0.25, 0.5, 0.75, 1.25] {
                    func coveredPixels(_ bar: ChartBarInstance) -> Int {
                        let lower = Int(floor(bar.left + translation)) - 1
                        let upper = Int(ceil(bar.right + translation)) + 1
                        return (lower...upper).filter {
                            let x = Float($0) + 0.5
                            return x >= bar.left + translation && x < bar.right + translation
                        }.count
                    }
                    XCTAssertEqual(coveredPixels(sides[0]), coveredPixels(sides[1]),
                        "Both sides must cover the same number of pixels during fractional pans")
                }
            }
        }
        let liveBars = try XCTUnwrap(output.renderState.liveTail.batches.first { $0.coordinateSpace == .timeline }).storage.barInstances
        XCTAssertEqual(liveBars.count, 4)
    }

    @MainActor
    func testSwiftUIIntervalLoadingRetainsTheMetalHostAndRenderer() async throws {
        let fixture = try await makeChartSceneFixture()
        let initializationBaseline = KlineChartHostView.diagnosticInitializationCount
        let initialStarted = ProcessInfo.processInfo.systemUptime
        let model = ChartHostedReuseFixtureModel(frame: nil)
        let hosting = UIHostingController(rootView: ChartHostedReuseFixture(model: model))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.frame = window.bounds
        hosting.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        func findHost(_ view: UIView) -> KlineChartHostView? {
            if let host = view as? KlineChartHostView { return host }
            return view.subviews.lazy.compactMap(findHost).first
        }
        for _ in 0..<100 where findHost(hosting.view) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let original = try XCTUnwrap(findHost(hosting.view))
        XCTAssertTrue(original.diagnosticIsLoadingCovered, "The renderer can initialize while HTTP history is still unavailable")
        XCTAssertTrue(original.diagnosticIsRendererSuspended)
        model.frame = fixture.frame
        original.diagnosticSetApplicationActive(true)
        for _ in 0..<100 where model.presentations.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.presentations.first?.0, fixture.frame.epoch)
        if let initialTime = model.presentations.first?.1 {
            print("chart_host_fixture initial_ui_to_gpu_ms=\((initialTime - initialStarted) * 1000)")
        }
        let originalIdentity = ObjectIdentifier(original)
        let rendererIdentity = try XCTUnwrap(original.diagnosticRendererIdentity)
        model.frame = nil
        try await Task.sleep(for: .milliseconds(100))
        let loadingHost = findHost(hosting.view)
        XCTAssertEqual(loadingHost.map(ObjectIdentifier.init), originalIdentity,
            "Loading another interval must retain the existing Metal host")
        XCTAssertFalse(loadingHost?.isUserInteractionEnabled ?? true,
            "The old interval must not remain interactive under the loading indicator")
        for generation in UInt64(78)...80 {
            let started = ProcessInfo.processInfo.systemUptime
            let epoch = KlineStreamEpoch(generation: generation)
            let stream = ChartStreamKey(symbol: fixture.frame.stream.symbol,
                interval: generation == 79 ? "5m" : "1h")
            model.frame = ChartDataFrame(stream: stream, epoch: epoch,
                candles: fixture.frame.candles, indicators: fixture.frame.indicators,
                recoveryRequest: nil, readyTime: started)
            for _ in 0..<100 where !model.presentations.contains(where: { $0.0 == epoch }) {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(model.presentations.last?.0, epoch)
            if let presented = model.presentations.last, presented.0 == epoch {
                print("chart_host_fixture generation=\(generation) state_to_gpu_ms=\((presented.1 - started) * 1000)")
            }
            XCTAssertEqual(original.diagnosticRendererIdentity, rendererIdentity)
        }
        let restored = try XCTUnwrap(findHost(hosting.view))
        XCTAssertEqual(ObjectIdentifier(restored), originalIdentity,
            "The new interval must reuse the same UIView and its renderer")
        XCTAssertFalse(original.diagnosticIsRendererStopped,
            "Interval loading must pause rather than dispose the renderer")
        XCTAssertEqual(KlineChartHostView.diagnosticInitializationCount - initializationBaseline, 1)
        XCTAssertEqual(model.presentations.count, 4, "Each submitted epoch presents once")
        print("chart_host_fixture host_constructions=\(KlineChartHostView.diagnosticInitializationCount - initializationBaseline) renderer_identity_retained=true")
    }

    func testFirstPresentationMatchesTheSubmittedStreamAndEpoch() async {
        let health = MetalRendererHealth()
        let firstID = ChartPresentationID(stream: stream, epoch: KlineStreamEpoch(generation: 1))
        let currentID = ChartPresentationID(stream: stream, epoch: KlineStreamEpoch(generation: 2))
        let anotherStream = ChartPresentationID(stream: ChartStreamKey(symbol: "ETHUSDT", interval: "5m"),
            epoch: currentID.epoch)
        let first = expectation(description: "Current epoch presentation only")
        health.observeFirstPresentation(for: currentID) { id, time in
            XCTAssertEqual(id, currentID)
            XCTAssertEqual(time, 20)
            XCTAssertGreaterThan(health.snapshot().presentedFrames, 0, "Observer runs outside the health lock")
            first.fulfill()
        }
        for (id, time) in [(firstID, 10.0), (anotherStream, 11.0), (currentID, 0.0),
                            (currentID, 20.0), (currentID, 21.0)] {
            health.recordPresented(revision: 1, liveRevision: 1, liveReadyTime: 1,
                presentedTime: time, readyTime: 1, submittedTime: 2, presentationID: id)
        }
        await fulfillment(of: [first], timeout: 1)
    }

    func testLivePresentationWatermarkFollowsCurrentStreamAndRejectsOldGPUCallbacks() {
        let health = MetalRendererHealth()
        let oldID = ChartPresentationID(stream: stream, epoch: KlineStreamEpoch(generation: 1))
        let newID = ChartPresentationID(stream: ChartStreamKey(symbol: "ETHUSDT", interval: "5m"),
            epoch: KlineStreamEpoch(generation: 2))
        func present(_ id: ChartPresentationID, _ liveRevision: UInt64) {
            health.recordPresented(revision: liveRevision, liveRevision: liveRevision,
                liveReadyTime: 1, presentedTime: 3, readyTime: 1, submittedTime: 2,
                presentationID: id)
        }
        health.observeFirstPresentation(for: oldID) { _, _ in }
        present(oldID, 100)
        XCTAssertEqual(health.snapshot().lastPresentedLiveRevision, 100)
        health.observeFirstPresentation(for: newID) { _, _ in }
        XCTAssertEqual(health.snapshot().lastPresentedLiveRevision, 0)
        present(newID, 1)
        XCTAssertEqual(health.snapshot().lastPresentedLiveRevision, 1)
        XCTAssertEqual(health.snapshot().livePresentationLatency.sampleCount, 2)
        present(oldID, 101)
        XCTAssertEqual(health.snapshot().lastPresentedLiveRevision, 1,
            "A late GPU callback must not change the new stream's watermark")
        XCTAssertEqual(health.snapshot().livePresentationLatency.sampleCount, 2)
        present(newID, 2)
        XCTAssertEqual(health.snapshot().lastPresentedLiveRevision, 2)
        XCTAssertEqual(health.snapshot().livePresentationLatency.sampleCount, 3)
    }

    @MainActor
    func testHostEpochSwitchClearsInteractionAndIgnoresQueuedOldPresentations() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
        let scene = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport)
        let timeline = try XCTUnwrap(ChartTimelineViewport(visibleSlotCount: 40, trailingOffsetSlots: 30))
        let host = KlineChartHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        defer { host.dispose() }
        let firstID = ChartPresentationID(stream: stream, epoch: fixture.frame.epoch)
        let nextID = ChartPresentationID(stream: stream, epoch: KlineStreamEpoch(generation: 78))
        var presentations: [ChartPresentationID] = []
        host.observeFirstPresentation(for: firstID) { id, _ in presentations.append(id) }
        host.configureTimelineInteraction(viewport: timeline, totalSlotCount: 221) { _ in }
        host.submit(scene.renderState)
        host.setLoadingPresentation(false)
        let gesture = ContinuousScaleTestPan()
        gesture.phase = .began
        host.perform(NSSelectorFromString("handleTimelinePan:"), with: gesture)
        gesture.phase = .changed
        gesture.translationX = 60
        host.perform(NSSelectorFromString("handleTimelinePan:"), with: gesture)
        host.diagnosticInteractionFrame(at: 10)
        XCTAssertTrue(host.diagnosticHasInteractionBaseline)
        // Replay an already completed GPU command whose MainActor delivery is still queued.
        host.diagnosticRecordPresentation(for: firstID, at: 10)
        host.observeFirstPresentation(for: nextID) { id, _ in presentations.append(id) }
        XCTAssertFalse(host.diagnosticHasInteractionBaseline)
        host.configureTimelineInteraction(viewport: timeline, totalSlotCount: 221) { _ in }
        host.submit(scene.renderState)
        host.setLoadingPresentation(false)
        // A live update may replace the callback, but cannot re-arm the epoch's observer.
        host.observeFirstPresentation(for: nextID) { id, _ in presentations.append(id) }
        host.diagnosticRecordPresentation(for: firstID, at: 11)
        host.diagnosticRecordPresentation(for: nextID, at: 20)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(presentations, [nextID])
        host.observeFirstPresentation(for: nextID) { id, _ in presentations.append(id) }
        host.diagnosticRecordPresentation(for: nextID, at: 21)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(presentations, [nextID])
        let tagged = scene.renderState.withPresentationID(nextID)
        XCTAssertEqual(tagged.withAppearance(.light).withAxisPriceLabels([]).presentationID, nextID)
        host.diagnosticSetApplicationActive(false)
        host.observeFirstPresentation(for: nil) { id, _ in presentations.append(id) }
        let resumedID = ChartPresentationID(stream: stream, epoch: KlineStreamEpoch(generation: 79))
        host.observeFirstPresentation(for: resumedID) { id, _ in presentations.append(id) }
        host.submit(scene.renderState)
        host.setLoadingPresentation(false)
        host.diagnosticSetApplicationActive(true)
        host.diagnosticRecordPresentation(for: nextID, at: 22)
        host.diagnosticRecordPresentation(for: resumedID, at: 30)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(presentations, [nextID, resumedID])
    }

    @MainActor
    func testHostStreamSwitchCancelsPinchInertiaAndCrosshair() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
        let scene = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport)
        let timeline = try XCTUnwrap(ChartTimelineViewport(visibleSlotCount: 40, trailingOffsetSlots: 30))
        let host = KlineChartHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        defer { host.dispose() }
        for mode in 0..<3 {
            host.observeFirstPresentation(for: ChartPresentationID(stream: stream,
                epoch: KlineStreamEpoch(generation: UInt64(mode * 2 + 1)))) { _, _ in }
            host.configureTimelineInteraction(viewport: timeline, totalSlotCount: 221) { _ in }
            host.submit(scene.renderState)
            host.setLoadingPresentation(false)
            if mode == 0 {
                let pinch = ContinuousScaleTestPinch()
                pinch.phase = .began
                host.perform(NSSelectorFromString("handleTimelinePinch:"), with: pinch)
                pinch.phase = .changed
                pinch.scale = 1.3
                host.perform(NSSelectorFromString("handleTimelinePinch:"), with: pinch)
            } else if mode == 1 {
                let pan = ContinuousScaleTestPan()
                pan.phase = .began
                host.perform(NSSelectorFromString("handleTimelinePan:"), with: pan)
                pan.phase = .ended
                pan.velocityX = 900
                host.perform(NSSelectorFromString("handleTimelinePan:"), with: pan)
            } else {
                let press = ContinuousScaleTestLongPress()
                press.phase = .began
                host.perform(NSSelectorFromString("handleCrosshair:"), with: press)
            }
            XCTAssertTrue(host.diagnosticHasInteractionBaseline, "Fixture mode \(mode) must start an interaction")
            host.observeFirstPresentation(for: ChartPresentationID(
                stream: ChartStreamKey(symbol: "ETHUSDT", interval: "5m"),
                epoch: KlineStreamEpoch(generation: UInt64(mode * 2 + 2)))) { _, _ in }
            XCTAssertFalse(host.diagnosticHasInteractionBaseline, "Switch must clear mode \(mode)")
            XCTAssertFalse(host.diagnosticIsInteractionActive)
        }
    }

    @MainActor
    func testLoadingIndicatorStaysVisibleUntilTheMatchingFrameIsPresented() async throws {
        let fixture = try await makeChartSceneFixture()
        let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: 700, displayScale: 3))
        let scene = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport)
        let host = KlineChartHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        defer { host.dispose() }
        let id = ChartPresentationID(stream: fixture.frame.stream, epoch: fixture.frame.epoch)
        host.observeFirstPresentation(for: id) { _, _ in }
        host.setLoadingPresentation(true)
        host.submit(scene.renderState)
        host.setLoadingPresentation(false)
        XCTAssertTrue(host.diagnosticIsLoadingIndicatorVisible,
            "Scene readiness must not remove the loading indicator before GPU presentation")
        let stale = ChartPresentationID(stream: id.stream, epoch: KlineStreamEpoch(generation: 1))
        host.diagnosticRecordPresentation(for: stale, at: 10)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(host.diagnosticIsLoadingIndicatorVisible,
            "A late frame from another epoch must not uncover a blank chart")
        host.diagnosticRecordPresentation(for: id, at: 20)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(host.diagnosticIsLoadingIndicatorVisible)
        XCTAssertFalse(host.diagnosticIsLoadingCovered)
        XCTAssertTrue(host.isUserInteractionEnabled)
    }

    @MainActor
    func testLoadingCoverRendersTheIndicatorInBothThemes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.makeKeyAndVisible()
        let host = KlineChartHostView(frame: window.bounds)
        controller.view.addSubview(host)
        defer { host.dispose(); window.isHidden = true; window.rootViewController = nil }
        host.diagnosticSetApplicationActive(false)
        host.setLoadingPresentation(true)
        for appearance in [ChartAppearance.light, .dark] {
            host.setAppearance(appearance)
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let snapshot = UIGraphicsImageRenderer(bounds: host.bounds).image { _ in
                host.drawHierarchy(in: host.bounds, afterScreenUpdates: true)
            }
            let image = try XCTUnwrap(snapshot.cgImage)
            let scale = snapshot.scale
            let region = try XCTUnwrap(image.cropping(to: CGRect(
                x: (host.bounds.midX - 20) * scale, y: (host.bounds.midY - 12) * scale,
                width: 40 * scale, height: 24 * scale)))
            var pixels = [UInt8](repeating: 0, count: region.width * region.height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                    width: region.width, height: region.height, bitsPerComponent: 8,
                    bytesPerRow: region.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(region, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
            }
            let yellowPixels = stride(from: 0, to: pixels.count, by: 4).filter {
                Int(pixels[$0]) - Int(pixels[$0 + 2]) > 100
                    && Int(pixels[$0 + 1]) - Int(pixels[$0 + 2]) > 80
            }.count
            XCTAssertGreaterThan(yellowPixels, 20, "The loading cover must contain visible bars in \(appearance)")
            let attachment = XCTAttachment(image: snapshot)
            attachment.name = "chart-loading-cover-\(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        host.diagnosticSetApplicationActive(true)
        XCTAssertTrue(host.diagnosticIsLoadingIndicatorAnimating)
        host.diagnosticSetApplicationActive(false)
        XCTAssertFalse(host.diagnosticIsLoadingIndicatorAnimating)
        host.diagnosticSetApplicationActive(true)
        for _ in 0..<3 { host.diagnosticInjectCommandFailure() }
        XCTAssertFalse(host.diagnosticIsLoadingIndicatorAnimating,
            "A renderer error must stop the loading animation behind its message")
        XCTAssertNotNil(host.diagnosticVisibleRendererError)
        host.dispose()
        XCTAssertFalse(host.diagnosticIsLoadingIndicatorVisible)
    }

    @MainActor
    func testLoadingCoverKeepsRendererFailureVisibleBeforeTheFirstFrame() {
        let host = KlineChartHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        defer { host.dispose() }
        host.observeFirstPresentation(for: ChartPresentationID(stream: stream,
            epoch: KlineStreamEpoch(generation: 1))) { _, _ in XCTFail("A failed renderer cannot present") }
        host.setLoadingPresentation(true)
        for _ in 0..<3 { host.diagnosticInjectCommandFailure() }
        XCTAssertTrue(host.diagnosticIsRendererStopped)
        XCTAssertTrue(host.diagnosticIsLoadingCovered)
        XCTAssertEqual(host.diagnosticVisibleRendererError, "K线 GPU 连续渲染失败，请重新进入页面")
        XCTAssertFalse(host.diagnosticIsLoadingIndicatorAnimating)
        XCTAssertFalse(host.isUserInteractionEnabled)
    }

    func testPlotStartsAtCanvasEdgeAndRetainsSquarePriceArea() throws {
        for scale in [2.0, 3.0] {
            let height = ChartPanelLayout.squareViewportHeightPoints(widthPoints: 390, indicatorPanelCount: 1)
            let viewport = try XCTUnwrap(ChartSceneViewport(widthPoints: 390, heightPoints: height, displayScale: scale))
            let layout = try XCTUnwrap(ChartPanelLayout.make(viewport: viewport, indicatorPanelIDs: [ChartPanelID.volume]))
            XCTAssertEqual(layout.plotLeft, 0, "The chart must not leave a blank strip at the canvas edge")
            let price = try XCTUnwrap(layout.pricePanel)
            XCTAssertEqual(price.plot.width, price.plot.height, accuracy: 0.01)
        }
    }

    @MainActor
    func testCrosshairPriceDistanceRendersExactlyTwoFractionDigits() async throws {
        let fixture = try await makeChartSceneFixture()
        let examples: [(Double, String)] = [
            (0.039110270783, "+3.91%"), (-0.039110270783, "-3.91%"),
            (0.001234, "+0.12%"), (-0.001234, "-0.12%"),
            (0.01, "+1.00%"), (0, "0.00%"),
            (0.0000001, "0.00%"), (-0.0000001, "0.00%"),
            (1.23456, "+123.46%"),
        ]
        for scale in [2.0, 3.0] {
            let viewport = try XCTUnwrap(ChartSceneViewport(
                widthPoints: 390, heightPoints: 396, displayScale: scale))
            let output = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport)
            let data = try XCTUnwrap(output.renderState.staticScene.crosshairData)
            let layout = output.panelLayout
            let panel = try XCTUnwrap(layout.pricePanel)
            let hit = try XCTUnwrap(ChartCrosshairResolver.resolve(
                screenX: Double(layout.plotLeft + 180),
                screenY: Double((panel.plot.top + panel.plot.bottom) / 2),
                transform: .identity, data: data,
                liveData: output.renderState.liveTail.crosshairLiveData))
            for (rate, expected) in examples {
                let snapshot = ChartCrosshairOverlayBuilder().makeSnapshot(
                    hit: hit, data: data, latestPrice: hit.selection.panelValue / (1 + rate))
                let storage = try XCTUnwrap(snapshot.batches.first?.storage)
                let label = try XCTUnwrap(storage.barInstances.first {
                    $0.color == .crosshairAxisLabelBackground && $0.left >= layout.plotRight
                })
                let rateGlyphs = storage.glyphInstances.filter {
                    $0.color == .crosshairAxisLabelText && $0.left >= layout.plotRight
                        && ($0.top + $0.bottom) / 2 >= (label.top + label.bottom) / 2
                        && $0.bottom <= label.bottom
                }
                let expectedGlyphs = MetalTextLayouter.layout(text: expected, atlas: data.glyphAtlas,
                    originX: 0, baselineY: 0, color: .crosshairAxisLabelText).instances
                XCTAssertEqual(rateGlyphs.count, expectedGlyphs.count, expected)
                for (actual, expectedGlyph) in zip(rateGlyphs, expectedGlyphs) {
                    XCTAssertEqual(actual.uvLeft, expectedGlyph.uvLeft, expected)
                    XCTAssertEqual(actual.uvTop, expectedGlyph.uvTop, expected)
                    XCTAssertEqual(actual.uvRight, expectedGlyph.uvRight, expected)
                    XCTAssertEqual(actual.uvBottom, expectedGlyph.uvBottom, expected)
                }
            }
        }
    }

    func testOrderPriceAxisLabelsKeepCompletePricesInsideTheFixedAxis() async throws {
        let fixture = try await makeChartSceneFixture()
        for width in [320.0, 390.0] {
            for scale in [2.0, 3.0] {
                let viewport = try XCTUnwrap(ChartSceneViewport(
                    widthPoints: width, heightPoints: 396, displayScale: scale))
                let output = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport)
                let data = try XCTUnwrap(output.renderState.staticScene.crosshairData)
                let plot = try XCTUnwrap(data.panelLayout.pricePanel?.plot)
                let midpoint = (data.priceDomain.lower + data.priceDomain.upper) / 2
                let labels = [
                    ChartAxisPriceLabel(id: "entry", price: midpoint, text: "60220.12345678", color: .positive),
                    ChartAxisPriceLabel(id: "stop", price: data.priceDomain.lower, text: "0.00000123456", color: .negative),
                    ChartAxisPriceLabel(id: "outside", price: data.priceDomain.upper + 1, text: "1", color: .negative),
                    ChartAxisPriceLabel(id: "invalid", price: .nan, text: "1", color: .negative)
                ]
                let batches = ChartAxisPriceLabelBuilder.batches(for: labels, data: data)
                XCTAssertEqual(batches.count, 2, "Offscreen and invalid prices must not stick to a chart edge")
                for (index, batch) in batches.enumerated() {
                    XCTAssertEqual(batch.coordinateSpace, .fixed)
                    let frame = try XCTUnwrap(batch.storage.barInstances.first)
                    XCTAssertEqual(frame.left, plot.right + Float(2 * scale))
                    XCTAssertEqual(frame.right, data.widthPixels - Float(scale))
                    XCTAssertGreaterThanOrEqual(frame.top, plot.top)
                    XCTAssertLessThanOrEqual(frame.bottom, plot.bottom)
                    XCTAssertEqual(frame.bottom - frame.top, Float(18 * scale))
                    let fill = try XCTUnwrap(batch.storage.barInstances.last)
                    for appearance in [ChartAppearance.light, .dark] {
                        let color = fill.color.resolved(for: appearance)
                        XCTAssertEqual(color, ChartColor.chartBackground.resolved(for: appearance),
                            "Order prices must have opaque white/light and gray-black/dark interiors")
                    }
                    let original = MetalTextLayouter.layout(text: labels[index].text, atlas: data.glyphAtlas,
                        originX: 0, baselineY: 0, color: labels[index].color)
                    XCTAssertFalse(original.instances.isEmpty)
                    XCTAssertEqual(batch.storage.glyphInstances.count, original.instances.count,
                        "Long prices must fit as a complete row, without dropping digits")
                    XCTAssertTrue(batch.storage.glyphInstances.allSatisfy {
                        $0.left >= frame.left && $0.right <= frame.right
                            && $0.top >= frame.top && $0.bottom <= frame.bottom
                    })
                    let line = try XCTUnwrap(batch.storage.lineSegments.first)
                    XCTAssertEqual(line.start.x, plot.right)
                    XCTAssertEqual(line.end.x, frame.left,
                        "The price line must end at the frame border, without passing through its interior")
                    XCTAssertGreaterThanOrEqual(line.end.y, frame.top + frame.cornerRadius)
                    XCTAssertLessThanOrEqual(line.end.y, frame.bottom - frame.cornerRadius)
                    XCTAssertEqual(line.dashLength, 0, "The short axis connector must reach the frame without a dash gap")
                }
                let state = output.renderState.withAxisPriceLabels(labels).withAppearance(.light)
                XCTAssertEqual(state.axisPriceLabels.map(\.id), labels.map(\.id))
            }
        }
    }

    @MainActor
    func testOrderPriceAxisLabelsUseThemeFillAndConnectedLinesDuringPan() async throws {
        let fixture = try await makeChartSceneFixture()
        let renderer = try MetalRenderer(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            pixelFormat: .bgra8Unorm_srgb)
        for scale in [2, 3] {
            let viewport = try XCTUnwrap(ChartSceneViewport(
                widthPoints: 390, heightPoints: 396, displayScale: Double(scale)))
            let output = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport)
            let data = try XCTUnwrap(output.renderState.staticScene.crosshairData)
            let label = ChartAxisPriceLabel(id: "stop", price: data.priceDomain.lower
                + (data.priceDomain.upper - data.priceDomain.lower) * 0.2, text: "1", color: .negative)
            let batch = try XCTUnwrap(ChartAxisPriceLabelBuilder.batches(for: [label], data: data).first)
            let frame = try XCTUnwrap(batch.storage.barInstances.first)
            let line = try XCTUnwrap(batch.storage.lineSegments.first)
            for appearance in [ChartAppearance.light, .dark] {
                var reference: MetalOffscreenImage?
                for translation: Double in [0, -43 * Double(scale)] {
                    let state = RenderState(staticScene: output.renderState.staticScene,
                        liveTail: output.renderState.liveTail,
                        interaction: InteractionSnapshot(revision: 999, translationX: translation,
                            scaleX: translation == 0 ? 1 : 1.4, crosshair: nil),
                        invalidation: .full, appearance: appearance).withAxisPriceLabels([label])
                    let image = try XCTUnwrap(renderer.renderOffscreen(
                        state: state, width: 390 * scale, height: 396 * scale))
                    let fill = ChartColor.chartBackground.resolved(for: appearance)
                    let expected = [fill.blue, fill.green, fill.red, fill.alpha].map { Int(($0 * 255).rounded()) }
                    let centerY = Int((frame.top + frame.bottom) / 2)
                    let startX = Int(frame.left) + 8 * scale
                    let endX = Int(frame.left) + 20 * scale
                    let interiorMatches = (startX..<endX).allSatisfy { x in
                        let offset = centerY * image.bytesPerRow + x * 4
                        let actual = Array(image.bgra8UnormSRGB[offset..<offset + 4]).map(Int.init)
                        return zip(actual, expected).allSatisfy { abs($0 - $1) <= 1 }
                    }
                    XCTAssertTrue(interiorMatches,
                        "The opaque order-price fill must hide the underlying chart and any crossing line")
                    let connectionX = Int((line.start.x + frame.left) / 2)
                    let connectionY = Int((line.start.y + line.end.y) / 2)
                    let pixels = (-1...1).map { dy -> [Int] in
                        let offset = (connectionY + dy) * image.bytesPerRow + connectionX * 4
                        return Array(image.bgra8UnormSRGB[offset..<offset + 4]).map(Int.init)
                    }
                    let color = label.color.resolved(for: appearance)
                    let lineColor = [color.blue, color.green, color.red].map { Int(($0 * 255).rounded()) }
                    XCTAssertTrue(pixels.contains { pixel in
                        zip(pixel.prefix(3), lineColor).allSatisfy { abs($0 - $1) <= 1 }
                    }, "The axis connector must visibly meet the colored frame")
                    if let reference {
                        for y in Int(frame.top) + 3 * scale..<Int(frame.bottom) - 3 * scale {
                            let start = y * image.bytesPerRow + (Int(frame.left) + 4 * scale) * 4
                            let end = y * image.bytesPerRow + (Int(frame.right) - 4 * scale) * 4
                            XCTAssertEqual(image.bgra8UnormSRGB[start..<end], reference.bgra8UnormSRGB[start..<end],
                                "Timeline pans and zooms must not move or remove the axis frame")
                        }
                    } else { reference = image }
                }
            }
        }
    }

    @MainActor
    func testOrderPriceAxisLabelsStayBelowLatestPriceAndCrosshairPixels() async throws {
        let fixture = try await makeChartSceneFixture()
        let renderer = try MetalRenderer(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            pixelFormat: .bgra8Unorm_srgb)
        for scale in [2, 3] {
            let viewport = try XCTUnwrap(ChartSceneViewport(
                widthPoints: 390, heightPoints: 396, displayScale: Double(scale)))
            let output = try await ChartSceneBuilder().build(frame: fixture.frame, viewport: viewport)
            let data = try XCTUnwrap(output.renderState.staticScene.crosshairData)
            let marker = try XCTUnwrap(output.renderState.liveTail.latestPriceMarker)
            let label = ChartAxisPriceLabel(id: "entry", price: try XCTUnwrap(output.renderState.liveTail.latestPrice),
                text: "999999999999.9", color: .negative)
            let hit = try XCTUnwrap(ChartCrosshairResolver.resolve(
                screenX: Double(data.panelLayout.plotLeft + 180),
                screenY: Double((marker.top + marker.bottom) / 2), transform: .identity,
                data: data, liveData: output.renderState.liveTail.crosshairLiveData, clampsToPlot: true))
            let crosshair = ChartCrosshairOverlayBuilder().makeSnapshot(
                hit: hit, data: data, latestPrice: output.renderState.liveTail.latestPrice)
            for appearance in [ChartAppearance.light, .dark] {
                for selection in [CrosshairSnapshot?.none, crosshair] {
                    let referenceState = RenderState(
                        staticScene: output.renderState.staticScene, liveTail: output.renderState.liveTail,
                        interaction: InteractionSnapshot(revision: 999, translationX: 0, scaleX: 1, crosshair: selection),
                        invalidation: .full, appearance: appearance)
                    let actual = try XCTUnwrap(renderer.renderOffscreen(
                        state: referenceState.withAxisPriceLabels([label]), width: 390 * scale, height: 396 * scale))
                    let reference = try XCTUnwrap(renderer.renderOffscreen(
                        state: referenceState, width: actual.width, height: actual.height))
                    // Opaque interiors must be identical to rendering without any order label.
                    for y in Int(marker.top) + 3 * scale..<Int(marker.bottom) - 3 * scale {
                        let start = y * actual.bytesPerRow + (Int(marker.left) + 5 * scale) * 4
                        let end = y * actual.bytesPerRow + (Int(marker.right) - 5 * scale) * 4
                        XCTAssertEqual(actual.bgra8UnormSRGB[start..<end], reference.bgra8UnormSRGB[start..<end],
                            "Order-price fill or digits covered a higher price frame")
                    }
                }
            }
        }
    }

    private func makeChartSceneFixture()
        async throws -> (
            pipeline: ChartDataPipeline,
            epoch: KlineStreamEpoch,
            frame: ChartDataFrame
        ) {
        let epoch = KlineStreamEpoch(generation: 77)
        let pipeline = try XCTUnwrap(ChartDataPipeline(
            stream: stream,
            intervalMilliseconds: 3_600_000,
            epoch: epoch
        ))
        let history = (0..<220).map { index in
            marketCandle(
                openTime: Int64(index) * 3_600_000,
                closePrice: 60_000
                    + sin(Double(index) * 0.13) * 180
                    + Double(index)
            )
        }
        let installed = await pipeline.installSnapshot(
            history,
            fetchedAtMilliseconds: 220 * 3_600_000,
            epoch: epoch
        )
        XCTAssertNotNil(installed.frame)
        XCTAssertNil(installed.recoveryRequest)
        _ = await pipeline.accept(
            payload: realtimePayload(
                sequence: 1,
                openTime: 220 * 3_600_000,
                closePrice: 60_220,
                closed: false
            ),
            sequence: 1,
            epoch: epoch
        )
        let drained = await pipeline.drain()
        let frame = try XCTUnwrap(drained.frame)
        return (pipeline, epoch, frame)
    }

    private func makeOffscreenState(
        scale: Int,
        builder: MetalGlyphAtlasBuilder
    ) throws -> RenderState {
        let factor = Float(scale)
        let text = "63,900.8 EMA"
        let key = try XCTUnwrap(ChartGlyphAtlasKey(
            fontName: "HelveticaNeue",
            pointSize: 11,
            displayScale: Double(scale),
            localeIdentifier: "en_US"
        ))
        let atlas = try builder.build(
            key: key,
            seedStrings: [text]
        )
        let textLayout = MetalTextLayouter.layout(
            text: text,
            atlas: atlas,
            originX: Double(8 * scale),
            baselineY: Double(70 * scale),
            color: .neutral
        )
        let lines = ChartBatchCompiler.lineSegments(
            spans: [[
                ChartPolylinePoint(
                    x: 8 * factor,
                    y: 35 * factor
                ),
                ChartPolylinePoint(
                    x: 75 * factor,
                    y: 12 * factor
                ),
                ChartPolylinePoint(
                    x: 145 * factor,
                    y: 28 * factor
                ),
            ]],
            width: factor,
            dashLength: 5 * factor,
            gapLength: 3 * factor,
            color: .neutral
        )
        let batch = ChartRenderBatch(
            candleInstances: [
                ChartCandleInstance(
                    x: 45 * factor,
                    openY: 18 * factor,
                    highY: 8 * factor,
                    lowY: 48 * factor,
                    closeY: 40 * factor,
                    halfBodyWidth: 4 * factor,
                    isRising: false
                ),
                ChartCandleInstance(
                    x: 62 * factor,
                    openY: 42 * factor,
                    highY: 22 * factor,
                    lowY: 54 * factor,
                    closeY: 28 * factor,
                    halfBodyWidth: 4 * factor,
                    isRising: true
                ),
            ],
            lineSegments: lines,
            barInstances: [
                ChartBarInstance(
                    left: 95 * factor,
                    top: 20 * factor,
                    right: 115 * factor,
                    bottom: 52 * factor,
                    color: .negative
                ),
            ],
            glyphInstances: textLayout.instances,
            glyphAtlas: atlas
        )
        let history = ChartCandleHistory(candles: [])
        return RenderState(
            staticScene: StaticSceneSnapshot(
                revision: UInt64(scale),
                candleHistory: history,
                batches: [batch]
            ),
            liveTail: LiveTailSnapshot(
                revision: UInt64(scale),
                candle: nil,
                batches: [],
                latestPrice: nil
            ),
            interaction: InteractionSnapshot(
                revision: UInt64(scale),
                translationX: 0,
                scaleX: 1,
                crosshair: nil
            ),
            invalidation: .full
        )
    }

    private func makePreviewImage(
        _ image: MetalOffscreenImage
    ) -> UIImage? {
        guard let provider = CGDataProvider(
            data: image.bgra8UnormSRGB as CFData
        ),
        let colorSpace = CGColorSpace(
            name: CGColorSpace.sRGB
        ),
        let cgImage = CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.bytesPerRow,
            space: colorSpace,
            bitmapInfo: [
                .byteOrder32Little,
                CGBitmapInfo(
                    rawValue:
                        CGImageAlphaInfo.premultipliedFirst.rawValue
                ),
            ],
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func isColoredPixel(
        _ image: MetalOffscreenImage,
        x: Int,
        y: Int
    ) -> Bool {
        guard x >= 0,
              x < image.width,
              y >= 0,
              y < image.height else {
            return false
        }
        return image.bgra8UnormSRGB.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.baseAddress?
                    .assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            let offset = y * image.bytesPerRow + x * 4
            // The current dark canvas has a non-black background. Compare to
            // the untouched corner rather than classifying the canvas as a line.
            return bytes[offset] != bytes[0]
                || bytes[offset + 1] != bytes[1]
                || bytes[offset + 2] != bytes[2]
        }
    }

}

private struct TestConstantIndicatorPlugin: ChartIndicatorPlugin {
    let descriptor = ChartIndicatorDescriptor(
        id: "test.constant",
        displayName: "Test Constant",
        definitionVersion: 1,
        placement: .priceOverlay,
        parameters: [
            ChartIndicatorParameterDescriptor(
                id: "value",
                displayName: "Value",
                defaultValue: 0,
                range: -1_000...1_000,
                step: 1
            )
        ],
        outputs: [
            ChartIndicatorOutputDescriptor(
                id: "value",
                displayName: "Value",
                colorToken: .neutral,
                lineWidthPoints: 1,
                autoscale: .included
            )
        ],
        warmupCount: 0,
        yAxisPolicy: .sharedPrice,
        allowsMultipleInstances: true
    )

    func makeCalculator(
        configuration: ChartIndicatorInstanceConfiguration,
        intervalMilliseconds: Int64
    ) -> (any ChartIndicatorCalculator)? {
        let value = configuration.parameters["value"] ?? 0
        guard value.isFinite, intervalMilliseconds > 0 else {
            return nil
        }
        return TestConstantIndicatorCalculator(value: value)
    }
}

private struct TestConstantIndicatorCalculator:
    ChartIndicatorCalculator {
    let value: Double
    private(set) var lastCommittedOpenTime: Int64?

    mutating func commit(
        _ candle: ChartCandle
    ) -> ChartIndicatorPluginComputation {
        guard candle.closure == .closed, candle.isValid else {
            return computation(
                openTime: candle.openTime,
                validity: .invalid
            )
        }
        lastCommittedOpenTime = candle.openTime
        return computation(
            openTime: candle.openTime,
            validity: .valid
        )
    }

    func provisional(
        _ candle: ChartCandle?
    ) -> ChartIndicatorPluginComputation {
        guard let candle else {
            return ChartIndicatorPluginComputation(
                points: [:],
                legendValue: nil,
                legendColorToken: nil
            )
        }
        return computation(
            openTime: candle.openTime,
            validity: candle.isValid ? .valid : .invalid
        )
    }

    private func computation(
        openTime: Int64,
        validity: IndicatorPointValidity
    ) -> ChartIndicatorPluginComputation {
        ChartIndicatorPluginComputation(
            points: [
                "value": IndicatorPoint(
                    openTime: openTime,
                    value: validity == .valid ? value : nil,
                    validity: validity
                )
            ],
            legendValue: validity == .valid ? value : nil,
            legendColorToken: .neutral
        )
    }
}

@MainActor
private final class ContinuousScaleTestPinch: UIPinchGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
    override func location(in view: UIView?) -> CGPoint {
        CGPoint(x: 168, y: 120)
    }
}

@MainActor
private final class ContinuousScaleTestLongPress: UILongPressGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var point = CGPoint(x: 168, y: 120)
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
private final class ContinuousScaleTestPan: UIPanGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var translationX: CGFloat = 0
    var translationY: CGFloat = 0
    var velocityX: CGFloat = 0
    var point = CGPoint(x: 168, y: 120)
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
    override func translation(in view: UIView?) -> CGPoint {
        CGPoint(x: translationX, y: translationY)
    }
    override func velocity(in view: UIView?) -> CGPoint {
        CGPoint(x: velocityX, y: 0)
    }
    override func location(in view: UIView?) -> CGPoint { point }
}

final class ChartOrderOverlayRenderingTests: XCTestCase {
    @MainActor
    func testRiskFillReachesRightEdgeAndClipsToThePricePlot() throws {
        let projection = try XCTUnwrap(ChartPriceProjection(lowerBound: 0, upperBound: 200,
            plotLeft: 0, plotTop: 20, plotRight: 302, plotBottom: 300))
        for scale in [2.0, 3.0] {
            for side in [ChartOrderSide.long, .short] {
                let state = ChartOrderDrawingState(side: side, entryOrderType: .limit,
                    referencePrice: 100, riskAmount: 10, entryPrice: 100,
                    stopLossPrice: side == .long ? 60 : 140)
                let renderer = ImageRenderer(content: ChartOrderDrawingOverlay(drawing: .constant(state),
                    projection: projection, formatPrice: { String($0) }, showsSummary: false)
                    .frame(width: 360, height: 320))
                renderer.scale = scale
                let image = try XCTUnwrap(renderer.cgImage)
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try pixels.withUnsafeMutableBytes { bytes in
                    let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width,
                        height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                func alpha(_ x: Double, _ y: Double) -> UInt8 {
                    pixels[(Int(y * scale) * image.width + Int(x * scale)) * 4 + 3]
                }
                let y = side == .long ? 188.0 : 132.0
                XCTAssertGreaterThan(alpha(358, y), 10, "Fill must reach the outer edge of the right price axis")
                XCTAssertEqual(alpha(358, y), alpha(280, y), "The right axis must use the same risk tint")
                XCTAssertEqual(alpha(358, 10), 0)
                XCTAssertEqual(alpha(358, 310), 0)
            }
        }
    }
}

@MainActor
final class ChartPositionContextTests: XCTestCase {
    private func row(_ changes: [String: JSONValue] = [:]) -> JSONValue {
        .object(["id": .number(101), "symbol": .string("BTCUSDT"), "side": .number(0),
            "exchange_size": .string("0.1"), "open_price": .string("68000.12345678"),
            "stop_loss_price": .string("67000"), "market_stop_set": .bool(true),
            "market_stop_price": .string("67100"), "manual_take_profit_set": .bool(false)]
            .merging(changes, uniquingKeysWith: { _, new in new }))
    }

    func testLinesUseCurrentSymbolAndActualMarketStopPrice() {
        let rows = [row(), row(["symbol": .string("ETHUSDT")]), row(["exchange_size": .string("0")]),
            row(["status": .number(1)])]
        let lines = ChartPositionLine.lines(in: rows, symbol: "btcusdt")
        XCTAssertEqual(lines.map(\.kind), [.entry, .stopLoss])
        XCTAssertEqual(lines.map(\.price), [Decimal(string: "68000.12345678")!, Decimal(67100)])
    }

    func testTakeProfitRequiresAnExistingOrderAndSupportsBothOrderTypes() {
        for type in ["limit", "market"] {
            let pending = row(["manual_take_profit_price": .string("70000"),
                "manual_take_profit_order_type": .string(type)])
            XCTAssertEqual(ChartPositionLine.lines(in: [pending], symbol: "BTCUSDT").count, 2)
            let placed = row(["manual_take_profit_set": .bool(true),
                "manual_take_profit_price": .string("70000"), "manual_take_profit_order_type": .string(type)])
            XCTAssertEqual(ChartPositionLine.lines(in: [placed], symbol: "BTCUSDT").last?.kind, .takeProfit)
        }
    }

    func testInvalidProtectionPricesAreNotDrawnAndStopFallsBack() {
        let invalid = row(["market_stop_price": .string("NaN"), "open_price": .string("-1"),
            "manual_take_profit_set": .bool(true), "manual_take_profit_price": .string("Infinity")])
        let lines = ChartPositionLine.lines(in: [invalid], symbol: "BTCUSDT")
        XCTAssertEqual(lines.map(\.kind), [.stopLoss])
        XCTAssertEqual(lines.first?.price, Decimal(67000))
    }

    func testHedgedPositionsHaveDistinctLabelsAndIdentifiers() {
        let lines = ChartPositionLine.lines(in: [row(), row(["id": .number(102), "side": .number(1)])], symbol: "BTCUSDT")
        XCTAssertEqual(Set(lines.map(\.id)).count, 4)
        XCTAssertEqual(lines.map(\.title), ["多 · 开仓", "多 · 止损", "空 · 开仓", "空 · 止损"])
    }

    func testPositionLabelsShowLiveProfitAndFrozenNegativeRisk() throws {
        let position = row(["open_price": .string("100"), "exchange_size": .string("2"),
            "stop_loss_amount": .string("10")])
        let lines = ChartPositionLine.lines(in: [position], symbol: "BTCUSDT", currentPrice: 105)
        XCTAssertEqual(lines[0].detail, "+10 U")
        XCTAssertEqual(lines[1].detail, "-10 U")
        let loss = ChartPositionLine.lines(in: [position], symbol: "BTCUSDT", currentPrice: 97)
        XCTAssertEqual(loss[0].detail, "-6 U")
        XCTAssertEqual(loss[1].detail, "-10 U")
    }

    func testPositionAmountsRoundIndependentlyWithoutLosingProfitSign() throws {
        let position = row(["open_price": .string("100"), "exchange_size": .string("2"),
            "stop_loss_amount": .string("10.55")])
        let profit = ChartPositionLine.lines(in: [position], symbol: "BTCUSDT", currentPrice: Decimal(string: "105.617")!)
        XCTAssertEqual(profit[0].detail, "+11.2 U")
        XCTAssertEqual(profit[1].detail, "-10.6 U")
        let loss = ChartPositionLine.lines(in: [position], symbol: "BTCUSDT", currentPrice: Decimal(string: "99.999")!)
        XCTAssertEqual(loss[0].detail, "0 U")
        XCTAssertLessThan(try XCTUnwrap(loss[0].profit), 0, "The raw Decimal sign still controls color when rounded text is zero")
        let wholeRisk = row(["stop_loss_amount": .string("10.04")])
        XCTAssertEqual(ChartPositionLine.lines(in: [wholeRisk], symbol: "BTCUSDT")[1].detail, "-10 U")
    }

    @MainActor
    func testPositionLabelsAreCompactSolidWhiteTextAndLeaveAxisToMetal() throws {
        let position = row(["open_price": .string("100"), "exchange_size": .string("2"),
            "market_stop_price": .string("60"), "stop_loss_amount": .string("10")])
        let projection = try XCTUnwrap(ChartPriceProjection(lowerBound: 0, upperBound: 200,
            plotLeft: 4, plotTop: 0, plotRight: 302, plotBottom: 300))
        for scheme in [ColorScheme.light, .dark] {
            for scale in [2.0, 3.0] {
                for quote in [Decimal(105), Decimal(99), Decimal(string: "99.999")!, Decimal(1_000_000)] {
                    let lines = ChartPositionLine.lines(in: [position], symbol: "BTCUSDT", currentPrice: quote)
                    let frames = ChartPositionLinesOverlay.labelFrames(lines: lines, projection: projection)
                    XCTAssertEqual(frames.count, 2)
                    XCTAssertEqual(frames.map(\.width), [80, 80])
                    XCTAssertEqual(frames.map(\.height), [20, 20])
                    XCTAssertEqual(frames.map(\.minX), [10, 10])
                    let image = try renderPositionLines(lines, projection: projection, scheme: scheme, scale: scale)
                    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
                        let offset = (y * image.width + x) * 4
                        return (Int(image.pixels[offset]), Int(image.pixels[offset + 1]),
                            Int(image.pixels[offset + 2]), Int(image.pixels[offset + 3]))
                    }
                    func isColor(_ pixel: (Int, Int, Int, Int), red: Bool) -> Bool {
                        guard pixel.3 > 20 else { return false }
                        let r = pixel.0 * 255 / pixel.3, g = pixel.1 * 255 / pixel.3, b = pixel.2 * 255 / pixel.3
                        return red ? r > g + 90 && r > b + 90 : g > r + 60 && g > b + 30
                    }
                    for (index, centerY) in [150, 210].enumerated() {
                        let red = index == 1 || quote < 100
                        let fill = pixel(Int(12 * scale), Int(Double(centerY) * scale))
                        XCTAssertTrue(isColor(fill, red: red), "Label interior must have an opaque direction color in either theme")
                        XCTAssertEqual(fill.3, 255)
                        var whiteGlyphs = 0
                        for y in Int(Double(centerY - 8) * scale)..<Int(Double(centerY + 8) * scale) {
                            for x in Int(18 * scale)..<Int(86 * scale) {
                                let p = pixel(x, y)
                                if min(p.0, p.1, p.2) > 235 && p.3 > 240 { whiteGlyphs += 1 }
                            }
                        }
                        XCTAssertGreaterThan(whiteGlyphs, 3, "Position label glyphs must be white")
                        var gutterColorPixels = 0
                        var farEdgeColorPixels = 0
                        for y in Int(Double(centerY - 1) * scale)...Int(Double(centerY + 1) * scale) {
                            for x in Int(304 * scale)..<Int(359 * scale) {
                                if isColor(pixel(x, y), red: red) {
                                    gutterColorPixels += 1
                                    if x >= Int(350 * scale) { farEdgeColorPixels += 1 }
                                }
                            }
                        }
                        XCTAssertEqual(gutterColorPixels, 0, "Metal continues the line below its axis markers; SwiftUI must not overpaint latest price")
                        XCTAssertEqual(farEdgeColorPixels, 0)
                    }
                }
            }
        }
        let offscreen = [ChartPositionLine(id: "outside", kind: .entry, price: 300, title: "开仓")]
        XCTAssertTrue(ChartPositionLinesOverlay.labelFrames(lines: offscreen, projection: projection).isEmpty)
    }

    @MainActor
    func testAllPositionLinesLeaveThePriceAxisToMetal() throws {
        let projection = try XCTUnwrap(ChartPriceProjection(lowerBound: 0, upperBound: 200,
            plotLeft: 4, plotTop: 0, plotRight: 302, plotBottom: 300))
        for scheme in [ColorScheme.light, .dark] {
            for scale in [2.0, 3.0] {
                for kind in [ChartPositionLine.Kind.entry, .stopLoss, .takeProfit] {
                    let line = ChartPositionLine(id: kind.rawValue, kind: kind, price: 100,
                        title: kind.rawValue, detail: "1")
                    let image = try renderPositionLines([line], projection: projection, scheme: scheme, scale: scale)
                    var plotPixels = 0
                    var axisPixels = 0
                    for y in Int(149 * scale)...Int(151 * scale) {
                        for x in Int(280 * scale)..<Int(359 * scale) {
                            let alpha = image.pixels[(y * image.width + x) * 4 + 3]
                            if alpha > 20 {
                                if x < Int(301 * scale) { plotPixels += 1 }
                                if x > Int(303 * scale) { axisPixels += 1 }
                            }
                        }
                    }
                    XCTAssertGreaterThan(plotPixels, 0, "The in-chart price line must remain visible")
                    XCTAssertEqual(axisPixels, 0,
                        "Entry, stop-loss and take-profit lines must not overpaint the Metal price frames")
                }
            }
        }
    }

    @MainActor
    private func renderPositionLines(_ lines: [ChartPositionLine], projection: ChartPriceProjection,
                                     scheme: ColorScheme, scale: Double) throws -> (width: Int, pixels: [UInt8]) {
        let renderer = ImageRenderer(content: ChartPositionLinesOverlay(lines: lines, projection: projection)
            .frame(width: 360, height: 320).environment(\.colorScheme, scheme))
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (image.width, pixels)
    }

    @MainActor
    func testOrderLabelWidthIsCompactEqualAndLeftAligned() throws {
        let projection = try XCTUnwrap(ChartPriceProjection(lowerBound: 1, upperBound: 2,
            plotLeft: 4, plotTop: 30, plotRight: 332, plotBottom: 350))
        let layout = ChartPriceLineLabelLayout(projection: projection, texts: ["限价建仓", "止损价"], draggable: true)
        XCTAssertLessThan(layout.width, 90)
        XCTAssertEqual(layout.centerX - layout.width / 2, 10)
    }

    @MainActor
    func testSnapshotResetRejectsResponseFromPriorViewLifetime() async throws {
        let api = ChartPositionsSuspendedAPI()
        let store = USDTStore(api: api)
        store.prepareSession(userID: "chart-position-test")
        store.binding = .object(["id": .number(1)])
        let model = USDTChartPositionsModel()
        let task = Task { await model.refresh(store) }
        try await api.waitForRequest()
        model.reset()
        await api.complete(.array([row()]))
        await task.value
        XCTAssertFalse(model.isReady(scope: store.scope))
        XCTAssertTrue(model.positions(for: "BTCUSDT", scope: store.scope).isEmpty)
    }

    @MainActor
    func testAccountChangeHidesPriorPositionsAndRejectsDelayedReply() async throws {
        let api = ChartPositionsSuspendedAPI()
        let store = USDTStore(api: api)
        store.prepareSession(userID: "chart-position-test")
        store.binding = .object(["id": .number(1)])
        let model = USDTChartPositionsModel()
        let oldScope = store.scope
        let task = Task { await model.refresh(store) }
        try await api.waitForRequest()
        store.invalidate()
        await api.complete(.array([row()]))
        await task.value
        XCTAssertNotEqual(oldScope, store.scope)
        XCTAssertFalse(model.isReady(scope: store.scope))
        XCTAssertTrue(model.positions(for: "BTCUSDT", scope: store.scope).isEmpty)
        await model.refresh(store)
        XCTAssertTrue(model.isReady(scope: store.scope))
        XCTAssertTrue(model.rows.isEmpty)
    }
}

private actor ChartPositionsSuspendedAPI: APIClient {
    private var pending: CheckedContinuation<JSONValue, Never>?
    func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
        guard request.path == "/v1/position/list" else { throw APIError.invalidResponse }
        let result = await withCheckedContinuation { pending = $0 }
        return result as! Response
    }
    func waitForRequest() async throws {
        for _ in 0..<1000 {
            if pending != nil { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw APIError.invalidResponse
    }
    func complete(_ value: JSONValue) { pending?.resume(returning: value); pending = nil }
}

final class ChartPositionEntryMarkerTests: XCTestCase {
    private func row(_ changes: [String: JSONValue] = [:]) -> JSONValue {
        .object(["id": .number(42), "symbol": .string("BTCUSDT"), "side": .number(0),
            "exchange_size": .string("0.1"), "created_at": .string("2026-11-03T10:00:30.125Z")]
            .merging(changes, uniquingKeysWith: { _, new in new }))
    }

    private func candle(open: Int64 = 1_000, close: Int64 = 1_999) -> ChartCandle {
        ChartCandle(openTime: open, closeTime: close, openPrice: 100, highPrice: 110, lowPrice: 90,
            closePrice: 105, volume: 1, quoteVolume: 100, closure: .closed)
    }

    private func marker(_ placement: ChartCandleMarker.Placement = .below,
                        timestamp: Int64 = 1_500) -> ChartCandleMarker {
        ChartCandleMarker(id: "position", symbol: "BTCUSDT", timestamp: timestamp,
            text: placement == .below ? "B" : "S", placement: placement,
            color: placement == .below ? .positive : .negative, accessibilityLabel: "当前持仓")
    }

    func testOnlyCurrentNonzeroPositionsProduceDirectionMarkers() {
        let active = [row(), row(["id": .number(43), "side": .number(1)])]
        let ignored = [row(["symbol": .string("ETHUSDT")]), row(["status": .number(1)]),
            row(["exchange_size": .string("0")]), row(["exchange_size": .string("NaN")]),
            row(["side": .number(9)]), row(["created_at": .null])]
        let result = ChartPositionEntryMarkers.markers(in: active + ignored, symbol: "btcusdt")
        XCTAssertEqual(result.map(\.text), ["B", "S"])
        XCTAssertEqual(result.map(\.placement), [.below, .above])
        XCTAssertEqual(result.map(\.color), [.positive, .negative])
        XCTAssertEqual(Set(result.map(\.id)).count, 2)
        XCTAssertTrue(ChartPositionEntryMarkers.markers(in: [], symbol: "BTCUSDT").isEmpty,
            "Closing the position must remove its marker, rather than retain trade history")
    }

    func testEntryTimePrefersOpenedAtAndSupportsExistingDateFormats() throws {
        let first = try XCTUnwrap(ChartPositionEntryMarkers.markers(in: [row()], symbol: "BTCUSDT").first)
        XCTAssertEqual(first.timestamp, 1_793_700_030_125)
        for time in ["1793700060", "1793700060000", "2026-11-03T10:01:00Z"] {
            let result = ChartPositionEntryMarkers.markers(in: [row(["opened_at": .string(time)])], symbol: "BTCUSDT")
            XCTAssertEqual(result.first?.timestamp, 1_793_700_060_000)
        }
        XCTAssertEqual(ChartPositionEntryMarkers.markers(in: [row(["opened_at": .null])], symbol: "BTCUSDT").first?.timestamp,
            first.timestamp)
    }

    func testTimeMustBelongToAnActualCandleAndNeverSnapsAcrossGaps() {
        let candles = [candle(), candle(open: 3_000, close: 3_999)]
        XCTAssertEqual(marker(timestamp: 1_000).candleIndex(in: candles), 0)
        XCTAssertEqual(marker(timestamp: 1_999).candleIndex(in: candles), 0)
        XCTAssertEqual(marker(timestamp: 3_000).candleIndex(in: candles), 1)
        XCTAssertNil(marker(timestamp: 2_500).candleIndex(in: candles))
        XCTAssertNil(marker(timestamp: 4_000).candleIndex(in: candles))
        XCTAssertNil(marker(timestamp: 500).candleIndex(in: candles))
        XCTAssertNil(marker().candleIndex(in: []))
    }

    func testMarkersStayAboveOrBelowWicksAndKeepSizeWhilePanningAndZooming() throws {
        for scale in [2.0, 3.0] {
            let plot = ChartPanelRect(left: Float(4 * scale), top: Float(30 * scale),
                right: Float(332 * scale), bottom: Float(350 * scale))
            let domain = try XCTUnwrap(ChartCrosshairValueDomain(lower: 80, upper: 120))
            for transform in [ChartTimelineInteractionTransform.identity,
                .init(translationPixels: -100 * scale, scaleX: 2)] {
                let lower = try XCTUnwrap(ChartCandleMarkerLayout.frame(marker: marker(), candle: candle(),
                    baselineX: 120 * scale, plot: plot, domain: domain, transform: transform,
                    displayScale: scale, boundaryTranslationPoints: 5))
                let upper = try XCTUnwrap(ChartCandleMarkerLayout.frame(marker: marker(.above), candle: candle(),
                    baselineX: 120 * scale, plot: plot, domain: domain, transform: transform,
                    displayScale: scale, boundaryTranslationPoints: 5))
                XCTAssertEqual(lower.size, CGSize(width: 10, height: 10))
                XCTAssertEqual(upper.size, lower.size)
                XCTAssertEqual(lower.midX, transform.screenX(baselineX: 120 * scale) / scale + 5, accuracy: 0.001)
                XCTAssertEqual(lower.minY, 270 + 3, accuracy: 0.001)
                XCTAssertEqual(upper.maxY, 110 - 3, accuracy: 0.001)
            }
        }
    }

    func testMarkerAvoidsPositionPriceLabelsWithoutChangingItsCandle() throws {
        let plot = ChartPanelRect(left: 4, top: 30, right: 332, bottom: 350)
        let domain = try XCTUnwrap(ChartCrosshairValueDomain(lower: 80, upper: 120))
        for (placement, obstacle) in [(ChartCandleMarker.Placement.below, CGRect(x: 10, y: 270, width: 120, height: 24)),
            (.above, CGRect(x: 10, y: 90, width: 120, height: 24))] {
            let result = try XCTUnwrap(ChartCandleMarkerLayout.frame(marker: marker(placement), candle: candle(),
                baselineX: 50, plot: plot, domain: domain, transform: .identity, displayScale: 1, avoiding: [obstacle]))
            XCTAssertFalse(result.intersects(obstacle))
            XCTAssertEqual(result.midX, 50, accuracy: 0.001)
            XCTAssertEqual(result.size, CGSize(width: 10, height: 10))
            if placement == .below { XCTAssertGreaterThan(result.minY, obstacle.maxY) }
            else { XCTAssertLessThan(result.maxY, obstacle.minY) }
        }
    }

    func testOffscreenOrUnrelatedCandleDoesNotCreatePinnedMarker() throws {
        let plot = ChartPanelRect(left: 4, top: 30, right: 332, bottom: 350)
        let domain = try XCTUnwrap(ChartCrosshairValueDomain(lower: 80, upper: 120))
        XCTAssertNil(ChartCandleMarkerLayout.frame(marker: marker(), candle: candle(), baselineX: -50,
            plot: plot, domain: domain, transform: .identity, displayScale: 1))
        XCTAssertNil(ChartCandleMarkerLayout.frame(marker: marker(timestamp: 2_000), candle: candle(), baselineX: 120,
            plot: plot, domain: domain, transform: .identity, displayScale: 1))
    }
}

@MainActor
private final class ChartHostedReuseFixtureModel: ObservableObject {
    @Published var frame: ChartDataFrame?
    var presentations: [(KlineStreamEpoch, TimeInterval)] = []
    init(frame: ChartDataFrame?) { self.frame = frame }
}

@MainActor
private struct ChartHostedReuseFixture: View {
    @ObservedObject var model: ChartHostedReuseFixtureModel
    var body: some View {
        KlineChartSceneView(frame: model.frame, onFirstFramePresented: { epoch, time in
            model.presentations.append((epoch, time))
        }).frame(width: 390, height: 396)
    }
}
