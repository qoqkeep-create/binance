import Combine
import Metal
import Network
import SwiftUI
import UIKit
import XCTest
@testable import TradeTool

@MainActor
final class WebModalRenderingTests: XCTestCase {
  func testTallFadeDialogsKeepTheirMotion() {
    for height: CGFloat in [200, 650] {
      let motion = WebModalMotion.resolve(cardHeight: height, containerHeight: 800,
        reduceMotion: false, preferred: .fade)
      XCTAssertEqual(motion, .fade, "Loading execution records must not turn a tall dialog into a slide")
      let transition = WebModalTransitionState(motion: motion, progress: 0.5, drag: 0, containerHeight: 800)
      XCTAssertEqual(transition.cardOffset, 0)
      XCTAssertEqual(transition.cardOpacity, 0.5)
    }
  }

  func testCardAndBackdropFadeTogetherWithoutChangingTheirFrames() throws {
    for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
      let transition = WebModalTransitionState(motion: .fade, progress: progress, drag: 0, containerHeight: 100)
      let content = ZStack {
        WebModalBackdrop(opacity: 0.6)
        Color.white.frame(width: 20, height: 20).webModalCard()
      }.frame(width: 100, height: 100)
        .modifier(WebModalVisuals(motion: .fade, transition: transition, underlying: 0))
      let renderer = ImageRenderer(content: content)
      let image = try XCTUnwrap(renderer.cgImage)
      var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
      try pixels.withUnsafeMutableBytes { bytes in
        let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      }
      func pixel(_ x: Int, _ y: Int, _ channel: Int) -> Int { Int(pixels[(y * image.width + x) * 4 + channel]) }
      XCTAssertEqual(Double(pixel(50, 50, 3)), Double(progress) * 255, accuracy: 2)
      XCTAssertEqual(Double(pixel(10, 10, 3)), Double(progress) * 0.6 * 255, accuracy: 2)
      XCTAssertEqual(pixel(50, 50, 0), pixel(50, 50, 3), "The card stays centered throughout the fade")
      XCTAssertEqual(pixel(50, 85, 0), 0, "No card pixels may slide down into the backdrop")
    }
  }
}

final class AppearanceTests: XCTestCase {
    @MainActor
    func testPositionOperationsUseTheSharedFadePresenter() {
      for status in ["0", "1", "2"] {
        for action in ["strategy", "strategyLog", "breakEven", "takeProfit", "close"] {
          let operation = WebPositionOperation(position: .object(["strategy_status": .string(status)]), action: action)
            XCTAssertFalse(operation.usesNativeSheet,
              "All position operations must use the shared in-place fade presenter")
        }
      }
    }

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

  func testForegroundReconnectReplacesAnExistingSocketImmediately() async throws {
    let ready = expectation(description: "Loopback WebSocket listening")
    let peer = try LatencySocketPeer(ready: ready, pings: [])
    peer.start()
    defer { peer.stop() }
    await fulfillment(of: [ready], timeout: 3)
    let port = try XCTUnwrap(peer.port)
    let client = RealtimeClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!,
      session: URLSession(configuration: .ephemeral), tokenProvider: { "foreground-token" })
    defer { client.disconnect() }

    let firstReady = expectation(description: "Initial socket ready")
    let foregroundReady = expectation(description: "Foreground socket ready")
    var readyCount = 0
    let observation = client.$state.sink { state in
      guard state == .connected else { return }
      readyCount += 1
      if readyCount == 1 { firstReady.fulfill() }
      if readyCount == 2 { foregroundReady.fulfill() }
    }
    defer { observation.cancel() }
    client.connect()
    await fulfillment(of: [firstReady], timeout: 3)

