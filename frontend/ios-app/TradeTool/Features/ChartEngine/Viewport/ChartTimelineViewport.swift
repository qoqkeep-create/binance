import Foundation

struct ChartInteractionMetrics: Equatable, Sendable {
    static let standard = ChartInteractionMetrics(
        plotLeadingInsetPoints: 4,
        plotTrailingInsetPoints: 58,
        defaultPointsPerSlot: 7.6,
        minimumVisibleSlotCount: 10,
        maximumVisibleSlotCount: 164,
        guardBandSlotCount: 48,
        candleGapPoints: 1,
        latestBoundaryVisibleCandleCount: 5,
        directionLockRatio: 1.15,
        // Keep the chart's horizontal pan outside WidePopController's start zone.
        systemNavigationEdgeWidthPoints: 50,
        crosshairMinimumPressDurationSeconds: 0.35,
        crosshairAllowableMovementPoints: 12
    )

    let plotLeadingInsetPoints: Double
    let plotTrailingInsetPoints: Double
    let defaultPointsPerSlot: Double
    let minimumVisibleSlotCount: Double
    let maximumVisibleSlotCount: Double
    let guardBandSlotCount: Int
    let candleGapPoints: Double
    let latestBoundaryVisibleCandleCount: Double
    let directionLockRatio: Double
    let systemNavigationEdgeWidthPoints: Double
    let crosshairMinimumPressDurationSeconds: Double
    let crosshairAllowableMovementPoints: Double

    func plotWidth(totalWidthPoints: Double) -> Double {
        max(
            1,
            totalWidthPoints
                - plotLeadingInsetPoints
                - plotTrailingInsetPoints
        )
    }

    func plotLeftPixels(displayScale: Double) -> Double {
        plotLeadingInsetPoints * displayScale
    }

    func plotWidthPixels(
        totalWidthPoints: Double,
        displayScale: Double
    ) -> Double {
        plotWidth(totalWidthPoints: totalWidthPoints) * displayScale
    }

    func candleHalfBodyWidthPixels(
        visibleSlotCount: Double,
        totalWidthPoints: Double,
        displayScale: Double
    ) -> Double {
        guard visibleSlotCount.isFinite,
              visibleSlotCount > 0,
              displayScale.isFinite,
              displayScale > 0 else {
            return 0
        }
        let slotWidth = plotWidthPixels(
            totalWidthPoints: totalWidthPoints,
            displayScale: displayScale
        ) / visibleSlotCount
        let gap = min(
            max(0, candleGapPoints * displayScale),
            max(0, slotWidth - 1)
        )
        return max(
            0.5,
            (slotWidth - gap) / 2
        )
    }

    func candleHalfWickWidthPixels(
        displayScale: Double
    ) -> Double {
        guard displayScale.isFinite,
              displayScale > 0 else {
            return 0.5
        }
        return max(0.5, displayScale / 2)
    }

    func minimumTrailingOffsetSlots(
        visibleSlotCount: Double
    ) -> Double {
        guard visibleSlotCount.isFinite,
              visibleSlotCount > 0,
              latestBoundaryVisibleCandleCount.isFinite else {
            return 0
        }
        let visibleCandlesAtBoundary = min(
            visibleSlotCount - 0.5,
            max(0.5, latestBoundaryVisibleCandleCount)
        )
        return max(
            0.5 - visibleSlotCount,
            visibleCandlesAtBoundary - visibleSlotCount
        )
    }
}

struct ChartTimelineMotionMetrics: Equatable, Sendable {
    static let standard = ChartTimelineMotionMetrics(
        decelerationRatePerMillisecond: 0.998,
        minimumInertialVelocityPointsPerSecond: 300,
        maximumInertialVelocityPointsPerSecond: 6_000,
        rubberBandCoefficient: 0.55,
        maximumBoundaryTranslationPoints: 72,
        springAngularFrequency: 14,
        springSettlingDistancePoints: 0.25,
        springSettlingVelocityPointsPerSecond: 5,
        maximumTimeStepSeconds: 1.0 / 30.0,
        maximumMotionDurationSeconds: 2
    )

    let decelerationRatePerMillisecond: Double
    let minimumInertialVelocityPointsPerSecond: Double
    let maximumInertialVelocityPointsPerSecond: Double
    let rubberBandCoefficient: Double
    let maximumBoundaryTranslationPoints: Double
    let springAngularFrequency: Double
    let springSettlingDistancePoints: Double
    let springSettlingVelocityPointsPerSecond: Double
    let maximumTimeStepSeconds: Double
    let maximumMotionDurationSeconds: Double

