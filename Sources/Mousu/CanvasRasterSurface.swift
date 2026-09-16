import AppKit

/// Reuses a bounded bitmap for the static fallback when Metal is unavailable.
@MainActor
final class CanvasRasterSurface {
    private var context: CGContext?

    func reset() { context = nil }

    func image(size: CGSize, scale: CGFloat, draw: () -> Void) -> CGImage? {
        guard size.width > 0, size.height > 0, scale > 0,
            size.width.isFinite, size.height.isFinite, scale.isFinite
        else {
            reset()
            return nil
        }
        let width = Int(ceil(size.width * scale))
        let height = Int(ceil(size.height * scale))
        if context?.width != width || context?.height != height {
            context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let context else { return nil }
        context.saveGState()
        defer { context.restoreGState() }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / size.width, y: -CGFloat(height) / size.height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw()
        return context.makeImage()
    }
}
