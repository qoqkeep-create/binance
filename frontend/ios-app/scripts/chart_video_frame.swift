import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct Arguments {
    let input: URL
    let output: URL
    let seconds: Double

    init(_ values: [String]) throws {
        var parsed: [String: String] = [:]
        var index = 1
        while index < values.count {
            let key = values[index]
            guard key.hasPrefix("--"),
                  index + 1 < values.count else {
                throw FrameError.usage
            }
            parsed[key] = values[index + 1]
            index += 2
        }
        guard let inputPath = parsed["--input"],
              let outputPath = parsed["--output"],
              let secondsText = parsed["--time"],
              let seconds = Double(secondsText),
              seconds.isFinite,
              seconds >= 0 else {
            throw FrameError.usage
        }
        input = URL(fileURLWithPath: inputPath)
        output = URL(fileURLWithPath: outputPath)
        self.seconds = seconds
    }
}

private enum FrameError: Error, CustomStringConvertible {
    case usage
    case cannotCreateFrame(Double)
    case cannotEncode(String)

    var description: String {
        switch self {
        case .usage:
            return """
            Usage: xcrun swift chart_video_frame.swift \\
              --input recording.mp4 --time 12.5 --output frame.png
            """
        case let .cannotCreateFrame(seconds):
            return "Cannot create a video frame at \(seconds) seconds"
        case let .cannotEncode(path):
            return "Cannot encode PNG: \(path)"
        }
    }
}

private func writePNG(
    _ image: CGImage,
    to output: URL
) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        output as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw FrameError.cannotEncode(output.path)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw FrameError.cannotEncode(output.path)
    }
}

private func extract(_ arguments: Arguments) async throws {
    let asset = AVURLAsset(url: arguments.input)
    let duration = try await asset.load(.duration)
    guard duration.isNumeric,
          arguments.seconds <= duration.seconds else {
        throw FrameError.cannotCreateFrame(arguments.seconds)
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let requestedTime = CMTime(
        seconds: arguments.seconds,
        preferredTimescale: 600
    )
    let image: CGImage
    let actualTime: CMTime
    do {
        (image, actualTime) = try await generator.image(
            at: requestedTime
        )
    } catch {
        throw FrameError.cannotCreateFrame(arguments.seconds)
    }
    try writePNG(image, to: arguments.output)
    let report: [String: Any] = [
        "input": arguments.input.path,
        "output": arguments.output.path,
        "requestedSeconds": arguments.seconds,
        "actualSeconds": actualTime.seconds,
        "durationSeconds": duration.seconds,
        "width": image.width,
        "height": image.height,
    ]
    let data = try JSONSerialization.data(
        withJSONObject: report,
        options: [.prettyPrinted, .sortedKeys]
    )
    print(String(decoding: data, as: UTF8.self))
}

do {
    try await extract(Arguments(CommandLine.arguments))
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
