import CoreGraphics
import CoreText
import Foundation

private func chartRunFont(
    _ run: CTRun,
    fallback: CTFont
) -> CTFont {
    let attributes = CTRunGetAttributes(run) as NSDictionary
    guard let candidate = attributes[kCTFontAttributeName] else {
        return fallback
    }
    let coreFoundationCandidate = candidate as CFTypeRef
    guard CFGetTypeID(coreFoundationCandidate)
        == CTFontGetTypeID() else {
        return fallback
    }
    return unsafeBitCast(
        coreFoundationCandidate,
        to: CTFont.self
    )
}

enum MetalGlyphAtlasError: Error {
    case invalidLimits
    case noGlyphs
    case capacityExceeded
    case bitmapContextUnavailable
}

struct MetalGlyphAtlasLimits: Equatable, Sendable {
    let maximumDimension: Int
    let maximumGlyphCount: Int
    let maximumBytes: Int
    let padding: Int

    init(
        maximumDimension: Int = 1_024,
        maximumGlyphCount: Int = 512,
        maximumBytes: Int = 1_048_576,
        padding: Int = 2
    ) {
        self.maximumDimension = maximumDimension
        self.maximumGlyphCount = maximumGlyphCount
        self.maximumBytes = maximumBytes
        self.padding = padding
    }

    var isValid: Bool {
        maximumDimension > 0
            && maximumDimension <= 8_192
            && maximumGlyphCount > 0
            && maximumGlyphCount <= 8_192
            && maximumBytes > 0
            && maximumBytes <= 67_108_864
            && padding >= 1
            && padding <= 16
    }
}

struct ChartTextLayoutResult: Sendable {
    let instances: [ChartGlyphInstance]
    let advance: Double
    let ascent: Double
    let descent: Double
    let missingGlyphCount: Int
}

final class MetalGlyphAtlasBuilder: @unchecked Sendable {
    private struct GlyphRecord {
        let key: ChartGlyphKey
        let font: CTFont
        let bounds: CGRect
        let advance: CGSize
        let cellWidth: Int
        let cellHeight: Int
    }

    private struct Placement {
        let x: Int
        let y: Int
    }

    private let limits: MetalGlyphAtlasLimits
    private let lock = NSLock()
    private var nextRevision: UInt64 = 1

    init(limits: MetalGlyphAtlasLimits = MetalGlyphAtlasLimits()) {
        self.limits = limits
    }

    func build(
        key: ChartGlyphAtlasKey,
        seedStrings: [String]
    ) throws -> ChartGlyphAtlasSnapshot {
        guard limits.isValid else {
            throw MetalGlyphAtlasError.invalidLimits
        }

        let font = makeFont(key: key)
        let fallback = firstGlyph(
            in: "□",
            font: font
        ) ?? firstGlyph(in: "?", font: font)

        var glyphFonts = collectGlyphs(
            strings: seedStrings + ["□", "?"],
            font: font
        )
        let fallbackKey: ChartGlyphKey
        if let fallback {
            fallbackKey = fallback.key
            glyphFonts[fallback.key] = fallback.font
        } else {
            fallbackKey = ChartGlyphKey(
                fontName: CTFontCopyPostScriptName(font) as String,
                glyph: 0
            )
            glyphFonts[fallbackKey] = font
        }
        guard !glyphFonts.isEmpty else {
            throw MetalGlyphAtlasError.noGlyphs
        }
        guard glyphFonts.count <= limits.maximumGlyphCount else {
            throw MetalGlyphAtlasError.capacityExceeded
        }

        let sortedKeys = glyphFonts.keys.sorted {
            if $0.fontName == $1.fontName {
                return $0.glyph < $1.glyph
            }
            return $0.fontName < $1.fontName
        }
        var records: [GlyphRecord] = []
        records.reserveCapacity(sortedKeys.count)
        for glyphKey in sortedKeys {
            if let glyphFont = glyphFonts[glyphKey] {
                records.append(
                    makeRecord(
                        key: glyphKey,
                        font: glyphFont
                    )
                )
            }
        }
        guard let packed = pack(records: records) else {
            throw MetalGlyphAtlasError.capacityExceeded
        }

        let width = packed.width
        let height = packed.height
        let (byteCount, overflow) = width.multipliedReportingOverflow(
            by: height
        )
        guard !overflow,
              byteCount <= limits.maximumBytes else {
            throw MetalGlyphAtlasError.capacityExceeded
        }

        var pixels = Data(count: byteCount)
        let rendered = pixels.withUnsafeMutableBytes { rawBuffer in
            let colorSpace = CGColorSpaceCreateDeviceGray()
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }

            context.setShouldAntialias(true)
            context.setAllowsAntialiasing(true)
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSmoothing(false)
            context.setFillColor(gray: 1, alpha: 1)

            for record in records {
                guard let placement = packed.placements[record.key] else {
                    continue
                }
                var glyph = record.key.glyph
                var position = CGPoint(
                    x: CGFloat(placement.x + limits.padding)
                        - record.bounds.minX,
                    y: CGFloat(placement.y + limits.padding)
                        - record.bounds.minY
                )
                CTFontDrawGlyphs(
                    record.font,
                    &glyph,
                    &position,
                    1,
                    context
                )
            }
            return true
        }
        guard rendered else {
            throw MetalGlyphAtlasError.bitmapContextUnavailable
        }

