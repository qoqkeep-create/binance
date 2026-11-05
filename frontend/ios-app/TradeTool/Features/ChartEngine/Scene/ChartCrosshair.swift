import Foundation
import CoreGraphics

struct ChartCrosshairValueDomain: Equatable, Sendable {
    let lower: Double
    let upper: Double

    init?(lower: Double, upper: Double) {
        guard lower.isFinite,
              upper.isFinite,
              upper > lower else {
            return nil
        }
        self.lower = lower
        self.upper = upper
    }

    func value(
        atY y: Double,
        in plot: ChartPanelRect
    ) -> Double? {
        guard y.isFinite,
              plot.isValid else {
            return nil
        }
        let clampedY = min(
            Double(plot.bottom),
            max(Double(plot.top), y)
        )
        let fraction = (clampedY - Double(plot.top))
            / Double(plot.height)
        let value = upper - (upper - lower) * fraction
        return value.isFinite ? value : nil
    }
}

final class ChartCrosshairDataSnapshot: @unchecked Sendable {
    let stream: ChartStreamKey
    let history: ChartCandleHistory
    let indicatorHistory: ChartIndicatorHistorySnapshot
    let panelLayout: ChartPanelLayout
    let priceDomain: ChartCrosshairValueDomain
    let panelDomains: [String: ChartCrosshairValueDomain]
    let glyphAtlas: ChartGlyphAtlasSnapshot
    let timelineViewport: ChartTimelineViewport
    let totalSlotCount: Int
    let reservesLiveSlot: Bool
    let widthPixels: Float
    let heightPixels: Float
    let displayScale: Float
    let slotWidthPixels: Float

    private let historyIndexByOpenTime: [Int64: Int]

    init?(
        stream: ChartStreamKey,
        history: ChartCandleHistory,
        indicatorHistory: ChartIndicatorHistorySnapshot,
        panelLayout: ChartPanelLayout,
        priceDomain: ChartCrosshairValueDomain,
        panelDomains: [String: ChartCrosshairValueDomain],
        glyphAtlas: ChartGlyphAtlasSnapshot,
        timelineViewport: ChartTimelineViewport,
        totalSlotCount: Int,
        reservesLiveSlot: Bool,
        widthPixels: Float,
        heightPixels: Float,
        displayScale: Float,
        slotWidthPixels: Float
    ) {
        guard totalSlotCount > 0,
              totalSlotCount == history.candles.count
                + (reservesLiveSlot ? 1 : 0),
              widthPixels.isFinite,
              widthPixels > 0,
              heightPixels.isFinite,
              heightPixels > 0,
              displayScale.isFinite,
              displayScale > 0,
              slotWidthPixels.isFinite,
              slotWidthPixels > 0 else {
            return nil
        }
        var indexes: [Int64: Int] = [:]
        indexes.reserveCapacity(history.candles.count)
        for (index, candle) in history.candles.enumerated() {
            guard indexes.updateValue(
                index,
                forKey: candle.openTime
            ) == nil else {
                return nil
            }
        }
        self.stream = stream
        self.history = history
        self.indicatorHistory = indicatorHistory
        self.panelLayout = panelLayout
        self.priceDomain = priceDomain
        self.panelDomains = panelDomains
        self.glyphAtlas = glyphAtlas
        self.timelineViewport = timelineViewport
        self.totalSlotCount = totalSlotCount
        self.reservesLiveSlot = reservesLiveSlot
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.displayScale = displayScale
        self.slotWidthPixels = slotWidthPixels
        historyIndexByOpenTime = indexes
    }

    var historyCount: Int {
        history.candles.count
    }

    func historyIndex(openTime: Int64) -> Int? {
        historyIndexByOpenTime[openTime]
    }

    func baselineX(globalSlot: Int) -> Double? {
        guard globalSlot >= 0,
              globalSlot < totalSlotCount else {
            return nil
        }
        let latestSlot = totalSlotCount - 1
        let localSlot = timelineViewport.visibleSlotCount
            - 0.5
            + timelineViewport.trailingOffsetSlots
            + Double(globalSlot - latestSlot)
        let value = Double(panelLayout.plotLeft)
            + localSlot * Double(slotWidthPixels)
        return value.isFinite ? value : nil
    }

    func globalSlot(baselineX: Double) -> Int? {
        guard baselineX.isFinite else {
            return nil
        }
        let localSlot = (baselineX - Double(panelLayout.plotLeft))
            / Double(slotWidthPixels)
        let latestSlot = totalSlotCount - 1
        let rawSlot = localSlot
            - timelineViewport.visibleSlotCount
            + 0.5
            - timelineViewport.trailingOffsetSlots
            + Double(latestSlot)
        guard rawSlot.isFinite,
              rawSlot >= Double(Int.min),
              rawSlot <= Double(Int.max) else {
            return nil
        }
        let slot = Int(rawSlot.rounded())
        return (0..<totalSlotCount).contains(slot)
            ? slot
            : nil
    }
}

