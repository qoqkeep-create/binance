import Combine
import Metal
import Network
import SwiftUI
import UIKit
import XCTest
@testable import TradeTool

final class AppearanceTests: XCTestCase {
    @MainActor
    func testPositionAndSelectedTradeTickersSurviveFavoritesAndSearchSubscriptionChanges() async throws {
        let ready = expectation(description: "Loopback ready")
        let peer = try LatencySocketPeer(ready: ready, pings: [])
        peer.start()
        defer { peer.stop() }
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(peer.port)
        let client = RealtimeClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, tokenProvider: { "isolated-test" })
        let markets = (0..<210).map {
            MarketSnapshot(symbol: "TEST\($0)USDT", quoteAsset: "USDT", price: 1,
                changePercent24h: 0, updatedAt: .distantPast)
        }
        let model = DashboardViewModel(markets: markets, realtimeClient: client)
        model.startRealtime(userID: "test")
        defer { model.stopRealtime(); client.disconnect() }
        model.trackPositionTickerSymbols(["HOLDUSDT"])
        model.trackTradeTickerSymbol("SELECTEDUSDT")
        let received = expectation(description: "Selected quote over real WSS")
        let observation = model.$realtimeTickerRevision.dropFirst().filter { _ in
            model.tradeQuote(for: "SELECTEDUSDT") == "123.45"
        }.prefix(1).sink { _ in received.fulfill() }
        defer { observation.cancel() }
        client.connect()
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(peer.tickerSymbols.count, 200)
        XCTAssertEqual(Array(peer.tickerSymbols.prefix(2)), ["HOLDUSDT", "SELECTEDUSDT"])
        model.trackSearchTickerSymbols((0..<210).map { "SEARCH\($0)USDT" })
        model.stopTrackingSearchTickers()
        model.hideMarkets(Set(markets.map(\.symbol)))
        client.unsubscribe(channels: ["market.ticker"])
        model.restoreRealtimeSubscriptions()
        XCTAssertEqual(model.tradeQuote(for: "SELECTEDUSDT"), "123.45")
        let next = expectation(description: "New selected quote")
        let nextObservation = model.$realtimeTickerRevision.dropFirst().filter { _ in
            model.tradeQuote(for: "NEXTUSDT") == "234.56"
        }.prefix(1).sink { _ in next.fulfill() }
        defer { nextObservation.cancel() }
        model.trackTradeTickerSymbol("NEXTUSDT")
        await fulfillment(of: [next], timeout: 5)
        XCTAssertEqual(peer.tickerSymbols, ["HOLDUSDT", "NEXTUSDT"])
    }

    @MainActor
    func testAppearanceDefaultsToLightAndRestoresSavedSelection() throws {
        let suite = "AppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = AppStorage(
            wrappedValue: AppAppearance.defaultValue,
            AppAppearance.storageKey,
            store: defaults
        )
        XCTAssertEqual(selection.wrappedValue, .light)
        selection.wrappedValue = .dark
        let restored = AppStorage(
            wrappedValue: AppAppearance.defaultValue,
            AppAppearance.storageKey,
            store: defaults
        )
        XCTAssertEqual(restored.wrappedValue, .dark)
        selection.wrappedValue = .light
        XCTAssertEqual(defaults.string(forKey: AppAppearance.storageKey), "light")
    }

    @MainActor
    func testSemanticTextHasContrastInBothAppearances() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let background = resolved(BinanceTheme.background, style: style)
            for token in [BinanceTheme.primaryText, BinanceTheme.secondaryText,
                          BinanceTheme.accentText, BinanceTheme.positive,
                          BinanceTheme.negative] {
                XCTAssertGreaterThanOrEqual(
                    contrast(resolved(token, style: style), background), 4.5
                )
            }
            for token in [BinanceTheme.positive, BinanceTheme.negative, BinanceTheme.accentText] {
                XCTAssertGreaterThanOrEqual(
                    contrast(resolved(BinanceTheme.onColor, style: style),
                             resolved(token, style: style)), 4.5
                )
            }
            XCTAssertGreaterThanOrEqual(
                contrast(resolved(BinanceTheme.onAccent, style: style),
                         resolved(BinanceTheme.accent, style: style)), 4.5
            )
        }
    }

    func testChartResolutionPreservesOpacityAndCustomIndicatorColors() throws {
        let transparent = ChartColor.primaryText.withAlpha(0.37)
        XCTAssertEqual(transparent.resolved(for: .dark), transparent)
        XCTAssertEqual(transparent.resolved(for: .light).alpha, 0.37)
        XCTAssertLessThan(transparent.resolved(for: .light).red, 0.2)
        let custom = try XCTUnwrap(ChartColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 0.6))
        XCTAssertEqual(custom.resolved(for: .light), custom)
        XCTAssertEqual(ChartColor.ema55.resolved(for: .light), .ema55)
        XCTAssertEqual(ChartColor.ema144.resolved(for: .light), .ema144)
    }

    func testChartAxisLabelsKeepOppositeTextAndBackground() {
        for appearance in [ChartAppearance.light, .dark] {
            let text = ChartColor.crosshairAxisLabelText.resolved(for: appearance)
            let background = ChartColor.crosshairAxisLabelBackground.resolved(for: appearance)
            XCTAssertGreaterThan(abs(text.red - background.red), 0.8)
            XCTAssertNotEqual(ChartColor.grid.resolved(for: appearance),
                              ChartColor.chartBackground.resolved(for: appearance))
        }
    }

    func testChangingAppearanceSharesSnapshotsAndKeepsRevisionAndTiming() {
        let state = scene()
        let light = state.withAppearance(.light)
        XCTAssertEqual(light.appearance, .light)
        XCTAssertTrue(light.staticScene === state.staticScene)
        XCTAssertTrue(light.liveTail === state.liveTail)
        XCTAssertTrue(light.interaction === state.interaction)
        XCTAssertEqual(light.revision, state.revision)
        XCTAssertEqual(light.readyTime, state.readyTime)
    }

    @MainActor
    func testMetalRendersBothThemesForTheSameSceneRevision() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let renderer = try MetalRenderer(device: device, pixelFormat: .bgra8Unorm_srgb)
        let state = scene()
        let dark = try XCTUnwrap(renderer.renderOffscreen(state: state, width: 16, height: 16))
        let light = try XCTUnwrap(renderer.renderOffscreen(
            state: state.withAppearance(.light), width: 16, height: 16
        ))
        for (rendered, style) in [(dark, UIUserInterfaceStyle.dark), (light, .light)] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            resolved(BinanceTheme.background, style: style).getRed(
                &red, green: &green, blue: &blue, alpha: &alpha
            )
            for (channel, expected) in [blue, green, red, alpha].enumerated() {
                XCTAssertEqual(
                    Double(rendered.bgra8UnormSRGB[channel]) / 255,
                    Double(expected), accuracy: 1.0 / 255,
                    "Metal canvas must match the surrounding SwiftUI background"
                )
            }
        }
        let darkCenter = 8 * dark.bytesPerRow + 8 * 4
        let lightCenter = 8 * light.bytesPerRow + 8 * 4
        XCTAssertGreaterThan(dark.bgra8UnormSRGB[darkCenter], 220)
        XCTAssertLessThan(light.bgra8UnormSRGB[lightCenter], 40)
        XCTAssertNotEqual(dark.visiblePixelHash, light.visiblePixelHash)
    }

    private func scene() -> RenderState {
        RenderState(
            staticScene: StaticSceneSnapshot(
                revision: 1,
                candleHistory: ChartCandleHistory(candles: []),
                batches: [ChartRenderBatch(barInstances: [ChartBarInstance(
                    left: 4, top: 4, right: 12, bottom: 12, color: .primaryText
                )], coordinateSpace: .fixed)]
            ),
            liveTail: LiveTailSnapshot(revision: 1, candle: nil, batches: [], latestPrice: nil),
            interaction: InteractionSnapshot(
                revision: 1, translationX: 0, scaleX: 1, crosshair: nil
            ),
            invalidation: .full
        )
    }

    @MainActor
    private func resolved(_ color: Color, style: UIUserInterfaceStyle) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    private func contrast(_ first: UIColor, _ second: UIColor) -> Double {
        func luminance(_ color: UIColor) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let values = [r, g, b].map { value -> Double in
                let component = Double(value)
                return component <= 0.04045
                    ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
        }
        let lhs = luminance(first), rhs = luminance(second)
        return (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
    }
}