    // The app foreground handler uses the same explicit reconnect path. It
    // must cancel a healthy-or-stale task and bypass any pending 30s backoff.
    client.reconnect()
    await fulfillment(of: [foregroundReady], timeout: 1.5)
    XCTAssertEqual(client.state, .connected)
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
    XCTAssertEqual(WebModalMotion.resolve(cardHeight: 0, containerHeight: 0, reduceMotion: false), .fade)
    XCTAssertEqual(WebModalMotion.resolve(cardHeight: 240, containerHeight: 0, reduceMotion: false), .fade)
    XCTAssertEqual(WebModalMotion.resolve(cardHeight: 240, containerHeight: 800, reduceMotion: false), .fade)
    XCTAssertEqual(WebModalMotion.resolve(cardHeight: 600, containerHeight: 800, reduceMotion: false), .slide)
    XCTAssertEqual(WebModalMotion.resolve(cardHeight: 600, containerHeight: 800, reduceMotion: true), .fade)
    XCTAssertEqual(WebModalMotion.resolve(cardHeight: 600, containerHeight: 800, reduceMotion: false,
      preferred: .fade), .fade)
    XCTAssertEqual(WebModalMotion.resolve(cardHeight: 600, containerHeight: 800, reduceMotion: true,
      preferred: .slide), .fade)
    XCTAssertLessThan(WebModalMotion.slide.openingDuration, 0.28)
  }

  func testModalFadeKeepsCardAndBackdropAtTheSameProgress() {
    // Both directions use the same path, including a partially dragged dialog.
    for progress in [CGFloat(0), 0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25, 0] {
      let state = WebModalTransitionState(motion: .fade, progress: progress,
        drag: 0, containerHeight: 800)
      XCTAssertEqual(state.cardOffset, 0)
      XCTAssertEqual(state.phase, progress)
      XCTAssertEqual(state.cardOpacity, Double(state.phase))
    }
    let dragged = WebModalTransitionState(motion: .fade, progress: 1,
      drag: 200, containerHeight: 800)
    XCTAssertEqual(dragged.cardOffset, 0)
    XCTAssertEqual(dragged.phase, 0.75)
    XCTAssertEqual(dragged.cardOpacity, 0.75)
  }

  func testModalSlideOnlyMovesTheLargeCardAndStartsHiddenUntilMeasured() {
    for progress in [CGFloat(0), 0.5, 1] {
      let unknown = WebModalTransitionState(motion: nil, progress: progress,
        drag: 0, containerHeight: 800)
      XCTAssertEqual(unknown.cardOffset, 0)
      XCTAssertEqual(unknown.cardOpacity, 0)
      XCTAssertEqual(unknown.phase, 0)
    }
    let unmeasured = WebModalTransitionState(motion: .slide, progress: 1,
      drag: 0, containerHeight: 0)
    XCTAssertEqual(unmeasured.cardOffset, 0)
    XCTAssertEqual(unmeasured.cardOpacity, 0)
    XCTAssertEqual(unmeasured.phase, 0)
    let large = WebModalTransitionState(motion: .slide, progress: 0.5,
      drag: 0, containerHeight: 800)
    XCTAssertEqual(large.cardOffset, 400)
    XCTAssertEqual(large.cardOpacity, 1)
    XCTAssertEqual(large.phase, 0.5)
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

  func testAppLaunchMatchesSystemLaunchAcrossAsymmetricSafeAreas() throws {
    let controller = try XCTUnwrap(UIStoryboard(name: "BrandLaunchScreen", bundle: Bundle(for: AuthStore.self))
      .instantiateInitialViewController())
    controller.loadViewIfNeeded()
    let mark = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UIImageView }.first?.image)
    let cases: [(CGSize, EdgeInsets)] = [
      (CGSize(width: 393, height: 852), EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)),
      (CGSize(width: 402, height: 874), EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)),
      (CGSize(width: 852, height: 393), EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 21)),
    ]
    for (size, insets) in cases {
      for scheme in [ColorScheme.light, .dark] {
        let actual = ImageRenderer(content: AppLaunchView()
          .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: insets.top) }
          .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: insets.bottom) }
          .safeAreaInset(edge: .leading, spacing: 0) { Color.clear.frame(width: insets.leading) }
          .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: insets.trailing) }
          .frame(width: size.width, height: size.height)
          .environment(\.colorScheme, scheme))
        let reference = ImageRenderer(content: ZStack {
          Color.white
          Image(uiImage: mark).resizable().scaledToFit().frame(width: 96, height: 96)
        }.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme))
        actual.scale = 1
        reference.scale = 1
        let actualImage = try XCTUnwrap(actual.cgImage)
        let referenceImage = try XCTUnwrap(reference.cgImage)
        XCTAssertEqual(actualImage.width, Int(size.width))
        XCTAssertEqual(actualImage.height, Int(size.height))
        XCTAssertTrue(try launchPixels(actualImage) == launchPixels(referenceImage),
          "App launch must retain the system launch artwork, size and full-window center: \(size), \(scheme)")
      }
    }
  }

  private func launchPixels(_ image: CGImage) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try pixels.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return pixels
  }
}