    func resistedBoundaryTranslation(
        rawTranslationPoints: Double,
        plotWidthPoints: Double
    ) -> Double {
        guard rawTranslationPoints.isFinite,
              plotWidthPoints.isFinite,
              plotWidthPoints > 0,
              rubberBandCoefficient.isFinite,
              rubberBandCoefficient > 0,
              maximumBoundaryTranslationPoints.isFinite,
              maximumBoundaryTranslationPoints > 0 else {
            return 0
        }
        let magnitude = abs(rawTranslationPoints)
        guard magnitude > 0 else {
            return 0
        }
        let resisted = plotWidthPoints
            * (rubberBandCoefficient * magnitude)
            / (plotWidthPoints
                + rubberBandCoefficient * magnitude)
        return rawTranslationPoints.sign == .minus
            ? -min(maximumBoundaryTranslationPoints, resisted)
            : min(maximumBoundaryTranslationPoints, resisted)
    }
}

enum ChartTimelineBoundary: Equatable, Sendable {
    case none
    case latest
    case oldest
}

struct ChartTimelinePanSample: Equatable, Sendable {
    let viewport: ChartTimelineViewport
    let boundary: ChartTimelineBoundary
    let boundaryTranslationPoints: Double
}

struct ChartTimelineMotionStep: Equatable, Sendable {
    let viewport: ChartTimelineViewport
    let boundaryTranslationPoints: Double
    let isFinished: Bool
}

struct ChartTimelineMotion: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case decelerating
        case springing
    }

    private(set) var phase: Phase = .idle
    private(set) var velocityPointsPerSecond: Double = 0
    private(set) var boundaryTranslationPoints: Double = 0
    private var elapsedSeconds: Double = 0

    var isActive: Bool {
        phase != .idle
    }

    mutating func begin(
        velocityPointsPerSecond velocity: Double,
        boundaryTranslationPoints: Double,
        metrics: ChartTimelineMotionMetrics = .standard
    ) -> Bool {
        cancel()
        let finiteVelocity = velocity.isFinite ? velocity : 0
        velocityPointsPerSecond = min(
            metrics.maximumInertialVelocityPointsPerSecond,
            max(
                -metrics.maximumInertialVelocityPointsPerSecond,
                finiteVelocity
            )
        )
        if boundaryTranslationPoints.isFinite,
           abs(boundaryTranslationPoints)
            > metrics.springSettlingDistancePoints {
            self.boundaryTranslationPoints = min(
                metrics.maximumBoundaryTranslationPoints,
                max(
                    -metrics.maximumBoundaryTranslationPoints,
                    boundaryTranslationPoints
                )
            )
            phase = .springing
            return true
        }
        guard abs(velocityPointsPerSecond)
                >= metrics.minimumInertialVelocityPointsPerSecond else {
            cancel()
            return false
        }
        phase = .decelerating
        return true
    }

    mutating func advance(
        from viewport: ChartTimelineViewport,
        deltaTimeSeconds: Double,
        plotWidthPoints: Double,
        totalSlotCount: Int,
        interactionMetrics: ChartInteractionMetrics = .standard,
        motionMetrics: ChartTimelineMotionMetrics = .standard
    ) -> ChartTimelineMotionStep {
        guard isActive,
              deltaTimeSeconds.isFinite,
              deltaTimeSeconds > 0 else {
            return ChartTimelineMotionStep(
                viewport: viewport,
                boundaryTranslationPoints:
                    boundaryTranslationPoints,
                isFinished: !isActive
            )
        }
        let deltaTime = min(
            motionMetrics.maximumTimeStepSeconds,
            deltaTimeSeconds
        )
        elapsedSeconds += deltaTime
        guard elapsedSeconds
                < motionMetrics.maximumMotionDurationSeconds else {
            cancel()
            return ChartTimelineMotionStep(
                viewport: viewport,
                boundaryTranslationPoints: 0,
                isFinished: true
            )
        }

        switch phase {
        case .idle:
            return ChartTimelineMotionStep(
                viewport: viewport,
                boundaryTranslationPoints: 0,
                isFinished: true
            )
        case .decelerating:
            let sample = viewport.pannedWithBoundaryResistance(
                translationPoints:
                    velocityPointsPerSecond * deltaTime,
                plotWidthPoints: plotWidthPoints,
                totalSlotCount: totalSlotCount,
                interactionMetrics: interactionMetrics,
                motionMetrics: motionMetrics
            )
            if sample.boundary != .none {
                phase = .springing
                boundaryTranslationPoints =
                    sample.boundaryTranslationPoints
                return ChartTimelineMotionStep(
                    viewport: sample.viewport,
                    boundaryTranslationPoints:
                        boundaryTranslationPoints,
                    isFinished: false
                )
            }
            velocityPointsPerSecond *= pow(
                motionMetrics.decelerationRatePerMillisecond,
                deltaTime * 1_000
            )
            if abs(velocityPointsPerSecond)
                < motionMetrics
                    .minimumInertialVelocityPointsPerSecond {
                cancel()
                return ChartTimelineMotionStep(
                    viewport: sample.viewport,
                    boundaryTranslationPoints: 0,
                    isFinished: true
                )
            }
            return ChartTimelineMotionStep(
                viewport: sample.viewport,
                boundaryTranslationPoints: 0,
                isFinished: false
            )
        case .springing:
            let omega = motionMetrics.springAngularFrequency
            let position = boundaryTranslationPoints
            let coefficient = velocityPointsPerSecond
                + omega * position
            let decay = exp(-omega * deltaTime)
            boundaryTranslationPoints = (
                position + coefficient * deltaTime
            ) * decay
            velocityPointsPerSecond = (
                velocityPointsPerSecond
                    - omega * coefficient * deltaTime
            ) * decay
            if abs(boundaryTranslationPoints)
                    <= motionMetrics.springSettlingDistancePoints,
               abs(velocityPointsPerSecond)
                    <= motionMetrics
                        .springSettlingVelocityPointsPerSecond {
                cancel()
                return ChartTimelineMotionStep(
                    viewport: viewport,
                    boundaryTranslationPoints: 0,
                    isFinished: true
                )
            }
            return ChartTimelineMotionStep(
                viewport: viewport,
                boundaryTranslationPoints:
                    boundaryTranslationPoints,
                isFinished: false
            )
        }
    }

    mutating func cancel() {
        phase = .idle
        velocityPointsPerSecond = 0
        boundaryTranslationPoints = 0
        elapsedSeconds = 0
    }
}

