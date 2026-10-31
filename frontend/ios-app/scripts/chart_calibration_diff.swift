import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct Arguments {
    let reference: URL
    let candidate: URL
    let diff: URL
    let report: URL
    let crop: CGRect?
    let threshold: UInt8

    init(_ values: [String]) throws {
        var parsed: [String: String] = [:]
        var index = 1
        while index < values.count {
            let key = values[index]
            guard key.hasPrefix("--"),
                  index + 1 < values.count else {
                throw CalibrationError.usage
            }
            parsed[key] = values[index + 1]
            index += 2
        }
        guard let referencePath = parsed["--reference"],
              let candidatePath = parsed["--candidate"],
              let diffPath = parsed["--output-diff"],
              let reportPath = parsed["--output-json"] else {
            throw CalibrationError.usage
        }
        reference = URL(fileURLWithPath: referencePath)
        candidate = URL(fileURLWithPath: candidatePath)
        diff = URL(fileURLWithPath: diffPath)
        report = URL(fileURLWithPath: reportPath)

        if let thresholdText = parsed["--threshold"],
           let value = UInt8(thresholdText) {
            threshold = value
        } else {
            threshold = 8
        }

        if let cropText = parsed["--crop"] {
            let components = cropText.split(separator: ",")
                .compactMap { Double($0) }
            guard components.count == 4,
                  components[2] > 0,
                  components[3] > 0 else {
                throw CalibrationError.invalidCrop(cropText)
            }
            crop = CGRect(
                x: components[0],
                y: components[1],
                width: components[2],
                height: components[3]
            )
        } else {
            crop = nil
        }
    }
}

private enum CalibrationError: Error, CustomStringConvertible {
    case usage
    case cannotLoad(String)
    case sizeMismatch(CGSize, CGSize)
    case invalidCrop(String)
    case cropOutsideImage(CGRect, CGSize)
    case cannotEncode(String)

    var description: String {
        switch self {
        case .usage:
            return """
            Usage: xcrun swift chart_calibration_diff.swift \\
              --reference binance.png --candidate trade-tool.png \\
              --output-diff diff.png --output-json report.json \\
              [--crop x,y,width,height] [--threshold 8]
            """
        case let .cannotLoad(path):
            return "Cannot load PNG: \(path)"
        case let .sizeMismatch(reference, candidate):
            return "Image sizes differ: \(reference) vs \(candidate)"
        case let .invalidCrop(value):
            return "Invalid crop; expected x,y,width,height: \(value)"
        case let .cropOutsideImage(crop, size):
            return "Crop \(crop) is outside image size \(size)"
        case let .cannotEncode(path):
            return "Cannot encode output: \(path)"
        }
    }
}

private struct Bitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]
}

private func loadBitmap(_ url: URL) throws -> Bitmap {
    guard let source = CGImageSourceCreateWithURL(
        url as CFURL,
        nil
    ), let image = CGImageSourceCreateImageAtIndex(
        source,
        0,
        nil
    ) else {
        throw CalibrationError.cannotLoad(url.path)
    }
    let width = image.width
    let height = image.height
    let rowBytes = try checked(
        width.multipliedReportingOverflow(by: 4),
        label: "row bytes"
    )
    let byteCount = try checked(
        rowBytes.multipliedReportingOverflow(by: height),
        label: "bitmap bytes"
    )
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue
    let rendered = bytes.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return false
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return true
    }
    guard rendered else {
        throw CalibrationError.cannotLoad(url.path)
    }
    return Bitmap(width: width, height: height, bytes: bytes)
}

private func checked(
    _ result: (partialValue: Int, overflow: Bool),
    label: String
) throws -> Int {
    guard !result.overflow else {
        throw CalibrationError.cannotEncode(label)
    }
    return result.partialValue
}

private func writePNG(
    bytes: [UInt8],
    width: Int,
    height: Int,
    url: URL
) throws {
    let data = Data(bytes)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
          ) else {
        throw CalibrationError.cannotEncode(url.path)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CalibrationError.cannotEncode(url.path)
    }
}

private func rounded(_ value: Double) -> Double {
    (value * 1_000_000).rounded() / 1_000_000
}

