import AppKit

// Finder supplies the two real, draggable icons. Only the preview paints them.
let width = 720.0
let height = 440.0
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fatalError("Usage: RenderDMG.swift app-path output-directory")
}
let app = URL(fileURLWithPath: arguments[1])
guard let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
    fatalError("App bundle is missing its version")
}
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
let ink = NSColor(srgbRed: 0.125, green: 0.137, blue: 0.165, alpha: 1)
let muted = NSColor(srgbRed: 0.416, green: 0.439, blue: 0.486, alpha: 1)
let blue = NSColor(srgbRed: 0.157, green: 0.404, blue: 0.91, alpha: 1)

func text(
    _ string: String, y: Double, size: Double, weight: NSFont.Weight,
    color: NSColor, x: Double = 0, span: Double = 720
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: paragraph,
    ]
    (string as NSString).draw(
        in: NSRect(x: x, y: y, width: span, height: size * 1.5),
        withAttributes: attributes)
}

func render(scale: Int, preview: Bool) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width) * scale,
        pixelsHigh: Int(height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    NSColor(srgbRed: 0.98, green: 0.984, blue: 0.988, alpha: 1).setFill()
    bounds.fill()

    // The website's dot field, held at a quiet moment around the installation path.
    for x in stride(from: 34.0, through: 686.0, by: 24) {
        for y in stride(from: 100.0, through: 316.0, by: 24) {
            let distance = pow((x - 360) / 260, 2) + pow((y - 220) / 105, 2)
            let alpha = 0.14 * exp(-distance * 1.2)
            blue.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.7, height: 1.7)).fill()
        }
    }
    text("Mousü", y: 343, size: 34, weight: .semibold, color: ink)
    text("Drag Mousü to Applications.", y: 307, size: 17, weight: .regular, color: muted)

    let arrow = NSBezierPath()
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 285, y: 215))
    arrow.curve(
        to: NSPoint(x: 379, y: 222),
        controlPoint1: NSPoint(x: 311, y: 207),
        controlPoint2: NSPoint(x: 379, y: 206))
    arrow.curve(
        to: NSPoint(x: 340, y: 228),
        controlPoint1: NSPoint(x: 379, y: 232),
        controlPoint2: NSPoint(x: 355, y: 236))
    let outgoing = NSBezierPath()
    outgoing.lineWidth = arrow.lineWidth
    outgoing.lineCapStyle = .round
    outgoing.lineJoinStyle = .round
    outgoing.move(to: NSPoint(x: 340, y: 228))
    outgoing.curve(
        to: NSPoint(x: 367, y: 212),
        controlPoint1: NSPoint(x: 325, y: 220),
        controlPoint2: NSPoint(x: 344, y: 210))
    outgoing.curve(
        to: NSPoint(x: 435, y: 219),
        controlPoint1: NSPoint(x: 397, y: 213),
        controlPoint2: NSPoint(x: 421, y: 215))
    outgoing.move(to: NSPoint(x: 421, y: 222))
    outgoing.line(to: NSPoint(x: 435, y: 219))
    outgoing.line(to: NSPoint(x: 424, y: 212))
    blue.withAlphaComponent(0.75).setStroke()
    arrow.stroke()

    // A narrow white edge lets the outgoing stroke pass over the loop.
    let crossing = NSBezierPath()
    crossing.lineCapStyle = .round
    crossing.move(to: NSPoint(x: 356.39, y: 211.9))
    crossing.curve(
        to: NSPoint(x: 367, y: 212),
        controlPoint1: NSPoint(x: 359.74, y: 211.67),
        controlPoint2: NSPoint(x: 363.32, y: 211.68))
    crossing.curve(
        to: NSPoint(x: 377.53, y: 212.4),
        controlPoint1: NSPoint(x: 370.6, y: 212.12),
        controlPoint2: NSPoint(x: 374.11, y: 212.25))
    crossing.lineWidth = 6
    NSColor.white.setStroke()
    crossing.stroke()
    blue.withAlphaComponent(0.75).setStroke()
    outgoing.stroke()
    text(
        "\(version) beta  ·  macOS 26+  ·  Apple Silicon", y: 80, size: 12,
        weight: .regular, color: muted)

    if preview {
        let appIcon = NSImage(contentsOf: app.appendingPathComponent("Contents/Resources/Mousu.icns"))!
        let folderIcon = NSWorkspace.shared.icon(forFile: "/Applications")
        appIcon.draw(in: NSRect(x: 126, y: 146, width: 128, height: 128))
        folderIcon.draw(in: NSRect(x: 466, y: 146, width: 128, height: 128))
        text("Mousü", y: 115, size: 14, weight: .regular, color: ink, x: 110, span: 160)
        text("Applications", y: 115, size: 14, weight: .regular, color: ink, x: 450, span: 160)
    }
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

// dmgbuild combines these resolutions with tiffutil, preserving Retina metadata.
for scale in 1...2 {
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try render(scale: scale, preview: false).representation(using: .png, properties: [:])!
        .write(to: output.appendingPathComponent(name))
}
try render(scale: 2, preview: true).representation(using: .png, properties: [:])!
    .write(to: output.appendingPathComponent("preview.png"))
