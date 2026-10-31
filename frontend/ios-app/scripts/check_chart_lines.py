#!/usr/bin/env python3
"""Run production BOLL math and Metal line shaders on macOS, without an iOS build."""
from pathlib import Path
import os
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "TradeTool"
CHART = APP / "Features/ChartEngine"

HARNESS = r'''
struct LineUniforms {
    var viewportSize = SIMD2<Float>(128, 96)
    var translationAndScale = SIMD2<Float>(0, 1)
    var horizontalPlotBounds = SIMD2<Float>(0, 128)
    var timelineBodyStyle = SIMD2<Float>(0, 0.5)
    var positiveColor = SIMD4<Float>(1, 1, 1, 1)
    var negativeColor = SIMD4<Float>(1, 1, 1, 1)
}

@main struct ChartLineChecks {
    static func main() throws {
        var failures = 0
        var calculator = BollingerBandsIndicatorCalculator(
            period: 20, multiplier: 2, intervalMilliseconds: 60_000
        )!
        var window: [Double] = []
        var maximumError = 0.0
        for index in 0..<240 {
            let value = 100_000_000 + sin(Double(index) * 0.21) * 0.01
            window.append(value)
            if window.count > 20 { window.removeFirst() }
            let candle = ChartCandle(
                openTime: Int64(index) * 60_000, closeTime: Int64(index + 1) * 60_000 - 1,
                openPrice: value, highPrice: value, lowPrice: value, closePrice: value,
                volume: 1, quoteVolume: value, closure: .closed
            )
            let point = calculator.commit(candle)
            if window.count == 20, let upper = point.upper, let middle = point.middle {
                let origin = window[0]
                let offsets = window.map { $0 - origin }
                let mean = offsets.reduce(0, +) / 20
                let deviation = sqrt(offsets.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 20)
                maximumError = max(maximumError, abs((upper - middle) - deviation * 2))
            }
        }
        print("\(maximumError < 0.000001 ? "PASS" : "FAIL") BOLL low-volatility width error: \(maximumError)")
        if maximumError >= 0.000001 { failures += 1 }

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("SKIP Metal line coverage: no device")
            exit(failures == 0 ? 0 : 1)
        }
        let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "chartLineVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "chartLineFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let queue = device.makeCommandQueue()!
        // Covers shallow and steep BOLL/EMA slopes, sharp joins and dashed drawing lines.
        let cases: [(String, [ChartPolylinePoint], Float, Float)] = [
            ("shallow", [.init(x: 12, y: 24), .init(x: 115, y: 48)], 0, 0),
            ("steep", [.init(x: 28, y: 12), .init(x: 52, y: 84)], 0, 0),
            ("join", [.init(x: 12, y: 70), .init(x: 55, y: 22), .init(x: 115, y: 55)], 0, 0),
            ("dashed", [.init(x: 12, y: 24), .init(x: 115, y: 48)], 6, 4),
        ]
        for (name, points, dash, gap) in cases {
            let segments = ChartBatchCompiler.lineSegments(
                spans: [points], width: 2, dashLength: dash, gapLength: gap, color: .primaryText, antialias: true
            )
            var instances = segments.map { segment -> MetalLineInstance in
                MetalLineInstance(segment, timelineTransformMode: 0, appearance: .dark)
            }
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: 128, height: 96, mipmapped: false
            )
            textureDescriptor.storageMode = .shared
            textureDescriptor.usage = [.renderTarget]
            let target = device.makeTexture(descriptor: textureDescriptor)!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline)
            instances.withUnsafeMutableBytes {
                encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
            }
            var uniforms = LineUniforms()
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<LineUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { throw command.error! }
            var pixels = [UInt8](repeating: 0, count: 128 * 96 * 4)
            pixels.withUnsafeMutableBytes {
                target.getBytes($0.baseAddress!, bytesPerRow: 128 * 4,
                    from: MTLRegionMake2D(0, 0, 128, 96), mipmapLevel: 0)
            }
            let alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
            let partial = alpha.filter { $0 > 0 && $0 < 255 }.count
            let solid = alpha.filter { $0 == 255 }.count
            let passes = partial > 30 && solid > 20
            print("\(passes ? "PASS" : "FAIL") Metal \(name): partial edge pixels=\(partial), solid=\(solid)")
            if !passes { failures += 1 }
        }
        exit(failures == 0 ? 0 : 1)
    }
}
'''


def main():
    env = dict(os.environ)
    with tempfile.TemporaryDirectory(prefix="tradetool-chart-lines-") as folder:
        folder = Path(folder)
        candle = (CHART / "Domain/ChartCandle.swift").read_text().split("extension ChartCandle {")[0]
        bollinger = (CHART / "Indicators/BollingerBandsIndicator.swift").read_text().split("struct BollingerBandsChartIndicatorPlugin")[0]
        (folder / "Calculators.swift").write_text(
            "import Foundation\nstruct MarketChartTradingData: Equatable, Sendable {}\n"
            + candle + (CHART / "Indicators/EMAIndicator.swift").read_text() + bollinger
        )
        renderer = (CHART / "Rendering/Metal/MetalRenderer.swift").read_text()
        # Compile the real GPU instance encoders, without the UIKit chart host.
        encoders = renderer[renderer.index("private struct MetalCandleInstance"):renderer.index("private struct MetalChartUniforms")]
        colors = renderer[renderer.index("private extension ChartColor"):renderer.index("private extension MTLCommandBufferStatus")]
        (folder / "Harness.swift").write_text("import Foundation\nimport Metal\n" + encoders + colors + HARNESS)
        sources = [folder / "Calculators.swift", folder / "Harness.swift",
                   CHART / "Domain/ChartFigure.swift", CHART / "Scene/ChartText.swift",
                   CHART / "Scene/ChartRenderBatch.swift"]
        executable = folder / "check"
        subprocess.run(["swiftc", *map(str, sources), "-o", str(executable)], env=env, check=True)
        return subprocess.run([str(executable), str(CHART / "Rendering/Metal/ChartShaders.metal")], env=env).returncode


if __name__ == "__main__":
    raise SystemExit(main())
