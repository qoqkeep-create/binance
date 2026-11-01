// Render the native continuous corner mask into launch assets; iOS launch storyboards ignore runtime attributes.
import SwiftUI
import AppKit

@MainActor
func render() throws {
    let source = NSImage(contentsOfFile: CommandLine.arguments[1])!
    let target = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    for scale in 1...3 {
        let view = Image(nsImage: source).resizable().scaledToFit()
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 96 * 0.22, style: .continuous))
        let renderer = ImageRenderer(content: view)
        renderer.scale = CGFloat(scale)
        let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
        let suffix = scale == 1 ? "" : "@\(scale)x"
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: target.appendingPathComponent("LaunchBrandMark\(suffix).png"))
    }
}
try await render()
