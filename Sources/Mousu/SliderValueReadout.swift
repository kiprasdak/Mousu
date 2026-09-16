import AppKit
import QuartzCore
import SwiftUI

/// A single reused text layer keeps slider values immediate without retaining
/// animated numeric transitions. Speed formatting reserves both decimal places.
struct SliderValueReadout: NSViewRepresentable {
    let text: String
    let color: Color
    let leading: Bool

    func makeNSView(context: Context) -> SliderDigitsView { SliderDigitsView() }

    func updateNSView(_ view: SliderDigitsView, context: Context) {
        view.show(text, color: NSColor(color), leading: leading)
    }
}

@MainActor
final class SliderDigitsView: NSView {
    private let textLayer = CATextLayer()
    private(set) var displayedText = ""
    private var tint: NSColor = .labelColor
    private var leading = false
    private let digitFont: NSFont = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 11) } ?? font
    }()

    override var isFlipped: Bool { true }
    var activeTransitionCount: Int { textLayer.animationKeys()?.count ?? 0 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        textLayer.alignmentMode = .left
        textLayer.isWrapped = false
        textLayer.truncationMode = .end
        // CATextLayer renders contents after updateText's transaction has ended.
        // Block its deferred implicit fade as well as immediate property animation.
        textLayer.actions = ["contents": NSNull()]
        layer?.addSublayer(textLayer)
        setAccessibilityElement(false)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    // SwiftUI owns click, focus and accessibility behavior around this display.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, color: NSColor, leading: Bool) {
        guard displayedText != text || tint != color || self.leading != leading else { return }
        displayedText = text
        tint = color
        self.leading = leading
        updateText()
    }

    override func layout() {
        super.layout()
        updateText()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateText()
    }

    private func updateText() {
        var attributes: [NSAttributedString.Key: Any] = [.font: digitFont, .foregroundColor: tint]
        let fullWidth = NSAttributedString(string: displayedText, attributes: attributes).size().width
        // Keep exact values available to the editor and accessibility while truncating
        // long readouts at a readable size instead of shrinking them to a few pixels.
        let scale = max(9.5 / 11, min(1, bounds.width / max(1, fullWidth)))
        let font = NSFont(descriptor: digitFont.fontDescriptor, size: 11 * scale) ?? digitFont
        attributes[.font] = font
        let height = ceil(font.ascender - font.descender + font.leading)
        let width = min(bounds.width, fullWidth * scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
        textLayer.frame = CGRect(
            x: leading ? 0 : max(0, bounds.width - width), y: (bounds.height - height) / 2,
            width: ceil(width) + 1, height: height)
        textLayer.string = NSAttributedString(string: displayedText, attributes: attributes)
        CATransaction.commit()
    }
}