/// A real loopback WebSocket peer; no production account, HTTP stub or fixture RTT is used.
private final class LatencySocketPeer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "test.latency-socket")
  private var connections: [NWConnection] = []
  private var pings: [XCTestExpectation]
  private var lastTickerSymbols: [String] = []
  private var mutedConnections: Set<ObjectIdentifier> = []
  private let holdsFirstReady: Bool
  var tickerSymbols: [String] { queue.sync { lastTickerSymbols } }
  var connectionCount: Int { queue.sync { connections.count } }
  var port: UInt16? { listener.port?.rawValue }

  init(ready: XCTestExpectation, pings: [XCTestExpectation], holdsFirstReady: Bool = false) throws {
    self.pings = pings
    self.holdsFirstReady = holdsFirstReady
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
        if let self, !(self.holdsFirstReady && self.connections.first === connection) {
          self.send(["version": 1, "type": "ready", "timestamp": 0], to: connection)
        }
        self?.receive(from: connection)
      }
      connection.start(queue: self.queue)
    }
  }

  func start() { listener.start(queue: queue) }
  func expectNextPing(_ expectation: XCTestExpectation) { queue.sync { pings.append(expectation) } }
  func blackholeCurrentConnections() {
    queue.sync { mutedConnections.formUnion(connections.map(ObjectIdentifier.init)) }
  }
  func closeCurrentConnections() { queue.sync { connections.forEach { $0.cancel() } } }
  func closeUnauthorized() {
    queue.sync {
      for connection in connections {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .privateCode(4_401)
        let context = NWConnection.ContentContext(identifier: "test-expired", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true,
          completion: .contentProcessed { _ in })
      }
    }
  }
  func stop() {
    queue.sync {
      listener.cancel()
      connections.forEach { $0.cancel() }
    }
  }

  private func receive(from connection: NWConnection) {
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let self, error == nil, let data else { return }
      if self.mutedConnections.contains(ObjectIdentifier(connection)) {
        self.receive(from: connection)
        return
      }
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

@MainActor
final class NetworkRecoveryTests: XCTestCase {
  private final class Paths: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<RealtimeNetworkPath>.Continuation?
    func makeStream() -> AsyncStream<RealtimeNetworkPath> {
      let pair = AsyncStream<RealtimeNetworkPath>.makeStream()
      lock.lock(); defer { lock.unlock() }
      continuation = pair.continuation
      return pair.stream
    }
    func send(_ available: Bool, _ signature: String) {
      lock.lock(); let continuation = continuation; lock.unlock()
      continuation?.yield(RealtimeNetworkPath(available: available, signature: signature))
    }
  }

  func testNetworkHandoverReplacesBlackholedSocketAndRestoresSubscriptionsWithoutLatencyUI() async throws {
    let listening = expectation(description: "Recovery peer listening")
    let peer = try LatencySocketPeer(ready: listening, pings: [])
    peer.start()
    defer { peer.stop() }
    await fulfillment(of: [listening], timeout: 3)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let paths = Paths()
    let client = RealtimeClient(baseURL: URL(string: "http://127.0.0.1:\(try XCTUnwrap(peer.port))")!,
      session: session, networkPaths: { paths.makeStream() }, tokenProvider: { "isolated-recovery-test" })
    defer { client.disconnect() }
    let firstReady = expectation(description: "First socket ready")
    let recovered = expectation(description: "New path socket ready")
    var readyCount = 0
    let observation = client.$state.filter { $0 == .connected }.sink { _ in
      readyCount += 1
      if readyCount == 1 { firstReady.fulfill() }
      if readyCount == 2 { recovered.fulfill() }
    }
    defer { observation.cancel() }
    client.subscribe([.marketTicker(symbols: ["HOLDUSDT"])])
    client.connect()
    paths.send(true, "test-wifi")
    await fulfillment(of: [firstReady], timeout: 3)
    try await Task.sleep(for: .milliseconds(200))
    peer.blackholeCurrentConnections()
    paths.send(false, "test-offline")
    paths.send(true, "test-cellular")
    await fulfillment(of: [recovered], timeout: 1.5)
    XCTAssertEqual(peer.connectionCount, 2, "A restored path must not wait for the old socket's server timeout")
    XCTAssertEqual(peer.tickerSymbols, ["HOLDUSDT"])
    paths.send(true, "test-cellular")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(peer.connectionCount, 2, "Duplicate path events must not churn a healthy connection")
    client.disconnect()
    paths.send(false, "test-stopped-offline")
    paths.send(true, "test-stopped-online")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(client.state, .disconnected, "Connectivity must never reopen a signed-out or stopped client")
  }

  func testHandoverReplacesAConnectingSocketBeforeHandshakeTimeout() async throws {
    let listening = expectation(description: "Stalled ready peer listening")
    let peer = try LatencySocketPeer(ready: listening, pings: [], holdsFirstReady: true)
    peer.start()
    defer { peer.stop() }
    await fulfillment(of: [listening], timeout: 3)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let paths = Paths()
    let client = RealtimeClient(baseURL: URL(string: "http://127.0.0.1:\(try XCTUnwrap(peer.port))")!,
      session: session, networkPaths: { paths.makeStream() }, tokenProvider: { "isolated-connecting-test" })
    defer { client.disconnect() }
    let recovered = expectation(description: "Replacement handshake ready")
    let observation = client.$state.filter { $0 == .connected }.prefix(1).sink { _ in recovered.fulfill() }
    defer { observation.cancel() }
    client.connect()
    paths.send(true, "test-initial-interface")
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(peer.connectionCount, 1)
    XCTAssertEqual(client.state, .connecting)
    paths.send(true, "test-restored-interface")
    await fulfillment(of: [recovered], timeout: 1.5)
    XCTAssertEqual(peer.connectionCount, 2)
  }

  func testOfflinePausesTransportRetriesAndRestorationBypassesPendingBackoff() async throws {
    let listening = expectation(description: "Retry peer listening")
    let peer = try LatencySocketPeer(ready: listening, pings: [])
    peer.start()
    defer { peer.stop() }
    await fulfillment(of: [listening], timeout: 3)
    let paths = Paths()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let client = RealtimeClient(baseURL: URL(string: "http://127.0.0.1:\(try XCTUnwrap(peer.port))")!,
      session: session, networkPaths: { paths.makeStream() }, tokenProvider: { "isolated-retry-test" })
    defer { client.disconnect() }
    let initial = expectation(description: "Initial retry socket ready")
    let disconnected = expectation(description: "Transport ended")
    let recovered = expectation(description: "Recovered immediately")
    var hasConnected = false
    var recoveredOnce = false
    var observedDisconnect = false
    let observation = client.$state.sink { state in
      if state == .connected {
        if hasConnected && !recoveredOnce { recoveredOnce = true; recovered.fulfill() }
        else if !hasConnected { hasConnected = true; initial.fulfill() }
      } else if state == .disconnected && hasConnected && !recoveredOnce && !observedDisconnect {
        observedDisconnect = true
        disconnected.fulfill()
      }
    }
    defer { observation.cancel() }
    client.connect()
    paths.send(true, "test-wifi")
    await fulfillment(of: [initial], timeout: 3)
    peer.closeCurrentConnections()
    await fulfillment(of: [disconnected], timeout: 2)
    paths.send(false, "test-offline")
    try await Task.sleep(for: .milliseconds(1_500))
    XCTAssertEqual(peer.connectionCount, 1, "Offline time must not consume retry attempts or open more sockets")
    paths.send(true, "test-wifi")
    await fulfillment(of: [recovered], timeout: 0.75)
    XCTAssertEqual(peer.connectionCount, 2)
  }

  func testOldUnauthorizedSocketRefreshCannotCloseAReplacementConnection() async throws {
    let listening = expectation(description: "Expired session peer listening")
    let peer = try LatencySocketPeer(ready: listening, pings: [])
    peer.start()
    defer { peer.stop() }
    await fulfillment(of: [listening], timeout: 3)
    let paths = Paths()
    let events = NotificationCenter()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let client = RealtimeClient(baseURL: URL(string: "http://127.0.0.1:\(try XCTUnwrap(peer.port))")!,
      session: session, notificationCenter: events, networkPaths: { paths.makeStream() }, tokenProvider: { "isolated-session-test" })
    defer { client.disconnect() }
    let first = expectation(description: "Old session connected")
    let replacement = expectation(description: "Replacement session connected")
    let refreshStarted = expectation(description: "Old token refresh pending")
    let unauthorized = expectation(description: "Replacement session must not expire")
    unauthorized.isInverted = true
    let observer = events.addObserver(forName: .apiSessionUnauthorized, object: nil, queue: .main) { _ in unauthorized.fulfill() }
    defer { events.removeObserver(observer) }
    var refresh: CheckedContinuation<String, Error>?
    client.refreshAccessToken = {
      refreshStarted.fulfill()
      return try await withCheckedThrowingContinuation { refresh = $0 }
    }
    defer { refresh?.resume(throwing: CancellationError()) }
    var readyCount = 0
    let observation = client.$state.filter { $0 == .connected }.sink { _ in
      readyCount += 1
      if readyCount == 1 { first.fulfill() }
      if readyCount == 2 { replacement.fulfill() }
    }
    defer { observation.cancel() }
    client.connect()
    paths.send(true, "test-old-interface")
    await fulfillment(of: [first], timeout: 3)
    peer.closeUnauthorized()
    await fulfillment(of: [refreshStarted], timeout: 2)
    client.disconnect()
    client.connect()
    paths.send(true, "test-new-interface")
    await fulfillment(of: [replacement], timeout: 1.5)
    refresh?.resume(throwing: APIError.unauthorized(message: "old session superseded"))
    refresh = nil
    await fulfillment(of: [unauthorized], timeout: 0.15)
    XCTAssertEqual(client.state, .connected)
  }

  func testOfflineDisconnectAndForegroundInitialOnlineRestoreHTTPReads() async throws {
    let listening = expectation(description: "Foreground recovery peer listening")
    let peer = try LatencySocketPeer(ready: listening, pings: [])
    peer.start()
    defer { peer.stop() }
    await fulfillment(of: [listening], timeout: 3)
    RecoveryHTTPProtocol.reset(parked: 0)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecoveryHTTPProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let events = NotificationCenter()
    let paths = Paths()
    let api = URLSessionAPIClient(baseURL: URL(string: "https://network-recovery.invalid")!, session: session,
      notificationCenter: events, readRecovery: APIReadRecovery(notificationCenter: events))
    let client = RealtimeClient(baseURL: URL(string: "http://127.0.0.1:\(try XCTUnwrap(peer.port))")!,
      session: session, notificationCenter: events, networkPaths: { paths.makeStream() }, tokenProvider: { "isolated-foreground-test" })
    defer { client.disconnect() }
    let offline = expectation(description: "Offline path processed")
    let offlineObservation = client.$state.dropFirst().filter { $0 == .disconnected }.prefix(1).sink { _ in offline.fulfill() }
    defer { offlineObservation.cancel() }
    client.connect()
    paths.send(false, "test-offline")
    await fulfillment(of: [offline], timeout: 1)
    do {
      _ = try await api.send(APIRequest<JSONValue>(path: "/foreground-read", responseMode: .plain, showsErrorToast: false))
      XCTFail("Offline read must fail promptly")
    } catch {
      guard case .networkUnavailable = APIError.map(error) else { return XCTFail("Expected offline read") }
    }
    client.disconnect()
    let connected = expectation(description: "Foreground path connected")
    let connectedObservation = client.$state.filter { $0 == .connected }.prefix(1).sink { _ in connected.fulfill() }
    defer { connectedObservation.cancel() }
    client.connect()
    paths.send(true, "test-new-monitor-initial-online")
    await fulfillment(of: [connected], timeout: 1.5)
    let value = try await api.send(APIRequest<JSONValue>(path: "/foreground-read", responseMode: .plain, showsErrorToast: false))
    XCTAssertEqual(value["ok"], .bool(true))
    XCTAssertEqual(RecoveryHTTPProtocol.count("/foreground-read"), 1)
  }

  func testSilentBlackholeRecoversWithoutPathEventsOrLatencyMonitoring() async throws {
    let listening = expectation(description: "Silent peer listening")
    let peer = try LatencySocketPeer(ready: listening, pings: [])
    peer.start()
    defer { peer.stop() }
    await fulfillment(of: [listening], timeout: 3)
    let paths = Paths()
    let events = NotificationCenter()
    RecoveryHTTPProtocol.reset(parked: 1)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecoveryHTTPProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = RealtimeClient(baseURL: URL(string: "http://127.0.0.1:\(try XCTUnwrap(peer.port))")!,
      session: session, notificationCenter: events, networkPaths: { paths.makeStream() }, tokenProvider: { "isolated-blackhole-test" })
    let api = URLSessionAPIClient(baseURL: URL(string: "https://network-recovery.invalid")!, session: session,
      notificationCenter: events, readRecovery: APIReadRecovery(notificationCenter: events))
    defer { client.disconnect() }
    let first = expectation(description: "Silent peer initially connected")
    let recovered = expectation(description: "Independent liveness replaces silent socket")
    var count = 0
    let observation = client.$state.filter { $0 == .connected }.sink { _ in
      count += 1
      if count == 1 { first.fulfill() }
      if count == 2 { recovered.fulfill() }
    }
    defer { observation.cancel() }
    client.connect()
    paths.send(true, "test-cellular-still-satisfied")
    await fulfillment(of: [first], timeout: 3)
    peer.blackholeCurrentConnections()
    let readRecovered = expectation(description: "Silent transport releases old HTTP read")
    let read = Task {
      defer { readRecovered.fulfill() }
      return try await api.send(APIRequest<JSONValue>(path: "/silent-blackhole-read", responseMode: .plain, showsErrorToast: false))
    }
    defer { read.cancel() }
    // No additional NWPath event: the radio can lose packets while its cellular
    // interface remains satisfied. The old 60s server timeout must not own this.
    let recoveryResult = await XCTWaiter.fulfillment(of: [recovered, readRecovered], timeout: 14)
    XCTAssertEqual(recoveryResult, .completed)
    guard recoveryResult == .completed else { return }
    XCTAssertEqual(peer.connectionCount, 2)
    let value = try await read.value
    XCTAssertEqual(value["ok"], .bool(true))
    XCTAssertEqual(RecoveryHTTPProtocol.count("/silent-blackhole-read"), 2)
    XCTAssertEqual(RecoveryHTTPProtocol.count("/silent-blackhole-read", stopped: true), 1)
  }

  func testConnectingSocketWithoutReadyHasABoundedIndependentWatchdog() async throws {
    let listening = expectation(description: "Stalled ready watchdog peer listening")
    let peer = try LatencySocketPeer(ready: listening, pings: [], holdsFirstReady: true)
    peer.start()
    defer { peer.stop() }
    await fulfillment(of: [listening], timeout: 3)
    let paths = Paths()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let client = RealtimeClient(baseURL: URL(string: "http://127.0.0.1:\(try XCTUnwrap(peer.port))")!,
      session: session, networkPaths: { paths.makeStream() }, tokenProvider: { "isolated-watchdog-test" })
    defer { client.disconnect() }
    let recovered = expectation(description: "Connecting watchdog starts replacement handshake")
    let observation = client.$state.filter { $0 == .connected }.prefix(1).sink { _ in recovered.fulfill() }
    defer { observation.cancel() }
    client.connect()
    paths.send(true, "test-same-interface")
    await fulfillment(of: [recovered], timeout: 11)
    XCTAssertEqual(peer.connectionCount, 2)
  }
}

