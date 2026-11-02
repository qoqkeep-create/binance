import SwiftUI

struct ChartPriceProjection: Equatable, Sendable {
  let lowerBound: Double
  let upperBound: Double
  let plotLeft: Double
  let plotTop: Double
  let plotRight: Double
  let plotBottom: Double

  init?(
    lowerBound: Double,
    upperBound: Double,
    plotLeft: Double,
    plotTop: Double,
    plotRight: Double,
    plotBottom: Double
  ) {
    guard [
      lowerBound, upperBound, plotLeft,
      plotTop, plotRight, plotBottom,
    ].allSatisfy(\.isFinite),
      upperBound > lowerBound,
      plotRight > plotLeft,
      plotBottom > plotTop
    else {
      return nil
    }
    self.lowerBound = lowerBound
    self.upperBound = upperBound
    self.plotLeft = plotLeft
    self.plotTop = plotTop
    self.plotRight = plotRight
    self.plotBottom = plotBottom
  }

  var priceRange: ClosedRange<Double> {
    lowerBound...upperBound
  }

  func screenY(for price: Double) -> Double? {
    guard price.isFinite else { return nil }
    let ratio = (upperBound - price) / (upperBound - lowerBound)
    let y = plotTop + ratio * (plotBottom - plotTop)
    return y.isFinite ? y : nil
  }

  func price(atScreenY y: Double) -> Double? {
    guard y.isFinite else { return nil }
    let clampedY = min(plotBottom, max(plotTop, y))
    let ratio = (clampedY - plotTop) / (plotBottom - plotTop)
    let price = upperBound - ratio * (upperBound - lowerBound)
    return price.isFinite ? price : nil
  }
}

@MainActor
final class KlineChartSceneController: ObservableObject {
  var diagnostics: ChartLoadDiagnostics?
  @Published private(set) var renderState: RenderState?
  @Published private(set) var timelineViewport:
    ChartTimelineViewport?
  @Published private(set) var priceViewport:
    ChartPriceViewport = .automatic
  @Published private(set) var priceProjection:
    ChartPriceProjection?

  private let builder = ChartSceneBuilder()
  private var requestKey: RequestKey?
  private var pendingRenderRequest: RenderRequest?
  private var renderTask: Task<Void, Never>?
  private var latestRenderRequestRevision: UInt64 = 0
  private var renderedOwner: ViewportOwner?
  private var viewportOwner: ViewportOwner?
  private var viewportOwnerSlotCount = 0
  private var viewportOwnerNewestOpenTime: Int64?

  private struct ViewportOwner: Equatable {
    let stream: ChartStreamKey
    let epoch: KlineStreamEpoch
  }

  struct RequestKey: Hashable {
    let stream: ChartStreamKey
    let epoch: KlineStreamEpoch
    let candleRevision: UInt64
    let indicatorHistory: ObjectIdentifier
    let viewport: ChartSceneViewport
    let timelineViewport: ChartTimelineViewport
    let priceViewport: ChartPriceViewport
  }

  private struct RenderRequest {
    let revision: UInt64
    let frame: ChartDataFrame?
    let viewport: ChartSceneViewport?
    let proposedTimelineViewport: ChartTimelineViewport?
    let proposedPriceViewport: ChartPriceViewport
  }

  func requestRender(
    frame: ChartDataFrame?,
    viewport: ChartSceneViewport?,
    proposedTimelineViewport: ChartTimelineViewport?,
    proposedPriceViewport: ChartPriceViewport
  ) {
    latestRenderRequestRevision &+= 1
    pendingRenderRequest = RenderRequest(
      revision: latestRenderRequestRevision,
      frame: frame,
      viewport: viewport,
      proposedTimelineViewport: proposedTimelineViewport,
      proposedPriceViewport: proposedPriceViewport
    )
    startRenderLoopIfNeeded()
  }

  func cancelPendingRenders() {
    latestRenderRequestRevision &+= 1
    pendingRenderRequest = nil
    renderTask?.cancel()
  }

#if DEBUG
  func diagnosticWaitForRenderIdle() async {
    while renderTask != nil || pendingRenderRequest != nil {
      await Task.yield()
    }
  }
#endif

  private func startRenderLoopIfNeeded() {
    guard renderTask == nil else {
      return
    }
    renderTask = Task { [weak self] in
      await self?.drainRenderRequests()
    }
  }

