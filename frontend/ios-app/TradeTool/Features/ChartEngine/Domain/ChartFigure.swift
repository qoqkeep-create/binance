import Foundation

enum ChartAppearance: Hashable, Sendable {
    case light
    case dark
}

struct ChartBarKey: Hashable, Sendable {
    let stream: ChartStreamKey
    let openTime: Int64
}

struct ChartBarSlot: Hashable, Sendable {
    let key: ChartBarKey
    let ordinal: Int64
}

enum ChartFigurePrimitive: String, Sendable {
    case candle
    case polyline
    case bar
    case text
}

struct ChartFigureDefinition: Hashable, Sendable {
    let id: String
    let primitive: ChartFigurePrimitive
    let panelID: String
    let zIndex: Int
    let visualLineWidth: Float
    let hitSlop: Float

    init?(
        id: String,
        primitive: ChartFigurePrimitive,
        panelID: String,
        zIndex: Int,
        visualLineWidth: Float,
        hitSlop: Float
    ) {
        guard !id.isEmpty,
              !panelID.isEmpty,
              visualLineWidth.isFinite,
              visualLineWidth >= 0,
              hitSlop.isFinite,
              hitSlop >= visualLineWidth / 2 else {
            return nil
        }
        self.id = id
        self.primitive = primitive
        self.panelID = panelID
        self.zIndex = zIndex
        self.visualLineWidth = visualLineWidth
        self.hitSlop = hitSlop
    }
}

struct ChartColor: Equatable, Sendable {
    let red: Float
    let green: Float
    let blue: Float
    let alpha: Float

    init?(
        red: Float,
        green: Float,
        blue: Float,
        alpha: Float = 1
    ) {
        let components = [red, green, blue, alpha]
        guard components.allSatisfy({
            $0.isFinite && (0...1).contains($0)
        }) else {
            return nil
        }
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    private init(
        uncheckedRed red: Float,
        green: Float,
        blue: Float,
        alpha: Float = 1
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var linearRGBA: SIMD4<Float> {
        SIMD4(
            Self.linearizedSRGBComponent(red),
            Self.linearizedSRGBComponent(green),
            Self.linearizedSRGBComponent(blue),
            alpha
        )
    }

    func withAlpha(_ alpha: Float) -> ChartColor {
        ChartColor(
            uncheckedRed: red,
            green: green,
            blue: blue,
            alpha: min(1, max(0, alpha))
        )
    }

    /// Resolve semantic scene colors at encoding time so theme changes can
    /// reuse history, geometry and glyph atlases without rebuilding the scene.
    func resolved(for appearance: ChartAppearance) -> ChartColor {
        guard appearance == .light else { return self }
        let opaque = withAlpha(1)
        let color: ChartColor = switch opaque {
        case Self.chartBackground: Self.rgb(0xFFFFFF)
        case Self.primaryText: Self.rgb(0x181A20)
        case Self.neutral: Self.rgb(0x707A8A)
        case Self.grid: Self.rgb(0xEAECEF)
        case Self.positive: Self.rgb(0x2EBD85)
        case Self.negative: Self.rgb(0xF6465D)
        case Self.crosshairLabelBackground.withAlpha(1): Self.rgb(0xF5F5F5)
        case Self.crosshairLabelBorder.withAlpha(1): Self.rgb(0xD8DCE1)
        case Self.crosshairAxisLabelBackground: Self.rgb(0x181A20)
        case Self.crosshairAxisLabelText: Self.rgb(0xFFFFFF)
        case Self.ema21: Self.rgb(0x9C7400)
        default: self
        }
        return color.withAlpha(alpha)
    }

    private static func rgb(_ hex: UInt32) -> ChartColor {
        ChartColor(
            uncheckedRed: Float((hex >> 16) & 0xFF) / 255,
            green: Float((hex >> 8) & 0xFF) / 255,
            blue: Float(hex & 0xFF) / 255
        )
    }

    private static func linearizedSRGBComponent(
        _ component: Float
    ) -> Float {
        if component <= 0.04045 {
            return component / 12.92
        }
        return Float(pow(
            Double((component + 0.055) / 1.055),
            2.4
        ))
    }

    static let positive = ChartColor(
        uncheckedRed: 0.156_863,
        green: 0.643_137,
        blue: 0.450_980
    )
    static let negative = ChartColor(
        uncheckedRed: 0.964_706,
        green: 0.235_294,
        blue: 0.333_333
    )
    static let neutral = ChartColor(
        uncheckedRed: 0.6078,
        green: 0.6078,
        blue: 0.6667
    )
    static let grid = rgb(0x333B47)
    static let primaryText = ChartColor(
        uncheckedRed: 0.9412,
        green: 0.9412,
        blue: 0.9569
    )
    static let chartBackground = rgb(0x212731)
    static let latestPriceLine = primaryText.withAlpha(0.72)
    static let latestPriceMarkerBackground = chartBackground.withAlpha(0.92)
    static let crosshair = ChartColor(
        uncheckedRed: 0.6078,
        green: 0.6078,
        blue: 0.6667,
        alpha: 0.82
    )
    static let crosshairLabelBackground = ChartColor(
        uncheckedRed: 0.1569,
        green: 0.1569,
        blue: 0.1765,
        alpha: 0.96
    )
    static let crosshairLabelBorder = ChartColor(
        uncheckedRed: 0.3137,
        green: 0.3216,
        blue: 0.3451,
        alpha: 0.9
    )
    static let crosshairAxisLabelBackground = ChartColor(
        uncheckedRed: 0.9569,
        green: 0.9569,
        blue: 0.9686
    )
    static let crosshairAxisLabelText = ChartColor(
        uncheckedRed: 0.0863,
        green: 0.0902,
        blue: 0.102
    )
    // Sampled from the user's Display P3 screenshot after conversion to sRGB.
    static let emaShort = rgb(0x2DBD85)
    static let emaMedium = rgb(0x3860F6)
    static let emaLong = rgb(0x71269C)

    static let ema21 = ChartColor(
        uncheckedRed: 0.9412,
        green: 0.7255,
        blue: 0.0431
    )
    static let ema55 = ChartColor(
        uncheckedRed: 0.909_804,
        green: 0.250_980,
        blue: 0.709_804
    )
    static let ema144 = ChartColor(
        uncheckedRed: 0.545_098,
        green: 0.407_843,
        blue: 0.768_627
    )
    static let orange = ChartColor(
        uncheckedRed: 0.941_176,
        green: 0.384_314,
        blue: 0.235_294
    )
}
