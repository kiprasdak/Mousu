import CoreGraphics
import Foundation

/// The CPU canvas's wheel response, sampled by the display clock instead of an
/// 8 ms task. Retargeting keeps only the current position and latest destination.
struct CanvasScrollMotion {
    private(set) var position = CGSize.zero
    private(set) var target = CGSize.zero
    private var updatedAt: TimeInterval?
    private static let timeConstant = 0.045
    private static let settlingDistance = 0.05

    var isAnimating: Bool { position != target }

    mutating func retarget(to destination: CGSize, at time: TimeInterval, animated: Bool) {
        guard time.isFinite, destination.width.isFinite, destination.height.isFinite,
            abs(destination.width) < 1e12, abs(destination.height) < 1e12
        else { return }
        advance(at: time)
        target = destination
        if animated {
            updatedAt = time
        } else {
            finish()
        }
    }

    @discardableResult
    mutating func advance(at time: TimeInterval) -> Bool {
        guard isAnimating, let previous = updatedAt, time.isFinite, time > previous else { return isAnimating }
        // Analytic exponential response: equivalent elapsed time gives the same
        // position at 60/120 Hz or after a dropped frame. Never replay old steps.
        let blend = -expm1(-(time - previous) / Self.timeConstant)
        position.width += (target.width - position.width) * blend
        position.height += (target.height - position.height) * blend
        updatedAt = time
        if abs(target.width - position.width) < Self.settlingDistance,
            abs(target.height - position.height) < Self.settlingDistance
        {
            finish()
        }
        return isAnimating
    }

    mutating func finish() {
        position = target
        updatedAt = nil
    }
}