struct ChartTimelineInteractionTransform: Equatable, Sendable {
    static let identity = ChartTimelineInteractionTransform(
        translationPixels: 0,
        scaleX: 1
    )

    let translationPixels: Double
    let scaleX: Double

    var isIdentity: Bool {
        abs(translationPixels) <= 0.000_1
            && abs(scaleX - 1) <= 0.000_1
    }

    static func mapping(
        from baseline: ChartTimelineViewport,
        to current: ChartTimelineViewport,
        totalWidthPoints: Double,
        displayScale: Double,
        metrics: ChartInteractionMetrics = .standard
    ) -> ChartTimelineInteractionTransform {
        guard totalWidthPoints.isFinite,
              displayScale.isFinite,
              displayScale > 0,
              baseline.visibleSlotCount > 0,
              current.visibleSlotCount > 0 else {
            return .identity
        }
        let scale = baseline.visibleSlotCount
            / current.visibleSlotCount
        let slotDelta = current.visibleSlotCount
            - baseline.visibleSlotCount
            + current.trailingOffsetSlots
            - baseline.trailingOffsetSlots
        let plotLeft = metrics.plotLeftPixels(
            displayScale: displayScale
        )
        let plotWidth = metrics.plotWidthPixels(
            totalWidthPoints: totalWidthPoints,
            displayScale: displayScale
        )
        let translation = plotLeft * (1 - scale)
            + slotDelta * plotWidth
                / current.visibleSlotCount
        guard scale.isFinite,
              scale > 0,
              translation.isFinite else {
            return .identity
        }
        return ChartTimelineInteractionTransform(
            translationPixels: translation,
            scaleX: scale
        )
    }

    func baselineX(screenX: Double) -> Double? {
        guard screenX.isFinite,
              scaleX.isFinite,
              scaleX > 0,
              translationPixels.isFinite else {
            return nil
        }
        let value = (screenX - translationPixels) / scaleX
        return value.isFinite ? value : nil
    }

    func screenX(baselineX: Double) -> Double {
        baselineX * scaleX + translationPixels
    }
}

struct ChartTimelineViewport: Hashable, Sendable {
    private static let latestTolerance = 0.000_1

    let visibleSlotCount: Double
    let trailingOffsetSlots: Double

    init?(
        visibleSlotCount: Double,
        trailingOffsetSlots: Double
    ) {
        guard visibleSlotCount.isFinite,
              visibleSlotCount > 0,
              trailingOffsetSlots.isFinite,
              trailingOffsetSlots
                >= 0.5 - visibleSlotCount else {
            return nil
        }
        self.visibleSlotCount = visibleSlotCount
        self.trailingOffsetSlots = trailingOffsetSlots
    }

