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
    for ratio in ["25", "55", "85"] {
      let store = USDTStore(api: HeaderFixtureAPI(ratio: ratio))
      store.binding = .object(["id": .string("fixture")])
      let model = PositionMarginModel()
      let monitor = Task { await model.monitor(store) }
      for _ in 0..<1000 where model.snapshot == .null { await Task.yield() }
      XCTAssertTrue(model.isCurrent(scope: store.scope, now: .now))
      for dark in [false, true] {
        WebTheme.dark = dark
        for width in [320, 393, 440] {
          let renderer = ImageRenderer(content: PositionHeaderHarness(store: store, margin: model)
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
          let url = output.appendingPathComponent("header-\(width)-\(dark ? "dark" : "light")-\(ratio).png")
          let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
          CGImageDestinationAddImage(destination, image, nil)
          XCTAssertTrue(CGImageDestinationFinalize(destination))
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