@MainActor
final class NetworkLatencyAndModalTests: XCTestCase {
  func testLatencyDistinguishesMissingSamplesFromMeasuredNumbers() {
    XCTAssertEqual(RealtimeLatency.unavailable.text, "-- ms")
    XCTAssertEqual(RealtimeLatency.measuring.text, "测量中")
    XCTAssertEqual(RealtimeLatency.measured(86.4).text, "86 ms")
    XCTAssertEqual(RealtimeLatency.measured(998.8).text, "999 ms")
    XCTAssertEqual(RealtimeLatency.measured(2_500).text, "999 ms")
    XCTAssertEqual(RealtimeLatency.measured(-1).text, "0 ms")
    XCTAssertEqual(RealtimeLatency.measured(.infinity).text, "999 ms")
  }

  func testAutomaticSamplingDoesNotReplaceASlowInFlightPing() {
    let start = ContinuousClock.now
    var tracker = RealtimeLatencyTracker()
    tracker.begin(id: "slow", at: start)
    tracker.begin(id: "next-tick", at: start.advanced(by: .seconds(2)))
    tracker.receive(id: "slow", at: start.advanced(by: .milliseconds(2_500)))
    XCTAssertEqual(tracker.reading, .measured(2_500))
  }

  func testRealSocketMeasuresPongAndRepeatedConnectKeepsSampling() async throws {
    let ready = expectation(description: "Loopback WebSocket listening")
    let ping = expectation(description: "Application ping received")
    let measured = expectation(description: "Real socket RTT measured")
    let nextPing = expectation(description: "Monitoring survives repeated connect")
    let peer = try LatencySocketPeer(ready: ready, pings: [ping])
    peer.start()
    defer { peer.stop() }
    await fulfillment(of: [ready], timeout: 3)
    let port = try XCTUnwrap(peer.port)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let client = RealtimeClient(baseURL: URL(string: "http://127.0.0.1:\(port)/integrated")!,
      session: session, tokenProvider: { "isolated-test-token" })
    let observation = client.$latency.filter { value in
      if case .measured = value { return true }; return false
    }.prefix(1).sink { _ in measured.fulfill() }
    defer { observation.cancel(); client.disconnect() }
    client.setLatencyMonitoring(true)
    client.connect()
    await fulfillment(of: [ping, measured], timeout: 5)
    guard case let .measured(milliseconds) = client.latency else {
      return XCTFail("A real matching pong must replace the unavailable value")
    }
    // The peer delays its pong by 120 ms; this must be measured, not a fixture constant.
    XCTAssertGreaterThanOrEqual(milliseconds, 100)
    XCTAssertLessThan(milliseconds, 3_000)
    XCTAssertEqual(client.state, .connected)
    let previousReading = client.latency
    client.requestLatencyTest()
    XCTAssertEqual(client.latency, previousReading, "Refreshing must retain the last measured value")
    XCTAssertTrue(client.isTestingLatency)
    let refreshed = expectation(description: "Matching pong completes manual refresh")
    let refreshObservation = client.$isTestingLatency.dropFirst().filter { !$0 }.prefix(1)
      .sink { _ in refreshed.fulfill() }
    defer { refreshObservation.cancel() }
    await DashboardViewModel(realtimeClient: client).refresh()
    XCTAssertEqual(client.state, .connected, "Pull to refresh must keep a healthy socket open")
    XCTAssertEqual(client.latency, previousReading)
    XCTAssertTrue(client.isTestingLatency)
    await fulfillment(of: [refreshed], timeout: 3)
    XCTAssertFalse(client.isTestingLatency)
    guard case .measured = client.latency else { return XCTFail("Refresh must install the new RTT") }
    peer.expectNextPing(nextPing)
    client.connect()
    XCTAssertEqual(client.state, .connected)
    await fulfillment(of: [nextPing], timeout: 7)
  }

