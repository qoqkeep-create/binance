#!/usr/bin/env python3
"""Render the production launch view against the storyboard's full-window layout.

Runs SwiftUI ImageRenderer on macOS without a simulator or production transport.
Only the asset loader is adapted from the iOS bundle to the source PNG files.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

IOS = Path(__file__).resolve().parents[1]
APP = IOS / "TradeTool"
ASSETS = APP / "Resources/Assets.xcassets"


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise ValueError(f"Unclosed Swift declaration: {marker}")


def asset(name):
    directory = ASSETS / f"{name}.imageset"
    contents = json.loads((directory / "Contents.json").read_text())
    image = next(item for item in contents["images"] if item.get("scale") == "1x")
    return directory / image["filename"]


def run(destination, source):
    storyboard = APP / "Resources/BrandLaunchScreen.storyboard"
    tree = ET.parse(storyboard)
    window = tree.find(".//view[@id='brand-launch-view']")
    mark = window.find("./subviews/imageView")
    assert mark is not None, "System launch image is missing"
    for axis in ("centerX", "centerY"):
        anchor = window.find(f"./constraints/constraint[@firstAttribute='{axis}']")
        assert anchor is not None and anchor.get("firstItem") == mark.get("id")
        assert anchor.get("secondItem") == window.get("id"), "System launch must center in the full window"
    for dimension in ("width", "height"):
        constraint = mark.find(f"./constraints/constraint[@firstAttribute='{dimension}']")
        assert constraint is not None and float(constraint.get("constant")) == 96
    image_name = mark.get("image")
    view = block(source.read_text(), "struct AppLaunchView: View")
    # Preserve the old helper when replaying a pre-fix RootView.swift.
    if "BinanceLogoMark(" in view:
        theme = (APP / "Core/Design/BinanceTheme.swift").read_text()
        view = block(theme, "struct BinanceLogoMark: View") + "\n" + view
    names = sorted(set(re.findall(r'Image\("([^"\n]+)"\)', view)) | {image_name})
    for index, name in enumerate(names, start=1):
        view = view.replace(f'Image("{name}")', f'Image(nsImage: NSImage(contentsOfFile: CommandLine.arguments[{index}])!)')
    reference_index = names.index(image_name) + 1
    destination.mkdir(parents=True, exist_ok=True)
    swift = destination / "LaunchLayout.swift"
    swift.write_text("import AppKit\nimport SwiftUI\n" + view + "\n" + CHECKS.replace("REFERENCE_INDEX", str(reference_index)))
    inputs = [source, storyboard, Path(__file__).resolve(), *(asset(name) for name in names)]
    (destination / "production-inputs.json").write_text(json.dumps({
        str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs
    }, indent=2) + "\n")
    executable = destination / "launch-layout"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                    str(swift), "-o", str(executable)], check=True)
    return subprocess.run([str(executable), *(str(asset(name)) for name in names)], check=False).returncode


CHECKS = r'''
@main
enum LaunchLayoutChecks {
    @MainActor
    static func main() throws {
        let cases: [(String, CGSize, EdgeInsets)] = [
            ("portrait without insets", CGSize(width: 393, height: 852), EdgeInsets()),
            ("portrait with notch", CGSize(width: 393, height: 852),
             EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)),
            ("large portrait", CGSize(width: 402, height: 874),
             EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)),
            ("landscape with asymmetric insets", CGSize(width: 852, height: 393),
             EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 21)),
        ]
        let mark = NSImage(contentsOfFile: CommandLine.arguments[REFERENCE_INDEX])!
        var failures = 0
        for (name, size, insets) in cases {
            for scheme in [ColorScheme.light, .dark] {
                let actual = ImageRenderer(content: AppLaunchView()
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: insets.top) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: insets.bottom) }
                    .safeAreaInset(edge: .leading, spacing: 0) { Color.clear.frame(width: insets.leading) }
                    .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: insets.trailing) }
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, scheme))
                let reference = ImageRenderer(content: ZStack {
                    Color.white
                    Image(nsImage: mark).resizable().scaledToFit().frame(width: 96, height: 96)
                }.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme))
                actual.scale = 1
                reference.scale = 1
                guard let output = actual.cgImage, let expected = reference.cgImage else {
                    fatalError("ImageRenderer did not produce a launch image")
                }
                let actualPixels = try pixels(output), expectedPixels = try pixels(expected)
                let matches = output.width == Int(size.width) && output.height == Int(size.height)
                    && actualPixels == expectedPixels
                if !matches { failures += 1 }
                print("\(matches ? "PASS" : "FAIL") \(name), \(scheme): \(bounds(actualPixels, width: output.width))")
            }
        }
        print("Launch layout: \(cases.count * 2 - failures)/\(cases.count * 2) passed")
        if failures > 0 { exit(1) }
    }

    static func pixels(_ image: CGImage) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        result.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }

    static func bounds(_ pixels: [UInt8], width: Int) -> CGRect {
        var minX = width, minY = pixels.count / 4 / width, maxX = -1, maxY = -1
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[index + 3] > 200 && pixels[index..<index + 3].contains(where: { $0 < 250 }) {
                let x = index / 4 % width, y = index / 4 / width
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
'''


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", nargs="?", type=Path)
    parser.add_argument("--source", type=Path, default=APP / "App/RootView.swift",
                        help="Alternate RootView.swift for regression replay")
    args = parser.parse_args()
    if args.destination:
        raise SystemExit(run(args.destination.resolve(), args.source.resolve()))
    with tempfile.TemporaryDirectory(prefix="launch-layout-") as directory:
        raise SystemExit(run(Path(directory), args.source.resolve()))