private final class RecoveryHTTPProtocol: URLProtocol {
  private final class State: @unchecked Sendable {
    let lock = NSLock()
    var parked = 1
    var requests: [URLRequest] = []
    var stopped: [URLRequest] = []
    var pending: [ObjectIdentifier: RecoveryHTTPProtocol] = [:]
  }
  private static let state = State()
  static func reset(parked: Int) {
    state.lock.lock(); defer { state.lock.unlock() }
    state.parked = parked; state.requests = []; state.stopped = []; state.pending = [:]
  }
  static func count(_ path: String, stopped: Bool = false) -> Int {
    state.lock.lock(); defer { state.lock.unlock() }
    return (stopped ? state.stopped : state.requests).filter { $0.url?.path == path }.count
  }
  static func finishPending(_ path: String, status: Int = 200) {
    state.lock.lock()
    let pending = state.pending.values.filter { $0.request.url?.path == path }
    state.lock.unlock()
    for request in pending { request.reply(status: status) }
  }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "network-recovery.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.state.lock.lock()
    Self.state.requests.append(request)
    Self.state.pending[ObjectIdentifier(self)] = self
    let count = Self.state.requests.filter { $0.url?.path == request.url?.path }.count
    let replyNow = count > Self.state.parked
    Self.state.lock.unlock()
    if replyNow { reply() }
  }
  override func stopLoading() {
    Self.state.lock.lock(); defer { Self.state.lock.unlock() }
    if Self.state.pending.removeValue(forKey: ObjectIdentifier(self)) != nil {
      Self.state.stopped.append(request)
    }
  }
  private func reply(status: Int = 200) {
    Self.state.lock.lock()
    let active = Self.state.pending.removeValue(forKey: ObjectIdentifier(self)) != nil
    Self.state.lock.unlock()
    guard active, let url = request.url else { return }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
      httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}