private func compare(_ arguments: Arguments) throws {
    let reference = try loadBitmap(arguments.reference)
    let candidate = try loadBitmap(arguments.candidate)
    let referenceSize = CGSize(
        width: reference.width,
        height: reference.height
    )
    let candidateSize = CGSize(
        width: candidate.width,
        height: candidate.height
    )
    guard referenceSize == candidateSize else {
        throw CalibrationError.sizeMismatch(
            referenceSize,
            candidateSize
        )
    }

    let fullRect = CGRect(
        x: 0,
        y: 0,
        width: reference.width,
        height: reference.height
    )
    let requestedCrop = arguments.crop ?? fullRect
    let integralCrop = requestedCrop.integral
    guard fullRect.contains(integralCrop),
          !integralCrop.isEmpty else {
        throw CalibrationError.cropOutsideImage(
            integralCrop,
            referenceSize
        )
    }

    let minX = Int(integralCrop.minX)
    let minY = Int(integralCrop.minY)
    let maxX = Int(integralCrop.maxX)
    let maxY = Int(integralCrop.maxY)
    let diffWidth = maxX - minX
    let diffHeight = maxY - minY
    var diffBytes = [UInt8](
        repeating: 0,
        count: diffWidth * diffHeight * 4
    )
    var changedCount = 0
    var channelDeltaTotal: UInt64 = 0
    var maximumDelta: UInt8 = 0
    var pixelDeltas: [UInt8] = []
    pixelDeltas.reserveCapacity(diffWidth * diffHeight)
    var changedMinX = Int.max
    var changedMinY = Int.max
    var changedMaxX = Int.min
    var changedMaxY = Int.min

    for y in minY..<maxY {
        for x in minX..<maxX {
            let sourceOffset = (y * reference.width + x) * 4
            let outputOffset = (
                (y - minY) * diffWidth + x - minX
            ) * 4
            var pixelMaximum: UInt8 = 0
            for channel in 0..<3 {
                let referenceValue = reference.bytes[
                    sourceOffset + channel
                ]
                let candidateValue = candidate.bytes[
                    sourceOffset + channel
                ]
                let delta = UInt8(abs(
                    Int(referenceValue) - Int(candidateValue)
                ))
                channelDeltaTotal += UInt64(delta)
                pixelMaximum = max(pixelMaximum, delta)
                diffBytes[outputOffset + channel] = min(
                    255,
                    UInt8(clamping: Int(delta) * 4)
                )
            }
            diffBytes[outputOffset + 3] = 255
            maximumDelta = max(maximumDelta, pixelMaximum)
            pixelDeltas.append(pixelMaximum)
            if pixelMaximum > arguments.threshold {
                changedCount += 1
                changedMinX = min(changedMinX, x)
                changedMinY = min(changedMinY, y)
                changedMaxX = max(changedMaxX, x)
                changedMaxY = max(changedMaxY, y)
            }
        }
    }

    pixelDeltas.sort()
    let pixelCount = diffWidth * diffHeight
    let p95Index = max(
        0,
        min(pixelDeltas.count - 1, Int(
            (Double(pixelDeltas.count) * 0.95).rounded(.up)
        ) - 1)
    )
    let boundingBox: [String: Int]? = changedCount == 0
        ? nil
        : [
            "x": changedMinX,
            "y": changedMinY,
            "width": changedMaxX - changedMinX + 1,
            "height": changedMaxY - changedMinY + 1,
        ]
    let report: [String: Any] = [
        "schemaVersion": 1,
        "reference": arguments.reference.path,
        "candidate": arguments.candidate.path,
        "imageWidth": reference.width,
        "imageHeight": reference.height,
        "crop": [
            "x": minX,
            "y": minY,
            "width": diffWidth,
            "height": diffHeight,
        ],
        "threshold": Int(arguments.threshold),
        "pixelCount": pixelCount,
        "changedPixelCount": changedCount,
        "changedPixelRate": rounded(
            Double(changedCount) / Double(pixelCount)
        ),
        "meanAbsoluteChannelDelta": rounded(
            Double(channelDeltaTotal) / Double(pixelCount * 3)
        ),
        "p95PixelDelta": Int(pixelDeltas[p95Index]),
        "maximumPixelDelta": Int(maximumDelta),
        "changedBoundingBox": boundingBox as Any,
    ]

    try writePNG(
        bytes: diffBytes,
        width: diffWidth,
        height: diffHeight,
        url: arguments.diff
    )
    let reportData = try JSONSerialization.data(
        withJSONObject: report,
        options: [.prettyPrinted, .sortedKeys]
    )
    try reportData.write(to: arguments.report, options: .atomic)
    print(String(data: reportData, encoding: .utf8) ?? "")
}

do {
    try compare(Arguments(CommandLine.arguments))
} catch {
    FileHandle.standardError.write(
        Data("\(error)\n".utf8)
    )
    exit(2)
}