    var followsLatest: Bool {
        abs(trailingOffsetSlots) <= Self.latestTolerance
    }

    var containsLatestSlot: Bool {
        trailingOffsetSlots
            >= 0.5 - visibleSlotCount - Self.latestTolerance
            && trailingOffsetSlots
                <= 0.5 + Self.latestTolerance
    }

    static func latest(
        totalWidthPoints: Double,
        metrics: ChartInteractionMetrics = .standard
    ) -> ChartTimelineViewport {
        let defaultCount = metrics
            .plotWidth(totalWidthPoints: totalWidthPoints)
            / metrics.defaultPointsPerSlot
        return ChartTimelineViewport(
            validatedVisibleSlotCount: min(
                metrics.maximumVisibleSlotCount,
                max(metrics.minimumVisibleSlotCount, defaultCount)
            ),
            trailingOffsetSlots: 0
        )
    }

    func clamped(
        totalSlotCount: Int,
        metrics: ChartInteractionMetrics = .standard
    ) -> ChartTimelineViewport {
        let visible = min(
            metrics.maximumVisibleSlotCount,
            max(metrics.minimumVisibleSlotCount, visibleSlotCount)
        )
        let maximumOffset = max(
            0,
            Double(max(0, totalSlotCount)) - visible
        )
        let minimumOffset = metrics.minimumTrailingOffsetSlots(
            visibleSlotCount: visible
        )
        return ChartTimelineViewport(
            validatedVisibleSlotCount: visible,
            trailingOffsetSlots: min(
                maximumOffset,
                max(minimumOffset, trailingOffsetSlots)
            )
        )
    }

    func panned(
        translationPoints: Double,
        plotWidthPoints: Double,
        totalSlotCount: Int,
        metrics: ChartInteractionMetrics = .standard
    ) -> ChartTimelineViewport {
        guard translationPoints.isFinite,
              plotWidthPoints.isFinite,
              plotWidthPoints > 0 else {
            return clamped(
                totalSlotCount: totalSlotCount,
                metrics: metrics
            )
        }
        let slotWidth = plotWidthPoints / visibleSlotCount
        guard slotWidth.isFinite, slotWidth > 0 else {
            return self
        }
        return ChartTimelineViewport(
            validatedVisibleSlotCount: visibleSlotCount,
            trailingOffsetSlots:
                trailingOffsetSlots
                + translationPoints / slotWidth
        ).clamped(
            totalSlotCount: totalSlotCount,
            metrics: metrics
        )
    }

    func pannedWithBoundaryResistance(
        translationPoints: Double,
        plotWidthPoints: Double,
        totalSlotCount: Int,
        interactionMetrics: ChartInteractionMetrics = .standard,
        motionMetrics: ChartTimelineMotionMetrics = .standard
    ) -> ChartTimelinePanSample {
        let baseline = clamped(
            totalSlotCount: totalSlotCount,
            metrics: interactionMetrics
        )
        guard translationPoints.isFinite,
              plotWidthPoints.isFinite,
              plotWidthPoints > 0 else {
            return ChartTimelinePanSample(
                viewport: baseline,
                boundary: .none,
                boundaryTranslationPoints: 0
            )
        }
        let slotWidth = plotWidthPoints
            / baseline.visibleSlotCount
        guard slotWidth.isFinite, slotWidth > 0 else {
            return ChartTimelinePanSample(
                viewport: baseline,
                boundary: .none,
                boundaryTranslationPoints: 0
            )
        }
        let maximumOffset = max(
            0,
            Double(max(0, totalSlotCount))
                - baseline.visibleSlotCount
        )
        let minimumOffset = interactionMetrics
            .minimumTrailingOffsetSlots(
                visibleSlotCount: baseline.visibleSlotCount
            )
        let desiredOffset = baseline.trailingOffsetSlots
            + translationPoints / slotWidth
        let clampedOffset = min(
            maximumOffset,
            max(minimumOffset, desiredOffset)
        )
        let viewport = ChartTimelineViewport(
            validatedVisibleSlotCount:
                baseline.visibleSlotCount,
            trailingOffsetSlots: clampedOffset
        )
        let overflowPoints = (
            desiredOffset - clampedOffset
        ) * slotWidth
        let boundary: ChartTimelineBoundary
        if overflowPoints < 0 {
            boundary = .latest
        } else if overflowPoints > 0 {
            boundary = .oldest
        } else {
            boundary = .none
        }
        return ChartTimelinePanSample(
            viewport: viewport,
            boundary: boundary,
            boundaryTranslationPoints:
                motionMetrics.resistedBoundaryTranslation(
                    rawTranslationPoints: overflowPoints,
                    plotWidthPoints: plotWidthPoints
                )
        )
    }