  private func drainRenderRequests() async {
    defer {
      renderTask = nil
      if pendingRenderRequest != nil {
        startRenderLoopIfNeeded()
      }
    }
    while !Task.isCancelled,
      let request = pendingRenderRequest
    {
      pendingRenderRequest = nil
      await render(request)
    }
  }

  private func render(_ request: RenderRequest) async {
    guard request.revision == latestRenderRequestRevision else {
      return
    }
    let frame = request.frame
    let viewport = request.viewport
    guard let frame, let viewport else {
      requestKey = nil
      renderedOwner = nil
      renderState = nil
      priceProjection = nil
      return
    }
    let owner = ViewportOwner(
      stream: frame.stream,
      epoch: frame.epoch
    )
    let totalSlotCount = Self.totalSlotCount(frame)
    let newestOpenTime = Self.newestOpenTime(frame)
    let timeline: ChartTimelineViewport
    let resolvedPriceViewport: ChartPriceViewport
    if viewportOwner != owner {
      viewportOwner = owner
      viewportOwnerSlotCount = totalSlotCount
      viewportOwnerNewestOpenTime = newestOpenTime
      priceViewport = .automatic
      resolvedPriceViewport = .automatic
      timeline = ChartTimelineViewport.latest(
        totalWidthPoints: viewport.widthPoints
      ).clamped(totalSlotCount: totalSlotCount)
    } else {
      resolvedPriceViewport = request.proposedPriceViewport
      let proposed = (
        request.proposedTimelineViewport
          ?? ChartTimelineViewport.latest(
            totalWidthPoints: viewport.widthPoints
          )
      )
      let appendedSlotCount = Self.appendedSlotCount(
        previousNewestOpenTime: viewportOwnerNewestOpenTime,
        newestOpenTime: newestOpenTime,
        previousTotalSlotCount: viewportOwnerSlotCount,
        totalSlotCount: totalSlotCount
      )
      timeline = proposed.preservingVisibleContent(
        appendedSlotCount: appendedSlotCount,
        totalSlotCount: totalSlotCount
      )
      viewportOwnerSlotCount = totalSlotCount
      viewportOwnerNewestOpenTime = newestOpenTime
    }
    if timelineViewport != timeline {
      timelineViewport = timeline
    }
    let key = RequestKey(
      stream: frame.stream,
      epoch: frame.epoch,
      candleRevision: frame.candles.revision,
      indicatorHistory: ObjectIdentifier(
        frame.indicators.history
      ),
      viewport: viewport,
      timelineViewport: timeline,
      priceViewport: resolvedPriceViewport
    )
    requestKey = key
    do {
      let trace = diagnostics
      trace?.record("scene_started")
      let output = try await builder.build(
        frame: frame,
        viewport: viewport,
        timelineViewport: timeline,
        priceViewport: resolvedPriceViewport
      )
      guard !Task.isCancelled,
        request.revision == latestRenderRequestRevision,
        requestKey == key
      else {
        return
      }
      renderedOwner = owner
      trace?.record("scene_ready")
      renderState = output.renderState
      let projection = Self.priceProjection(
        output: output,
        displayScale: viewport.displayScale
      )
      if priceProjection != projection {
        priceProjection = projection
      }
    } catch is CancellationError {
      return
    } catch {
      guard request.revision == latestRenderRequestRevision,
        requestKey == key
      else {
        return
      }
      renderedOwner = nil
      renderState = nil
      priceProjection = nil
    }
  }

  func renderState(
    matching frame: ChartDataFrame?
  ) -> RenderState? {
    guard let frame,
      renderedOwner == ViewportOwner(
        stream: frame.stream,
        epoch: frame.epoch
      )
    else {
      return nil
    }
    return renderState
  }

  func updateTimelineViewport(
    _ viewport: ChartTimelineViewport,
    totalSlotCount: Int
  ) {
    let clamped = viewport.clamped(
      totalSlotCount: totalSlotCount
    )
    if timelineViewport != clamped {
      timelineViewport = clamped
    }
  }

  func updatePriceViewport(
    _ viewport: ChartPriceViewport
  ) {
    if priceViewport != viewport {
      priceViewport = viewport
    }
  }

