import CoreGraphics
import Foundation

struct ChartGlyphAtlasKey: Hashable, Sendable {
    let fontName: String
    let pointSize: Double
    let displayScale: Double
    let localeIdentifier: String

    init?(
        fontName: String,
        pointSize: Double,
        displayScale: Double,
        localeIdentifier: String
    ) {
        guard !fontName.isEmpty,
              pointSize.isFinite,
              pointSize > 0,
              displayScale.isFinite,
              (1...4).contains(displayScale),
              !localeIdentifier.isEmpty else {
            return nil
        }
        self.fontName = fontName
        self.pointSize = pointSize
        self.displayScale = displayScale
        self.localeIdentifier = localeIdentifier
    }
}

struct ChartGlyphKey: Hashable, Sendable {
    let fontName: String
    let glyph: CGGlyph
}

struct ChartGlyphAtlasEntry: Equatable, Sendable {
    let key: ChartGlyphKey
    let pixelRect: CGRect
    let fontBounds: CGRect
    let advance: CGSize
    let uvLeft: Float
    let uvTop: Float
    let uvRight: Float
    let uvBottom: Float
}

final class ChartGlyphAtlasSnapshot: @unchecked Sendable {
    let revision: UInt64
    let key: ChartGlyphAtlasKey
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: Data
    let entries: [ChartGlyphKey: ChartGlyphAtlasEntry]
    let fallbackKey: ChartGlyphKey

    init(
        revision: UInt64,
        key: ChartGlyphAtlasKey,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixels: Data,
        entries: [ChartGlyphKey: ChartGlyphAtlasEntry],
        fallbackKey: ChartGlyphKey
    ) {
        self.revision = revision
        self.key = key
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
        self.entries = entries
        self.fallbackKey = fallbackKey
    }
}

struct ChartGlyphInstance: Equatable, Sendable {
    let left: Float
    let top: Float
    let right: Float
    let bottom: Float
    let uvLeft: Float
    let uvTop: Float
    let uvRight: Float
    let uvBottom: Float
    let color: ChartColor
    let timelineAnchorX: Float?

    init(
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        uvLeft: Float,
        uvTop: Float,
        uvRight: Float,
        uvBottom: Float,
        color: ChartColor,
        timelineAnchorX: Float? = nil
    ) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.uvLeft = uvLeft
        self.uvTop = uvTop
        self.uvRight = uvRight
        self.uvBottom = uvBottom
        self.color = color
        self.timelineAnchorX = timelineAnchorX
    }

    var isValid: Bool {
        [
            left,
            top,
            right,
            bottom,
            uvLeft,
            uvTop,
            uvRight,
            uvBottom,
        ].allSatisfy(\.isFinite)
            && right >= left
            && bottom >= top
            && (timelineAnchorX?.isFinite ?? true)
            && (0...1).contains(uvLeft)
            && (0...1).contains(uvTop)
            && (0...1).contains(uvRight)
            && (0...1).contains(uvBottom)
    }
}

enum ChartGlyphRowLayout {
    /// Fit the complete row, including atlas padding, without dropping values.
    static func fitting(
        _ glyphs: [ChartGlyphInstance],
        left: Float,
        right: Float,
        baseline: Float
    ) -> [ChartGlyphInstance] {
        guard let first = glyphs.map(\.left).min(),
              let last = glyphs.map(\.right).max(),
              right > left else { return [] }
        let origin = min(left, first)
        let scale = min(1, (right - left) / max(1, last - origin))
        return glyphs.map { glyph in
            ChartGlyphInstance(
                left: left + (glyph.left - origin) * scale,
                top: baseline + (glyph.top - baseline) * scale,
                right: left + (glyph.right - origin) * scale,
                bottom: baseline + (glyph.bottom - baseline) * scale,
                uvLeft: glyph.uvLeft, uvTop: glyph.uvTop,
                uvRight: glyph.uvRight, uvBottom: glyph.uvBottom,
                color: glyph.color, timelineAnchorX: glyph.timelineAnchorX
            )
        }
    }
}
