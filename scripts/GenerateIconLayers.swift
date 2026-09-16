import AppKit
import SwiftUI

// Import the transparent foreground into Icon Composer. Keep the enclosure,
// lighting, shadows, and glass material in Composer instead of baking them in.
// Typography and proportions match AppMark in Sources/Mousu/Views.swift.
@MainActor
func writePNG<V: View>(_ view: V, to url: URL) throws {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
    renderer.scale = 1
    guard let image = renderer.cgImage,
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url, options: .atomic)
}

@main
struct GenerateIconLayers {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: generate-icon-layers OUTPUT_DIRECTORY")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try writePNG(
            MousuSymbol(size: 1024).foregroundStyle(.white),
            to: output.appendingPathComponent("Cursor.png"))
        try writePNG(
            MousuSymbol(size: 1024, paused: true).foregroundStyle(.white),
            to: output.appendingPathComponent("CursorPaused.png"))
    }
}