struct ChartCrosshairLiveData: Sendable {
    let candle: ChartCandle?
    let indicatorPoints: [ChartIndicatorLivePoint]
    let legends: [ChartIndicatorLegendEntry]
}

enum ChartCandleMarkerLayout {
    /// Transform the anchor only; the square and its gap retain their point size when zooming.
    static func frame(marker: ChartCandleMarker, candle: ChartCandle, baselineX: Double,
                      plot: ChartPanelRect, domain: ChartCrosshairValueDomain,
                      transform: ChartTimelineInteractionTransform, displayScale: Double,
                      boundaryTranslationPoints: Double = 0, avoiding exclusions: [CGRect] = []) -> CGRect? {
        guard displayScale.isFinite, displayScale > 0, plot.isValid, candle.isValid,
              candle.openTime <= marker.timestamp, marker.timestamp <= candle.closeTime else { return nil }
        let x = transform.screenX(baselineX: baselineX) / displayScale + boundaryTranslationPoints
        let price = marker.placement == .above ? candle.highPrice : candle.lowPrice
        let anchorY = (Double(plot.top) + (domain.upper - price) / (domain.upper - domain.lower)
            * Double(plot.height)) / displayScale
        let size = ChartCandleMarker.sizePoints
        let centerY = anchorY + (marker.placement == .above ? -1 : 1) * (size / 2 + ChartCandleMarker.gapPoints)
        guard x.isFinite, centerY.isFinite else { return nil }
        var result = CGRect(x: CGFloat(x - size / 2), y: CGFloat(centerY - size / 2),
            width: CGFloat(size), height: CGFloat(size))
        // Keep the entry badge clear of the read-only price labels above this native layer.
        for _ in exclusions.indices {
            guard let obstacle = exclusions.first(where: { result.intersects($0) }) else { break }
            result.origin.y = marker.placement == .above ? obstacle.minY - result.height - 1 : obstacle.maxY + 1
        }
        let visible = CGRect(x: CGFloat(Double(plot.left) / displayScale), y: CGFloat(Double(plot.top) / displayScale),
            width: CGFloat(Double(plot.width) / displayScale), height: CGFloat(Double(plot.height) / displayScale))
        return result.intersects(visible) ? result : nil
    }
}

struct ChartCrosshairSelection: Equatable, Sendable {
    let openTime: Int64
    let panelID: String
    let snappedX: Float
    let fingerY: Float
    let panelValue: Double
}

struct ChartCrosshairIndicatorValue: Equatable, Sendable {
    let key: ChartIndicatorSeriesKey
    let label: String
    let value: Double?
    let labelColorToken: ChartIndicatorColorToken
    let colorToken: ChartIndicatorColorToken
    let placement: ChartIndicatorPlacement
    let row: Int
    let order: Int
}

struct ChartCrosshairHit: Equatable, Sendable {
    let selection: ChartCrosshairSelection
    let candle: ChartCandle
    let priceChange: Double
    let priceChangeRate: Double?
    let indicatorValues: [ChartCrosshairIndicatorValue]
}

enum ChartCrosshairDisplaySemantics {
    static func relativePriceRate(
        crosshairPrice: Double,
        latestPrice: Double?
    ) -> Double? {
        guard crosshairPrice.isFinite,
              let latestPrice,
              latestPrice.isFinite,
              latestPrice > 0 else {
            return nil
        }
        let rate = crosshairPrice / latestPrice - 1
        return rate.isFinite ? rate : nil
    }

    static func amplitudeRate(
        for candle: ChartCandle
    ) -> Double? {
        guard candle.openPrice.isFinite,
              candle.openPrice != 0 else {
            return nil
        }
        let rate = (candle.highPrice - candle.lowPrice)
            / abs(candle.openPrice)
        return rate.isFinite ? rate : nil
    }
}

final class CrosshairSnapshot: @unchecked Sendable {
    static let maximumLineCount = 32
    static let maximumBarCount = 24
    static let maximumGlyphCount = 384

    let hit: ChartCrosshairHit
    let batches: [ChartRenderBatch]
    let renderedIndicatorKeys: [ChartIndicatorSeriesKey]
    let axisPriceChangeRate: Double?

    init(
        hit: ChartCrosshairHit,
        batches: [ChartRenderBatch],
        renderedIndicatorKeys: [ChartIndicatorSeriesKey],
        axisPriceChangeRate: Double?
    ) {
        self.hit = hit
        self.batches = batches
        self.renderedIndicatorKeys = renderedIndicatorKeys
        self.axisPriceChangeRate = axisPriceChangeRate
    }

    var lineCount: Int {
        batches.reduce(0) {
            $0 + $1.storage.lineSegments.count
        }
    }

