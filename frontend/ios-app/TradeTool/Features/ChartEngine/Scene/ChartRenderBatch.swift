import Foundation

enum ChartBatchCoordinateSpace: Equatable, Sendable {
    case fixed
    case latestPrice
    case latestPriceTimelineLine
    case timeline
}

enum ChartBatchInteractionVisibility: Equatable, Sendable {
    case always
    case hiddenWhileCrosshairIsActive
}

struct ChartCandleInstance: Equatable, Sendable {
    var x: Float
    var openY: Float
    var highY: Float
    var lowY: Float
    var closeY: Float
    var halfBodyWidth: Float
    var isRising: Bool

    var isValid: Bool {
        [
            x,
            openY,
            highY,
            lowY,
            closeY,
            halfBodyWidth,
        ].allSatisfy(\.isFinite)
            && halfBodyWidth >= 0
    }
}

struct ChartPolylinePoint: Equatable, Sendable {
    var x: Float
    var y: Float
}

struct ChartLineSegmentInstance: Equatable, Sendable {
    let start: ChartPolylinePoint
    let end: ChartPolylinePoint
    let width: Float
    let dashLength: Float
    let gapLength: Float
    let dashPhase: Float
    let color: ChartColor
    let antialias: Bool

    init(
        start: ChartPolylinePoint,
        end: ChartPolylinePoint,
        width: Float,
        dashLength: Float,
        gapLength: Float,
        dashPhase: Float,
        color: ChartColor,
        antialias: Bool = false
    ) {
        self.start = start
        self.end = end
        self.width = width
        self.dashLength = dashLength
        self.gapLength = gapLength
        self.dashPhase = dashPhase
        self.color = color
        self.antialias = antialias
    }

    var isValid: Bool {
        let values = [
            start.x,
            start.y,
            end.x,
            end.y,
            width,
            dashLength,
            gapLength,
            dashPhase,
        ]
        return values.allSatisfy(\.isFinite)
            && width > 0
            && dashLength >= 0
            && gapLength >= 0
    }
}

struct ChartBarInstance: Equatable, Sendable {
    let left: Float
    let top: Float
    let right: Float
    let bottom: Float
    let color: ChartColor
    let cornerRadius: Float

    init(
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        color: ChartColor,
        cornerRadius: Float = 0
    ) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.color = color
        self.cornerRadius = cornerRadius
    }

    var isValid: Bool {
        [left, top, right, bottom, cornerRadius]
            .allSatisfy(\.isFinite)
            && right >= left
            && bottom >= top
            && cornerRadius >= 0
    }
}

final class ChartRenderBatchStorage: @unchecked Sendable {
    let candleInstances: [ChartCandleInstance]
    let lineSegments: [ChartLineSegmentInstance]
    let barInstances: [ChartBarInstance]
    let glyphInstances: [ChartGlyphInstance]
    let glyphAtlas: ChartGlyphAtlasSnapshot?

    init(
        candleInstances: [ChartCandleInstance] = [],
        lineSegments: [ChartLineSegmentInstance] = [],
        barInstances: [ChartBarInstance] = [],
        glyphInstances: [ChartGlyphInstance] = [],
        glyphAtlas: ChartGlyphAtlasSnapshot? = nil
    ) {
        self.candleInstances = candleInstances.filter(\.isValid)
        self.lineSegments = lineSegments.filter(\.isValid)
        self.barInstances = barInstances.filter(\.isValid)
        self.glyphInstances = glyphInstances.filter(\.isValid)
        self.glyphAtlas = glyphAtlas
    }
}

struct ChartRenderBatch: Sendable {
    let storage: ChartRenderBatchStorage
    let coordinateSpace: ChartBatchCoordinateSpace
    let interactionVisibility: ChartBatchInteractionVisibility

    init(
        candleInstances: [ChartCandleInstance] = [],
        lineSegments: [ChartLineSegmentInstance] = [],
        barInstances: [ChartBarInstance] = [],
        glyphInstances: [ChartGlyphInstance] = [],
        glyphAtlas: ChartGlyphAtlasSnapshot? = nil,
        coordinateSpace: ChartBatchCoordinateSpace = .timeline,
        interactionVisibility: ChartBatchInteractionVisibility = .always
    ) {
        storage = ChartRenderBatchStorage(
            candleInstances: candleInstances,
            lineSegments: lineSegments,
            barInstances: barInstances,
            glyphInstances: glyphInstances,
            glyphAtlas: glyphAtlas
        )
        self.coordinateSpace = coordinateSpace
        self.interactionVisibility = interactionVisibility
    }
}

enum ChartBatchCompiler {
    static func lineSegments(
        spans: [[ChartPolylinePoint]],
        width: Float,
        dashLength: Float = 0,
        gapLength: Float = 0,
        dashPhase: Float = 0,
        color: ChartColor,
        antialias: Bool = false
    ) -> [ChartLineSegmentInstance] {
        guard width.isFinite,
              width > 0,
              dashLength.isFinite,
              dashLength >= 0,
              gapLength.isFinite,
              gapLength >= 0,
              dashPhase.isFinite else {
            return []
        }

        var result: [ChartLineSegmentInstance] = []
        result.reserveCapacity(
            spans.reduce(into: 0) {
                $0 += max(0, $1.count - 1)
            }
        )

        for span in spans where span.count > 1 {
            for index in 1..<span.count {
                let segment = ChartLineSegmentInstance(
                    start: span[index - 1],
                    end: span[index],
                    width: width,
                    dashLength: dashLength,
                    gapLength: gapLength,
                    dashPhase: dashPhase,
                    color: color,
                    antialias: antialias
                )
                if segment.isValid {
                    result.append(segment)
                }
            }
        }
        return result
    }
}
