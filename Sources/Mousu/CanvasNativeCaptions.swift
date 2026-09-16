import AppKit

/// Fast-mode text stays at native display resolution even if the effects surface
/// needs fewer pixels. This view never intercepts pointer or scroll events.
@MainActor
final class CanvasNativeCaptions: NSView {
    private let title = NSTextField(labelWithString: "Try it")
    private let subtitle = NSTextField(labelWithString: "Move your pointer here and try scrolling.")
    private let coordinates = NSTextField(labelWithString: "")
    private var lastDark: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 11)
        coordinates.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        for label in [title, subtitle, coordinates] {
            label.isSelectable = false
            label.isEditable = false
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 1
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(text: String, coordinateOpacity: Double, reveal: Double, dark: Bool, visible: Bool) {
        if isHidden == visible { isHidden = !visible }
        guard visible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if alphaValue != reveal { alphaValue = reveal }
        if coordinates.alphaValue != coordinateOpacity { coordinates.alphaValue = coordinateOpacity }
        if coordinates.stringValue != text { coordinates.stringValue = text }
        if lastDark != dark {
            title.textColor = NSColor(calibratedWhite: dark ? 0.92 : 0.12, alpha: 1)
            let secondary = NSColor(calibratedWhite: dark ? 0.65 : 0.36, alpha: 1)
            subtitle.textColor = secondary
            coordinates.textColor = secondary
            lastDark = dark
        }
        CATransaction.commit()
    }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 40)
        title.frame = CGRect(x: 18, y: 18, width: width, height: 20)
        subtitle.frame = CGRect(x: 18, y: 42, width: width, height: 18)
        coordinates.frame = CGRect(x: 18, y: 73, width: width, height: 18)
    }
}
