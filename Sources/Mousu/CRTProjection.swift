import CoreGraphics

/// Keep GPU screen curvature and pointer hit testing in the same logical coordinates.
enum CRTProjection {
    static func sourcePoint(at point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return point }
        let nx = point.x / size.width * 2 - 1
        let ny = point.y / size.height * 2 - 1
        let u = nx * (1 + 0.045 * ny * ny + 0.012 * nx * nx)
        let v = ny * (1 + 0.045 * nx * nx + 0.012 * ny * ny)
        return CGPoint(x: (u + 1) * size.width / 2, y: (v + 1) * size.height / 2)
    }
}