@MainActor
final class HTTPNetworkRecoveryTests: XCTestCase {
  private func makeAPI(parked: Int = 1) -> (URLSessionAPIClient, URLSession, NotificationCenter) {
    RecoveryHTTPProtocol.reset(parked: parked)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecoveryHTTPProtocol.self]
    let session = URLSession(configuration: configuration)
    let events = NotificationCenter()
    let recovery = APIReadRecovery(notificationCenter: events)
    return (URLSessionAPIClient(baseURL: URL(string: "https://network-recovery.invalid")!,
      session: session, notificationCenter: events, readRecovery: recovery), session, events)
  }
  private func start(_ api: URLSessionAPIClient, path: String, method: HTTPMethod = .get,
                     completed: XCTestExpectation) -> Task<Result<JSONValue, Error>, Never> {
    Task {
      defer { completed.fulfill() }
      do {
        return .success(try await api.send(APIRequest<JSONValue>(path: path, method: method,
          responseMode: .plain, showsErrorToast: false, timeoutInterval: 30)))
      } catch { return .failure(error) }
    }
  }
  private func waitForRead(_ path: String, count: Int = 1) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while RecoveryHTTPProtocol.count(path) < count, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(RecoveryHTTPProtocol.count(path), count)
  }
  private func path(_ events: NotificationCenter, available: Bool, initial: Bool = false) {
    events.post(name: .apiNetworkPathChanged, object: nil,
      userInfo: ["available": available, "initial": initial])
  }

  func testRestoredPathReplacesHungReadBeforeItsThirtySecondTimeout() async throws {
    let (api, session, events) = makeAPI()
    defer { session.invalidateAndCancel() }
    let done = expectation(description: "Hung GET recovered")
    let read = start(api, path: "/hung-read", completed: done)
    defer { read.cancel() }
    await waitForRead("/hung-read")
    path(events, available: true)
    let result = await XCTWaiter.fulfillment(of: [done], timeout: 1)
    XCTAssertEqual(result, .completed, "A restored path must not wait on the abandoned 30s request")
    guard result == .completed else { return }
    let recoveredValue = try await read.value.get()
    XCTAssertEqual(recoveredValue["ok"], .bool(true))
    XCTAssertEqual(RecoveryHTTPProtocol.count("/hung-read"), 2)
    XCTAssertEqual(RecoveryHTTPProtocol.count("/hung-read", stopped: true), 1)
    path(events, available: true)
    XCTAssertEqual(RecoveryHTTPProtocol.count("/hung-read"), 2, "Completed reads must not be replayed")
  }

  func testOfflineReleasesHungReadAndRejectsFurtherReadsUntilInitialOnlineSnapshot() async throws {
    let (api, session, events) = makeAPI()
    defer { session.invalidateAndCancel() }
    let done = expectation(description: "Offline GET released")
    let read = start(api, path: "/offline-read", completed: done)
    defer { read.cancel() }
    await waitForRead("/offline-read")
    path(events, available: false)
    let result = await XCTWaiter.fulfillment(of: [done], timeout: 1)
    XCTAssertEqual(result, .completed, "Shared readers must be released promptly while offline")
    guard result == .completed else { return }
    if case let .failure(error) = await read.value {
      guard case .networkUnavailable = APIError.map(error) else { return XCTFail("Expected offline error") }
    } else { XCTFail("Offline read must not succeed") }
    do {
      _ = try await api.send(APIRequest<JSONValue>(path: "/offline-read", responseMode: .plain, showsErrorToast: false))
      XCTFail("Offline reads must fail promptly")
    } catch {
      guard case .networkUnavailable = APIError.map(error) else { return XCTFail("Expected offline error") }
    }
    XCTAssertEqual(RecoveryHTTPProtocol.count("/offline-read"), 1)
    // Foreground reconnect restarts NWPathMonitor and reports its first snapshot.
    path(events, available: true, initial: true)
    let value = try await api.send(APIRequest<JSONValue>(path: "/offline-read", responseMode: .plain, showsErrorToast: false))
    XCTAssertEqual(value["ok"], .bool(true))
  }

  func testInitialHealthySnapshotKeepsInFlightReadAndSecondHandoverDoesNotLoopRetries() async {
    let (api, session, events) = makeAPI(parked: .max)
    defer { session.invalidateAndCancel() }
    let done = expectation(description: "Bounded GET recovery")
    let read = start(api, path: "/bounded-read", completed: done)
    defer { read.cancel() }
    await waitForRead("/bounded-read")
    path(events, available: true, initial: true)
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(RecoveryHTTPProtocol.count("/bounded-read"), 1)
    XCTAssertEqual(RecoveryHTTPProtocol.count("/bounded-read", stopped: true), 0)
    path(events, available: true)
    await waitForRead("/bounded-read", count: 2)
    path(events, available: true)
    let result = await XCTWaiter.fulfillment(of: [done], timeout: 1)
    XCTAssertEqual(result, .completed)
    XCTAssertEqual(RecoveryHTTPProtocol.count("/bounded-read"), 2, "One read can be retried only once")
  }

  func testBindingLogoutAndCallerCancellationPreventOldContextReplay() async {
    for reason in ["binding", "logout", "caller"] {
      let (api, session, events) = makeAPI(parked: .max)
      defer { session.invalidateAndCancel() }
      let done = expectation(description: reason + " read cancelled")
      let requestPath = "/context-" + reason
      let read = start(api, path: requestPath, completed: done)
      defer { read.cancel() }
      await waitForRead(requestPath)
      if reason == "binding" { api.invalidateReadContext() }
      else if reason == "logout" { events.post(name: .apiReadContextChanged, object: nil) }
      else { read.cancel() }
      path(events, available: true)
      let result = await XCTWaiter.fulfillment(of: [done], timeout: 1)
      XCTAssertEqual(result, .completed, reason)
      guard result == .completed else { continue }
      if case let .failure(error) = await read.value {
        guard case .cancelled = APIError.map(error) else { XCTFail(reason); continue }
      } else { XCTFail(reason) }
      XCTAssertEqual(RecoveryHTTPProtocol.count(requestPath), 1, "An obsolete account read must not be replayed")
    }
  }

  func testTradeAndCapitalWritesAreNeitherCancelledNorReplayedByNetworkChanges() async throws {
    for requestPath in ["/api/commands", "/v1/trade/capital/wallet/execute"] {
      let (api, session, events) = makeAPI(parked: .max)
      defer { session.invalidateAndCancel() }
      let done = expectation(description: "Original write completed")
      let write = start(api, path: requestPath, method: .post, completed: done)
      defer { write.cancel() }
      await waitForRead(requestPath)
      path(events, available: false)
      path(events, available: true)
      api.invalidateReadContext()
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertEqual(RecoveryHTTPProtocol.count(requestPath), 1)
      XCTAssertEqual(RecoveryHTTPProtocol.count(requestPath, stopped: true), 0)
      RecoveryHTTPProtocol.finishPending(requestPath)
      let result = await XCTWaiter.fulfillment(of: [done], timeout: 1)
      XCTAssertEqual(result, .completed)
      let writtenValue = try await write.value.get()
      XCTAssertEqual(writtenValue["ok"], .bool(true))
    }
  }

  func testOldReadRefreshFailureCannotExpireANewAccountContext() async {
    let fixture = makeAPI(parked: .max)
    var api = fixture.0
    let session = fixture.1
    let events = fixture.2
    defer { session.invalidateAndCancel() }
    let refreshStarted = expectation(description: "Old read token refresh started")
    var refresh: CheckedContinuation<String, Error>?
    api.refreshAccessToken = {
      refreshStarted.fulfill()
      return try await withCheckedThrowingContinuation { refresh = $0 }
    }
    defer { refresh?.resume(throwing: CancellationError()) }
    let unauthorized = expectation(description: "New context must not be signed out")
    unauthorized.isInverted = true
    let observer = events.addObserver(forName: .apiSessionUnauthorized, object: nil, queue: .main) { _ in unauthorized.fulfill() }
    defer { events.removeObserver(observer) }
    let done = expectation(description: "Old read cancelled after refresh")
    let read = start(api, path: "/old-auth-read", completed: done)
    defer { read.cancel() }
    await waitForRead("/old-auth-read")
    RecoveryHTTPProtocol.finishPending("/old-auth-read", status: 401)
    await fulfillment(of: [refreshStarted], timeout: 1)
    api.invalidateReadContext()
    refresh?.resume(throwing: APIError.unauthorized(message: "old account superseded"))
    refresh = nil
    await fulfillment(of: [done, unauthorized], timeout: 0.2)
    if case let .failure(error) = await read.value {
      guard case .cancelled = APIError.map(error) else { return XCTFail("Obsolete refresh must be a cancellation") }
    } else { XCTFail("Obsolete request must not succeed") }
    XCTAssertEqual(RecoveryHTTPProtocol.count("/old-auth-read"), 1)
  }
}

