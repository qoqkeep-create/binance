import Metal
import SwiftUI
import UIKit
import XCTest
@testable import TradeTool

final class AppearanceTests: XCTestCase {
    @MainActor
    func testAppearanceDefaultsToLightAndRestoresSavedSelection() throws {
        let suite = "AppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = AppStorage(
            wrappedValue: AppAppearance.defaultValue,
            AppAppearance.storageKey,
            store: defaults
        )
        XCTAssertEqual(selection.wrappedValue, .light)
        selection.wrappedValue = .dark
        let restored = AppStorage(
            wrappedValue: AppAppearance.defaultValue,
            AppAppearance.storageKey,
            store: defaults
        )
        XCTAssertEqual(restored.wrappedValue, .dark)
        selection.wrappedValue = .light
        XCTAssertEqual(defaults.string(forKey: AppAppearance.storageKey), "light")
    }

    @MainActor
    func testSemanticTextHasContrastInBothAppearances() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let background = resolved(BinanceTheme.background, style: style)
            for token in [BinanceTheme.primaryText, BinanceTheme.secondaryText,
                          BinanceTheme.accentText, BinanceTheme.positive,
                          BinanceTheme.negative] {
                XCTAssertGreaterThanOrEqual(
                    contrast(resolved(token, style: style), background), 4.5
                )
            }
            for token in [BinanceTheme.positive, BinanceTheme.negative, BinanceTheme.accentText] {
                XCTAssertGreaterThanOrEqual(
                    contrast(resolved(BinanceTheme.onColor, style: style),
                             resolved(token, style: style)), 4.5
                )
            }
            XCTAssertGreaterThanOrEqual(
                contrast(resolved(BinanceTheme.onAccent, style: style),
                         resolved(BinanceTheme.accent, style: style)), 4.5
            )
        }
    }

    func testChartResolutionPreservesOpacityAndCustomIndicatorColors() throws {
        let transparent = ChartColor.primaryText.withAlpha(0.37)
        XCTAssertEqual(transparent.resolved(for: .dark), transparent)
        XCTAssertEqual(transparent.resolved(for: .light).alpha, 0.37)
        XCTAssertLessThan(transparent.resolved(for: .light).red, 0.2)
        let custom = try XCTUnwrap(ChartColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 0.6))
        XCTAssertEqual(custom.resolved(for: .light), custom)
        XCTAssertEqual(ChartColor.ema55.resolved(for: .light), .ema55)
        XCTAssertEqual(ChartColor.ema144.resolved(for: .light), .ema144)
    }

    func testChartAxisLabelsKeepOppositeTextAndBackground() {
        for appearance in [ChartAppearance.light, .dark] {
            let text = ChartColor.crosshairAxisLabelText.resolved(for: appearance)
            let background = ChartColor.crosshairAxisLabelBackground.resolved(for: appearance)
            XCTAssertGreaterThan(abs(text.red - background.red), 0.8)
            XCTAssertNotEqual(ChartColor.grid.resolved(for: appearance),
                              ChartColor.chartBackground.resolved(for: appearance))
        }
    }

    func testChangingAppearanceSharesSnapshotsAndKeepsRevisionAndTiming() {
        let state = scene()
        let light = state.withAppearance(.light)
        XCTAssertEqual(light.appearance, .light)
        XCTAssertTrue(light.staticScene === state.staticScene)
        XCTAssertTrue(light.liveTail === state.liveTail)
        XCTAssertTrue(light.interaction === state.interaction)
        XCTAssertEqual(light.revision, state.revision)
        XCTAssertEqual(light.readyTime, state.readyTime)
    }

    @MainActor
    func testMetalRendersBothThemesForTheSameSceneRevision() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let renderer = try MetalRenderer(device: device, pixelFormat: .bgra8Unorm_srgb)
        let state = scene()
        let dark = try XCTUnwrap(renderer.renderOffscreen(state: state, width: 16, height: 16))
        let light = try XCTUnwrap(renderer.renderOffscreen(
            state: state.withAppearance(.light), width: 16, height: 16
        ))
        for (rendered, style) in [(dark, UIUserInterfaceStyle.dark), (light, .light)] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            resolved(BinanceTheme.background, style: style).getRed(
                &red, green: &green, blue: &blue, alpha: &alpha
            )
            for (channel, expected) in [blue, green, red, alpha].enumerated() {
                XCTAssertEqual(
                    Double(rendered.bgra8UnormSRGB[channel]) / 255,
                    Double(expected), accuracy: 1.0 / 255,
                    "Metal canvas must match the surrounding SwiftUI background"
                )
            }
        }
        let darkCenter = 8 * dark.bytesPerRow + 8 * 4
        let lightCenter = 8 * light.bytesPerRow + 8 * 4
        XCTAssertGreaterThan(dark.bgra8UnormSRGB[darkCenter], 220)
        XCTAssertLessThan(light.bgra8UnormSRGB[lightCenter], 40)
        XCTAssertNotEqual(dark.visiblePixelHash, light.visiblePixelHash)
    }

    private func scene() -> RenderState {
        RenderState(
            staticScene: StaticSceneSnapshot(
                revision: 1,
                candleHistory: ChartCandleHistory(candles: []),
                batches: [ChartRenderBatch(barInstances: [ChartBarInstance(
                    left: 4, top: 4, right: 12, bottom: 12, color: .primaryText
                )], coordinateSpace: .fixed)]
            ),
            liveTail: LiveTailSnapshot(revision: 1, candle: nil, batches: [], latestPrice: nil),
            interaction: InteractionSnapshot(
                revision: 1, translationX: 0, scaleX: 1, crosshair: nil
            ),
            invalidation: .full
        )
    }

    @MainActor
    private func resolved(_ color: Color, style: UIUserInterfaceStyle) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    private func contrast(_ first: UIColor, _ second: UIColor) -> Double {
        func luminance(_ color: UIColor) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let values = [r, g, b].map { value -> Double in
                let component = Double(value)
                return component <= 0.04045
                    ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
        }
        let lhs = luminance(first), rhs = luminance(second)
        return (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
    }
}

final class WebParityFormattingTests: XCTestCase {
  func testStopLossPreviewRoundsAcrossWebStepBoundaries() {
    let examples = [
      ("0", "1"), ("19.01", "20"), ("20", "20"), ("20.01", "25"), ("99.01", "100"), ("100", "100"),
      ("100.01", "110"),
    ]
    for (input, expected) in examples {
      XCTAssertEqual(
        WebStopLossAmount.roundUp(Decimal(string: input)!), Decimal(string: expected)!, input)
    }
  }
  func testResearchAndRecordTimesAcceptFractionalISOAndExchangeMilliseconds() throws {
    let fractional = try XCTUnwrap(WebFormat.date("2026-10-31T02:00:00.123Z"))
    let milliseconds = String(Int64((fractional.timeIntervalSince1970 * 1000).rounded()))
    XCTAssertEqual(
      try XCTUnwrap(WebFormat.date(milliseconds)).timeIntervalSince1970,
      fractional.timeIntervalSince1970, accuracy: 0.001)
    XCTAssertNotNil(WebFormat.date("2026-10-31T02:00:00Z"))
    XCTAssertNil(WebFormat.date("--"))
  }
}