    var barCount: Int {
        batches.reduce(0) {
            $0 + $1.storage.barInstances.count
        }
    }

    var glyphCount: Int {
        batches.reduce(0) {
            $0 + $1.storage.glyphInstances.count
        }
    }
}

enum ChartCrosshairResolver {
    static func resolve(
        screenX: Double,
        screenY: Double,
        transform: ChartTimelineInteractionTransform,
        data: ChartCrosshairDataSnapshot,
        liveData: ChartCrosshairLiveData?,
        preferredOpenTime: Int64? = nil,
        preferredPanelID: String? = nil,
        clampsToPlot: Bool = false
    ) -> ChartCrosshairHit? {
        guard screenX.isFinite,
              screenY.isFinite else {
            return nil
        }
        let plotLeft = Double(data.panelLayout.plotLeft)
        let plotRight = Double(data.panelLayout.plotRight)
        let resolvedScreenX: Double
        if clampsToPlot {
            resolvedScreenX = min(
                plotRight,
                max(plotLeft, screenX)
            )
        } else {
            guard screenX >= plotLeft,
                  screenX <= plotRight else {
                return nil
            }
            resolvedScreenX = screenX
        }

        guard let panel = resolvedPanel(
            screenY: screenY,
            preferredPanelID: preferredPanelID,
            layout: data.panelLayout,
            clampsToPlot: clampsToPlot
        ) else {
            return nil
        }
        let clampedY = min(
            Double(panel.plot.bottom),
            max(Double(panel.plot.top), screenY)
        )

        let globalSlot: Int
        if let preferredOpenTime {
            if let index = data.historyIndex(
                openTime: preferredOpenTime
            ) {
                globalSlot = index
            } else if data.reservesLiveSlot,
                      liveData?.candle?.openTime
                        == preferredOpenTime {
                globalSlot = data.historyCount
            } else {
                return nil
            }
        } else {
            guard let baselineX = transform
                .baselineX(screenX: resolvedScreenX),
                  let slot = data.globalSlot(
                    baselineX: baselineX
                  ) else {
                return nil
            }
            globalSlot = slot
        }

        let candle: ChartCandle
        let isLive: Bool
        if globalSlot < data.historyCount {
            candle = data.history.candles[globalSlot]
            isLive = false
        } else if data.reservesLiveSlot,
                  globalSlot == data.historyCount,
                  let liveCandle = liveData?.candle {
            candle = liveCandle
            isLive = true
        } else {
            return nil
        }

        guard let baselineSnappedX = data.baselineX(
            globalSlot: globalSlot
        ) else {
            return nil
        }
        let snappedX = transform.screenX(
            baselineX: baselineSnappedX
        )
        guard snappedX.isFinite,
              snappedX >= plotLeft - 0.000_1,
              snappedX <= plotRight + 0.000_1 else {
            return nil
        }

        let valueDomain: ChartCrosshairValueDomain
        if panel.isPricePanel {
            valueDomain = data.priceDomain
        } else if let domain = data.panelDomains[panel.id] {
            valueDomain = domain
        } else {
            return nil
        }
        guard let panelValue = valueDomain.value(
            atY: clampedY,
            in: panel.plot
        ) else {
            return nil
        }

        let change = candle.closePrice - candle.openPrice
        let changeRate = candle.openPrice == 0
            ? nil
            : change / candle.openPrice
        return ChartCrosshairHit(
            selection: ChartCrosshairSelection(
                openTime: candle.openTime,
                panelID: panel.id,
                snappedX: Float(snappedX),
                fingerY: Float(clampedY),
                panelValue: panelValue
            ),
            candle: candle,
            priceChange: change,
            priceChangeRate: changeRate,
            indicatorValues: indicatorValues(
                globalSlot: globalSlot,
                candle: candle,
                isLive: isLive,
                data: data,
                liveData: liveData
            )
        )
    }

    private static func resolvedPanel(
        screenY: Double,
        preferredPanelID: String?,
        layout: ChartPanelLayout,
        clampsToPlot: Bool
    ) -> ChartPanelFrame? {
        if let direct = layout.panels.first(where: {
            screenY >= Double($0.plot.top)
                && screenY <= Double($0.plot.bottom)
        }) {
            return direct
        }
        guard clampsToPlot,
              let preferredPanelID else {
            return nil
        }
        return layout.panel(id: preferredPanelID)
    }