        var entries: [ChartGlyphKey: ChartGlyphAtlasEntry] = [:]
        entries.reserveCapacity(records.count)
        for record in records {
            guard let placement = packed.placements[record.key] else {
                continue
            }
            let rect = CGRect(
                x: placement.x,
                y: placement.y,
                width: record.cellWidth,
                height: record.cellHeight
            )
            let uvLeft = Float(rect.minX) / Float(width)
            let uvTop = 1 - Float(rect.maxY) / Float(height)
            let uvRight = Float(rect.maxX) / Float(width)
            let uvBottom = 1 - Float(rect.minY) / Float(height)
            let entry = ChartGlyphAtlasEntry(
                key: record.key,
                pixelRect: rect,
                fontBounds: record.bounds,
                advance: record.advance,
                uvLeft: uvLeft,
                uvTop: uvTop,
                uvRight: uvRight,
                uvBottom: uvBottom
            )
            entries[record.key] = entry
        }

        return ChartGlyphAtlasSnapshot(
            revision: consumeRevision(),
            key: key,
            width: width,
            height: height,
            bytesPerRow: width,
            pixels: pixels,
            entries: entries,
            fallbackKey: fallbackKey
        )
    }

    private func makeFont(key: ChartGlyphAtlasKey) -> CTFont {
        CTFontCreateWithName(
            key.fontName as CFString,
            CGFloat(key.pointSize * key.displayScale),
            nil
        )
    }

    private func collectGlyphs(
        strings: [String],
        font: CTFont
    ) -> [ChartGlyphKey: CTFont] {
        var result: [ChartGlyphKey: CTFont] = [:]
        for string in strings where !string.isEmpty {
            let line = makeLine(text: string, font: font)
            let runs = CTLineGetGlyphRuns(line) as NSArray
            for case let run as CTRun in runs {
                let runFont = chartRunFont(run, fallback: font)
                let fontName = CTFontCopyPostScriptName(
                    runFont
                ) as String
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else {
                    continue
                }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                glyphs.withUnsafeMutableBufferPointer { pointer in
                    guard let baseAddress = pointer.baseAddress else {
                        return
                    }
                    CTRunGetGlyphs(
                        run,
                        CFRange(location: 0, length: 0),
                        baseAddress
                    )
                }
                for glyph in glyphs {
                    result[
                        ChartGlyphKey(
                            fontName: fontName,
                            glyph: glyph
                        )
                    ] = runFont
                }
            }
        }
        return result
    }

    private func firstGlyph(
        in string: String,
        font: CTFont
    ) -> (key: ChartGlyphKey, font: CTFont)? {
        let glyphFonts = collectGlyphs(
            strings: [string],
            font: font
        )
        let first = glyphFonts.sorted {
            if $0.key.fontName == $1.key.fontName {
                return $0.key.glyph < $1.key.glyph
            }
            return $0.key.fontName < $1.key.fontName
        }.first
        guard let first else {
            return nil
        }
        return (first.key, first.value)
    }

    private func makeLine(
        text: String,
        font: CTFont
    ) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: attributes
            )
        )
    }

    private func makeRecord(
        key: ChartGlyphKey,
        font: CTFont
    ) -> GlyphRecord {
        var glyph = key.glyph
        var bounds = CGRect.zero
        var advance = CGSize.zero
        CTFontGetBoundingRectsForGlyphs(
            font,
            .default,
            &glyph,
            &bounds,
            1
        )
        CTFontGetAdvancesForGlyphs(
            font,
            .default,
            &glyph,
            &advance,
            1
        )

        let cellWidth = max(
            1,
            Int(ceil(bounds.width)) + limits.padding * 2
        )
        let cellHeight = max(
            1,
            Int(ceil(bounds.height)) + limits.padding * 2
        )
        return GlyphRecord(
            key: key,
            font: font,
            bounds: bounds,
            advance: advance,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )
    }

    private func pack(
        records: [GlyphRecord]
    ) -> (
        width: Int,
        height: Int,
        placements: [ChartGlyphKey: Placement]
    )? {
        let largestCell = records.reduce(1) {
            max($0, $1.cellWidth)
        }
        var width = nextPowerOfTwo(max(64, largestCell))

        while width <= limits.maximumDimension {
            var placements: [ChartGlyphKey: Placement] = [:]
            var x = 0
            var y = 0
            var rowHeight = 0

            for record in records {
                if x > 0, x + record.cellWidth > width {
                    x = 0
                    y += rowHeight
                    rowHeight = 0
                }
                guard record.cellWidth <= width,
                      y + record.cellHeight
                        <= limits.maximumDimension else {
                    placements.removeAll()
                    break
                }
                placements[record.key] = Placement(x: x, y: y)
                x += record.cellWidth
                rowHeight = max(rowHeight, record.cellHeight)
            }

            if placements.count == records.count {
                let usedHeight = max(1, y + rowHeight)
                let height = nextPowerOfTwo(usedHeight)
                if height <= limits.maximumDimension {
                    return (width, height, placements)
                }
            }
            width *= 2
        }
        return nil
    }

    private func nextPowerOfTwo(_ value: Int) -> Int {
        guard value > 1 else {
            return 1
        }
        var result = 1
        while result < value,
              result <= limits.maximumDimension {
            result *= 2
        }
        return result
    }

    private func consumeRevision() -> UInt64 {
        lock.lock()
        defer {
            lock.unlock()
        }
        let revision = nextRevision
        nextRevision &+= 1
        return revision
    }
}