final class WebParityFormattingTests: XCTestCase {
  func testStopLossDisplayRoundsToThreeDecimalsWithoutPaddingZeros() {
    for (input, expected) in [
      ("10", "10"), ("10.5000", "10.5"), ("123.4565", "123.457"),
      ("0.12349", "0.123"), ("0.0005", "0.001"), ("0.0004", "0"),
      ("999.9995", "1000"), ("1234567890123.4565", "1234567890123.457"),
    ] {
      XCTAssertEqual(WebStopLossAmount.text(Decimal(string: input)!), expected, input)
    }
    XCTAssertEqual(WebStopLossAmount.text(.nan), "--")
  }

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

/// Exercise the real presenter from a bottom inset, not just the card's fade pixels.
@MainActor
final class WebModalHostTests: XCTestCase {
  private final class Frames {
    var stage = CGRect.zero
    var content = CGRect.zero
  }

  private final class DialogState: ObservableObject {
    @Published var first = false
    @Published var second = false
    @Published var nested = false
    @Published var locked = true
    @Published var sheet = false
    var appearances: [String: Int] = [:]
    var dismissals: [String: Int] = [:]
    var close: [String: () -> Void] = [:]
    var schemes: [String: ColorScheme] = [:]
  }

  private struct DialogProbe: View {
    let tag: String
    @EnvironmentObject private var state: DialogState
    @Environment(\.webDismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    var body: some View {
      Color.clear.frame(height: 100).onAppear {
        state.appearances[tag, default: 0] += 1
        state.close[tag] = { dismiss() }
        state.schemes[tag] = scheme
      }
    }
  }