    func pinched(
        scale: Double,
        anchorFraction: Double,
        totalSlotCount: Int,
        metrics: ChartInteractionMetrics = .standard
    ) -> ChartTimelineViewport {
        guard scale.isFinite,
              scale > 0,
              anchorFraction.isFinite else {
            return clamped(
                totalSlotCount: totalSlotCount,
                metrics: metrics
            )
        }
        let anchor = min(1, max(0, anchorFraction))
        let visible = min(
            metrics.maximumVisibleSlotCount,
            max(
                metrics.minimumVisibleSlotCount,
                visibleSlotCount / scale
            )
        )
        let anchoredOffset = trailingOffsetSlots
            + (visibleSlotCount - visible) * (1 - anchor)
        return ChartTimelineViewport(
            validatedVisibleSlotCount: visible,
            trailingOffsetSlots: anchoredOffset
        ).clamped(
            totalSlotCount: totalSlotCount,
            metrics: metrics
        )
    }

    func returningToLatest(
        totalSlotCount: Int,
        metrics: ChartInteractionMetrics = .standard
    ) -> ChartTimelineViewport {
        ChartTimelineViewport(
            validatedVisibleSlotCount: visibleSlotCount,
            trailingOffsetSlots: 0
        ).clamped(
            totalSlotCount: totalSlotCount,
            metrics: metrics
        )
    }

    func preservingVisibleContent(
        appendedSlotCount: Int,
        totalSlotCount: Int,
        metrics: ChartInteractionMetrics = .standard
    ) -> ChartTimelineViewport {
        guard !followsLatest, appendedSlotCount > 0 else {
            return clamped(
                totalSlotCount: totalSlotCount,
                metrics: metrics
            )
        }
        return ChartTimelineViewport(
            validatedVisibleSlotCount: visibleSlotCount,
            trailingOffsetSlots:
                trailingOffsetSlots + Double(appendedSlotCount)
        ).clamped(
            totalSlotCount: totalSlotCount,
            metrics: metrics
        )
    }

    func isRenderable(
        from baseline: ChartTimelineViewport,
        guardBandSlotCount: Int
    ) -> Bool {
        guard guardBandSlotCount >= 0 else {
            return false
        }
        let guardSlots = Double(guardBandSlotCount)
        let baselineLower = -baseline.visibleSlotCount
            + 0.5
            - baseline.trailingOffsetSlots
            - guardSlots
        let baselineUpper = 0.5
            - baseline.trailingOffsetSlots
            + guardSlots
        let currentLower = -visibleSlotCount
            + 0.5
            - trailingOffsetSlots
        let currentUpper = 0.5 - trailingOffsetSlots
        let tolerance = 0.000_1
        return currentLower >= baselineLower - tolerance
            && currentUpper <= baselineUpper + tolerance
    }

    private init(
        validatedVisibleSlotCount: Double,
        trailingOffsetSlots: Double
    ) {
        visibleSlotCount = validatedVisibleSlotCount
        self.trailingOffsetSlots = trailingOffsetSlots
    }
}

enum ChartPanOwnership: Equatable {
    case chart
    case parentScrollView
    case systemNavigation
}

enum ChartPanDirectionResolver {
    static func ownership(
        velocityX: Double,
        velocityY: Double,
        initialX: Double,
        metrics: ChartInteractionMetrics = .standard
    ) -> ChartPanOwnership {
        guard velocityX.isFinite,
              velocityY.isFinite,
              initialX.isFinite else {
            return .parentScrollView
        }
        if initialX <= metrics.systemNavigationEdgeWidthPoints {
            return .systemNavigation
        }
        return abs(velocityX)
            > abs(velocityY) * metrics.directionLockRatio
            ? .chart
            : .parentScrollView
    }
}

struct ChartInteractionStateMachine: Equatable {
    enum State: Equatable {
        case idle
        case panningTimeline
        case pinchingTimeline
        case trackingCrosshair
    }

    private(set) var state: State = .idle

    mutating func beginPan() -> Bool {
        guard state == .idle else {
            return false
        }
        state = .panningTimeline
        return true
    }

    mutating func beginPinch() -> Bool {
        guard state == .idle else {
            return false
        }
        state = .pinchingTimeline
        return true
    }

    mutating func beginCrosshair() -> Bool {
        guard state == .idle else {
            return false
        }
        state = .trackingCrosshair
        return true
    }

    mutating func finishInteraction() {
        state = .idle
    }
}
