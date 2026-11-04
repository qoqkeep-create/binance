import Foundation

final class StaticSceneSnapshot: @unchecked Sendable {
    let revision: UInt64
    let candleHistory: ChartCandleHistory
    let batches: [ChartRenderBatch]
    let timelineViewport: ChartTimelineViewport?
    let horizontalPlotBounds: ChartHorizontalPlotBounds?
    let crosshairData: ChartCrosshairDataSnapshot?

    init(
        revision: UInt64,
        candleHistory: ChartCandleHistory,
        batches: [ChartRenderBatch],
        timelineViewport: ChartTimelineViewport? = nil,
        horizontalPlotBounds: ChartHorizontalPlotBounds? = nil,
        crosshairData: ChartCrosshairDataSnapshot? = nil
    ) {
        self.revision = revision
        self.candleHistory = candleHistory
        self.batches = batches
        self.timelineViewport = timelineViewport
        self.horizontalPlotBounds = horizontalPlotBounds
        self.crosshairData = crosshairData
    }
}

struct ChartHorizontalPlotBounds: Equatable, Sendable {
    let left: Float
    let right: Float

    init?(left: Float, right: Float) {
        guard left.isFinite,
              right.isFinite,
              right > left else {
            return nil
        }
        self.left = left
        self.right = right
    }
}

final class LiveTailSnapshot: @unchecked Sendable {
    let revision: UInt64
    let readyTime: TimeInterval
    let candle: ChartCandle?
    let batches: [ChartRenderBatch]
    let latestPrice: Double?
    let latestPriceMarker: ChartLatestPriceMarkerSnapshot?
    let displayedLegends: [ChartIndicatorLegendEntry]
    let crosshairLiveData: ChartCrosshairLiveData?

    init(
        revision: UInt64,
        readyTime: TimeInterval =
            ProcessInfo.processInfo.systemUptime,
        candle: ChartCandle?,
        batches: [ChartRenderBatch],
        latestPrice: Double?,
        latestPriceMarker: ChartLatestPriceMarkerSnapshot? = nil,
        displayedLegends: [ChartIndicatorLegendEntry] = [],
        crosshairLiveData: ChartCrosshairLiveData? = nil
    ) {
        self.revision = revision
        self.readyTime = readyTime
        self.candle = candle
        self.batches = batches
        self.latestPrice = latestPrice
        self.latestPriceMarker = latestPriceMarker
        self.displayedLegends = displayedLegends
        self.crosshairLiveData = crosshairLiveData
    }
}

struct ChartLatestPriceMarkerSnapshot: Equatable, Sendable {
    let left: Float
    let top: Float
    let right: Float
    let bottom: Float
    let returnsToLatest: Bool

    init?(
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        returnsToLatest: Bool
    ) {
        guard [left, top, right, bottom].allSatisfy(\.isFinite),
              right > left,
              bottom > top else {
            return nil
        }
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.returnsToLatest = returnsToLatest
    }

    func contains(
        x: Float,
        y: Float,
        padding: Float = 0
    ) -> Bool {
        guard x.isFinite,
              y.isFinite,
              padding.isFinite,
              padding >= 0 else {
            return false
        }
        return x >= left - padding
            && x <= right + padding
            && y >= top - padding
            && y <= bottom + padding
    }
}

final class InteractionSnapshot: @unchecked Sendable {
    let revision: UInt64
    let translationX: Double
    let scaleX: Double
    let candleHalfBodyWidthPixels: Double?
    let candleHalfWickWidthPixels: Double?
    let crosshair: CrosshairSnapshot?

    init(
        revision: UInt64,
        translationX: Double,
        scaleX: Double,
        candleHalfBodyWidthPixels: Double? = nil,
        candleHalfWickWidthPixels: Double? = nil,
        crosshair: CrosshairSnapshot?
    ) {
        self.revision = revision
        self.translationX = translationX
        self.scaleX = scaleX
        self.candleHalfBodyWidthPixels =
            candleHalfBodyWidthPixels
        self.candleHalfWickWidthPixels =
            candleHalfWickWidthPixels
        self.crosshair = crosshair
    }
}

struct RenderState: Sendable {
    let appearance: ChartAppearance
    let axisPriceLabels: [ChartAxisPriceLabel]
    let staticScene: StaticSceneSnapshot
    let liveTail: LiveTailSnapshot
    let interaction: InteractionSnapshot
    let invalidation: ChartInvalidation
    let readyTime: TimeInterval

    init(
        staticScene: StaticSceneSnapshot,
        liveTail: LiveTailSnapshot,
        interaction: InteractionSnapshot,
        invalidation: ChartInvalidation,
        appearance: ChartAppearance = .dark,
        axisPriceLabels: [ChartAxisPriceLabel] = [],
        readyTime: TimeInterval =
            ProcessInfo.processInfo.systemUptime
    ) {
        self.appearance = appearance
        self.axisPriceLabels = axisPriceLabels
        self.staticScene = staticScene
        self.liveTail = liveTail
        self.interaction = interaction
        self.invalidation = invalidation
        self.readyTime = readyTime
    }

    func withAppearance(_ appearance: ChartAppearance) -> RenderState {
        RenderState(
            staticScene: staticScene,
            liveTail: liveTail,
            interaction: interaction,
            invalidation: invalidation,
            appearance: appearance,
            axisPriceLabels: axisPriceLabels,
            readyTime: readyTime
        )
    }

    func withAxisPriceLabels(_ labels: [ChartAxisPriceLabel]) -> RenderState {
        RenderState(
            staticScene: staticScene,
            liveTail: liveTail,
            interaction: interaction,
            invalidation: invalidation,
            appearance: appearance,
            axisPriceLabels: labels,
            readyTime: readyTime
        )
    }

    var revision: UInt64 {
        max(
            staticScene.revision,
            max(liveTail.revision, interaction.revision)
        )
    }
}

final class LatestRenderStateMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: RenderState?

    func publish(_ state: RenderState) {
        lock.lock()
        pending = state
        lock.unlock()
    }

    func consumeLatest() -> RenderState? {
        lock.lock()
        defer {
            lock.unlock()
        }
        let latest = pending
        pending = nil
        return latest
    }

    var hasPendingState: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return pending != nil
    }
}