  private struct DialogSource: View {
    @ObservedObject var state: DialogState
    var body: some View {
      Color.gray.frame(height: 180)
        .webModal(isPresented: $state.first, onDismiss: { state.dismissals["first", default: 0] += 1 }) {
          WebModal(title: "开仓确认") {
            DialogProbe(tag: "first").webModalDismissDisabled(state.locked)
              .webModal(isPresented: $state.nested) {
                WebModal(title: "嵌套确认") { DialogProbe(tag: "nested") }
              }
          }
        }
        .webModal(isPresented: $state.second, onDismiss: { state.dismissals["second", default: 0] += 1 }) {
          WebModal(title: "开仓成功") { DialogProbe(tag: "second") }
        }
    }
  }

  private struct SheetSource: View {
    @ObservedObject var state: DialogState
    var body: some View {
      Color.white.sheet(isPresented: $state.sheet) {
        Color.white.safeAreaInset(edge: .bottom) { DialogSource(state: state) }
      }
    }
  }

  private func makeWindow<Content: View>(_ content: Content) -> UIWindow {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    window.rootViewController = UIHostingController(rootView: content)
    window.makeKeyAndVisible()
    return window
  }

  func testSequentialDialogsAndReopeningDismissExactlyOnce() async throws {
    let state = DialogState()
    let root = Color.white.safeAreaInset(edge: .bottom) { DialogSource(state: state) }
      .environmentObject(state)
    let window = makeWindow(root)
    defer { window.isHidden = true; window.rootViewController = nil }
    state.first = true
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(state.appearances["first"], 1)
    state.first = false
    state.second = true
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(state.dismissals["first"], 1)
    XCTAssertEqual(state.appearances["second"], 1, "Success must not be lost while confirmation fades out")
    try XCTUnwrap(state.close["second"])()
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertFalse(state.second)
    XCTAssertEqual(state.dismissals["second"], 1)
    XCTAssertNil(window.rootViewController?.presentedViewController)
    state.first = true
    state.locked = false
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(state.appearances["first"], 2)
    try XCTUnwrap(state.close["first"])()
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(state.dismissals["first"], 2)
    XCTAssertNil(window.rootViewController?.presentedViewController)
  }