  func testOnlyMatchingPongCompletesTheCurrentMonotonicSample() {
    let start = ContinuousClock.now
    var tracker = RealtimeLatencyTracker()
    tracker.begin(id: "current", at: start)
    tracker.receive(id: "previous", at: start.advanced(by: .milliseconds(20)))
    XCTAssertEqual(tracker.reading, .measuring)
    tracker.receive(id: "current", at: start.advanced(by: .milliseconds(86)))
    XCTAssertEqual(tracker.reading, .measured(86))
    tracker.receive(id: "current", at: start.advanced(by: .seconds(1)))
    XCTAssertEqual(tracker.reading, .measured(86))
  }

  func testRollingMedianLimitsSingleSpikeWithoutHidingPersistentLatency() {
    var tracker = RealtimeLatencyTracker()
    let start = ContinuousClock.now
    for (index, sample) in [100, 200, 900, 400, 800].enumerated() {
      let sent = start.advanced(by: .seconds(index * 5))
      tracker.begin(id: String(index), at: sent)
      tracker.receive(id: String(index), at: sent.advanced(by: .milliseconds(sample)))
      XCTAssertEqual(tracker.reading, .measured([100, 150, 200, 400, 800][index]))
    }
  }

  func testTimeoutAndConnectionResetDiscardOldGreenSamplesAndLatePongs() {
    var tracker = RealtimeLatencyTracker()
    let start = ContinuousClock.now
    tracker.begin(id: "fast", at: start)
    tracker.receive(id: "fast", at: start.advanced(by: .milliseconds(10)))
    tracker.begin(id: "lost", at: start.advanced(by: .seconds(5)))
    tracker.expire(at: start.advanced(by: .seconds(8)))
    XCTAssertEqual(tracker.reading, .unavailable)
    tracker.receive(id: "lost", at: start.advanced(by: .seconds(9)))
    XCTAssertEqual(tracker.reading, .unavailable)
    tracker.begin(id: "old-connection", at: start.advanced(by: .seconds(10)))
    tracker.reset()
    tracker.receive(id: "old-connection", at: start.advanced(by: .milliseconds(10_100)))
    XCTAssertEqual(tracker.reading, .measuring)
  }