    private static func indicatorValues(
        globalSlot: Int,
        candle: ChartCandle,
        isLive: Bool,
        data: ChartCrosshairDataSnapshot,
        liveData: ChartCrosshairLiveData?
    ) -> [ChartCrosshairIndicatorValue] {
        let legends = liveData?.legends ?? []
        var livePoints: [
            ChartIndicatorSeriesKey: IndicatorPoint
        ] = [:]
        for item in liveData?.indicatorPoints ?? [] {
            livePoints[item.key] = item.point
        }
        let values: [ChartCrosshairIndicatorValue]
        if legends.isEmpty {
            values = data.indicatorHistory.series.map { series in
                indicatorValue(
                    series: series,
                    legend: nil,
                    globalSlot: globalSlot,
                    candle: candle,
                    isLive: isLive,
                    livePoints: livePoints
                )
            }
        } else {
            values = legends.compactMap { legend in
                let exact = data.indicatorHistory.series.filter {
                    "\($0.key.instanceID).\($0.key.outputID)"
                        == legend.instanceID
                }
                let candidates = exact.isEmpty
                    ? data.indicatorHistory.series.filter {
                        $0.key.instanceID == legend.instanceID
                    }
                    : exact
                guard let fallback = candidates.first else {
                    return nil
                }
                let resolved = candidates.first {
                    let point = indicatorPoint(
                        series: $0,
                        globalSlot: globalSlot,
                        isLive: isLive,
                        livePoints: livePoints
                    )
                    return point?.openTime == candle.openTime
                        && point?.validity == .valid
                        && point?.value?.isFinite == true
                } ?? fallback
                return indicatorValue(
                    series: resolved,
                    legend: legend,
                    globalSlot: globalSlot,
                    candle: candle,
                    isLive: isLive,
                    livePoints: livePoints,
                    usesSeriesColor: exact.isEmpty
                        && candidates.count > 1
                )
            }
        }
        return decoratedVolumeValues(
            values,
            candle: candle,
            stream: data.stream
        ).sorted {
            if $0.row != $1.row {
                return $0.row < $1.row
            }
            return $0.order < $1.order
        }
    }

    private static func decoratedVolumeValues(
        _ values: [ChartCrosshairIndicatorValue],
        candle: ChartCandle,
        stream: ChartStreamKey
    ) -> [ChartCrosshairIndicatorValue] {
        guard let baseVolume = values.first(where: {
            $0.placement == .panel(ChartPanelID.volume)
                && $0.key.outputID == "volume"
        }) else {
            return values
        }
        let assets = splitTradingPair(stream.symbol)
        let directionColor: ChartIndicatorColorToken
        if candle.closePrice > candle.openPrice {
            directionColor = .positive
        } else if candle.closePrice < candle.openPrice {
            directionColor = .negative
        } else {
            directionColor = .neutral
        }
        var result: [ChartCrosshairIndicatorValue] = []
        result.reserveCapacity(values.count + 1)
        for item in values {
            guard item.placement == .panel(ChartPanelID.volume)
            else {
                result.append(item)
                continue
            }
            let isBaseVolume = item.key == baseVolume.key
            result.append(ChartCrosshairIndicatorValue(
                key: item.key,
                label: isBaseVolume
                    ? assets.map { "VOL(\($0.base)):" }
                        ?? "VOL:"
                    : item.label,
                value: item.value,
                labelColorToken: isBaseVolume
                    ? .neutral
                    : item.labelColorToken,
                colorToken: isBaseVolume
                    ? directionColor
                    : item.colorToken,
                placement: item.placement,
                row: item.row,
                order: isBaseVolume
                    ? 0
                    : volumeOrder(
                        outputID: item.key.outputID,
                        fallback: item.order + 1
                    )
            ))
        }
        if let quote = assets?.quote {
            result.append(ChartCrosshairIndicatorValue(
                key: ChartIndicatorSeriesKey(
                    instanceID: baseVolume.key.instanceID,
                    outputID: "quoteVolume"
                ),
                label: "VOL(\(quote)):",
                value: candle.quoteVolume,
                labelColorToken: .neutral,
                colorToken: .neutral,
                placement: .panel(ChartPanelID.volume),
                row: baseVolume.row,
                order: 1
            ))
        }
        return result
    }

    private static func volumeOrder(
        outputID: String,
        fallback: Int
    ) -> Int {
        switch outputID {
        case "fastAverage":
            return 2
        case "slowAverage":
            return 3
        default:
            return fallback
        }
    }

