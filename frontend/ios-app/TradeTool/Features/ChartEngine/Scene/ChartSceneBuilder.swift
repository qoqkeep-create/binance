import Foundation

struct ChartSceneViewport: Hashable, Sendable {
  let widthPixels: Int
  let heightPixels: Int
  let displayScale: Double

  var widthPoints: Double {
    Double(widthPixels) / displayScale
  }

  init?(
    widthPoints: Double,
    heightPoints: Double,
    displayScale: Double
  ) {
    guard widthPoints.isFinite,
      heightPoints.isFinite,
      widthPoints >= 120,
      heightPoints >= 120,
      displayScale.isFinite,
      (1...4).contains(displayScale)
    else {
      return nil
    }
    let width = widthPoints * displayScale
    let height = heightPoints * displayScale
    guard width.isFinite,
      height.isFinite,
      width <= Double(Int.max),
      height <= Double(Int.max)
    else {
      return nil
    }
    widthPixels = Int(width.rounded())
    heightPixels = Int(height.rounded())
    self.displayScale = displayScale
  }
}

struct ChartPriceViewport: Hashable, Sendable {
  static let automatic = ChartPriceViewport(
    validatedMagnification: 1
  )

  static let minimumMagnification = 0.35
  static let maximumMagnification = 4.5
  static let dragSensitivityPoints = 120.0

  let magnification: Double

  init?(magnification: Double) {
    guard magnification.isFinite,
      magnification >= Self.minimumMagnification,
      magnification <= Self.maximumMagnification
    else {
      return nil
    }
    self.magnification = magnification
  }

  func adjusted(
    verticalTranslationPoints: Double
  ) -> ChartPriceViewport {
    guard verticalTranslationPoints.isFinite else {
      return self
    }
    let factor = exp(
      -verticalTranslationPoints
        / Self.dragSensitivityPoints
    )
    let next = min(
      Self.maximumMagnification,
      max(
        Self.minimumMagnification,
        magnification * factor
      )
    )
    return ChartPriceViewport(
      validatedMagnification: next
    )
  }

  private init(validatedMagnification: Double) {
    magnification = validatedMagnification
  }
}

struct ChartSceneBuildOutput: Sendable {
  let renderState: RenderState
  let staticSceneReused: Bool
  let visibleClosedCandleCount: Int
  let renderedClosedCandleCount: Int
  let priceLowerBound: Double
  let priceUpperBound: Double
  let panelLayout: ChartPanelLayout
}

enum ChartSceneBuilderError: Error {
  case emptyFrame
  case invalidGeometry
}