  func testLatencyColorBoundariesAndUnavailableState() {
    XCTAssertEqual(RealtimeLatency.measured(199).quality, .good)
    XCTAssertEqual(RealtimeLatency.measured(200).quality, .fair)
    XCTAssertEqual(RealtimeLatency.measured(499).quality, .fair)
    XCTAssertEqual(RealtimeLatency.measured(500).quality, .poor)
    XCTAssertEqual(RealtimeLatency.unavailable.quality, .poor)
    XCTAssertEqual(RealtimeLatencyTracker.sampleInterval, .seconds(2))
  }

  func testSmallDialogsFadeAndLargePanelsSlideUnlessReducedMotionIsEnabled() {
    XCTAssertEqual(WebModalMotion.resolve(cardHeight: 240, containerHeight: 800, reduceMotion: false), .fade)
    XCTAssertEqual(WebModalMotion.resolve(cardHeight: 600, containerHeight: 800, reduceMotion: false), .slide)
    XCTAssertEqual(WebModalMotion.resolve(cardHeight: 600, containerHeight: 800, reduceMotion: true), .fade)
    XCTAssertEqual(WebModalMotion.resolve(cardHeight: 600, containerHeight: 800, reduceMotion: false,
      preferred: .fade), .fade)
    XCTAssertLessThan(WebModalMotion.slide.openingDuration, 0.28)
  }

  func testLaunchStoryboardUses96PointContinuousRoundedIcon() throws {
    let controller = try XCTUnwrap(UIStoryboard(name: "BrandLaunchScreen", bundle: Bundle(for: AuthStore.self))
      .instantiateInitialViewController())
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
    controller.view.layoutIfNeeded()
    let image = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UIImageView }.first)
    XCTAssertEqual(image.frame.size, CGSize(width: 96, height: 96))
    XCTAssertTrue(image.clipsToBounds)
    let source = try XCTUnwrap(image.image?.cgImage)
    var pixels = [UInt8](repeating: 0, count: 96 * 96 * 4)
    try pixels.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 96, height: 96,
        bitsPerComponent: 8, bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
      context.draw(source, in: CGRect(x: 0, y: 0, width: 96, height: 96))
    }
    XCTAssertEqual(pixels[3], 0, "System launch screens need the rounded mask in the asset itself")
    XCTAssertEqual(pixels[(48 * 96 + 48) * 4 + 3], 255)
  }
}