    private static func splitTradingPair(
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

    private static func indicatorValue(
        series: ChartIndicatorSeriesHistory,
        legend: ChartIndicatorLegendEntry?,
        globalSlot: Int,
        candle: ChartCandle,
        isLive: Bool,
        livePoints: [ChartIndicatorSeriesKey: IndicatorPoint],
        usesSeriesColor: Bool = false
    ) -> ChartCrosshairIndicatorValue {
        let point = indicatorPoint(
            series: series,
            globalSlot: globalSlot,
            isLive: isLive,
            livePoints: livePoints
        )
        let value: Double?
        if point?.openTime == candle.openTime,
           point?.validity == .valid,
           let finiteValue = point?.value,
           finiteValue.isFinite {
            value = finiteValue
        } else {
            value = nil
        }
        let selectedColor = usesSeriesColor
            ? series.colorToken
            : legend?.colorToken ?? series.colorToken
        return ChartCrosshairIndicatorValue(
            key: series.key,
            label: legend?.label
                ?? "\(series.key.outputID.uppercased()):",
            value: value,
            labelColorToken: usesSeriesColor
                ? selectedColor
                : legend?.labelColorToken ?? series.colorToken,
            colorToken: selectedColor,
            placement: legend?.placement ?? series.placement,
            row: legend?.row ?? 0,
            order: legend?.order ?? 0
        )
    }

    private static func indicatorPoint(
        series: ChartIndicatorSeriesHistory,
        globalSlot: Int,
        isLive: Bool,
        livePoints: [ChartIndicatorSeriesKey: IndicatorPoint]
    ) -> IndicatorPoint? {
        if isLive {
            return livePoints[series.key]
        }
        return globalSlot < series.points.count
            ? series.points[globalSlot]
            : nil
    }
}

@MainActor
final class ChartCrosshairOverlayBuilder {
    private let showsCandleCard: Bool

    init(showsCandleCard: Bool = false) {
        self.showsCandleCard = showsCandleCard
    }

    private enum TextAlignment {
        case leading
        case center
        case trailing
    }

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
    private lazy var candleTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    func makeSnapshot(
        hit: ChartCrosshairHit,
        data: ChartCrosshairDataSnapshot,
        latestPrice: Double? = nil
    ) -> CrosshairSnapshot {
        let scale = data.displayScale
        let layout = data.panelLayout
        let panel = layout.panel(
            id: hit.selection.panelID
        ) ?? layout.pricePanel!
        let x = hit.selection.snappedX
        let y = hit.selection.fingerY
        let lineColor = ChartColor.crosshair
        var lines = layout.panels.map { panel in
            ChartLineSegmentInstance(
                start: ChartPolylinePoint(
                    x: x,
                    y: panel.plot.top
                ),
                end: ChartPolylinePoint(
                    x: x,
                    y: panel.plot.bottom
                ),
                width: max(1, scale * 0.65),
                dashLength: 4 * scale,
                gapLength: 3 * scale,
                dashPhase: 0,
                color: lineColor
            )
        }
        lines.append(
            ChartLineSegmentInstance(
                start: ChartPolylinePoint(
                    x: layout.plotLeft,
                    y: y
                ),
                end: ChartPolylinePoint(
                    x: layout.plotRight,
                    y: y
                ),
                width: max(1, scale * 0.65),
                dashLength: 4 * scale,
                gapLength: 3 * scale,
                dashPhase: 0,
                color: lineColor
            )
        )

        var bars: [ChartBarInstance] = []
        var glyphs: [ChartGlyphInstance] = []
        var renderedIndicatorKeys: [ChartIndicatorSeriesKey] = []
        let pointRadius = 1.75 * scale
        bars.append(ChartBarInstance(
            left: x - pointRadius,
            top: y - pointRadius,
            right: x + pointRadius,
            bottom: y + pointRadius,
            color: .primaryText,
            cornerRadius: pointRadius
        ))
        let axisPriceChangeRate =
            panel.isPricePanel
                ? ChartCrosshairDisplaySemantics
                    .relativePriceRate(
                        crosshairPrice:
                            hit.selection.panelValue,
                        latestPrice: latestPrice
                    )
                : nil
        appendAxisLabel(
            hit: hit,
            panel: panel,
            data: data,
            axisPriceChangeRate: axisPriceChangeRate,
            bars: &bars,
            glyphs: &glyphs
        )
        appendTimeLabels(
            hit: hit,
            data: data,
            bars: &bars,
            glyphs: &glyphs
        )
        appendSelectedLegends(
            hit: hit,
            data: data,
            bars: &bars,
            glyphs: &glyphs,
            renderedIndicatorKeys: &renderedIndicatorKeys
        )

        let boundedLines = Array(
            lines.prefix(CrosshairSnapshot.maximumLineCount)
        )
        let boundedBars = Array(
            bars.prefix(CrosshairSnapshot.maximumBarCount)
        )
        let boundedGlyphs = Array(
            glyphs.prefix(CrosshairSnapshot.maximumGlyphCount)
        )
        return CrosshairSnapshot(
            hit: hit,
            batches: [ChartRenderBatch(
                lineSegments: boundedLines,
                barInstances: boundedBars,
                glyphInstances: boundedGlyphs,
                glyphAtlas: data.glyphAtlas,
                coordinateSpace: .fixed
            )],
            renderedIndicatorKeys: renderedIndicatorKeys,
            axisPriceChangeRate: axisPriceChangeRate
        )
    }