actor ChartSceneBuilder {
  private struct StaticIdentity: Equatable {
    let stream: ChartStreamKey
    let epoch: KlineStreamEpoch
    let candleHistory: ObjectIdentifier
    let indicatorHistory: ObjectIdentifier
    let viewport: ChartSceneViewport
    let timelineViewport: ChartTimelineViewport
    let priceViewport: ChartPriceViewport
    let reservesLiveSlot: Bool
    let indicatorPanelIDs: [String]
  }

  private struct PriceDomain: Sendable {
    let lower: Double
    let upper: Double

    var span: Double {
      upper - lower
    }

    func contains(_ values: [Double]) -> Bool {
      values.allSatisfy {
        $0.isFinite && $0 >= lower && $0 <= upper
      }
    }

    func y(
      for price: Double,
      top: Float,
      bottom: Float
    ) -> Float? {
      guard price.isFinite,
        span.isFinite,
        span > 0
      else {
        return nil
      }
      let fraction = (upper - price) / span
      let value =
        Double(top)
        + fraction * Double(bottom - top)
      guard value.isFinite,
        abs(value)
          <= Double(Float.greatestFiniteMagnitude)
      else {
        return nil
      }
      return Float(value)
    }

    func ticks(count: Int) -> [Double] {
      guard count > 1 else {
        return [upper]
      }
      return (0..<count).map { index in
        upper - span * Double(index) / Double(count - 1)
      }
    }

    func applying(
      _ viewport: ChartPriceViewport,
      verticalSpaceScale: Double
    ) -> PriceDomain? {
      let center = (lower + upper) / 2
      let adjustedSpan = span * verticalSpaceScale / viewport.magnification
      guard center.isFinite,
        adjustedSpan.isFinite,
        adjustedSpan > 0
      else {
        return nil
      }
      let halfSpan = adjustedSpan / 2
      let adjustedLower = center - halfSpan
      let adjustedUpper = center + halfSpan
      guard adjustedLower.isFinite,
        adjustedUpper.isFinite,
        adjustedUpper > adjustedLower
      else {
        return nil
      }
      return PriceDomain(
        lower: adjustedLower,
        upper: adjustedUpper
      )
    }
  }

  private struct Geometry: Sendable {
    let width: Float
    let height: Float
    let scale: Float
    let plotLeft: Float
    let plotTop: Float
    let plotRight: Float
    let plotBottom: Float
    let timelineViewport: ChartTimelineViewport
    let slotWidth: Float
    let halfBodyWidth: Float
    let panelLayout: ChartPanelLayout

    init?(
      viewport: ChartSceneViewport,
      timelineViewport: ChartTimelineViewport,
      indicatorPanelIDs: [String]
    ) {
      let width = Float(viewport.widthPixels)
      let height = Float(viewport.heightPixels)
      let scale = Float(viewport.displayScale)
      guard width.isFinite,
        height.isFinite,
        scale.isFinite,
        width > 0,
        height > 0,
        scale > 0
      else {
        return nil
      }

      guard
        let panelLayout = ChartPanelLayout.make(
          viewport: viewport,
          indicatorPanelIDs: indicatorPanelIDs
        ),
        let pricePanel = panelLayout.pricePanel
      else {
        return nil
      }
      let plotLeft = pricePanel.plot.left
      let plotTop = pricePanel.plot.top
      let plotRight = pricePanel.plot.right
      let plotBottom = pricePanel.plot.bottom
      let plotWidth = plotRight - plotLeft
      let plotHeight = plotBottom - plotTop
      guard plotWidth >= 48 * scale,
        plotHeight >= 48 * scale
      else {
        return nil
      }

      let slotWidth = plotWidth
        / Float(timelineViewport.visibleSlotCount)

      self.width = width
      self.height = height
      self.scale = scale
      self.plotLeft = plotLeft
      self.plotTop = plotTop
      self.plotRight = plotRight
      self.plotBottom = plotBottom
      self.panelLayout = panelLayout
      self.timelineViewport = timelineViewport
      self.slotWidth = slotWidth
      halfBodyWidth = Float(
        ChartInteractionMetrics.standard.candleHalfBodyWidthPixels(
          visibleSlotCount: timelineViewport.visibleSlotCount,
          totalWidthPoints: viewport.widthPoints,
          displayScale: viewport.displayScale
        )
      )
    }

    func x(
      globalSlot: Int,
      totalSlotCount: Int
    ) -> Float {
      let latestSlot = max(0, totalSlotCount - 1)
      let localSlot = timelineViewport.visibleSlotCount
        - 0.5
        + timelineViewport.trailingOffsetSlots
        + Double(globalSlot - latestSlot)
      return plotLeft + Float(localSlot) * slotWidth
    }

    func containsPlotX(_ x: Float) -> Bool {
      x.isFinite && x >= plotLeft && x <= plotRight
    }

    func containsCanvasX(_ x: Float) -> Bool {
      x.isFinite && x >= 0 && x <= width
    }

    func intersectsCanvasX(
      _ x: Float,
      halfWidth: Float
    ) -> Bool {
      x.isFinite
        && halfWidth.isFinite
        && halfWidth >= 0
        && x + halfWidth >= 0
        && x - halfWidth <= width
    }

    func containsGuardBandX(
      _ x: Float,
      guardBandSlotCount: Int
    ) -> Bool {
      guard x.isFinite,
        guardBandSlotCount >= 0
      else {
        return false
      }
      let extensionWidth = slotWidth
        * Float(guardBandSlotCount)
      return x >= plotLeft - extensionWidth
        && x <= plotRight + extensionWidth
    }
  }

  private struct StaticCache {
    let identity: StaticIdentity
    let domain: PriceDomain
    let panelDomains: [String: PriceDomain]
    let scene: StaticSceneSnapshot
    let atlas: ChartGlyphAtlasSnapshot
    let geometry: Geometry
    let visibleHistoryRange: Range<Int>
    let canvasVisibleHistoryRange: Range<Int>
    let renderedHistoryRange: Range<Int>
    let latestX: Float
    let liveX: Float?
    let anchors: [ChartIndicatorSeriesKey: ChartPolylinePoint]
  }

  private enum LatestPriceHorizontalState {
    case visible
    case offscreenLeading
    case offscreenTrailing
  }

  private struct VisibleCandleAnchor {
    let candle: ChartCandle
    let x: Float
  }

  private struct ExtremaAnnotation {
    let line: ChartLineSegmentInstance
    let glyphs: [ChartGlyphInstance]
  }

  private struct LiveBuildOutput {
    let batches: [ChartRenderBatch]
    let latestPriceMarker: ChartLatestPriceMarkerSnapshot?
    let displayedLegends: [ChartIndicatorLegendEntry]
  }

  private let atlasBuilder = MetalGlyphAtlasBuilder()
  private var atlasCache: [ChartGlyphAtlasKey: ChartGlyphAtlasSnapshot] = [:]
  private lazy var timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = .current
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter
  }()
  private var staticCache: StaticCache?
  private var nextRevision: UInt64 = 1

  func build(
    frame: ChartDataFrame,
    viewport: ChartSceneViewport,
    timelineViewport requestedTimelineViewport:
      ChartTimelineViewport? = nil,
    priceViewport: ChartPriceViewport = .automatic
  ) throws -> ChartSceneBuildOutput {
    try Task.checkCancellation()
    let panelIDs = indicatorPanelIDs(frame)
    let history = frame.candles.history.candles
    guard !history.isEmpty || frame.candles.liveTail != nil else {
      throw ChartSceneBuilderError.emptyFrame
    }
    let reservesLiveSlot = frame.candles.liveTail != nil
    let totalSlotCount = history.count + (reservesLiveSlot ? 1 : 0)
    let timelineViewport = (
      requestedTimelineViewport
        ?? ChartTimelineViewport.latest(
          totalWidthPoints: viewport.widthPoints
        )
    ).clamped(totalSlotCount: totalSlotCount)
    guard
      let geometry = Geometry(
        viewport: viewport,
        timelineViewport: timelineViewport,
        indicatorPanelIDs: panelIDs
      )
    else {
      throw ChartSceneBuilderError.invalidGeometry
    }
    let visibleRange = visibleHistoryRange(
      historyCount: history.count,
      totalSlotCount: totalSlotCount,
      timelineViewport: timelineViewport
    )
    let renderedRange = renderedHistoryRange(
      visibleRange: visibleRange,
      historyCount: history.count,
      guardBandSlotCount: ChartInteractionMetrics.standard
        .guardBandSlotCount
    )
    let canvasVisibleRange = canvasVisibleHistoryRange(
      renderedRange: renderedRange,
      totalSlotCount: totalSlotCount,
      geometry: geometry
    )
    let latestX = geometry.x(
      globalSlot: totalSlotCount - 1,
      totalSlotCount: totalSlotCount
    )
    let visibleLatestX = geometry.containsCanvasX(latestX)
      ? latestX
      : nil
    let bufferedLatestX = geometry.containsGuardBandX(
      latestX,
      guardBandSlotCount: ChartInteractionMetrics.standard
        .guardBandSlotCount
    ) ? latestX : nil
    let liveX = reservesLiveSlot ? bufferedLatestX : nil
    let identity = StaticIdentity(
      stream: frame.stream,
      epoch: frame.epoch,
      candleHistory: ObjectIdentifier(frame.candles.history),
      indicatorHistory: ObjectIdentifier(
        frame.indicators.history
      ),
      viewport: viewport,
      timelineViewport: timelineViewport,
      priceViewport: priceViewport,
      reservesLiveSlot: reservesLiveSlot,
      indicatorPanelIDs: panelIDs
    )
    let includesLiveValues = visibleLatestX != nil
    let dynamicPrices = includesLiveValues
      ? livePrices(frame)
      : []

    let cache: StaticCache
    let reused: Bool
    if let staticCache,
      staticCache.identity == identity,
      staticCache.visibleHistoryRange == visibleRange,
      staticCache.renderedHistoryRange == renderedRange,
      (
        priceViewport != .automatic
          || staticCache.domain.contains(dynamicPrices)
      ),
      (!includesLiveValues || panelDomainsContainLiveValues(
        frame: frame,
        cache: staticCache
      ))
    {
      cache = staticCache
      reused = true
    } else {
      let atlas = try atlas(for: viewport)
      let values =
        staticPrices(
          frame: frame,
          visibleRange: canvasVisibleRange
        ) + dynamicPrices
      // Fit the visible prices to the available plot height, including after a zoom.
      let verticalSpaceScale = 1.0
      guard let automaticDomain = makePriceDomain(values),
        let domain = automaticDomain.applying(
          priceViewport,
          verticalSpaceScale: verticalSpaceScale
        )
      else {
        throw ChartSceneBuilderError.emptyFrame
      }
      cache = makeStaticCache(
        frame: frame,
        identity: identity,
        geometry: geometry,
        domain: domain,
        atlas: atlas,
        visibleRange: visibleRange,
        canvasVisibleRange: canvasVisibleRange,
        renderedRange: renderedRange,
        totalSlotCount: totalSlotCount,
        latestX: latestX,
        visibleLatestX: visibleLatestX,
        liveX: liveX,
        includesLiveValues: includesLiveValues
      )
      staticCache = cache
      reused = false
    }

    try Task.checkCancellation()
    let liveRevision = consumeRevision()
    let liveBuild = makeLiveBatches(
      frame: frame,
      cache: cache
    )
    let latestCandle =
      frame.candles.liveTail
      ?? history.last
    let state = RenderState(
      staticScene: cache.scene,
      liveTail: LiveTailSnapshot(
        revision: liveRevision,
        readyTime: frame.readyTime,
        candle: frame.candles.liveTail,
        batches: liveBuild.batches,
        latestPrice: latestCandle?.closePrice,
        latestPriceMarker: liveBuild.latestPriceMarker,
        displayedLegends: liveBuild.displayedLegends,
        crosshairLiveData: ChartCrosshairLiveData(
          candle: frame.candles.liveTail,
          indicatorPoints: frame.indicators.livePoints,
          legends: liveBuild.displayedLegends
        )
      ),
      interaction: InteractionSnapshot(
        revision: 0,
        translationX: 0,
        scaleX: 1,
        candleHalfWickWidthPixels:
          ChartInteractionMetrics.standard
            .candleHalfWickWidthPixels(
              displayScale: viewport.displayScale
            ),
        crosshair: nil
      ),
      invalidation: reused
        ? [
          .data, .indicators, .annotations,
          .textAndAccessibility,
        ]
        : .full
    )
    return ChartSceneBuildOutput(
      renderState: state,
      staticSceneReused: reused,
      visibleClosedCandleCount:
        cache.visibleHistoryRange.count,
      renderedClosedCandleCount:
        cache.renderedHistoryRange.count,
      priceLowerBound: cache.domain.lower,
      priceUpperBound: cache.domain.upper,
      panelLayout: cache.geometry.panelLayout
    )
  }

  private func visibleHistoryRange(
    historyCount: Int,
    totalSlotCount: Int,
    timelineViewport: ChartTimelineViewport
  ) -> Range<Int> {
    guard historyCount > 0, totalSlotCount > 0 else {
      return 0..<0
    }
    let firstCandidate = ceil(
      Double(totalSlotCount)
        - timelineViewport.visibleSlotCount
        - timelineViewport.trailingOffsetSlots
        - 0.5
    )
    let lastCandidate = floor(
      Double(totalSlotCount)
        - timelineViewport.trailingOffsetSlots
        - 0.5
    )
    let lower = min(
      historyCount,
      max(0, Int(firstCandidate))
    )
    let upper = min(
      historyCount,
      max(lower, Int(lastCandidate) + 1)
    )
    return lower..<upper
  }

  private func renderedHistoryRange(
    visibleRange: Range<Int>,
    historyCount: Int,
    guardBandSlotCount: Int
  ) -> Range<Int> {
    guard historyCount > 0,
      !visibleRange.isEmpty,
      guardBandSlotCount >= 0
    else {
      return visibleRange
    }
    return max(
      0,
      visibleRange.lowerBound - guardBandSlotCount
    )..<min(
      historyCount,
      visibleRange.upperBound + guardBandSlotCount
    )
  }

  private func canvasVisibleHistoryRange(
    renderedRange: Range<Int>,
    totalSlotCount: Int,
    geometry: Geometry
  ) -> Range<Int> {
    var lowerBound: Int?
    var upperBound: Int?
    for index in renderedRange {
      let x = geometry.x(
        globalSlot: index,
        totalSlotCount: totalSlotCount
      )
      guard geometry.intersectsCanvasX(
        x,
        halfWidth: geometry.halfBodyWidth
      ) else {
        continue
      }
      lowerBound = lowerBound ?? index
      upperBound = index + 1
    }
    guard let lowerBound, let upperBound else {
      return renderedRange.lowerBound..<renderedRange.lowerBound
    }
    return lowerBound..<upperBound
  }

  private func makeStaticCache(
    frame: ChartDataFrame,
    identity: StaticIdentity,
    geometry: Geometry,
    domain: PriceDomain,
    atlas: ChartGlyphAtlasSnapshot,
    visibleRange: Range<Int>,
    canvasVisibleRange: Range<Int>,
    renderedRange: Range<Int>,
    totalSlotCount: Int,
    latestX: Float,
    visibleLatestX: Float?,
    liveX: Float?,
    includesLiveValues: Bool
  ) -> StaticCache {
    let history = frame.candles.history.candles
    var candles: [ChartCandleInstance] = []
    candles.reserveCapacity(renderedRange.count)
    var xValues: [Float] = []
    xValues.reserveCapacity(renderedRange.count)

    for index in renderedRange {
      let candle = history[index]
      let x = geometry.x(
        globalSlot: index,
        totalSlotCount: totalSlotCount
      )
      xValues.append(x)
      if let instance = candleInstance(
        candle,
        x: x,
        geometry: geometry,
        domain: domain
      ) {
        candles.append(instance)
      }
    }

    let panelDomains = makePanelDomains(
      frame: frame,
      visibleRange: canvasVisibleRange,
      includesLiveValues: includesLiveValues,
      panelLayout: geometry.panelLayout
    )
    var lines: [ChartLineSegmentInstance] = []
    var bars: [ChartBarInstance] = []
    var anchors: [ChartIndicatorSeriesKey: ChartPolylinePoint] = [:]
    for series in frame.indicators.history.series
    where series.placement == .priceOverlay {
      switch series.figureStyle {
      case .line:
        lines.append(
          contentsOf: indicatorSegments(
            points: series.points,
            candles: history,
            visibleRange: renderedRange,
            xValues: xValues,
            domain: domain,
            top: geometry.plotTop,
            bottom: geometry.plotBottom,
            scale: geometry.scale,
            lineWidthPoints: series.lineWidthPoints,
            color: series.colorToken.color
          ))
      case .lineWithCandleCloseBand(let fillAlpha):
        bars.append(
          contentsOf: indicatorPriceBandBars(
            points: series.points,
            candles: history,
            visibleRange: renderedRange,
            xValues: xValues,
            domain: domain,
            top: geometry.plotTop,
            bottom: geometry.plotBottom,
            halfSlotWidth: geometry.slotWidth / 2,
            color: series.colorToken.color.withAlpha(fillAlpha)
          ))
        lines.append(
          contentsOf: indicatorSegments(
            points: series.points,
            candles: history,
            visibleRange: renderedRange,
            xValues: xValues,
            domain: domain,
            top: geometry.plotTop,
            bottom: geometry.plotBottom,
            scale: geometry.scale,
            lineWidthPoints: series.lineWidthPoints,
            color: series.colorToken.color
          ))
      case .hollowSquareMarker(let sizePoints):
        lines.append(
          contentsOf: indicatorHollowSquareMarkers(
            points: series.points,
            candles: history,
            visibleRange: renderedRange,
            xValues: xValues,
            domain: domain,
            top: geometry.plotTop,
            bottom: geometry.plotBottom,
            scale: geometry.scale,
            sizePoints: sizePoints,
            lineWidthPoints: series.lineWidthPoints,
            color: series.colorToken.color
          ))
      case .histogramFromZero, .pairedHistogramFromZero,
        .areaFromZero:
        continue
      }
      switch series.figureStyle {
      case .line, .lineWithCandleCloseBand:
        if let anchor = lastIndicatorAnchor(
          points: series.points,
          candles: history,
          visibleRange: renderedRange,
          xValues: xValues,
          domain: domain,
          top: geometry.plotTop,
          bottom: geometry.plotBottom
        ) {
          anchors[series.key] = anchor
        }
      case .hollowSquareMarker, .histogramFromZero,
        .pairedHistogramFromZero, .areaFromZero:
        break
      }
    }

    for panel in geometry.panelLayout.indicatorPanels {
      guard let panelDomain = panelDomains[panel.id] else {
        continue
      }
      for series in frame.indicators.history.series
      where series.placement == .panel(panel.id) {
        switch series.figureStyle {
        case .line:
          lines.append(
            contentsOf: indicatorSegments(
              points: series.points,
              candles: history,
              visibleRange: renderedRange,
              xValues: xValues,
              domain: panelDomain,
              top: panel.plot.top,
              bottom: panel.plot.bottom,
              scale: geometry.scale,
              lineWidthPoints: series.lineWidthPoints,
              color: series.colorToken.color
            ))
          if let anchor = lastIndicatorAnchor(
            points: series.points,
            candles: history,
            visibleRange: renderedRange,
            xValues: xValues,
            domain: panelDomain,
            top: panel.plot.top,
            bottom: panel.plot.bottom
          ) {
            anchors[series.key] = anchor
          }
        case .lineWithCandleCloseBand:
          continue
        case .hollowSquareMarker(let sizePoints):
          lines.append(
            contentsOf: indicatorHollowSquareMarkers(
              points: series.points,
              candles: history,
              visibleRange: renderedRange,
              xValues: xValues,
              domain: panelDomain,
              top: panel.plot.top,
              bottom: panel.plot.bottom,
              scale: geometry.scale,
              sizePoints: sizePoints,
              lineWidthPoints: series.lineWidthPoints,
              color: series.colorToken.color
            ))
        case .histogramFromZero(let colorStrategy):
          bars.append(
            contentsOf: indicatorHistogramBars(
              points: series.points,
              candles: history,
              visibleRange: renderedRange,
              xValues: xValues,
              domain: panelDomain,
              panel: panel,
              halfWidth: geometry.halfBodyWidth,
              color: series.colorToken.color,
              colorStrategy: colorStrategy,
              scale: geometry.scale
            ))
        case .pairedHistogramFromZero(
          let colorStrategy,
          let position
        ):
          bars.append(
            contentsOf: indicatorHistogramBars(
              points: series.points,
              candles: history,
              visibleRange: renderedRange,
              xValues: xValues,
              domain: panelDomain,
              panel: panel,
              halfWidth: geometry.halfBodyWidth,
              color: series.colorToken.color,
              colorStrategy: colorStrategy,
              scale: geometry.scale,
              position: position
            ))
        case .areaFromZero(let fillAlpha):
          bars.append(
            contentsOf: indicatorHistogramBars(
              points: series.points,
              candles: history,
              visibleRange: renderedRange,
              xValues: xValues,
              domain: panelDomain,
              panel: panel,
              halfWidth: geometry.slotWidth / 2,
              color: series.colorToken.color,
              colorStrategy: .fixed,
              scale: geometry.scale,
              fillAlpha: fillAlpha
            ))
        }
      }
    }

    let visibleXValues = visibleRange.map {
      geometry.x(
        globalSlot: $0,
        totalSlotCount: totalSlotCount
      )
    }
    var missingGlyphCount = 0
    var glyphs: [ChartGlyphInstance] = []
    glyphs.append(
      contentsOf: priceAxisGlyphs(
        domain: domain,
        geometry: geometry,
        atlas: atlas,
        missingGlyphCount: &missingGlyphCount
      ))
    glyphs.append(
      contentsOf: timeAxisGlyphs(
        history: history,
        visibleRange: visibleRange,
        historyXValues: visibleXValues,
        liveOpenTime: frame.candles.liveTail?.openTime,
        liveX: visibleLatestX,
        geometry: geometry,
        atlas: atlas,
        missingGlyphCount: &missingGlyphCount
      ))
    for panel in geometry.panelLayout.indicatorPanels {
      guard let panelDomain = panelDomains[panel.id] else {
        continue
      }
      glyphs.append(
        contentsOf: panelAxisGlyphs(
          domain: panelDomain,
          panel: panel,
          geometry: geometry,
          atlas: atlas,
          missingGlyphCount: &missingGlyphCount
        ))
    }
    _ = missingGlyphCount

    let timelineBatch = ChartRenderBatch(
      candleInstances: candles,
      lineSegments: lines,
      barInstances: bars,
      coordinateSpace: .timeline
    )
    let gridBatch = ChartRenderBatch(
      barInstances: gridBars(
        geometry: geometry,
        domain: domain,
        panelDomains: panelDomains
      ),
      coordinateSpace: .fixed
    )
    let fixedBatch = ChartRenderBatch(
      glyphInstances: glyphs,
      glyphAtlas: atlas,
      coordinateSpace: .fixed
    )
    let crosshairPanelDomains = Dictionary(
      uniqueKeysWithValues: panelDomains.compactMap {
        panelID, valueDomain in
        ChartCrosshairValueDomain(
          lower: valueDomain.lower,
          upper: valueDomain.upper
        ).map { (panelID, $0) }
      }
    )
    let crosshairData = ChartCrosshairValueDomain(
      lower: domain.lower,
      upper: domain.upper
    ).flatMap { priceDomain in
      ChartCrosshairDataSnapshot(
        stream: frame.stream,
        history: frame.candles.history,
        indicatorHistory: frame.indicators.history,
        panelLayout: geometry.panelLayout,
        priceDomain: priceDomain,
        panelDomains: crosshairPanelDomains,
        glyphAtlas: atlas,
        timelineViewport: geometry.timelineViewport,
        totalSlotCount: totalSlotCount,
        reservesLiveSlot: frame.candles.liveTail != nil,
        widthPixels: geometry.width,
        heightPixels: geometry.height,
        displayScale: geometry.scale,
        slotWidthPixels: geometry.slotWidth
      )
    }
    let scene = StaticSceneSnapshot(
      revision: consumeRevision(),
      candleHistory: frame.candles.history,
      batches: [gridBatch, timelineBatch, fixedBatch],
      timelineViewport: geometry.timelineViewport,
      horizontalPlotBounds: ChartHorizontalPlotBounds(
        left: geometry.plotLeft,
        right: geometry.width
      ),
      crosshairData: crosshairData
    )
    return StaticCache(
      identity: identity,
      domain: domain,
      panelDomains: panelDomains,
      scene: scene,
      atlas: atlas,
      geometry: geometry,
      visibleHistoryRange: visibleRange,
      canvasVisibleHistoryRange: canvasVisibleRange,
      renderedHistoryRange: renderedRange,
      latestX: latestX,
      liveX: liveX,
      anchors: anchors
    )
  }

  private func makeLiveBatches(
    frame: ChartDataFrame,
    cache: StaticCache
  ) -> LiveBuildOutput {
    let geometry = cache.geometry
    let domain = cache.domain
    let live = frame.candles.liveTail
    let latest =
      live
      ?? frame.candles.history.candles.last
    guard let latest else {
      return LiveBuildOutput(
        batches: [],
        latestPriceMarker: nil,
        displayedLegends: []
      )
    }
    let latestY =
      domain.y(
        for: latest.closePrice,
        top: geometry.plotTop,
        bottom: geometry.plotBottom
      ) ?? geometry.plotBottom
    var candles: [ChartCandleInstance] = []
    if let live,
      let liveX = cache.liveX,
      let instance = candleInstance(
        live,
        x: liveX,
        geometry: geometry,
        domain: domain
      )
    {
      candles.append(instance)
    }

    var lines: [ChartLineSegmentInstance] = []
    var bars: [ChartBarInstance] = []
    var indicatorStyles: [ChartIndicatorSeriesKey: ChartIndicatorSeriesHistory] = [:]
    for series in frame.indicators.history.series {
      indicatorStyles[series.key] = series
    }
    for livePoint in frame.indicators.livePoints {
      guard let liveX = cache.liveX else {
        break
      }
      guard let style = indicatorStyles[livePoint.key]
      else {
        continue
      }
      let target:
        (
          domain: PriceDomain,
          top: Float,
          bottom: Float
        )?
      switch style.placement {
      case .priceOverlay:
        target = (
          domain,
          geometry.plotTop,
          geometry.plotBottom
        )
      case .panel(let panelID):
        guard let panel = geometry.panelLayout.panel(id: panelID),
          let panelDomain = cache.panelDomains[panelID]
        else {
          continue
        }
        target = (
          panelDomain,
          panel.plot.top,
          panel.plot.bottom
        )
      }
      guard let target else {
        continue
      }
      switch style.figureStyle {
      case .line:
        appendLiveIndicator(
          point: livePoint.point,
          anchor: cache.anchors[livePoint.key],
          x: liveX,
          lineWidthPoints: style.lineWidthPoints,
          color: style.colorToken.color,
          domain: target.domain,
          top: target.top,
          bottom: target.bottom,
          scale: geometry.scale,
          lines: &lines
        )
      case .lineWithCandleCloseBand(let fillAlpha):
        appendLiveIndicator(
          point: livePoint.point,
          anchor: cache.anchors[livePoint.key],
          x: liveX,
          lineWidthPoints: style.lineWidthPoints,
          color: style.colorToken.color,
          domain: target.domain,
          top: target.top,
          bottom: target.bottom,
          scale: geometry.scale,
          lines: &lines
        )
        if style.placement == .priceOverlay,
          let bar = indicatorPriceBandBar(
            point: livePoint.point,
            candle: latest,
            x: liveX,
            domain: target.domain,
            top: target.top,
            bottom: target.bottom,
            halfSlotWidth: geometry.slotWidth / 2,
            color: style.colorToken.color.withAlpha(fillAlpha)
          )
        {
          bars.append(bar)
        }
      case .hollowSquareMarker(let sizePoints):
        if let marker = liveIndicatorHollowSquareMarker(
          point: livePoint.point,
          x: liveX,
          domain: target.domain,
          top: target.top,
          bottom: target.bottom,
          scale: geometry.scale,
          sizePoints: sizePoints,
          lineWidthPoints: style.lineWidthPoints,
          color: style.colorToken.color
        ) {
          lines.append(contentsOf: marker)
        }
      case .histogramFromZero(let colorStrategy):
        if let bar = liveIndicatorHistogramBar(
          point: livePoint.point,
          candle: latest,
          x: liveX,
          domain: target.domain,
          top: target.top,
          bottom: target.bottom,
          halfWidth: geometry.halfBodyWidth,
          color: style.colorToken.color,
          colorStrategy: colorStrategy,
          scale: geometry.scale
        ) {
          let previous = frame.indicators.history.series.first { $0.key == livePoint.key }?.points.last
          bars.append(contentsOf: histogramBars(bar, value: livePoint.point.value,
            previous: previous?.validity == .valid ? previous?.value : nil,
            strategy: colorStrategy, scale: geometry.scale))
        }
      case .pairedHistogramFromZero(
        let colorStrategy,
        let position
      ):
        if let bar = liveIndicatorHistogramBar(
          point: livePoint.point,
          candle: latest,
          x: liveX,
          domain: target.domain,
          top: target.top,
          bottom: target.bottom,
          halfWidth: geometry.halfBodyWidth,
          color: style.colorToken.color,
          colorStrategy: colorStrategy,
          scale: geometry.scale,
          position: position
        ) {
          bars.append(bar)
        }
      case .areaFromZero(let fillAlpha):
        if let bar = liveIndicatorHistogramBar(
          point: livePoint.point,
          candle: latest,
          x: liveX,
          domain: target.domain,
          top: target.top,
          bottom: target.bottom,
          halfWidth: geometry.slotWidth / 2,
          color: style.colorToken.color,
          colorStrategy: .fixed,
          scale: geometry.scale,
          fillAlpha: fillAlpha
        ) {
          bars.append(bar)
        }
      }
    }

    let latestPriceState: LatestPriceHorizontalState
    if cache.latestX + geometry.halfBodyWidth < 0 {
      latestPriceState = .offscreenLeading
    } else if cache.latestX - geometry.halfBodyWidth > geometry.width {
      latestPriceState = .offscreenTrailing
    } else {
      latestPriceState = .visible
    }
    let label = formattedPrice(
      latest.closePrice,
      reference: latest.closePrice
    )
    let markerText: String
    switch latestPriceState {
    case .visible:
      markerText = label
    case .offscreenLeading:
      markerText = "< \(label)"
    case .offscreenTrailing:
      markerText = "\(label) >"
    }
    let measuredMarkerText = alignedText(
      markerText,
      atlas: cache.atlas,
      x: 0,
      baselineY: 0,
      alignment: .leading,
      color: .primaryText
    )
    let markerHalfHeight = 8 * geometry.scale
    let markerTop = min(
      geometry.plotBottom - markerHalfHeight * 2,
      max(geometry.plotTop, latestY - markerHalfHeight)
    )
    let normalMarkerLeft = geometry.plotRight + 2 * geometry.scale
    let offscreenMarkerWidth = max(
      58 * geometry.scale,
      Float(measuredMarkerText.advance) + 10 * geometry.scale
    )
    let markerLeft: Float
    let markerRight: Float
    switch latestPriceState {
    case .visible:
      markerLeft = normalMarkerLeft
      markerRight = geometry.width - geometry.scale
    case .offscreenLeading:
      markerLeft = geometry.plotLeft
      markerRight = min(
        geometry.plotRight,
        markerLeft + offscreenMarkerWidth
      )
    case .offscreenTrailing:
      markerRight = geometry.plotRight
      markerLeft = max(geometry.plotLeft, markerRight - offscreenMarkerWidth)
    }
    let marker = ChartBarInstance(
      left: markerLeft,
      top: markerTop,
      right: markerRight,
      bottom: markerTop + markerHalfHeight * 2,
      color: .latestPriceMarkerBackground
    )
    let markerBottom = marker.bottom
    let markerCenterY = (markerTop + markerBottom) / 2
    let borderWidth = max(1, geometry.scale * 0.7)
    let markerRadius = 4 * geometry.scale
    let markerFill = ChartLineSegmentInstance(
      start: ChartPolylinePoint(
        x: markerLeft + markerRadius,
        y: markerCenterY
      ),
      end: ChartPolylinePoint(
        x: markerRight - markerRadius,
        y: markerCenterY
      ),
      width: max(
        1,
        markerBottom - markerTop - borderWidth * 2
      ),
      dashLength: 0,
      gapLength: 0,
      dashPhase: 0,
      color: .chartBackground
    )
    let markerBorder = roundedRectangleBorder(
      left: markerLeft,
      top: markerTop,
      right: markerRight,
      bottom: markerBottom,
      radius: markerRadius,
      width: borderWidth,
      color: .latestPriceLine
    )
    var latestPriceFixedLines: [ChartLineSegmentInstance] = []
    switch latestPriceState {
    case .visible:
      latestPriceFixedLines.append(ChartLineSegmentInstance(
        start: ChartPolylinePoint(x: geometry.plotLeft, y: markerCenterY),
        end: ChartPolylinePoint(x: geometry.plotRight, y: markerCenterY),
        width: max(1, geometry.scale * 0.7),
        dashLength: 4 * geometry.scale,
        gapLength: 3 * geometry.scale,
        dashPhase: 0,
        color: .latestPriceLine
      ))
    case .offscreenLeading, .offscreenTrailing:
      if markerLeft > geometry.plotLeft {
        latestPriceFixedLines.append(ChartLineSegmentInstance(
          start: ChartPolylinePoint(x: geometry.plotLeft, y: markerCenterY),
          end: ChartPolylinePoint(
            x: markerLeft,
            y: markerCenterY
          ),
          width: max(1, geometry.scale * 0.7),
          dashLength: 4 * geometry.scale,
          gapLength: 3 * geometry.scale,
          dashPhase: 0,
          color: .latestPriceLine
        ))
      }
      if markerRight < geometry.plotRight {
        latestPriceFixedLines.append(ChartLineSegmentInstance(
          start: ChartPolylinePoint(
            x: markerRight,
            y: markerCenterY
          ),
          end: ChartPolylinePoint(
            x: geometry.plotRight,
            y: markerCenterY
          ),
          width: max(1, geometry.scale * 0.7),
          dashLength: 4 * geometry.scale,
          gapLength: 3 * geometry.scale,
          dashPhase: 0,
          color: .latestPriceLine
        ))
      }
    }
    let markerBaseline = markerCenterY + Float(
      (measuredMarkerText.ascent
        - measuredMarkerText.descent) / 2
    )
    let labelResult = alignedText(
      markerText,
      atlas: cache.atlas,
      x: markerRight - 3 * geometry.scale,
      baselineY: markerBaseline,
      alignment: .trailing,
      color: .primaryText
    )
    let textAnchor = markerRight - 3 * geometry.scale
    let textScale = min(1, (markerRight - markerLeft - 6 * geometry.scale)
      / max(1, Float(measuredMarkerText.advance)))
    let markerGlyphs = labelResult.instances.map { glyph in
      ChartGlyphInstance(
        left: textAnchor + (glyph.left - textAnchor) * textScale,
        top: markerCenterY + (glyph.top - markerCenterY) * textScale,
        right: textAnchor + (glyph.right - textAnchor) * textScale,
        bottom: markerCenterY + (glyph.bottom - markerCenterY) * textScale,
        uvLeft: glyph.uvLeft, uvTop: glyph.uvTop,
        uvRight: glyph.uvRight, uvBottom: glyph.uvBottom, color: glyph.color)
    }
    let displayedLegends = displayIndicatorLegends(
      frame: frame,
      cache: cache
    )
    let legendGlyphs = indicatorLegendGlyphs(
      displayedLegends,
      atlas: cache.atlas,
      geometry: geometry
    )

    var batches: [ChartRenderBatch] = []
    if !candles.isEmpty || !lines.isEmpty || !bars.isEmpty {
      batches.append(ChartRenderBatch(
        candleInstances: candles,
        lineSegments: lines,
        barInstances: bars,
        coordinateSpace: .timeline
      ))
    }
    if let extremaBatch = visibleExtremaBatch(
      frame: frame,
      cache: cache
    ) {
      batches.append(extremaBatch)
    }
    batches.append(ChartRenderBatch(
      lineSegments: latestPriceFixedLines + [markerFill] + markerBorder,
      barInstances: [marker],
      glyphInstances: markerGlyphs,
      glyphAtlas: cache.atlas,
      coordinateSpace: .latestPrice
    ))
    if !legendGlyphs.isEmpty {
      batches.append(ChartRenderBatch(
        glyphInstances: legendGlyphs,
        glyphAtlas: cache.atlas,
        coordinateSpace: .fixed,
        interactionVisibility: .hiddenWhileCrosshairIsActive
      ))
    }
    let returnsToLatest: Bool
    switch latestPriceState {
    case .visible:
      returnsToLatest = false
    case .offscreenLeading, .offscreenTrailing:
      returnsToLatest = true
    }
    return LiveBuildOutput(
      batches: batches,
      latestPriceMarker: ChartLatestPriceMarkerSnapshot(
        left: markerLeft,
        top: markerTop,
        right: markerRight,
        bottom: markerBottom,
        returnsToLatest: returnsToLatest
      ),
      displayedLegends: displayedLegends
    )
  }

  private func visibleExtremaBatch(
    frame: ChartDataFrame,
    cache: StaticCache
  ) -> ChartRenderBatch? {
    let geometry = cache.geometry
    let history = frame.candles.history.candles
    let totalSlotCount = history.count
      + (frame.candles.liveTail == nil ? 0 : 1)
    var samples: [VisibleCandleAnchor] = []
    samples.reserveCapacity(
      cache.canvasVisibleHistoryRange.count + 1
    )
    for index in cache.canvasVisibleHistoryRange {
      let x = geometry.x(
        globalSlot: index,
        totalSlotCount: totalSlotCount
      )
      guard geometry.containsCanvasX(x) else {
        continue
      }
      samples.append(VisibleCandleAnchor(
        candle: history[index],
        x: x
      ))
    }
    if let live = frame.candles.liveTail,
      geometry.containsCanvasX(cache.latestX) {
      samples.append(VisibleCandleAnchor(
        candle: live,
        x: cache.latestX
      ))
    }
    guard
      let highest = samples.max(by: {
        if $0.candle.highPrice == $1.candle.highPrice {
          return $0.x < $1.x
        }
        return $0.candle.highPrice < $1.candle.highPrice
      }),
      let lowest = samples.min(by: {
        if $0.candle.lowPrice == $1.candle.lowPrice {
          return $0.x > $1.x
        }
        return $0.candle.lowPrice < $1.candle.lowPrice
      }),
      let highY = cache.domain.y(
        for: highest.candle.highPrice,
        top: geometry.plotTop,
        bottom: geometry.plotBottom
      ),
      let lowY = cache.domain.y(
        for: lowest.candle.lowPrice,
        top: geometry.plotTop,
        bottom: geometry.plotBottom
      )
    else {
      return nil
    }

    let high = extremaAnnotation(
      value: highest.candle.highPrice,
      x: highest.x,
      y: highY,
      isHigh: true,
      cache: cache
    )
    let low = extremaAnnotation(
      value: lowest.candle.lowPrice,
      x: lowest.x,
      y: lowY,
      isHigh: false,
      cache: cache
    )
    guard let high, let low else {
      return nil
    }
    return ChartRenderBatch(
      lineSegments: [high.line, low.line],
      glyphInstances: high.glyphs + low.glyphs,
      glyphAtlas: cache.atlas,
      coordinateSpace: .timeline
    )
  }

  private func extremaAnnotation(
    value: Double,
    x: Float,
    y: Float,
    isHigh: Bool,
    cache: StaticCache
  ) -> ExtremaAnnotation? {
    let geometry = cache.geometry
    guard value.isFinite,
      x.isFinite,
      y.isFinite
    else {
      return nil
    }
    let text = formattedPrice(
      value,
      reference: cache.domain.upper
    )
    let measured = alignedText(
      text,
      atlas: cache.atlas,
      x: 0,
      baselineY: 0,
      alignment: .leading,
      color: .primaryText
    )
    let leaderLength = 9 * geometry.scale
    let textGap = 2 * geometry.scale
    let margin = 3 * geometry.scale
    let placeOnRight = x
      + leaderLength
      + textGap
      + Float(measured.advance)
      <= geometry.width - margin
    let lineStartX = placeOnRight ? x : x - leaderLength
    let lineEndX = placeOnRight ? x + leaderLength : x
    let textX = placeOnRight
      ? lineEndX + textGap
      : lineStartX - textGap
    let alignment: TextAlignment = placeOnRight
      ? .leading
      : .trailing

    func layout(baselineY: Float) -> ChartTextLayoutResult {
      alignedText(
        text,
        atlas: cache.atlas,
        x: textX,
        baselineY: baselineY,
        alignment: alignment,
        color: .primaryText
      )
    }

    let outsideBaseline = isHigh
      ? y - 2 * geometry.scale
      : y + 11 * geometry.scale
    let insideBaseline = isHigh
      ? y + 11 * geometry.scale
      : y - 2 * geometry.scale
    var textLayout = layout(baselineY: outsideBaseline)
    let glyphTop = textLayout.instances.map(\.top).min()
      ?? outsideBaseline
    let glyphBottom = textLayout.instances.map(\.bottom).max()
      ?? outsideBaseline
    if glyphTop < geometry.plotTop
      || glyphBottom > geometry.plotBottom {
      textLayout = layout(baselineY: insideBaseline)
    }
    let anchoredGlyphs = textLayout.instances.map { instance in
      ChartGlyphInstance(
        left: instance.left,
        top: instance.top,
        right: instance.right,
        bottom: instance.bottom,
        uvLeft: instance.uvLeft,
        uvTop: instance.uvTop,
        uvRight: instance.uvRight,
        uvBottom: instance.uvBottom,
        color: instance.color,
        timelineAnchorX: x
      )
    }
    let line = ChartLineSegmentInstance(
      start: ChartPolylinePoint(x: lineStartX, y: y),
      end: ChartPolylinePoint(x: lineEndX, y: y),
      width: max(1, geometry.scale * 0.7),
      dashLength: 0,
      gapLength: 0,
      dashPhase: 0,
      color: .primaryText
    )
    return ExtremaAnnotation(
      line: line,
      glyphs: anchoredGlyphs
    )
  }

  private func roundedRectangleBorder(
    left: Float,
    top: Float,
    right: Float,
    bottom: Float,
    radius: Float,
    width: Float,
    color: ChartColor,
    cornerSegmentCount: Int = 4
  ) -> [ChartLineSegmentInstance] {
    guard right > left,
      bottom > top,
      radius.isFinite,
      width.isFinite,
      width > 0,
      cornerSegmentCount > 0
    else {
      return []
    }
    let resolvedRadius = min(
      max(0, radius),
      min((right - left) / 2, (bottom - top) / 2)
    )
    let corners: [(x: Float, y: Float, start: Double)] = [
      (right - resolvedRadius, top + resolvedRadius, -.pi / 2),
      (right - resolvedRadius, bottom - resolvedRadius, 0),
      (left + resolvedRadius, bottom - resolvedRadius, .pi / 2),
      (left + resolvedRadius, top + resolvedRadius, .pi),
    ]
    var points = [ChartPolylinePoint(
      x: left + resolvedRadius,
      y: top
    )]
    points.reserveCapacity(1 + corners.count * (cornerSegmentCount + 1))
    for corner in corners {
      for segment in 0...cornerSegmentCount {
        let angle = corner.start
          + Double(segment) / Double(cornerSegmentCount)
            * .pi / 2
        points.append(ChartPolylinePoint(
          x: corner.x + resolvedRadius * Float(cos(angle)),
          y: corner.y + resolvedRadius * Float(sin(angle))
        ))
      }
    }
    return ChartBatchCompiler.lineSegments(
      spans: [points],
      width: width,
      color: color,
      antialias: true
    )
  }

  private func candleInstance(
    _ candle: ChartCandle,
    x: Float,
    geometry: Geometry,
    domain: PriceDomain
  ) -> ChartCandleInstance? {
    guard candle.isValid,
      let openY = domain.y(
        for: candle.openPrice,
        top: geometry.plotTop,
        bottom: geometry.plotBottom
      ),
      let highY = domain.y(
        for: candle.highPrice,
        top: geometry.plotTop,
        bottom: geometry.plotBottom
      ),
      let lowY = domain.y(
        for: candle.lowPrice,
        top: geometry.plotTop,
        bottom: geometry.plotBottom
      ),
      let closeY = domain.y(
        for: candle.closePrice,
        top: geometry.plotTop,
        bottom: geometry.plotBottom
      )
    else {
      return nil
    }
    return ChartCandleInstance(
      x: x,
      openY: openY,
      highY: highY,
      lowY: lowY,
      closeY: closeY,
      halfBodyWidth: geometry.halfBodyWidth,
      isRising: candle.closePrice >= candle.openPrice
    )
  }

  private func indicatorSegments(
    points: [IndicatorPoint],
    candles: [ChartCandle],
    visibleRange: Range<Int>,
    xValues: [Float],
    domain: PriceDomain,
    top: Float,
    bottom: Float,
    scale: Float,
    lineWidthPoints: Float,
    color: ChartColor
  ) -> [ChartLineSegmentInstance] {
    var spans: [[ChartPolylinePoint]] = []
    var current: [ChartPolylinePoint] = []

    for (offset, index) in visibleRange.enumerated() {
      guard index < points.count,
        offset < xValues.count,
        points[index].openTime == candles[index].openTime,
        points[index].validity == .valid,
        let value = points[index].value,
        let y = domain.y(
          for: value,
          top: top,
          bottom: bottom
        )
      else {
        if current.count > 1 {
          spans.append(current)
        }
        current.removeAll(keepingCapacity: true)
        continue
      }
      current.append(
        ChartPolylinePoint(
          x: xValues[offset],
          y: y
        ))
    }
    if current.count > 1 {
      spans.append(current)
    }
    return ChartBatchCompiler.lineSegments(
      spans: spans,
      width: max(
        1,
        scale * lineWidthPoints
      ),
      color: color,
      antialias: true
    )
  }

  private func indicatorHollowSquareMarkers(
    points: [IndicatorPoint],
    candles: [ChartCandle],
    visibleRange: Range<Int>,
    xValues: [Float],
    domain: PriceDomain,
    top: Float,
    bottom: Float,
    scale: Float,
    sizePoints: Float,
    lineWidthPoints: Float,
    color: ChartColor
  ) -> [ChartLineSegmentInstance] {
    var result: [ChartLineSegmentInstance] = []
    result.reserveCapacity(visibleRange.count * 4)
    for (offset, index) in visibleRange.enumerated() {
      guard index < points.count,
        index < candles.count,
        offset < xValues.count,
        points[index].openTime == candles[index].openTime,
        points[index].validity == .valid,
        let value = points[index].value,
        let y = domain.y(for: value, top: top, bottom: bottom)
      else {
        continue
      }
      result.append(contentsOf: hollowSquareMarkerSegments(
        x: xValues[offset],
        y: y,
        scale: scale,
        sizePoints: sizePoints,
        lineWidthPoints: lineWidthPoints,
        color: color
      ))
    }
    return result
  }

  private func liveIndicatorHollowSquareMarker(
    point: IndicatorPoint,
    x: Float,
    domain: PriceDomain,
    top: Float,
    bottom: Float,
    scale: Float,
    sizePoints: Float,
    lineWidthPoints: Float,
    color: ChartColor
  ) -> [ChartLineSegmentInstance]? {
    guard point.validity == .valid,
      let value = point.value,
      let y = domain.y(for: value, top: top, bottom: bottom)
    else {
      return nil
    }
    return hollowSquareMarkerSegments(
      x: x,
      y: y,
      scale: scale,
      sizePoints: sizePoints,
      lineWidthPoints: lineWidthPoints,
      color: color
    )
  }

  private func hollowSquareMarkerSegments(
    x: Float,
    y: Float,
    scale: Float,
    sizePoints: Float,
    lineWidthPoints: Float,
    color: ChartColor
  ) -> [ChartLineSegmentInstance] {
    let halfSize = max(0.5, scale * sizePoints / 2)
    let width = max(1, scale * lineWidthPoints)
    let topLeft = ChartPolylinePoint(x: x - halfSize, y: y - halfSize)
    let topRight = ChartPolylinePoint(x: x + halfSize, y: y - halfSize)
    let bottomRight = ChartPolylinePoint(x: x + halfSize, y: y + halfSize)
    let bottomLeft = ChartPolylinePoint(x: x - halfSize, y: y + halfSize)
    return [
      (topLeft, topRight),
      (topRight, bottomRight),
      (bottomRight, bottomLeft),
      (bottomLeft, topLeft),
    ].map { start, end in
      ChartLineSegmentInstance(
        start: start,
        end: end,
        width: width,
        dashLength: 0,
        gapLength: 0,
        dashPhase: 0,
        color: color
      )
    }
  }

  private func lastIndicatorAnchor(
    points: [IndicatorPoint],
    candles: [ChartCandle],
    visibleRange: Range<Int>,
    xValues: [Float],
    domain: PriceDomain,
    top: Float,
    bottom: Float
  ) -> ChartPolylinePoint? {
    guard let index = visibleRange.last,
      index < points.count,
      !visibleRange.isEmpty
    else {
      return nil
    }
    let offset = visibleRange.count - 1
    guard
      offset < xValues.count,
      points[index].openTime == candles[index].openTime,
      points[index].validity == .valid,
      let value = points[index].value,
      let y = domain.y(
        for: value,
        top: top,
        bottom: bottom
      )
    else {
      return nil
    }
    return ChartPolylinePoint(x: xValues[offset], y: y)
  }

  private func appendLiveIndicator(
    point: IndicatorPoint?,
    anchor: ChartPolylinePoint?,
    x: Float,
    lineWidthPoints: Float,
    color: ChartColor,
    domain: PriceDomain,
    top: Float,
    bottom: Float,
    scale: Float,
    lines: inout [ChartLineSegmentInstance]
  ) {
    guard let point,
      point.validity == .valid,
      let value = point.value,
      let anchor,
      let y = domain.y(
        for: value,
        top: top,
        bottom: bottom
      )
    else {
      return
    }
    lines.append(
      ChartLineSegmentInstance(
        start: anchor,
        end: ChartPolylinePoint(x: x, y: y),
        width: max(
          1,
          scale * lineWidthPoints
        ),
        dashLength: 0,
        gapLength: 0,
        dashPhase: 0,
        color: color,
        antialias: true
      ))
  }

  private func indicatorHistogramBars(
    points: [IndicatorPoint],
    candles: [ChartCandle],
    visibleRange: Range<Int>,
    xValues: [Float],
    domain: PriceDomain,
    panel: ChartPanelFrame,
    halfWidth: Float,
    color: ChartColor,
    colorStrategy: ChartIndicatorHistogramColorStrategy,
    scale: Float,
    position: ChartIndicatorHistogramPosition? = nil,
    fillAlpha: Float = 1
  ) -> [ChartBarInstance] {
    var bars: [ChartBarInstance] = []
    bars.reserveCapacity(visibleRange.count)
    for (offset, index) in visibleRange.enumerated() {
      guard index < points.count,
        offset < xValues.count,
        points[index].openTime == candles[index].openTime,
        let bar = liveIndicatorHistogramBar(
          point: points[index],
          candle: candles[index],
          x: xValues[offset],
          domain: domain,
          top: panel.plot.top,
          bottom: panel.plot.bottom,
          halfWidth: halfWidth,
          color: color,
          colorStrategy: colorStrategy,
          scale: scale,
          position: position,
          fillAlpha: fillAlpha
        )
      else {
        continue
      }
      let previous = index > 0 && points[index - 1].validity == .valid ? points[index - 1].value : nil
      bars.append(contentsOf: histogramBars(bar, value: points[index].value,
        previous: previous, strategy: colorStrategy, scale: scale))
    }
    return bars
  }

  private func histogramBars(_ bar: ChartBarInstance, value: Double?, previous: Double?,
    strategy: ChartIndicatorHistogramColorStrategy, scale: Float) -> [ChartBarInstance] {
    guard strategy == .valueSign, let value, let previous,
      abs(value) < abs(previous) else { return [bar] }
    let border = min(max(1, scale * 0.5), (bar.right - bar.left) / 2, (bar.bottom - bar.top) / 2)
    guard border > 0 else { return [bar] }
    return [
      ChartBarInstance(left: bar.left, top: bar.top, right: bar.right, bottom: bar.top + border, color: bar.color),
      ChartBarInstance(left: bar.left, top: bar.bottom - border, right: bar.right, bottom: bar.bottom, color: bar.color),
      ChartBarInstance(left: bar.left, top: bar.top + border, right: bar.left + border, bottom: bar.bottom - border, color: bar.color),
      ChartBarInstance(left: bar.right - border, top: bar.top + border, right: bar.right, bottom: bar.bottom - border, color: bar.color),
    ]
  }

  private func indicatorPriceBandBars(
    points: [IndicatorPoint],
    candles: [ChartCandle],
    visibleRange: Range<Int>,
    xValues: [Float],
    domain: PriceDomain,
    top: Float,
    bottom: Float,
    halfSlotWidth: Float,
    color: ChartColor
  ) -> [ChartBarInstance] {
    var bars: [ChartBarInstance] = []
    bars.reserveCapacity(visibleRange.count)
    for (offset, index) in visibleRange.enumerated() {
      guard index < points.count,
        index < candles.count,
        offset < xValues.count,
        points[index].openTime == candles[index].openTime,
        let bar = indicatorPriceBandBar(
          point: points[index],
          candle: candles[index],
          x: xValues[offset],
          domain: domain,
          top: top,
          bottom: bottom,
          halfSlotWidth: halfSlotWidth,
          color: color
        )
      else {
        continue
      }
      bars.append(bar)
    }
    return bars
  }

  private func indicatorPriceBandBar(
    point: IndicatorPoint,
    candle: ChartCandle,
    x: Float,
    domain: PriceDomain,
    top: Float,
    bottom: Float,
    halfSlotWidth: Float,
    color: ChartColor
  ) -> ChartBarInstance? {
    guard point.validity == .valid,
      let value = point.value,
      let indicatorY = domain.y(
        for: value,
        top: top,
        bottom: bottom
      ),
      let closeY = domain.y(
        for: candle.closePrice,
        top: top,
        bottom: bottom
      )
    else {
      return nil
    }
    return ChartBarInstance(
      left: x - halfSlotWidth,
      top: max(top, min(indicatorY, closeY)),
      right: x + halfSlotWidth,
      bottom: min(bottom, max(indicatorY, closeY)),
      color: color
    )
  }

  private func liveIndicatorHistogramBar(
    point: IndicatorPoint,
    candle: ChartCandle,
    x: Float,
    domain: PriceDomain,
    top: Float,
    bottom: Float,
    halfWidth: Float,
    color: ChartColor,
    colorStrategy: ChartIndicatorHistogramColorStrategy,
    scale: Float,
    position: ChartIndicatorHistogramPosition? = nil,
    fillAlpha: Float = 1
  ) -> ChartBarInstance? {
    guard point.validity == .valid,
      let value = point.value,
      value.isFinite,
      let valueY = domain.y(
        for: value,
        top: top,
        bottom: bottom
      ),
      let zeroY = domain.y(
        for: 0,
        top: top,
        bottom: bottom
      )
    else {
      return nil
    }
    let resolvedColor: ChartColor
    switch colorStrategy {
    case .fixed:
      resolvedColor = color
    case .valueSign:
      resolvedColor = value >= 0 ? .positive : .negative
    case .candleDirection:
      resolvedColor =
        candle.closePrice >= candle.openPrice
        ? .positive
        : .negative
    }
    let minimumHeight = max(1, scale * 0.65)
    let barTop = min(valueY, zeroY)
    let barBottom = max(
      barTop + minimumHeight,
      max(valueY, zeroY)
    )
    let left: Float
    let right: Float
    switch position {
    case .leading:
      left = x - halfWidth
      right = x
    case .trailing:
      left = x
      right = x + halfWidth
    case nil:
      left = x - halfWidth
      right = x + halfWidth
    }
    return ChartBarInstance(
      left: left,
      top: max(top, barTop),
      right: right,
      bottom: min(bottom, barBottom),
      color: resolvedColor.withAlpha(fillAlpha)
    )
  }

  private func gridBars(
    geometry: Geometry,
    domain: PriceDomain,
    panelDomains: [String: PriceDomain]
  ) -> [ChartBarInstance] {
    let thickness = max(1, geometry.scale * 0.45)
    let columns = 3
    let cellWidth = (geometry.plotRight - geometry.plotLeft) / Float(columns)
    // Keep cells wider than they are tall, including taller chart viewports.
    // Multiples of four keep every main price-axis tick on a grid line.
    let priceDivisions = max(
      4, Int(ceil((geometry.plotBottom - geometry.plotTop) * 1.8 / cellWidth / 4)) * 4
    )
    var bars: [ChartBarInstance] = []
    bars.reserveCapacity(16)
    for tick in domain.ticks(count: priceDivisions + 1) {
      guard
        let y = domain.y(
          for: tick,
          top: geometry.plotTop,
          bottom: geometry.plotBottom
        )
      else {
        continue
      }
      bars.append(
        ChartBarInstance(
          left: 0,
          top: y - thickness / 2,
          right: geometry.width,
          bottom: y + thickness / 2,
          color: .grid
        ))
    }
    for index in 1..<columns {
      let x =
        geometry.plotLeft
        + (geometry.plotRight - geometry.plotLeft)
        * Float(index) / Float(columns)
      for panel in geometry.panelLayout.panels {
        bars.append(
          ChartBarInstance(
            left: x - thickness / 2,
            top: panel.plot.top,
            right: x + thickness / 2,
            bottom: panel.plot.bottom,
            color: .grid
          ))
      }
    }
    for panel in geometry.panelLayout.indicatorPanels {
      guard let panelDomain = panelDomains[panel.id] else {
        continue
      }
      let divisions = max(
        2, Int(ceil(panel.plot.height * 1.8 / cellWidth / 2)) * 2
      )
      for tick in panelDomain.ticks(count: divisions + 1) {
        guard
          let y = panelDomain.y(
            for: tick,
            top: panel.plot.top,
            bottom: panel.plot.bottom
          )
        else {
          continue
        }
        bars.append(
          ChartBarInstance(
            left: 0,
            top: y - thickness / 2,
            right: geometry.width,
            bottom: y + thickness / 2,
            color: .grid
          ))
      }
    }
    return bars
  }

  private func priceAxisGlyphs(
    domain: PriceDomain,
    geometry: Geometry,
    atlas: ChartGlyphAtlasSnapshot,
    missingGlyphCount: inout Int
  ) -> [ChartGlyphInstance] {
    var glyphs: [ChartGlyphInstance] = []
    for tick in domain.ticks(count: 5) {
      guard
        let y = domain.y(
          for: tick,
          top: geometry.plotTop,
          bottom: geometry.plotBottom
        )
      else {
        continue
      }
      let text = formattedPrice(tick, reference: domain.upper)
      let result = alignedText(
        text,
        atlas: atlas,
        x: geometry.width - 4 * geometry.scale,
        baselineY: y + 3.3 * geometry.scale,
        alignment: .trailing,
        color: .neutral
      )
      glyphs.append(contentsOf: result.instances)
      missingGlyphCount += result.missingGlyphCount
    }
    return glyphs
  }

  private func panelAxisGlyphs(
    domain: PriceDomain,
    panel: ChartPanelFrame,
    geometry: Geometry,
    atlas: ChartGlyphAtlasSnapshot,
    missingGlyphCount: inout Int
  ) -> [ChartGlyphInstance] {
    var glyphs: [ChartGlyphInstance] = []
    for tick in domain.ticks(count: 3) {
      guard
        let y = domain.y(
          for: tick,
          top: panel.plot.top,
          bottom: panel.plot.bottom
        )
      else {
        continue
      }
      let result = alignedText(
        formattedPanelAxisValue(tick, panelID: panel.id),
        atlas: atlas,
        x: geometry.width - 4 * geometry.scale,
        baselineY: min(
          panel.plot.bottom - 2 * geometry.scale,
          max(panel.plot.top + 8.5 * geometry.scale, y + 3.3 * geometry.scale)
        ),
        alignment: .trailing,
        color: .neutral
      )
      glyphs.append(contentsOf: result.instances)
      missingGlyphCount += result.missingGlyphCount
    }
    return glyphs
  }

  private func displayIndicatorLegends(
    frame: ChartDataFrame,
    cache: StaticCache
  ) -> [ChartIndicatorLegendEntry] {
    let history = frame.candles.history.candles
    let showsLiveCandle = frame.candles.liveTail != nil
      && cache.geometry.containsCanvasX(cache.latestX)
    let selectedIndex = showsLiveCandle
      ? nil
      : cache.visibleHistoryRange.last
    let selectedCandle = showsLiveCandle
      ? frame.candles.liveTail
      : selectedIndex.flatMap {
        $0 < history.count ? history[$0] : nil
      }
    let entries: [ChartIndicatorLegendEntry]
    if let selectedIndex,
      let selectedCandle {
      entries = frame.indicators.legends.compactMap { entry in
        historicalLegendEntry(
          entry,
          selectedIndex: selectedIndex,
          candle: selectedCandle,
          history: frame.indicators.history
        )
      }
    } else {
      entries = frame.indicators.legends
    }
    return volumeLegendEntries(
      entries,
      candle: selectedCandle,
      stream: frame.stream
    )
  }

  private func historicalLegendEntry(
    _ entry: ChartIndicatorLegendEntry,
    selectedIndex: Int,
    candle: ChartCandle,
    history: ChartIndicatorHistorySnapshot
  ) -> ChartIndicatorLegendEntry? {
    let exact = history.series.filter {
      "\($0.key.instanceID).\($0.key.outputID)"
        == entry.instanceID
    }
    let candidates = exact.isEmpty
      ? history.series.filter {
        $0.key.instanceID == entry.instanceID
      }
      : exact
    guard let fallback = candidates.first else {
      return nil
    }
    let series = candidates.first { series in
      guard selectedIndex < series.points.count else {
        return false
      }
      let point = series.points[selectedIndex]
      return point.openTime == candle.openTime
        && point.validity == .valid
        && point.value?.isFinite == true
    } ?? fallback
    let point = selectedIndex < series.points.count
      ? series.points[selectedIndex]
      : nil
    let value: Double?
    if point?.openTime == candle.openTime,
      point?.validity == .valid,
      let finiteValue = point?.value,
      finiteValue.isFinite {
      value = finiteValue
    } else {
      value = nil
    }
    let valueColor = historicalLegendColor(
      series: series,
      value: value,
      candle: candle,
      fallback: entry.colorToken
    )
    return ChartIndicatorLegendEntry(
      instanceID: entry.instanceID,
      label: entry.label,
      value: value,
      labelColorToken: entry.labelColorToken,
      colorToken: valueColor,
      placement: entry.placement,
      row: entry.row,
      order: entry.order
    )
  }

  private func historicalLegendColor(
    series: ChartIndicatorSeriesHistory,
    value: Double?,
    candle: ChartCandle,
    fallback: ChartIndicatorColorToken
  ) -> ChartIndicatorColorToken {
    let strategy: ChartIndicatorHistogramColorStrategy
    switch series.figureStyle {
    case .histogramFromZero(let value),
      .pairedHistogramFromZero(let value, _):
      strategy = value
    default:
      return fallback
    }
    switch strategy {
    case .fixed:
      return fallback
    case .valueSign:
      guard let value else {
        return .neutral
      }
      return value >= 0 ? .positive : .negative
    case .candleDirection:
      return candle.closePrice >= candle.openPrice
        ? .positive
        : .negative
    }
  }

  private func volumeLegendEntries(
    _ entries: [ChartIndicatorLegendEntry],
    candle: ChartCandle?,
    stream: ChartStreamKey
  ) -> [ChartIndicatorLegendEntry] {
    guard let baseEntry = entries.first(where: {
      $0.placement == .panel(ChartPanelID.volume)
        && $0.label == "VOL:"
    }) else {
      return entries
    }
    let assets = splitTradingPair(stream.symbol)
    var result: [ChartIndicatorLegendEntry] = []
    result.reserveCapacity(entries.count + 1)
    for entry in entries {
      guard entry.placement == .panel(ChartPanelID.volume)
      else {
        result.append(entry)
        continue
      }
      let isBaseVolume = entry.instanceID
        == baseEntry.instanceID
      result.append(ChartIndicatorLegendEntry(
        instanceID: entry.instanceID,
        label: isBaseVolume
          ? assets.map { "VOL(\($0.base)):" } ?? "VOL:"
          : entry.label,
        value: entry.value,
        labelColorToken: entry.labelColorToken,
        colorToken: entry.colorToken,
        placement: entry.placement,
        row: entry.row,
        order: isBaseVolume
          ? 0
          : entry.order + 1
      ))
    }
    if let quote = assets?.quote {
      result.append(ChartIndicatorLegendEntry(
        instanceID: "\(baseEntry.instanceID).quote",
        label: "VOL(\(quote)):",
        value: candle?.quoteVolume,
        labelColorToken: .neutral,
        colorToken: .neutral,
        placement: .panel(ChartPanelID.volume),
        row: baseEntry.row,
        order: 1
      ))
    }
    return result.sorted {
      if $0.row != $1.row {
        return $0.row < $1.row
      }
      return $0.order < $1.order
    }
  }

  private func splitTradingPair(
    _ symbol: String
  ) -> (base: String, quote: String)? {
    let normalized = symbol.uppercased()
    let knownQuotes = [
      "FDUSD", "USDT", "USDC", "BUSD", "TUSD",
      "USD", "BTC", "ETH", "BNB",
    ]
    guard let quote = knownQuotes.first(where: {
      normalized.hasSuffix($0)
        && normalized.count > $0.count
    }) else {
      return nil
    }
    return (
      String(normalized.dropLast(quote.count)),
      quote
    )
  }

  private func indicatorLegendGlyphs(
    _ entries: [ChartIndicatorLegendEntry],
    atlas: ChartGlyphAtlasSnapshot,
    geometry: Geometry
  ) -> [ChartGlyphInstance] {
    var glyphs: [ChartGlyphInstance] = []
    glyphs.append(
      contentsOf: indicatorLegendRows(
        entries.filter { $0.placement == .priceOverlay },
        baseline: 10.5 * geometry.scale,
        maximumRows: 6,
        atlas: atlas,
        geometry: geometry
      ))
    for panel in geometry.panelLayout.indicatorPanels {
      glyphs.append(
        contentsOf: indicatorLegendRows(
          entries.filter { $0.placement == .panel(panel.id) },
          baseline: panel.legendBaseline,
          maximumRows: 1,
          atlas: atlas,
          geometry: geometry
        ))
    }
    return glyphs
  }

  private func indicatorLegendRows(
    _ entries: [ChartIndicatorLegendEntry],
    baseline: Float,
    maximumRows: Int,
    atlas: ChartGlyphAtlasSnapshot,
    geometry: Geometry
  ) -> [ChartGlyphInstance] {
    var glyphs: [ChartGlyphInstance] = []
    let rows = Dictionary(grouping: entries) { $0.row }
    for row in rows.keys.sorted()
    where row >= 0 && row < maximumRows {
      var cursor = geometry.plotLeft
      var rowGlyphs: [ChartGlyphInstance] = []
      let rowBaseline =
        baseline + Float(row) * 12 * geometry.scale
      for entry in rows[row, default: []].sorted(by: {
        $0.order < $1.order
      }) {
        let value =
          entry.value.map {
            formattedIndicatorLegendValue(
              $0,
              entry: entry
            )
          } ?? "--"
        let labelResult = alignedText(
          "\(entry.label) ",
          atlas: atlas,
          x: cursor,
          baselineY: rowBaseline,
          alignment: .leading,
          color: entry.labelColorToken.color
        )
        let valueResult = alignedText(
          value,
          atlas: atlas,
          x: cursor + Float(labelResult.advance),
          baselineY: rowBaseline,
          alignment: .leading,
          color: entry.colorToken.color
        )
        let nextCursor =
          cursor
          + Float(labelResult.advance)
          + Float(valueResult.advance)
          + 8 * geometry.scale
        rowGlyphs.append(contentsOf: labelResult.instances)
        rowGlyphs.append(contentsOf: valueResult.instances)
        cursor = nextCursor
      }
      glyphs.append(contentsOf: ChartGlyphRowLayout.fitting(
        rowGlyphs, left: geometry.plotLeft,
        right: geometry.plotRight, baseline: rowBaseline
      ))
    }
    return glyphs
  }

  private func timeAxisGlyphs(
    history: [ChartCandle],
    visibleRange: Range<Int>,
    historyXValues: [Float],
    liveOpenTime: Int64?,
    liveX: Float?,
    geometry: Geometry,
    atlas: ChartGlyphAtlasSnapshot,
    missingGlyphCount: inout Int
  ) -> [ChartGlyphInstance] {
    var samples: [(x: Float, time: Int64)] = []
    for (offset, index) in visibleRange.enumerated() {
      guard offset < historyXValues.count else {
        continue
      }
      samples.append(
        (
          x: historyXValues[offset],
          time: history[index].openTime
        ))
    }
    if let liveOpenTime, let liveX {
      samples.append(
        (
          x: liveX,
          time: liveOpenTime
        ))
    }
    guard !samples.isEmpty else {
      return []
    }

    let middleIndex = samples.count / 2
    var indexes = [middleIndex]
    if middleIndex != 0 {
      indexes.append(0)
    }
    if samples.count - 1 != middleIndex {
      indexes.append(samples.count - 1)
    }
    var glyphs: [ChartGlyphInstance] = []
    var occupiedRanges: [ClosedRange<Float>] = []
    let horizontalMargin = 2 * geometry.scale
    let collisionPadding = 8 * geometry.scale
    for sampleIndex in indexes {
      let sample = samples[sampleIndex]
      let alignment: TextAlignment
      if sampleIndex == 0 {
        alignment = .leading
      } else if sampleIndex == samples.count - 1 {
        alignment = .trailing
      } else {
        alignment = .center
      }
      let text = formattedTime(sample.time)
      let measured = MetalTextLayouter.layout(
        text: text,
        atlas: atlas,
        originX: 0,
        baselineY: 0,
        color: .neutral
      )
      let advance = Float(measured.advance)
      let anchorX: Float
      if advance + 2 * horizontalMargin >= geometry.width {
        anchorX = geometry.width / 2
      } else {
        switch alignment {
        case .leading:
          anchorX = min(
            geometry.width - horizontalMargin - advance,
            max(horizontalMargin, sample.x)
          )
        case .center:
          anchorX = min(
            geometry.width - horizontalMargin - advance / 2,
            max(horizontalMargin + advance / 2, sample.x)
          )
        case .trailing:
          anchorX = min(
            geometry.width - horizontalMargin,
            max(horizontalMargin + advance, sample.x)
          )
        }
      }
      let originX: Float
      switch alignment {
      case .leading:
        originX = anchorX
      case .center:
        originX = anchorX - advance / 2
      case .trailing:
        originX = anchorX - advance
      }
      let candidateRange = originX...(originX + advance)
      guard !occupiedRanges.contains(where: { occupied in
        candidateRange.lowerBound < occupied.upperBound + collisionPadding
          && candidateRange.upperBound > occupied.lowerBound - collisionPadding
      }) else {
        continue
      }
      let result = alignedText(
        text,
        atlas: atlas,
        x: anchorX,
        baselineY: geometry.panelLayout.timeAxisBottom - 6 * geometry.scale,
        alignment: alignment,
        color: .neutral
      )
      glyphs.append(contentsOf: result.instances)
      occupiedRanges.append(candidateRange)
      missingGlyphCount += result.missingGlyphCount
    }
    return glyphs
  }

  private enum TextAlignment {
    case leading
    case center
    case trailing
  }

  private func alignedText(
    _ text: String,
    atlas: ChartGlyphAtlasSnapshot,
    x: Float,
    baselineY: Float,
    alignment: TextAlignment,
    color: ChartColor
  ) -> ChartTextLayoutResult {
    let measured = MetalTextLayouter.layout(
      text: text,
      atlas: atlas,
      originX: 0,
      baselineY: Double(baselineY),
      color: color
    )
    let origin: Double
    switch alignment {
    case .leading:
      origin = Double(x)
    case .center:
      origin = Double(x) - measured.advance / 2
    case .trailing:
      origin = Double(x) - measured.advance
    }
    let translated = measured.instances.map { instance in
      let offset = Float(origin)
      return ChartGlyphInstance(
        left: instance.left + offset,
        top: instance.top,
        right: instance.right + offset,
        bottom: instance.bottom,
        uvLeft: instance.uvLeft,
        uvTop: instance.uvTop,
        uvRight: instance.uvRight,
        uvBottom: instance.uvBottom,
        color: instance.color
      )
    }
    return ChartTextLayoutResult(
      instances: translated,
      advance: measured.advance,
      ascent: measured.ascent,
      descent: measured.descent,
      missingGlyphCount: measured.missingGlyphCount
    )
  }

  private func staticPrices(
    frame: ChartDataFrame,
    visibleRange: Range<Int>
  ) -> [Double] {
    let candles = frame.candles.history.candles
    var values: [Double] = []
    values.reserveCapacity(visibleRange.count * 7)
    for index in visibleRange {
      let candle = candles[index]
      values.append(contentsOf: [
        candle.openPrice,
        candle.highPrice,
        candle.lowPrice,
        candle.closePrice,
      ])
      for series in frame.indicators.history.series
      where series.placement == .priceOverlay
        && series.yAxisPolicy == .sharedPrice
        && series.autoscale == .included
        && index < series.points.count
      {
        let point = series.points[index]
        if point.validity == .valid,
          point.openTime == candle.openTime,
          let value = point.value,
          value.isFinite
        {
          values.append(value)
        }
      }
    }
    return values
  }

  private func indicatorPanelIDs(
    _ frame: ChartDataFrame
  ) -> [String] {
    ChartPanelLayout.indicatorPanelIDs(
      series: frame.indicators.history.series
    )
  }

  private func makePanelDomains(
    frame: ChartDataFrame,
    visibleRange: Range<Int>,
    includesLiveValues: Bool,
    panelLayout: ChartPanelLayout
  ) -> [String: PriceDomain] {
    let candles = frame.candles.history.candles
    var result: [String: PriceDomain] = [:]
    for panel in panelLayout.indicatorPanels {
      let series = frame.indicators.history.series.filter {
        $0.placement == .panel(panel.id)
      }
      if let fixed = series.compactMap({ item -> PriceDomain? in
        guard case .fixed(let lower, let upper) = item.yAxisPolicy,
          lower.isFinite,
          upper.isFinite,
          upper > lower
        else {
          return nil
        }
        return PriceDomain(lower: lower, upper: upper)
      }).first {
        result[panel.id] = fixed
        continue
      }

      var values: [Double] = []
      var includesZero = false
      var hasHistogram = false
      var autoscaleKeys: Set<ChartIndicatorSeriesKey> = []
      for item in series where item.autoscale == .included {
        autoscaleKeys.insert(item.key)
        switch item.figureStyle {
        case .histogramFromZero,
          .pairedHistogramFromZero,
          .areaFromZero:
          includesZero = true
          hasHistogram = true
        default:
          break
        }
        for index in visibleRange
        where index < item.points.count
          && index < candles.count
        {
          let point = item.points[index]
          if point.validity == .valid,
            point.openTime == candles[index].openTime,
            let value = point.value,
            value.isFinite
          {
            values.append(value)
          }
        }
      }
      if includesLiveValues {
        for livePoint in frame.indicators.livePoints
        where autoscaleKeys.contains(livePoint.key) {
          if livePoint.point.validity == .valid,
            let value = livePoint.point.value,
            value.isFinite
          {
            values.append(value)
          }
        }
      }
      if includesZero {
        values.append(0)
      }
      let nonnegativeHistogram =
        hasHistogram
        && values.allSatisfy { $0 >= 0 }
      result[panel.id] =
        makeValueDomain(
          values,
          zeroFloor: nonnegativeHistogram
        ) ?? PriceDomain(lower: -1, upper: 1)
    }
    return result
  }

  private func panelDomainsContainLiveValues(
    frame: ChartDataFrame,
    cache: StaticCache
  ) -> Bool {
    var placementByKey: [ChartIndicatorSeriesKey: String] = [:]
    for series in frame.indicators.history.series
    where series.autoscale == .included {
      if case .panel(let panelID) = series.placement {
        placementByKey[series.key] = panelID
      }
    }
    for livePoint in frame.indicators.livePoints {
      guard let panelID = placementByKey[livePoint.key],
        livePoint.point.validity == .valid,
        let value = livePoint.point.value,
        value.isFinite
      else {
        continue
      }
      guard cache.panelDomains[panelID]?.contains([value]) == true
      else {
        return false
      }
    }
    return true
  }

  private func livePrices(_ frame: ChartDataFrame) -> [Double] {
    var values: [Double] = []
    if let candle = frame.candles.liveTail {
      values.append(contentsOf: [
        candle.openPrice,
        candle.highPrice,
        candle.lowPrice,
        candle.closePrice,
      ])
    }
    var autoscaleKeys: Set<ChartIndicatorSeriesKey> = []
    for series in frame.indicators.history.series
    where series.placement == .priceOverlay
      && series.yAxisPolicy == .sharedPrice
      && series.autoscale == .included
    {
      autoscaleKeys.insert(series.key)
    }
    for livePoint in frame.indicators.livePoints
    where autoscaleKeys.contains(livePoint.key) {
      if livePoint.point.validity == .valid,
        let value = livePoint.point.value,
        value.isFinite
      {
        values.append(value)
      }
    }
    return values
  }

  private func makePriceDomain(
    _ candidates: [Double]
  ) -> PriceDomain? {
    let values = candidates.filter(\.isFinite)
    guard let minimum = values.min(),
      let maximum = values.max()
    else {
      return nil
    }
    let rawSpan = maximum - minimum
    let reference = max(abs(minimum), abs(maximum))
    let minimumPadding = max(reference * 0.002, 0.000_000_01)
    let padding = max(rawSpan * 0.08, minimumPadding)
    var lower = minimum - padding
    var upper = maximum + padding
    if lower == upper {
      lower -= minimumPadding
      upper += minimumPadding
    }
    guard lower.isFinite,
      upper.isFinite,
      upper > lower
    else {
      return nil
    }
    return PriceDomain(lower: lower, upper: upper)
  }

  private func makeValueDomain(
    _ candidates: [Double],
    zeroFloor: Bool
  ) -> PriceDomain? {
    let values = candidates.filter(\.isFinite)
    guard let minimum = values.min(),
      let maximum = values.max()
    else {
      return nil
    }
    let rawSpan = maximum - minimum
    let reference = max(abs(minimum), abs(maximum))
    let minimumPadding = max(reference * 0.04, 0.000_000_01)
    let padding = max(rawSpan * 0.08, minimumPadding)
    var lower = zeroFloor ? 0 : minimum - padding
    var upper = maximum + padding
    if lower == upper {
      lower = zeroFloor ? 0 : lower - minimumPadding
      upper += minimumPadding
    }
    guard lower.isFinite,
      upper.isFinite,
      upper > lower
    else {
      return nil
    }
    return PriceDomain(lower: lower, upper: upper)
  }

  private func atlas(
    for viewport: ChartSceneViewport
  ) throws -> ChartGlyphAtlasSnapshot {
    guard
      let key = ChartGlyphAtlasKey(
        fontName: "HelveticaNeue",
        pointSize: 10,
        displayScale: viewport.displayScale,
        localeIdentifier: "zh-Hans"
      )
    else {
      throw ChartSceneBuilderError.invalidGeometry
    }
    if let cached = atlasCache[key] {
      return cached
    }
    let atlas = try atlasBuilder.build(
      key: key,
      seedStrings: [
        "0123456789,.-:/+% ()<>ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        "时间开高低收涨跌幅振量额万亿⊕"
      ]
    )
    atlasCache[key] = atlas
    return atlas
  }

  private func formattedPrice(_ value: Double, reference: Double) -> String {
    DisplayNumber.text(value, grouped: true)
  }

  private func formattedIndicatorLegendValue(
    _ value: Double,
    entry: ChartIndicatorLegendEntry
  ) -> String {
    switch entry.placement {
    case .panel(let panelID):
      if Self.compactQuantityPanelIDs.contains(panelID) {
        return formattedCompactQuantity(value)
      }
      if Self.longShortRatioPanelIDs.contains(panelID),
        entry.label == "L:" || entry.label == "S:"
      {
        return DisplayNumber.text(value) + "%"
      }
      return formattedPrice(value, reference: value)
    case .priceOverlay:
      return formattedPrice(value, reference: value)
    }
  }

  private func formattedPanelAxisValue(
    _ value: Double,
    panelID: String
  ) -> String {
    if Self.compactQuantityPanelIDs.contains(panelID) {
      return formattedCompactQuantity(value)
    }
    return formattedPrice(value, reference: value)
  }

  private static let compactQuantityPanelIDs: Set<String> = [
    ChartPanelID.volume,
    ChartPanelID.obv,
    ChartPanelID.openInterest,
    ChartPanelID.buySellVolume,
  ]

  private static let longShortRatioPanelIDs: Set<String> = [
    ChartPanelID.topAccountRatio,
    ChartPanelID.topPositionRatio,
    ChartPanelID.globalAccountRatio,
  ]

  private func formattedCompactQuantity(_ value: Double) -> String {
    DisplayNumber.compact(value)
  }

  private func formattedTime(_ openTime: Int64) -> String {
    timeFormatter.string(
      from: Date(
        timeIntervalSince1970: Double(openTime) / 1_000
      ))
  }

  private func consumeRevision() -> UInt64 {
    defer {
      nextRevision &+= 1
    }
    return nextRevision
  }
}