enum MetalTextLayouter {
    static func layout(
        text: String,
        atlas: ChartGlyphAtlasSnapshot,
        originX: Double,
        baselineY: Double,
        color: ChartColor
    ) -> ChartTextLayoutResult {
        let font = CTFontCreateWithName(
            atlas.key.fontName as CFString,
            CGFloat(
                atlas.key.pointSize * atlas.key.displayScale
            ),
            nil
        )
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: attributes
            )
        )

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(
            line,
            &ascent,
            &descent,
            &leading
        )

        var instances: [ChartGlyphInstance] = []
        var missingGlyphCount = 0
        let runs = CTLineGetGlyphRuns(line) as NSArray
        for case let run as CTRun in runs {
            let runFont = chartRunFont(run, fallback: font)
            let runFontName = CTFontCopyPostScriptName(
                runFont
            ) as String
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else {
                continue
            }

            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            glyphs.withUnsafeMutableBufferPointer { glyphPointer in
                positions.withUnsafeMutableBufferPointer {
                    positionPointer in
                    guard let glyphBase = glyphPointer.baseAddress,
                          let positionBase =
                            positionPointer.baseAddress else {
                        return
                    }
                    CTRunGetGlyphs(
                        run,
                        CFRange(location: 0, length: 0),
                        glyphBase
                    )
                    CTRunGetPositions(
                        run,
                        CFRange(location: 0, length: 0),
                        positionBase
                    )
                }
            }

            for index in 0..<count {
                let requestedGlyph = glyphs[index]
                let requestedKey = ChartGlyphKey(
                    fontName: runFontName,
                    glyph: requestedGlyph
                )
                let entry: ChartGlyphAtlasEntry?
                if let requested = atlas.entries[requestedKey] {
                    entry = requested
                } else {
                    entry = atlas.entries[atlas.fallbackKey]
                    missingGlyphCount += 1
                }
                guard let entry,
                      !entry.fontBounds.isEmpty else {
                    continue
                }

                let horizontalPadding = (
                    entry.pixelRect.width
                        - ceil(entry.fontBounds.width)
                ) / 2
                let verticalPadding = (
                    entry.pixelRect.height
                        - ceil(entry.fontBounds.height)
                ) / 2
                let position = positions[index]
                let left = originX
                    + position.x
                    + entry.fontBounds.minX
                    - horizontalPadding
                let top = baselineY
                    - position.y
                    - entry.fontBounds.maxY
                    - verticalPadding
                let right = left + entry.pixelRect.width
                let bottom = top + entry.pixelRect.height
                let values = [left, top, right, bottom]
                guard values.allSatisfy(\.isFinite),
                      values.allSatisfy({
                          abs($0)
                              <= Double(Float.greatestFiniteMagnitude)
                      }) else {
                    continue
                }

                instances.append(
                    ChartGlyphInstance(
                        left: Float(left),
                        top: Float(top),
                        right: Float(right),
                        bottom: Float(bottom),
                        uvLeft: entry.uvLeft,
                        uvTop: entry.uvTop,
                        uvRight: entry.uvRight,
                        uvBottom: entry.uvBottom,
                        color: color
                    )
                )
            }
        }

        return ChartTextLayoutResult(
            instances: instances,
            advance: advance,
            ascent: ascent,
            descent: descent,
            missingGlyphCount: missingGlyphCount
        )
    }
}
