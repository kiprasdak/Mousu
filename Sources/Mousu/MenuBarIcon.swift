import AppKit
import SwiftUI

/// MenuBarExtra extracts an Image from its label; supply the complete masked
/// artwork as one template image so it cannot fall back to the original symbol.
@MainActor
enum MenuBarIcon {
    private static let running = render(paused: false)
    private static let paused = render(paused: true)

    static func image(paused isPaused: Bool) -> NSImage {
        isPaused ? paused : running
    }

    private static func render(paused: Bool) -> NSImage {
        let renderer = ImageRenderer(
            content: MousuSymbol(size: 1024, paused: paused)
                .foregroundStyle(.black)
                .scaleEffect(30.2 / 1024.0)
                .frame(width: 17, height: 17)
                .clipped()
        )
        renderer.scale = 3
        guard let cgImage = renderer.cgImage else {
            return NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Mousü")!
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: 17, height: 17))
        image.isTemplate = true
        return image
    }
}