  static func totalSlotCount(_ frame: ChartDataFrame) -> Int {
    frame.candles.history.candles.count
      + (frame.candles.liveTail == nil ? 0 : 1)
  }

  nonisolated private static func priceProjection(
    output: ChartSceneBuildOutput,
    displayScale: Double
  ) -> ChartPriceProjection? {
    guard displayScale.isFinite,
      displayScale > 0,
      let plot = output.panelLayout.pricePanel?.plot
    else {
      return nil
    }
    return ChartPriceProjection(
      lowerBound: output.priceLowerBound,
      upperBound: output.priceUpperBound,
      plotLeft: Double(plot.left) / displayScale,
      plotTop: Double(plot.top) / displayScale,
      plotRight: Double(plot.right) / displayScale,
      plotBottom: Double(plot.bottom) / displayScale
    )
  }

  nonisolated static func newestOpenTime(
    _ frame: ChartDataFrame
  ) -> Int64? {
    frame.candles.liveTail?.openTime
      ?? frame.candles.history.candles.last?.openTime
  }

  nonisolated static func appendedSlotCount(
    previousNewestOpenTime: Int64?,
    newestOpenTime: Int64?,
    previousTotalSlotCount: Int,
    totalSlotCount: Int
  ) -> Int {
    guard let previousNewestOpenTime,
      let newestOpenTime,
      newestOpenTime > previousNewestOpenTime
    else {
      return 0
    }
    return max(1, totalSlotCount - previousTotalSlotCount)
  }

  nonisolated static func shouldRequestOlderHistory(
    viewport: ChartTimelineViewport,
    totalSlotCount: Int
  ) -> Bool {
    let maximumOffset = max(
      0,
      Double(totalSlotCount) - viewport.visibleSlotCount
    )
    let remainingSlots = maximumOffset
      - viewport.trailingOffsetSlots
    return remainingSlots <= max(
      viewport.visibleSlotCount,
      Double(ChartInteractionMetrics.standard.guardBandSlotCount)
    )
  }
}

struct KlineChartSceneView: View {
  let frame: ChartDataFrame?
  var diagnostics: ChartLoadDiagnostics? = nil
  var onFirstFramePresented: (KlineStreamEpoch, TimeInterval) -> Void = { _, _ in }
  var onNeedsOlderHistory: () -> Void = {}
  var onPriceProjectionChange:
    (ChartPriceProjection?) -> Void = { _ in }
  var onCrosshairSelection: (ChartCrosshairSelection) -> Void = { _ in }
  var onCrosshairDismiss: () -> Void = {}

  @Environment(\.displayScale) private var displayScale
  @StateObject private var controller =
    KlineChartSceneController()

  var body: some View {
    GeometryReader { proxy in
      let viewport = ChartSceneViewport(
        widthPoints: proxy.size.width,
        heightPoints: proxy.size.height,
        displayScale: displayScale
      )
      let timeline = effectiveTimelineViewport(
        frame: frame,
        viewport: viewport
      )
      let priceViewport = controller.priceViewport
      let key = taskKey(
        viewport: viewport,
        timelineViewport: timeline,
        priceViewport: priceViewport
      )

      ZStack {
        if let renderState = controller.renderState(
          matching: frame
        )
        {
          KlineChartRepresentable(
            renderState: renderState,
            timelineViewport: timeline,
            priceViewport: priceViewport,
            totalSlotCount: frame.map(
              KlineChartSceneController.totalSlotCount
            ) ?? 0,
            onTimelineViewportChange: { next in
              let totalSlotCount = frame.map(
                KlineChartSceneController.totalSlotCount
              ) ?? 0
              controller.updateTimelineViewport(
                next,
                totalSlotCount: totalSlotCount
              )
              if shouldRequestOlderHistory(
                viewport: next,
                totalSlotCount: totalSlotCount
              ) {
                onNeedsOlderHistory()
              }
            },
            onPriceViewportChange: { next in
              controller.updatePriceViewport(next)
            },
            onFirstFramePresented: { time in
              if let epoch = frame?.epoch { onFirstFramePresented(epoch, time) }
            },
            onCrosshairSelection: onCrosshairSelection,
            onCrosshairDismiss: onCrosshairDismiss
          )
          .transition(.opacity)
        } else {
          BinanceKlineLoadingIndicator()
        }
      }
      .background(BinanceTheme.background)
      .task(id: key) {
        controller.diagnostics = diagnostics
        controller.requestRender(
          frame: frame,
          viewport: viewport,
          proposedTimelineViewport: timeline,
          proposedPriceViewport: priceViewport
        )
      }
      .onDisappear {
        controller.cancelPendingRenders()
      }
      .onChange(
        of: controller.priceProjection,
        initial: true
      ) { _, projection in
        onPriceProjectionChange(projection)
      }
    }
  }

