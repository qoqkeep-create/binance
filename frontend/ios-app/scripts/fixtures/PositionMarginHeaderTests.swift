import AppKit
import SwiftUI
import ImageIO
import XCTest
@testable import TradeTool

@MainActor
final class PositionMarginHeaderTests: XCTestCase {
  func testActualHeaderFitsCompactPhonesInBothThemesAndAllRiskColors() async throws {
    let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("rendered", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for ratio in ["3.45", "55", "85", "121.25"] {
      let store = USDTStore(api: HeaderFixtureAPI(ratio: ratio))
      store.binding = .object(["id": .string("fixture")])
      let model = PositionMarginModel()
      let monitor = Task { await model.monitor(store) }
      for _ in 0..<1000 where model.snapshot == .null { await Task.yield() }
      XCTAssertTrue(model.isCurrent(scope: store.scope, now: .now))
      for dark in [false, true] {
        WebTheme.dark = dark
        for width in [320, 393, 440] {
          for selection in ["positions", "limits", "history"] {
            let renderer = ImageRenderer(content: PositionHeaderHarness(store: store, margin: model, selection: selection)
              .frame(width: CGFloat(width), height: 44).padding(.horizontal, 20)
              .environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, (width + 40) * 2)
            XCTAssertEqual(image.height, 88)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            pixels.withUnsafeMutableBytes { buffer in
              let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
              context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            for y in 0..<image.height {
              for x in [0, 10, image.width - 11, image.width - 1] {
                XCTAssertEqual(pixels[(y * image.width + x) * 4 + 3], 0,
                  "Header must not overflow at \(width) pt, ratio \(ratio)")
              }
            }
            let glyphPixels = (12..<68).reduce(0) { sum, y in
              sum + (56..<min(270, image.width / 2)).filter { x in
                let pixel = (y * image.width + x) * 4
                let rgb = pixels[pixel..<pixel + 3]
                return dark ? rgb.allSatisfy { $0 > 100 } : rgb.allSatisfy { $0 < 150 }
              }.count
            }
            XCTAssertGreaterThan(glyphPixels, 100, "The actual tab glyphs must render, including narrow layouts")
            let url = output.appendingPathComponent("header-\(width)-\(dark ? "dark" : "light")-\(ratio)-\(selection).png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
          }
        }
      }
      monitor.cancel(); await monitor.value
    }
  }
}

private struct HeaderFixtureAPI: APIClient {
  let ratio: String
  func send<Response: Decodable>(_ request: APIRequest<Response>) async throws -> Response {
    JSONValue.object(["supported": .bool(true), "observed_at": .number(Date().timeIntervalSince1970 * 1000),
      "max_age_seconds": .number(20), "margin_ratio_percent": .string(ratio), "liquidation_reached": .bool(false)]) as! Response
  }
}