    private func appendAxisLabel(
        hit: ChartCrosshairHit,
        panel: ChartPanelFrame,
        data: ChartCrosshairDataSnapshot,
        axisPriceChangeRate: Double?,
        bars: inout [ChartBarInstance],
        glyphs: inout [ChartGlyphInstance]
    ) {
        let scale = data.displayScale
        let priceText = formattedPrice(
            hit.selection.panelValue,
            reference: hit.selection.panelValue
        )
        let height = (panel.isPricePanel ? 32 : 18) * scale
        let top = min(panel.plot.bottom - height, max(panel.plot.top,
            hit.selection.fingerY - height / 2))
        let left = data.panelLayout.plotRight + 2 * scale
        let right = data.widthPixels - scale
        bars.append(ChartBarInstance(
            left: left, top: top, right: right, bottom: top + height,
            color: .crosshairAxisLabelBackground, cornerRadius: 4 * scale
        ))
        // Match the regular ticks and current-price marker's trailing text anchor.
        let textAnchor = data.widthPixels - 4 * scale
        let rowHeight = panel.isPricePanel ? height / 2 : height
        glyphs.append(contentsOf: axisLabelGlyphs(
            priceText, data: data, left: left, right: right,
            anchor: textAnchor, centerY: top + rowHeight / 2,
            height: rowHeight
        ))
        if panel.isPricePanel {
            let rateText = axisPriceChangeRate.map {
                let percent = $0 * 100
                guard percent.isFinite else { return "--" }
                let text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), percent)
                let normalized = text == "-0.00" ? "0.00" : text
                let sign = percent > 0 && normalized != "0.00" ? "+" : ""
                return sign + normalized + "%"
            } ?? "--"
            glyphs.append(contentsOf: axisLabelGlyphs(
                rateText, data: data, left: left, right: right,
                anchor: textAnchor, centerY: top + rowHeight * 1.5,
                height: rowHeight
            ))
        }
    }

    private func axisLabelGlyphs(
        _ text: String, data: ChartCrosshairDataSnapshot,
        left: Float, right: Float, anchor: Float, centerY: Float, height: Float
    ) -> [ChartGlyphInstance] {
        let measured = alignedText(text, atlas: data.glyphAtlas, x: anchor,
            baselineY: 0, alignment: .trailing, color: .crosshairAxisLabelText)
        guard let minX = measured.instances.map(\.left).min(),
              let maxX = measured.instances.map(\.right).max(),
              let minY = measured.instances.map(\.top).min(),
              let maxY = measured.instances.map(\.bottom).max() else { return [] }
        // Scale the entire row, preserving all digits and the axis alignment.
        let factor = min(1,
            (anchor - left) / max(1, anchor - minX),
            (right - anchor) / max(1, maxX - anchor),
            height / max(1, maxY - minY))
        let glyphCenterY = (minY + maxY) / 2
        return measured.instances.map { glyph in
            ChartGlyphInstance(
                left: anchor + (glyph.left - anchor) * factor,
                top: centerY + (glyph.top - glyphCenterY) * factor,
                right: anchor + (glyph.right - anchor) * factor,
                bottom: centerY + (glyph.bottom - glyphCenterY) * factor,
                uvLeft: glyph.uvLeft, uvTop: glyph.uvTop,
                uvRight: glyph.uvRight, uvBottom: glyph.uvBottom,
                color: glyph.color
            )
        }
    }

    private func appendTimeLabels(
        hit: ChartCrosshairHit,
        data: ChartCrosshairDataSnapshot,
        bars: inout [ChartBarInstance],
        glyphs: inout [ChartGlyphInstance]
    ) {
        let scale = data.displayScale
        let text = timeFormatter.string(from: Date(
            timeIntervalSince1970:
                Double(hit.selection.openTime) / 1_000
        ))
        let measured = alignedText(
            text,
            atlas: data.glyphAtlas,
            x: 0,
            baselineY: 0,
            alignment: .leading,
            color: .crosshairAxisLabelText
        )
        let halfWidth = Float(measured.advance) / 2
            + 5 * scale
        let centerX = min(
            data.panelLayout.plotRight - halfWidth,
            max(
                data.panelLayout.plotLeft + halfWidth,
                hit.selection.snappedX
            )
        )
        let axisTop = data.panelLayout.timeAxisTop
        let axisBottom = data.panelLayout.timeAxisBottom
        let centerY = (axisTop + axisBottom) / 2
        let height = min(20 * scale, axisBottom - axisTop)
        let top = centerY - height / 2
        let bottom = centerY + height / 2
        bars.append(ChartBarInstance(
            left: 0, top: axisTop, right: data.widthPixels, bottom: axisBottom,
            color: .chartBackground
        ))
        bars.append(ChartBarInstance(
            left: centerX - halfWidth, top: top,
            right: centerX + halfWidth, bottom: bottom,
            color: .crosshairAxisLabelBackground, cornerRadius: 4 * scale
        ))
        let glyphTop = measured.instances.map(\.top).min() ?? -Float(measured.ascent)
        let glyphBottom = measured.instances.map(\.bottom).max() ?? Float(measured.descent)
        glyphs.append(contentsOf: alignedText(
            text, atlas: data.glyphAtlas, x: centerX,
            baselineY: centerY - (glyphTop + glyphBottom) / 2,
            alignment: .center, color: .crosshairAxisLabelText
        ).instances)
    }

    private func appendSelectedLegends(
        hit: ChartCrosshairHit,
        data: ChartCrosshairDataSnapshot,
        bars: inout [ChartBarInstance],
        glyphs: inout [ChartGlyphInstance],
        renderedIndicatorKeys: inout [ChartIndicatorSeriesKey]
    ) {
        guard let pricePanel = data.panelLayout.pricePanel else {
            return
        }
        let scale = data.displayScale
        bars.append(ChartBarInstance(
            left: 0,
            top: 0,
            right: data.panelLayout.plotRight,
            bottom: pricePanel.plot.top,
            color: .chartBackground
        ))
        if showsCandleCard {
            appendCandleCard(
                hit: hit,
                pricePanel: pricePanel,
                data: data,
                bars: &bars,
                glyphs: &glyphs
            )
        }
        let priceValues = hit.indicatorValues.filter {
            $0.placement == .priceOverlay
        }
        let priceRows = Dictionary(grouping: priceValues) {
            $0.row
        }
        for row in priceRows.keys.sorted()
        where row >= 0 && row < 2 {
            appendIndicatorRow(
                priceRows[row, default: []],
                baseline: (10.5 + Float(row) * 12) * scale,
                data: data,
                glyphs: &glyphs,
                renderedIndicatorKeys: &renderedIndicatorKeys
            )
        }
        for panel in data.panelLayout.indicatorPanels {
            let values = hit.indicatorValues.filter {
                $0.placement == .panel(panel.id)
            }
            guard !values.isEmpty else {
                continue
            }
            bars.append(ChartBarInstance(
                left: 0,
                top: panel.plot.bottom,
                right: data.panelLayout.plotRight,
                bottom: panel.frame.bottom,
                color: .chartBackground
            ))
            appendIndicatorRow(
                values,
                baseline: panel.legendBaseline,
                data: data,
                glyphs: &glyphs,
                renderedIndicatorKeys: &renderedIndicatorKeys
            )
        }
    }

    private func appendCandleCard(
        hit: ChartCrosshairHit,
        pricePanel: ChartPanelFrame,
        data: ChartCrosshairDataSnapshot,
        bars: inout [ChartBarInstance],
        glyphs: inout [ChartGlyphInstance]
    ) {
        let scale = data.displayScale
        let candle = hit.candle
        let percentage = hit.priceChangeRate.map {
            DisplayNumber.text($0 * 100, signed: true) + "%"
        } ?? "--"
        let change = formattedSignedPrice(
            hit.priceChange,
            reference: candle.openPrice
        )
        let amplitude = ChartCrosshairDisplaySemantics
            .amplitudeRate(for: candle)
            .map { DisplayNumber.text($0 * 100) + "%" }
            ?? "--"
        let directionColor: ChartColor
        if hit.priceChange > 0 {
            directionColor = .positive
        } else if hit.priceChange < 0 {
            directionColor = .negative
        } else {
            directionColor = .primaryText
        }
        let time = candleTimeFormatter.string(from: Date(
            timeIntervalSince1970:
                Double(candle.openTime) / 1_000
        ))
        let lines: [(String, String, ChartColor)] = [
            ("时间", time, .primaryText),
            (
                "开",
                formattedPrice(
                    candle.openPrice,
                    reference: candle.closePrice
                ),
                .primaryText
            ),
            (
                "高",
                formattedPrice(
                    candle.highPrice,
                    reference: candle.closePrice
                ),
                .primaryText
            ),
            (
                "低",
                formattedPrice(
                    candle.lowPrice,
                    reference: candle.closePrice
                ),
                .primaryText
            ),
            (
                "收",
                formattedPrice(
                    candle.closePrice,
                    reference: candle.closePrice
                ),
                .primaryText
            ),
            ("涨跌", change, directionColor),
            ("涨跌幅", percentage, directionColor),
            ("振幅", amplitude, .primaryText),
            ("量", formattedQuantity(candle.volume), .primaryText),
            (
                "额",
                formattedQuoteVolume(candle.quoteVolume),
                .primaryText
            ),
        ]
        let horizontalPadding = 5 * scale
        let verticalPadding = 5 * scale
        let lineHeight = 14.3 * scale
        let cardWidth = min(
            pricePanel.plot.width,
            90 * scale
        )
        let cardHeight = verticalPadding * 2
            + lineHeight * Float(lines.count)
        let cardLeft: Float
        if hit.selection.snappedX
            > (pricePanel.plot.left + pricePanel.plot.right) / 2 {
            cardLeft = max(
                pricePanel.plot.left,
                10 * scale
            )
        } else {
            let rightEdge = min(
                pricePanel.plot.right - 24 * scale,
                data.widthPixels - 82 * scale
            )
            cardLeft = max(
                pricePanel.plot.left,
                rightEdge - cardWidth
            )
        }
        let cardTop = pricePanel.plot.top + 4 * scale
        let cardBottom = min(
            pricePanel.plot.bottom,
            cardTop + cardHeight
        )
        let borderWidth = max(1, 0.5 * scale)
        bars.append(ChartBarInstance(
            left: cardLeft,
            top: cardTop,
            right: cardLeft + cardWidth,
            bottom: cardBottom,
            color: .crosshairLabelBorder,
            cornerRadius: 5 * scale
        ))
        bars.append(ChartBarInstance(
            left: cardLeft + borderWidth,
            top: cardTop + borderWidth,
            right: cardLeft + cardWidth - borderWidth,
            bottom: cardBottom - borderWidth,
            color: .crosshairLabelBackground,
            cornerRadius: max(0, 5 * scale - borderWidth)
        ))
        for (index, line) in lines.enumerated() {
            glyphs.append(contentsOf: alignedText(
                line.0,
                atlas: data.glyphAtlas,
                x: cardLeft + horizontalPadding,
                baselineY: cardTop
                    + verticalPadding
                    + 8.5 * scale
                    + Float(index) * lineHeight,
                alignment: .leading,
                color: .primaryText
            ).instances.filter {
                $0.right <= cardLeft + cardWidth
                    - horizontalPadding
                    && $0.bottom <= cardBottom
            })
            glyphs.append(contentsOf: alignedText(
                line.1,
                atlas: data.glyphAtlas,
                x: cardLeft + cardWidth - horizontalPadding,
                baselineY: cardTop
                    + verticalPadding
                    + 8.5 * scale
                    + Float(index) * lineHeight,
                alignment: .trailing,
                color: line.2
            ).instances.filter {
                $0.left >= cardLeft + horizontalPadding
                    && $0.bottom <= cardBottom
            })
        }
    }

    private func appendIndicatorRow(
        _ values: [ChartCrosshairIndicatorValue],
        baseline: Float,
        data: ChartCrosshairDataSnapshot,
        glyphs: inout [ChartGlyphInstance],
        renderedIndicatorKeys: inout [ChartIndicatorSeriesKey]
    ) {
        var cursor = data.panelLayout.plotLeft
        var rowGlyphs: [ChartGlyphInstance] = []
        for item in values {
            let label = alignedText(
                "\(item.label) ",
                atlas: data.glyphAtlas,
                x: cursor,
                baselineY: baseline,
                alignment: .leading,
                color: item.labelColorToken.color
            )
            let value = alignedText(
                item.value.map {
                    if item.placement
                        == .panel(ChartPanelID.volume) {
                        return formattedCompactQuantity($0)
                    }
                    return formattedPrice($0, reference: $0)
                } ?? "--",
                atlas: data.glyphAtlas,
                x: cursor + Float(label.advance),
                baselineY: baseline,
                alignment: .leading,
                color: item.colorToken.color
            )
            let next = cursor
                + Float(label.advance)
                + Float(value.advance)
                + 8 * data.displayScale
            rowGlyphs.append(contentsOf: label.instances)
            rowGlyphs.append(contentsOf: value.instances)
            renderedIndicatorKeys.append(item.key)
            cursor = next
        }
        glyphs.append(contentsOf: ChartGlyphRowLayout.fitting(
            rowGlyphs, left: data.panelLayout.plotLeft,
            right: data.panelLayout.plotRight, baseline: baseline
        ))
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
        return ChartTextLayoutResult(
            instances: measured.instances.map { instance in
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
            },
            advance: measured.advance,
            ascent: measured.ascent,
            descent: measured.descent,
            missingGlyphCount: measured.missingGlyphCount
        )
    }

    private func formattedPrice(_ value: Double, reference: Double) -> String {
        DisplayNumber.text(value, grouped: true)
    }

    private func compactPrice(_ value: Double) -> String {
        DisplayNumber.text(value)
    }

    private func formattedSignedPrice(
        _ value: Double,
        reference: Double
    ) -> String {
        guard value.isFinite else {
            return "--"
        }
        let prefix = value >= 0 ? "+" : "-"
        return prefix + formattedPrice(
            abs(value),
            reference: reference
        )
    }


    private func formattedQuantity(_ value: Double) -> String {
          DisplayNumber.text(value, grouped: true)
    }

    private func formattedCompactQuantity(_ value: Double) -> String {
        DisplayNumber.compact(value)
    }

    private func formattedQuoteVolume(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 100_000_000 {
            return formattedQuantity(value / 100_000_000) + "亿"
        }
        if magnitude >= 10_000 {
            return formattedQuantity(value / 10_000) + "万"
        }
        return formattedQuantity(value)
    }
}