  private func shouldRequestOlderHistory(
    viewport: ChartTimelineViewport,
    totalSlotCount: Int
  ) -> Bool {
    KlineChartSceneController.shouldRequestOlderHistory(
      viewport: viewport,
      totalSlotCount: totalSlotCount
    )
  }

  private func taskKey(
    viewport: ChartSceneViewport?,
    timelineViewport: ChartTimelineViewport,
    priceViewport: ChartPriceViewport
  ) -> KlineChartSceneController.RequestKey? {
    guard let frame, let viewport else {
      return nil
    }
    return KlineChartSceneController.RequestKey(
      stream: frame.stream,
      epoch: frame.epoch,
      candleRevision: frame.candles.revision,
      indicatorHistory: ObjectIdentifier(
        frame.indicators.history
      ),
      viewport: viewport,
      timelineViewport: timelineViewport,
      priceViewport: priceViewport
    )
  }

  private func effectiveTimelineViewport(
    frame: ChartDataFrame?,
    viewport: ChartSceneViewport?
  ) -> ChartTimelineViewport {
    let width = viewport?.widthPoints ?? 390
    let proposed = controller.timelineViewport
      ?? ChartTimelineViewport.latest(
        totalWidthPoints: width
      )
    guard let frame else {
      return proposed
    }
    return proposed.clamped(
      totalSlotCount:
        KlineChartSceneController.totalSlotCount(frame)
    )
  }
}

enum BinanceKlineLoadingAnimation {
  static let barCount = 4
  static let barWidth: CGFloat = 10 / 3
  static let barSpacing: CGFloat = 8 / 3
  static let minimumHeight: CGFloat = 10 / 3
  static let maximumHeight: CGFloat = 10
  static let cycleDuration: TimeInterval = 0.72

  static var width: CGFloat {
    CGFloat(barCount) * barWidth
      + CGFloat(barCount - 1) * barSpacing
  }

  static func heights(
    elapsed: TimeInterval
  ) -> [CGFloat] {
    guard elapsed.isFinite else {
      return Array(
        repeating: minimumHeight,
        count: barCount
      )
    }
    let cycle = elapsed / cycleDuration
    return (0..<barCount).map { index in
      let wave = sin(
        (cycle - Double(index) * 0.13)
          * 2 * Double.pi
      )
      let normalized = (wave + 1) * 0.5
      let eased = normalized * normalized
        * (3 - 2 * normalized)
      return minimumHeight
        + (maximumHeight - minimumHeight)
          * CGFloat(eased)
    }
  }
}

private struct BinanceKlineLoadingIndicator: View {
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    TimelineView(
      .animation(
        minimumInterval: 1 / 60,
        paused: reduceMotion
      )
    ) { timeline in
      let elapsed = timeline.date
        .timeIntervalSinceReferenceDate
      let heights = reduceMotion
        ? [
          BinanceKlineLoadingAnimation.minimumHeight,
          5.5,
          7.5,
          BinanceKlineLoadingAnimation.maximumHeight,
        ]
        : BinanceKlineLoadingAnimation.heights(
          elapsed: elapsed
        )

      HStack(
        alignment: .bottom,
        spacing: BinanceKlineLoadingAnimation.barSpacing
      ) {
        ForEach(0..<BinanceKlineLoadingAnimation.barCount, id: \.self) {
          index in
          Rectangle()
            .fill(BinanceTheme.accent)
            .frame(
              width: BinanceKlineLoadingAnimation.barWidth,
              height: heights[index]
            )
        }
      }
      .frame(
        width: BinanceKlineLoadingAnimation.width,
        height: BinanceKlineLoadingAnimation.maximumHeight,
        alignment: .bottom
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(BinanceTheme.background)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("K线加载中")
    .accessibilityIdentifier(
      "market-chart-loading-indicator"
    )
  }
}
