import Metal
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
            .fifteenMinutes
        )
        XCTAssertEqual(
            sequence.item(offsetFromSelection: 1),
            .fourHours
        )
        XCTAssertEqual(
            sequence.item(offsetFromSelection: 3),
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
            symbol: "BTCUSDC",
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
    }

    func testReferenceTradeNotificationRoutesToReferenceTab() {
        let remotePayload: [AnyHashable: Any] = [
            "route": "reference.trade.notification",
            "eventId": "trade:open:1001:123456789",
            "type": "OPEN",
        ]

        XCTAssertEqual(
            StrategySignalNotificationManager.destination(
                from: remotePayload
            ),
            .reference
        )
    }

    func testIntegratedTabsKeepMarketFirstAndUSDTBusinessOrder() {
        XCTAssertEqual(AppTab.availableTabs(canViewReferenceNotifications: true), [.markets, .positions, .trade, .signals, .settings])
        XCTAssertEqual(AppTab.trade.title, "开仓")
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

    func testTradingAccountSnapshotDecodesJavaServerResponse() throws {
        let data = try XCTUnwrap(
            """
            {
              "id": "account-a",
              "label": "实盘",
              "status": "ACTIVE",
              "apiKeyMasked": "abcde****vwxyz",
              "quoteAsset": "USDC",
              "positionMode": "ONE_WAY",
              "canExecute": true,
              "totalMarginBalance": 152.32,
              "unrealizedProfit": -1.25,
              "lastVerifiedAtMillis": 100000,
              "lastSyncedAtMillis": 101000
            }
            """.data(using: .utf8)
        )
        let snapshot = try JSONDecoder().decode(
            BinanceFuturesAccountSnapshot.self,
            from: data
        )

        XCTAssertEqual(snapshot.asset, "USDC")
        XCTAssertEqual(snapshot.totalMarginBalance, Decimal(string: "152.32"))
        XCTAssertEqual(snapshot.unrealizedProfit, Decimal(string: "-1.25"))
        XCTAssertEqual(snapshot.apiKeyMasked, "abcde****vwxyz")
        XCTAssertTrue(snapshot.canExecute)
        XCTAssertEqual(
            snapshot.refreshedAt,
            Date(timeIntervalSince1970: 101)
        )
    }

    func testPositionDecodesActiveMakerCloseState() throws {
        let data = try XCTUnwrap(
            """
            {
              "id": "position-1",
              "symbol": "BTCUSDC",
              "positionSide": "LONG",
              "generation": 3,
              "quantity": 1.234,
              "entryPrice": 64000,
              "breakEvenPrice": 64002,
              "markPrice": 64100,
              "liquidationPrice": 50000,
              "leverage": 20,
              "marginType": "cross",
              "isolatedMargin": 0,
              "unrealizedProfit": 12.5,
              "exchangeUpdateMillis": 100000,
              "makerCloseOrderId": "order-close-1",
              "makerClosePrice": 64100.1,
              "makerCloseStatus": "LIVE",
              "makerCloseCancelable": true,
              "takeProfitPrices": [68000],
              "stopLossPrices": [62000],
              "realizedPnl": 1.25,
              "realizedPnlDetails": []
            }
            """.data(using: .utf8)
        )

        let position = try JSONDecoder().decode(
            TradingPositionSnapshot.self,
            from: data
        )

        XCTAssertEqual(position.leverage, 20)
        XCTAssertEqual(position.makerCloseOrderId, "order-close-1")
        XCTAssertEqual(position.makerClosePrice, Decimal(string: "64100.1"))
        XCTAssertEqual(position.makerCloseStatus, "LIVE")
        XCTAssertEqual(position.makerCloseCancelable, true)
    }

    func testSwiftCancellationMapsToSilentAPIError() {
        let error = APIError.map(CancellationError())

        XCTAssertFalse(error.shouldPresent)
        XCTAssertEqual(error.localizedDescription, "请求已取消")
    }

    func testTradingRiskSettingsValidateServerBoundValues() throws {
        let settings = TradingRiskSettings(
            isEnabled: true,
            takeProfitEnabled: true,
            stopLossEnabled: true,
            takeProfitPercent: 4.5,
            stopLossPercent: 1.8,
            stopLossAmount: 12,
            settlementAsset: "USDC"
        )

        XCTAssertEqual(try settings.validated(), settings)
    }

    func testTradingRiskSettingsRejectEnabledStrategyWithoutProtection() {
        var settings = TradingRiskSettings.defaultValue
        settings.isEnabled = true
        settings.takeProfitEnabled = false
        settings.stopLossEnabled = false

        XCTAssertThrowsError(try settings.validated()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "至少开启一项止盈或止损保护"
            )
        }
    }

    func testOrderSettingsAcceptLimitStopFallbackAboveOneR() throws {
        var settings = TradingOrderSettings.defaultValue
        settings.stopLossOrderType = .limit
        settings.fallbackMarketStopR = 1.01

        XCTAssertEqual(try settings.validated(), settings)
    }

    func testOrderSettingsRejectLimitStopAtOneR() {
        var settings = TradingOrderSettings.defaultValue
        settings.stopLossOrderType = .limit
        settings.fallbackMarketStopR = 1

        XCTAssertThrowsError(try settings.validated()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "保底市价止损必须大于 1R"
            )
        }
    }

    func testOrderSettingsDecodeServerContract() throws {
        let data = try XCTUnwrap(
            """
            {
              "accountId": "account-a",
              "revision": 2,
              "defaultExitStrategyId": "strategy-a",
              "defaultExitStrategyName": "默认策略",
              "entryOrderType": "MAKER_ONLY",
              "takeProfitOrderType": "LIMIT",
              "stopLossOrderType": "LIMIT",
              "fallbackMarketStopR": 1.5
            }
            """.data(using: .utf8)
        )

        let settings = try JSONDecoder().decode(
            TradingOrderSettings.self,
            from: data
        )

        XCTAssertEqual(settings.entryOrderType, .makerOnly)
        XCTAssertEqual(settings.takeProfitOrderType, .limit)
        XCTAssertEqual(settings.stopLossOrderType, .limit)
        XCTAssertEqual(settings.fallbackMarketStopR, 1.5)
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

    func testOrderIdempotencyKeyChangesOnlyWhenRequestChanges() {
        let original = ChartOrderSubmissionRequest(
            symbol: "BTCUSDC",
            direction: "LONG",
            entryPrice: 64_000,
            stopPrice: 63_000
        )
        var state = ChartOrderIdempotencyState()

        XCTAssertEqual(
            state.key(for: original, generate: { "key-a" }),
            "key-a"
        )
        XCTAssertEqual(
            state.key(for: original, generate: {
                XCTFail("相同参数重试不应生成新幂等键")
                return "key-b"
            }),
            "key-a"
        )

        let changed = ChartOrderSubmissionRequest(
            symbol: original.symbol,
            direction: original.direction,
            entryPrice: original.entryPrice,
            stopPrice: 62_900
        )
        XCTAssertEqual(
            state.key(for: changed, generate: { "key-b" }),
            "key-b"
        )
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

    func testLeveragePreviewUsesLargestEligibleNotionalBracket() {
        let settings = TradingLeverageSettings(
            symbol: "BTCUSDC",
            leverage: 125,
            maxLeverage: 125,
            maxNotionalValue: 50_000,
            brackets: [
                TradingLeverageBracket(
                    initialLeverage: 125,
                    notionalFloor: 0,
                    notionalCap: 50_000
                ),
                TradingLeverageBracket(
                    initialLeverage: 50,
                    notionalFloor: 50_000,
                    notionalCap: 250_000
                ),
            ]
        )

        XCTAssertEqual(settings.maximumNotional(for: 125), 50_000)
        XCTAssertEqual(settings.maximumNotional(for: 50), 250_000)
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

    func testExitStrategyDecodesFiveLevelServerContract() throws {
        let data = try XCTUnwrap(
            """
            {
              "id": "strategy-a",
              "name": "通用止盈",
              "revision": 4,
              "levels": [
                {
                  "id": "level-a",
                  "level": 1,
                  "triggerR": 1.5,
                  "reducePercent": 30,
                  "moveStopMode": "FIXED_R",
                  "moveStopR": 0
                },
                {
                  "id": "level-b",
                  "level": 2,
                  "triggerR": 4,
                  "reducePercent": 0,
                  "moveStopMode": "TRAILING_PROFIT_R",
                  "moveStopR": 1
                }
              ]
            }
            """.data(using: .utf8)
        )

        let strategy = try JSONDecoder().decode(
            TradingExitStrategy.self,
            from: data
        )

        XCTAssertEqual(strategy.levels.count, 2)
        XCTAssertEqual(strategy.levels[0].moveStopMode, .fixedR)
        XCTAssertEqual(strategy.levels[1].moveStopMode, .trailingProfitR)
    }

    func testLossLimitPreviewMatchesReferenceScreenSamples() {
        let balance = 152.32

        XCTAssertEqual(
            TradingLossLimitSettings.previewAmount(
                balance: balance,
                percentage: 1
            ),
            2
        )
        XCTAssertEqual(
            TradingLossLimitSettings.previewAmount(
                balance: balance,
                percentage: 9
            ),
            14
        )
        XCTAssertEqual(
            TradingLossLimitSettings.previewAmount(
                balance: balance,
                percentage: 25
            ),
            40
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
        XCTAssertEqual(live.closure, .provisional)
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
        XCTAssertFalse(machine.beginPinch())
        machine.finishInteraction()
        XCTAssertEqual(machine.state, .idle)
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
            transform: .identity,
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
        XCTAssertEqual(priceLines.count, 2)
        XCTAssertEqual(priceLines[0].start.x, 0, accuracy: 0.001)
        XCTAssertEqual(
            priceLines[0].end.x,
            marker.left,
            accuracy: 0.001
        )
        XCTAssertEqual(
            priceLines[1].start.x,
            marker.right,
            accuracy: 0.001
        )
        XCTAssertEqual(
            priceLines[1].end.x,
            Float(viewport.widthPixels),
            accuracy: 0.001
        )
        XCTAssertEqual(
            priceLines[0].start.y,
            priceLines[1].start.y,
            accuracy: 0.001
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
        XCTAssertEqual(priceLines.count, 2)
        XCTAssertEqual(priceLines[0].start.x, 0, accuracy: 0.001)
        XCTAssertEqual(
            priceLines[0].end.x,
            marker.left,
            accuracy: 0.001
        )
        XCTAssertEqual(
            priceLines[1].start.x,
            marker.right,
            accuracy: 0.001
        )
        XCTAssertEqual(
            priceLines[1].end.x,
            Float(viewport.widthPixels),
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(
            marker.right,
            output.panelLayout.plotRight + 3.001
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

    func testTallerPricePlotPreservesCandleProportionsAndZoom() async throws {
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
            XCTAssertGreaterThan(tallerSpan, originalSpan)
            XCTAssertEqual(
                Double(originalPlot.height) / originalSpan,
                Double(tallerPlot.height) / tallerSpan,
                accuracy: 0.000_001
            )
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
                    before.closeY - before.openY,
                    accuracy: 0.002
                )
                XCTAssertEqual(
                    after.lowY - after.highY,
                    before.lowY - before.highY,
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
        let latestPriceTimelineBatch = try XCTUnwrap(
            state.liveTail.batches.first {
                $0.coordinateSpace == .latestPriceTimelineLine
            }
        )
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
                abs($0.color.alpha - 0.01) < 0.000_1
            }.isEmpty
        )
        XCTAssertEqual(liveBatch.storage.candleInstances.count, 1)
        XCTAssertGreaterThanOrEqual(
            liveBatch.storage.lineSegments.count,
            3
        )
        XCTAssertEqual(latestPriceBatch.storage.barInstances.count, 1)
        XCTAssertEqual(latestPriceBatch.storage.lineSegments.count, 21)
        XCTAssertEqual(
            latestPriceTimelineBatch.storage.lineSegments.count,
            1
        )
        XCTAssertEqual(
            latestPriceBatch.storage.barInstances.first?.color,
            .latestPriceMarkerBackground
        )
        XCTAssertEqual(
            latestPriceTimelineBatch.storage.lineSegments.first?.color,
            .latestPriceLine
        )
        XCTAssertGreaterThan(
            latestPriceTimelineBatch.storage.lineSegments.first?
                .dashLength ?? 0,
            0
        )
        let latestPriceTimelineLine = try XCTUnwrap(
            latestPriceTimelineBatch.storage.lineSegments.first
        )
        let latestCandleX = try XCTUnwrap(
            liveBatch.storage.candleInstances.first?.x
        )
        XCTAssertEqual(
            latestPriceTimelineLine.start.x,
            latestCandleX
        )
        XCTAssertEqual(
            latestPriceTimelineLine.end.x,
            output.panelLayout.plotRight + Float(viewport.displayScale),
            accuracy: 0.001
        )
        XCTAssertEqual(
            state.staticScene.horizontalPlotBounds,
            ChartHorizontalPlotBounds(
                left: 0,
                right: Float(viewport.widthPixels)
            )
        )
        let roundedMarkerBorder = Array(
            latestPriceBatch.storage.lineSegments.dropFirst()
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
                && $0.top == layout.timeAxisTop
                && $0.bottom == layout.timeAxisBottom
        }
        XCTAssertEqual(timeLabels.count, 1)
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
            "SUPERTREND(14,3.5)"
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

    func testDrawingRegistryDraftProjectionHitAndCompilation() {
        let registry = ChartDrawingToolRegistry.standard
        XCTAssertEqual(
            registry.descriptors.map(\.id),
            [
                "horizontal-line",
                "range-measure",
                "ray",
                "trend-line",
                "vertical-line",
            ]
        )
        let first = ChartAnchor(
            openTime: 3_600_000,
            price: Decimal(101)
        )!
        let second = ChartAnchor(
            openTime: 7_200_000,
            price: Decimal(103)
        )!
        var draft = ChartDrawingDraft()
        XCTAssertTrue(draft.begin(toolID: "trend-line"))
        XCTAssertNil(draft.append(first))
        let annotation = draft.append(second)!
        XCTAssertTrue(registry.validates(annotation))

        let coordinates = RelativeChartCoordinateSpace(
            timeOrigin: 0,
            priceOrigin: 100,
            intervalMilliseconds: 3_600_000,
            pixelsPerSlot: 20,
            pixelsPerPriceUnit: 10
        )!
        let projection = ChartDrawingProjection(
            coordinateSpace: coordinates,
            plot: ChartPanelRect(
                left: 0,
                top: 0,
                right: 300,
                bottom: 200
            )
        )
        let projectedFirst = projection.point(for: first)!
        XCTAssertEqual(projectedFirst.x, 20, accuracy: 0.001)
        XCTAssertEqual(projectedFirst.y, 10, accuracy: 0.001)
        XCTAssertEqual(
            coordinates.openTime(screenX: projectedFirst.x),
            first.openTime
        )
        XCTAssertEqual(
            coordinates.price(screenY: projectedFirst.y)!,
            first.doublePrice,
            accuracy: 0.000_001
        )

        let hit = ChartDrawingHitTester.nearest(
            point: ChartDrawingPoint(x: 30, y: 21),
            annotations: [annotation],
            projection: projection,
            tolerancePoints: 4
        )
        XCTAssertEqual(hit?.annotationID, annotation.id)
        XCTAssertNil(hit?.anchorIndex)
        let segments = ChartDrawingSceneCompiler.lineSegments(
            annotations: [annotation],
            projection: projection
        )
        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy(\.antialias))
    }

    func testDrawingEditorLocksMovesAndUndoRedoAreBounded() {
        let first = ChartAnchor(openTime: 0, price: Decimal(100))!
        let second = ChartAnchor(
            openTime: 3_600_000,
            price: Decimal(101)
        )!
        let moved = ChartAnchor(
            openTime: 3_600_000,
            price: Decimal(105)
        )!
        let annotation = ChartAnnotation(
            toolID: "trend-line",
            anchors: [first, second]
        )!
        var editor = ChartAnnotationEditor(
            document: ChartAnnotationDocument(stream: stream),
            historyLimit: 2
        )
        XCTAssertTrue(editor.create(annotation))
        editor.select(annotation.id)
        XCTAssertTrue(editor.moveAnchor(
            annotationID: annotation.id,
            anchorIndex: 1,
            to: moved
        ))
        XCTAssertTrue(editor.setLocked(true, id: annotation.id))
        XCTAssertFalse(editor.remove(id: annotation.id))
        XCTAssertFalse(editor.moveAnchor(
            annotationID: annotation.id,
            anchorIndex: 1,
            to: second
        ))
        XCTAssertTrue(editor.undo())
        XCTAssertFalse(editor.document.annotations[0].isLocked)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(
            editor.document.annotations[0].anchors[1],
            second
        )
        XCTAssertTrue(editor.redo())
        XCTAssertEqual(
            editor.document.annotations[0].anchors[1],
            moved
        )
    }

    func testDrawingPersistenceIsAtomicAndCorruptionPreservesMemory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChartAnnotationJSONStore(directoryURL: directory)
        let anchor = ChartAnchor(openTime: 0, price: Decimal(100))!
        let annotation = ChartAnnotation(
            toolID: "horizontal-line",
            anchors: [anchor]
        )!
        let document = ChartAnnotationDocument(
            stream: stream,
            annotations: [annotation]
        )
        try store.save(document)
        XCTAssertEqual(try store.load(stream: stream), document)

        try Data("not-json".utf8).write(
            to: store.fileURL(for: stream),
            options: .atomic
        )
        XCTAssertEqual(
            store.load(stream: stream, preserving: document),
            document
        )
        XCTAssertThrowsError(try store.load(stream: stream))
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