  func testCancelledQueuedDialogCannotLeaveAnInvisibleCover() async throws {
    let state = DialogState()
    let root = Color.white.safeAreaInset(edge: .bottom) { DialogSource(state: state) }
      .environmentObject(state)
    let window = makeWindow(root)
    defer { window.isHidden = true; window.rootViewController = nil }
    state.first = true
    try await Task.sleep(for: .milliseconds(500))
    state.first = false
    state.second = true
    try await Task.sleep(for: .milliseconds(30))
    state.second = false
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertEqual(state.dismissals["first"], 1)
    XCTAssertNil(window.rootViewController?.presentedViewController,
      "A success/preview cancelled while confirmation closes must release its cover")
  }

  func testNestedConfirmationFromSheetPreservesEnvironmentAndSubmitLock() async throws {
    let state = DialogState()
    let root = SheetSource(state: state).environmentObject(state).environment(\.colorScheme, .dark)
    let window = makeWindow(root)
    defer { window.isHidden = true; window.rootViewController = nil }
    state.sheet = true
    try await Task.sleep(for: .milliseconds(600))
    state.first = true
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(state.schemes["first"], .dark)
    try XCTUnwrap(state.close["first"])()
    XCTAssertTrue(state.first, "Submit lock must block the shared close action")
    state.nested = true
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(state.appearances["nested"], 1)
    XCTAssertEqual(state.schemes["nested"], .dark)
    try XCTUnwrap(state.close["nested"])()
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertFalse(state.nested)
    XCTAssertTrue(state.first, "Closing a nested confirmation must preserve its parent")
    state.locked = false
    try await Task.sleep(for: .milliseconds(100))
    try XCTUnwrap(state.close["first"])()
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertFalse(state.first)
    XCTAssertEqual(state.dismissals["first"], 1)
    XCTAssertNotNil(window.rootViewController?.presentedViewController, "The original sheet stays open")
    XCTAssertNil(window.rootViewController?.presentedViewController?.presentedViewController)
    state.sheet = false
    let sheetDismissed = expectation(for: NSPredicate { object, _ in
      (object as? UIViewController)?.presentedViewController == nil
    }, evaluatedWith: try XCTUnwrap(window.rootViewController))
    await fulfillment(of: [sheetDismissed], timeout: 3)
    XCTAssertNil(window.rootViewController?.presentedViewController)
  }

  func testBottomTicketPresentsConfirmationAcrossTheWindow() async throws {
    try await checkPresentation(bottomTicket: true, contentHeight: 250)
  }

  func testShortConfirmationStillUsesTheWindow() async throws {
    try await checkPresentation(bottomTicket: true, contentHeight: 80)
  }

  func testFullPageConfirmationUsesTheWindow() async throws {
    try await checkPresentation(bottomTicket: false, contentHeight: 250)
  }

  private func checkPresentation(bottomTicket: Bool, contentHeight: CGFloat) async throws {
    let frames = Frames()
    let source = Color.gray.frame(maxHeight: bottomTicket ? 180 : .infinity)
      .webModal(isPresented: .constant(true)) {
        WebModal(title: "开仓确认") {
          Color.clear.frame(height: contentHeight).background(GeometryReader { geometry in
            Color.clear.onAppear { frames.content = geometry.frame(in: .global) }
              .onChange(of: geometry.frame(in: .global)) { _, frame in frames.content = frame }
          })
        }.background(GeometryReader { geometry in
          Color.clear.onAppear { frames.stage = geometry.frame(in: .global) }
            .onChange(of: geometry.frame(in: .global)) { _, frame in frames.stage = frame }
        })
      }
    let root = Color.white.safeAreaInset(edge: .bottom, spacing: 0) { source }
    let window = makeWindow(root)
    defer { window.isHidden = true; window.rootViewController = nil }
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertGreaterThan(frames.stage.height, window.bounds.height * 0.8,
      "A ticket's local bounds must never become the modal's presentation bounds: \(frames.stage)")
    XCTAssertGreaterThan(frames.content.height, 0)
    XCTAssertLessThan(frames.content.maxY, window.bounds.maxY - 40,
      "Confirmation actions must remain above the bottom of the screen: \(frames.content)")
    XCTAssertEqual(frames.stage.midY, window.bounds.midY, accuracy: 2,
      "Confirmation must be centered in the window, independently of the ticket")
  }
}
