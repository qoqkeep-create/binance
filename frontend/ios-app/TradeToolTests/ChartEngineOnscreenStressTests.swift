import MetalKit
import QuartzCore
import UIKit
import XCTest
@testable import TradeTool

@MainActor
final class ChartEngineOnscreenStressTests: XCTestCase {
    func testOnscreenFourAndTwentyHertzBurstsRemainBounded()
        async throws {
        try XCTSkipIf(
            requiresForegroundHarness,
            "Physical presentation is validated by the foreground Debug harness."
        )
        let context = try OnscreenMetalContext()
        defer {
            context.dispose()
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        context.submitAndDraw(revision: 10)
        try await waitForPresentation(
            revision: 10,
            health: context.health
        )

        let fourHertzRange: ClosedRange<UInt64> =
            1_000...1_007
        try await runBurst(
            revisions: fourHertzRange,
            hertz: 4,
            context: context
        )
        let fourHertzP95 = try presentationP95(
            revisions: fourHertzRange,
            health: context.health,
            minimumCoverage: 8
        )

        let twentyHertzRange: ClosedRange<UInt64> =
            2_000...2_039
        try await runBurst(
            revisions: twentyHertzRange,
            hertz: 20,
            context: context
        )
        let twentyHertzP95 = try presentationP95(
            revisions: twentyHertzRange,
            health: context.health,
            minimumCoverage: 36
        )

        let snapshot = context.health.snapshot()
        XCTAssertEqual(snapshot.commandBufferErrors, 0)
        XCTAssertEqual(snapshot.bufferCapacityRejections, 0)
        XCTAssertEqual(snapshot.currentInFlightFrames, 0)
        XCTAssertLessThanOrEqual(snapshot.peakInFlightFrames, 3)
#if targetEnvironment(simulator)
        XCTAssertLessThan(fourHertzP95, 0.150)
        XCTAssertLessThan(twentyHertzP95, 0.150)
#else
        XCTAssertLessThan(fourHertzP95, 0.050)
        XCTAssertLessThan(twentyHertzP95, 0.050)
#endif

        let report = """
        4Hz ready-to-present p95: \
        \(String(format: "%.3f", fourHertzP95 * 1_000)) ms
        20Hz ready-to-present p95: \
        \(String(format: "%.3f", twentyHertzP95 * 1_000)) ms
        submitted: \(snapshot.submittedFrames)
        completed: \(snapshot.completedFrames)
        presented: \(snapshot.presentedFrames)
        peak in-flight: \(snapshot.peakInFlightFrames)
        GPU busy skips: \(snapshot.gpuBusySkips)
        """
        let attachment = XCTAttachment(
            string: report
        )
        attachment.name = "Kline Onscreen Stress Report"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSuspendCoalescesLatestStateAndMemoryWarningRebuilds()
        async throws {
        try XCTSkipIf(
            requiresForegroundHarness,
            "Physical presentation is validated by the foreground Debug harness."
        )
        let context = try OnscreenMetalContext()
        defer {
            context.dispose()
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        context.submitAndDraw(revision: 3_000)
        try await waitForPresentation(
            revision: 3_000,
            health: context.health
        )

        context.coordinator.suspend()
        XCTAssertTrue(context.coordinator.isSuspended)
        let beforeSuspend = context.health.snapshot()

        for revision in UInt64(3_001)...3_025 {
            context.submitAndDraw(revision: revision)
        }
        context.coordinator.handleMemoryWarning()
        try await Task.sleep(nanoseconds: 100_000_000)

        let whileSuspended = context.health.snapshot()
        XCTAssertEqual(
            whileSuspended.submittedFrames,
            beforeSuspend.submittedFrames
        )
        XCTAssertEqual(
            whileSuspended.lastPresentedRevision,
            beforeSuspend.lastPresentedRevision
        )
        XCTAssertEqual(
            whileSuspended.memoryWarnings,
            beforeSuspend.memoryWarnings + 1
        )

        context.coordinator.resume()
        XCTAssertFalse(context.coordinator.isSuspended)
        context.metalView.draw()
        try await waitForPresentation(
            revision: 3_025,
            health: context.health
        )

        let afterResume = context.health.snapshot()
        XCTAssertEqual(
            afterResume.lastPresentedRevision,
            3_025
        )
        XCTAssertEqual(afterResume.commandBufferErrors, 0)
        XCTAssertEqual(afterResume.currentInFlightFrames, 0)
        XCTAssertLessThanOrEqual(afterResume.peakInFlightFrames, 3)
    }

    func testApplicationLifecycleNotificationsSuspendAndCoalesce()
        async throws {
        try XCTSkipIf(
            requiresForegroundHarness,
            "Physical lifecycle is validated by the foreground Debug harness."
        )
        let context = try OnscreenHostLifecycleContext()
        defer {
            context.dispose()
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(
            context.host.diagnosticIsRendererSuspended
        )
        context.submitAndDraw(revision: 4_000)
        try await waitForHostPresentation(
            revision: 4_000,
            host: context.host
        )
        let baseline =
            context.host.diagnosticHealthSnapshot()

        context.host.startInteractionFrames()
        NotificationCenter.default.post(
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.post(
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        XCTAssertTrue(
            context.host.diagnosticIsRendererSuspended
        )
        XCTAssertFalse(
            context.host.diagnosticIsApplicationActive
        )
        XCTAssertFalse(
            context.host.diagnosticIsInteractionActive
        )

        let inactiveBaseline =
            context.host.diagnosticHealthSnapshot()
        XCTAssertEqual(
            inactiveBaseline.rendererSuspends,
            baseline.rendererSuspends + 1
        )
        for revision in UInt64(4_001)...4_025 {
            context.submitAndDraw(revision: revision)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let whileInactive =
            context.host.diagnosticHealthSnapshot()
        XCTAssertEqual(
            whileInactive.submittedFrames,
            inactiveBaseline.submittedFrames
        )
        XCTAssertLessThan(
            whileInactive.lastPresentedRevision,
            4_001
        )

        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        XCTAssertFalse(
            context.host.diagnosticIsRendererSuspended
        )
        XCTAssertTrue(
            context.host.diagnosticIsApplicationActive
        )
        XCTAssertTrue(
            context.host.diagnosticIsInteractionActive
        )
        context.host.diagnosticDraw()
        try await waitForHostPresentation(
            revision: 4_025,
            host: context.host
        )

        let resumed =
            context.host.diagnosticHealthSnapshot()
        XCTAssertEqual(
            resumed.rendererResumes,
            baseline.rendererResumes + 1
        )
        let queuedPresentations = Set(
            resumed.recentPresentations
                .map(\.revision)
                .filter { (4_001...4_025).contains($0) }
        )
        XCTAssertEqual(queuedPresentations, Set([4_025]))
        XCTAssertEqual(resumed.commandBufferErrors, 0)
        XCTAssertEqual(resumed.currentInFlightFrames, 0)
    }

    private func runBurst(
        revisions: ClosedRange<UInt64>,
        hertz: UInt64,
        context: OnscreenMetalContext
    ) async throws {
        let interval = 1_000_000_000 / hertz
        for revision in revisions {
            context.submitAndDraw(revision: revision)
            try await Task.sleep(nanoseconds: interval)
        }
        try await waitForPresentation(
            revision: revisions.upperBound,
            health: context.health
        )
    }

    private var requiresForegroundHarness: Bool {
#if targetEnvironment(simulator)
        false
#else
        true
#endif
    }

    private func waitForPresentation(
        revision: UInt64,
        health: MetalRendererHealth,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime
            + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let snapshot = health.snapshot()
            if snapshot.lastPresentedRevision >= revision,
               snapshot.currentInFlightFrames == 0 {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail(
            """
            Timed out waiting for presented revision \(revision); \
            health=\(health.snapshot())
            """
        )
        throw StressTestError.presentationTimedOut
    }

    private func waitForHostPresentation(
        revision: UInt64,
        host: KlineChartHostView,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime
            + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let snapshot = host.diagnosticHealthSnapshot()
            if snapshot.lastPresentedRevision >= revision,
               snapshot.currentInFlightFrames == 0 {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail(
            """
            Timed out waiting for host revision \(revision); \
            health=\(host.diagnosticHealthSnapshot())
            """
        )
        throw StressTestError.presentationTimedOut
    }

    private func presentationP95(
        revisions: ClosedRange<UInt64>,
        health: MetalRendererHealth,
        minimumCoverage: Int
    ) throws -> TimeInterval {
        let grouped = Dictionary(
            grouping: health.snapshot()
                .recentPresentations
                .filter { revisions.contains($0.revision) },
            by: \.revision
        )
        let durations = grouped.values.compactMap { samples in
            samples.compactMap(\.readyToPresentDuration).min()
        }.sorted()

        XCTAssertGreaterThanOrEqual(
            durations.count,
            minimumCoverage
        )
        guard !durations.isEmpty else {
            throw StressTestError.noPresentationSamples
        }
        let index = min(
            durations.count - 1,
            Int(ceil(Double(durations.count) * 0.95)) - 1
        )
        return durations[max(0, index)]
    }
}

@MainActor
private final class OnscreenHostLifecycleContext {
    let window: UIWindow
    let host: KlineChartHostView

    private weak var previousKeyWindow: UIWindow?

    init() throws {
        let frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            throw StressTestError.windowSceneUnavailable
        }
        previousKeyWindow = windowScene.windows.first {
            $0.isKeyWindow
        }

        host = KlineChartHostView(frame: frame)
        let root = UIViewController()
        root.view.backgroundColor = .black
        root.view.frame = frame
        root.view.addSubview(host)
        window = UIWindow(windowScene: windowScene)
        window.frame = frame
        window.windowLevel = .alert + 1
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()
        host.layoutIfNeeded()
    }

    func submitAndDraw(revision: UInt64) {
        let state = RenderState(
            staticScene: StaticSceneSnapshot(
                revision: 1,
                candleHistory: ChartCandleHistory(candles: []),
                batches: []
            ),
            liveTail: LiveTailSnapshot(
                revision: revision,
                candle: nil,
                batches: [],
                latestPrice: nil
            ),
            interaction: InteractionSnapshot(
                revision: revision,
                translationX: 0,
                scaleX: 1,
                crosshair: nil
            ),
            invalidation: .data,
            readyTime: ProcessInfo.processInfo.systemUptime
        )
        host.submit(state)
        host.diagnosticDraw()
    }

    func dispose() {
        host.dispose()
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKeyAndVisible()
    }
}

@MainActor
private final class OnscreenMetalContext {
    let window: UIWindow
    let metalView: MTKView
    let health: MetalRendererHealth
    let coordinator: MetalFrameCoordinator

    private let staticScene: StaticSceneSnapshot
    private let interaction: InteractionSnapshot
    private weak var previousKeyWindow: UIWindow?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw StressTestError.metalUnavailable
        }

        let frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        metalView = MTKView(frame: frame, device: device)
        metalView.colorPixelFormat = .bgra8Unorm_srgb
        metalView.sampleCount = 1
        metalView.framebufferOnly = true
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.autoResizeDrawable = false

        let scale = UIScreen.main.scale
        metalView.contentScaleFactor = scale
        metalView.drawableSize = CGSize(
            width: frame.width * scale,
            height: frame.height * scale
        )

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            throw StressTestError.windowSceneUnavailable
        }
        previousKeyWindow = windowScene.windows.first {
            $0.isKeyWindow
        }

        let root = UIViewController()
        root.view.backgroundColor = .black
        root.view.frame = frame
        root.view.addSubview(metalView)
        window = UIWindow(windowScene: windowScene)
        window.frame = frame
        window.windowLevel = .alert + 1
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()

        let sharedHealth = MetalRendererHealth()
        health = sharedHealth
        let pixelFormat = metalView.colorPixelFormat
        let factory = {
            try MetalRenderer(
                device: device,
                pixelFormat: pixelFormat,
                health: sharedHealth
            )
        }
        let renderer = try factory()
        coordinator = MetalFrameCoordinator(
            view: metalView,
            renderer: renderer,
            rendererFactory: factory,
            onRendererStopped: { _ in }
        )

        staticScene = try Self.makeStaticScene(
            scale: Float(scale)
        )
        interaction = InteractionSnapshot(
            revision: 1,
            translationX: 0,
            scaleX: 1,
            crosshair: nil
        )
    }

    func submitAndDraw(revision: UInt64) {
        let scale = Float(metalView.contentScaleFactor)
        let priceY = 120 * scale
            + Float(revision % 7) * 0.25 * scale
        let liveBatch = ChartRenderBatch(
            candleInstances: [
                ChartCandleInstance(
                    x: 370 * scale,
                    openY: priceY - 8 * scale,
                    highY: priceY - 14 * scale,
                    lowY: priceY + 15 * scale,
                    closeY: priceY + 5 * scale,
                    halfBodyWidth: 1.5 * scale,
                    isRising: revision.isMultiple(of: 2)
                ),
            ],
            lineSegments: [
                ChartLineSegmentInstance(
                    start: ChartPolylinePoint(
                        x: 0,
                        y: priceY
                    ),
                    end: ChartPolylinePoint(
                        x: 390 * scale,
                        y: priceY
                    ),
                    width: scale,
                    dashLength: 4 * scale,
                    gapLength: 3 * scale,
                    dashPhase: 0,
                    color: .neutral
                ),
            ]
        )
        let state = RenderState(
            staticScene: staticScene,
            liveTail: LiveTailSnapshot(
                revision: revision,
                candle: nil,
                batches: [liveBatch],
                latestPrice: 63_900
            ),
            interaction: interaction,
            invalidation: .data,
            readyTime: ProcessInfo.processInfo.systemUptime
        )
        coordinator.submit(state)
        metalView.draw()
    }

    func dispose() {
        coordinator.dispose()
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKeyAndVisible()
    }

    private static func makeStaticScene(
        scale: Float
    ) throws -> StaticSceneSnapshot {
        let candleCount = 200
        let candles = (0..<candleCount).map { index in
            let x = Float(index) * 1.85 * scale + scale
            let center = (
                85
                + sin(Float(index) * 0.17) * 34
            ) * scale
            return ChartCandleInstance(
                x: x,
                openY: center - 5 * scale,
                highY: center - 13 * scale,
                lowY: center + 14 * scale,
                closeY: center + (
                    index.isMultiple(of: 2) ? 5 : -5
                ) * scale,
                halfBodyWidth: 0.75 * scale,
                isRising: index.isMultiple(of: 2)
            )
        }

        var lineSegments: [ChartLineSegmentInstance] = []
        for indicator in 0..<3 {
            let points = (0..<candleCount).map { index in
                ChartPolylinePoint(
                    x: Float(index) * 1.85 * scale + scale,
                    y: (
                        90
                        + Float(indicator) * 12
                        + sin(
                            Float(index) * 0.11
                            + Float(indicator)
                        ) * 22
                    ) * scale
                )
            }
            lineSegments.append(
                contentsOf: ChartBatchCompiler.lineSegments(
                    spans: [points],
                    width: scale,
                    color: .neutral
                )
            )
        }
        for tool in 0..<100 {
            let offset = Float(tool % 20) * 3 * scale
            lineSegments.append(
                ChartLineSegmentInstance(
                    start: ChartPolylinePoint(
                        x: 20 * scale + offset,
                        y: 170 * scale
                    ),
                    end: ChartPolylinePoint(
                        x: 160 * scale + offset,
                        y: 205 * scale
                    ),
                    width: scale,
                    dashLength: 0,
                    gapLength: 0,
                    dashPhase: 0,
                    color: .neutral
                )
            )
        }

        let volumeBars = (0..<candleCount).map { index in
            let left = Float(index) * 1.85 * scale
            return ChartBarInstance(
                left: left,
                top: (
                    270 - Float(index % 18)
                ) * scale,
                right: left + 1.3 * scale,
                bottom: 292 * scale,
                color: index.isMultiple(of: 2)
                    ? .positive
                    : .negative
            )
        }

        let atlasKey = try XCTUnwrap(
            ChartGlyphAtlasKey(
                fontName: "HelveticaNeue",
                pointSize: 11,
                displayScale: Double(scale),
                localeIdentifier: "zh-Hans"
            )
        )
        let atlas = try MetalGlyphAtlasBuilder().build(
            key: atlasKey,
            seedStrings: ["EMA(21) 63,900.8 最新价格"]
        )
        let glyphs = MetalTextLayouter.layout(
            text: "EMA(21) 63,900.8 最新价格",
            atlas: atlas,
            originX: Double(8 * scale),
            baselineY: Double(24 * scale),
            color: .neutral
        ).instances
        let batch = ChartRenderBatch(
            candleInstances: candles,
            lineSegments: lineSegments,
            barInstances: volumeBars,
            glyphInstances: glyphs,
            glyphAtlas: atlas
        )

        let history = (0..<3_000).map { index in
            let close = 60_000 + Double(index % 250)
            return ChartCandle(
                openTime: Int64(index) * 3_600_000,
                closeTime: Int64(index + 1) * 3_600_000 - 1,
                openPrice: close - 5,
                highPrice: close + 10,
                lowPrice: close - 10,
                closePrice: close,
                volume: 10,
                quoteVolume: close * 10,
                closure: .closed
            )
        }
        return StaticSceneSnapshot(
            revision: 1,
            candleHistory: ChartCandleHistory(candles: history),
            batches: [batch]
        )
    }
}

private enum StressTestError: Error {
    case metalUnavailable
    case windowSceneUnavailable
    case noPresentationSamples
    case presentationTimedOut
}
