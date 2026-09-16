import Foundation

/// Deterministic envelopes keep power transitions smooth and independent of frame rate.
enum CRTSignal {
    static let shutdownDuration = 0.55
    static let revealDuration = 0.24

    static func fastReveal(shutdownElapsed: Double?, reducedMotion: Bool = false) -> Double {
        guard !reducedMotion, let shutdownElapsed else { return 1 }
        let progress = min(1, max(0, (shutdownElapsed - shutdownDuration) / revealDuration))
        return progress * progress * (3 - 2 * progress)
    }

    struct Power {
        let width: Double
        let height: Double
        let brightness: Double
    }

    static func power(elapsed: Double, shutdownElapsed: Double? = nil, reducedMotion: Bool = false) -> Power {
        if reducedMotion { return Power(width: 1, height: 1, brightness: 1) }
        if let shutdownElapsed {
            let progress = min(1, max(0, shutdownElapsed / shutdownDuration))
            return Power(
                width: max(0.002, pow(1 - max(0, (progress - 0.4) / 0.6), 2)),
                height: max(0.003, pow(max(0, 1 - progress / 0.48), 4)),
                brightness: pow(1 - progress, 0.65))
        }
        let progress = min(1, max(0, elapsed / 0.7))
        let opening = max(0, (progress - 0.12) / 0.88)
        return Power(
            width: min(1, 0.015 + progress * 8),
            height: max(0.004, 1 - pow(1 - opening, 3)),
            brightness: min(1, progress * 5))
    }
}

/// Keep only the power clock across device-detail reconstruction, not the canvas
/// or its rendering resources. Choosing a different effect starts a new transition.
@MainActor
final class CRTPlaybackState {
    private(set) var effect: TryAreaEffect = .fast
    private(set) var startedAt = ProcessInfo.processInfo.systemUptime
    private(set) var stoppedAt: TimeInterval?

    func select(_ effect: TryAreaEffect, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard self.effect != effect else { return }
        self.effect = effect
        if effect == .crt {
            startedAt = time
            stoppedAt = nil
        } else {
            stoppedAt = time
        }
    }
}