/// A real loopback WebSocket peer; no production account, HTTP stub or fixture RTT is used.
private final class LatencySocketPeer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "test.latency-socket")
  private var connections: [NWConnection] = []
  private var pings: [XCTestExpectation]
  private var lastTickerSymbols: [String] = []
  var tickerSymbols: [String] { queue.sync { lastTickerSymbols } }
  var port: UInt16? { listener.port?.rawValue }

  init(ready: XCTestExpectation, pings: [XCTestExpectation]) throws {
    self.pings = pings
    let parameters = NWParameters.tcp
    let websocket = NWProtocolWebSocket.Options()
    websocket.autoReplyPing = true
    parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.fulfill() }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      self.connections.append(connection)
      connection.stateUpdateHandler = { [weak self] state in
        guard case .ready = state else { return }
        self?.send(["version": 1, "type": "ready", "timestamp": 0], to: connection)
        self?.receive(from: connection)
      }
      connection.start(queue: self.queue)
    }
  }

  func start() { listener.start(queue: queue) }
  func expectNextPing(_ expectation: XCTestExpectation) { queue.sync { pings.append(expectation) } }
  func stop() {
    queue.sync {
      listener.cancel()
      connections.forEach { $0.cancel() }
    }
  }

  private func receive(from connection: NWConnection) {
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let self, error == nil, let data else { return }
      if let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         message["type"] as? String == "ping", let id = message["requestId"] as? String {
        if !self.pings.isEmpty { self.pings.removeFirst().fulfill() }
        self.queue.asyncAfter(deadline: .now() + .milliseconds(120)) {
          self.send(["version": 1, "type": "pong", "timestamp": 0, "requestId": id], to: connection)
        }
      }
      if let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         message["type"] as? String == "subscribe",
         let subscriptions = message["subscriptions"] as? [[String: Any]] {
        for subscription in subscriptions where subscription["channel"] as? String == "market.ticker" {
          let filters = subscription["filters"] as? [String: Any]
          self.lastTickerSymbols = filters?["symbols"] as? [String] ?? []
          for symbol in self.lastTickerSymbols where symbol == "SELECTEDUSDT" || symbol == "NEXTUSDT" {
            self.send(["version": 1, "type": "event", "channel": "market.ticker", "event": "updated",
              "timestamp": 0, "data": ["symbol": symbol, "lastPrice": symbol == "SELECTEDUSDT" ? 123.45 : 234.56,
                "quoteVolume24h": 1, "priceChangePercent24h": 1, "eventTime": 2_000_000_000_000]], to: connection)
          }
        }
      }
      self.receive(from: connection)
    }
  }

  private func send(_ message: [String: Any], to connection: NWConnection) {
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "latency-test", metadata: [metadata])
    connection.send(content: try? JSONSerialization.data(withJSONObject: message),
      contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
  }
}

final class WebParityFormattingTests: XCTestCase {
  func testStopLossPreviewRoundsAcrossWebStepBoundaries() {
    let examples = [
      ("0", "1"), ("19.01", "20"), ("20", "20"), ("20.01", "25"), ("99.01", "100"), ("100", "100"),
      ("100.01", "110"),
    ]
    for (input, expected) in examples {
      XCTAssertEqual(
        WebStopLossAmount.roundUp(Decimal(string: input)!), Decimal(string: expected)!, input)
    }
  }
  func testRecordTimesAcceptFractionalISOAndExchangeMilliseconds() throws {
    let fractional = try XCTUnwrap(WebFormat.date("2026-10-31T02:00:00.123Z"))
    let milliseconds = String(Int64((fractional.timeIntervalSince1970 * 1000).rounded()))
    XCTAssertEqual(
      try XCTUnwrap(WebFormat.date(milliseconds)).timeIntervalSince1970,
      fractional.timeIntervalSince1970, accuracy: 0.001)
    XCTAssertNotNil(WebFormat.date("2026-10-31T02:00:00Z"))
    XCTAssertNil(WebFormat.date("--"))
  }
}
