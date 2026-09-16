import Foundation

enum TryAreaEffect: String, CaseIterable {
    case fast, crt

    var title: String { self == .fast ? "Fast" : rawValue.uppercased() }

    static func isCRTUnlocked(in defaults: UserDefaults = .standard) -> Bool {
        // A saved rendering choice is not evidence that the Easter egg was discovered.
        defaults.bool(forKey: "crtUnlocked")
    }

    static func initial(in defaults: UserDefaults = .standard) -> Self {
        guard isCRTUnlocked(in: defaults) else { return .fast }
        if let value = defaults.string(forKey: "tryAreaEffect") { return Self(rawValue: value) ?? .fast }
        return defaults.object(forKey: "crtTryArea") as? Bool == true ? .crt : .fast
    }
}

/// Five nearby-in-time primary clicks; scrolling or leaving the canvas breaks the sequence.
struct CRTUnlockSequence {
    private var count = 0
    private var lastClick: TimeInterval?

    mutating func reset() {
        count = 0
        lastClick = nil
    }

    mutating func click(at time: TimeInterval) -> Bool {
        if let lastClick, time - lastClick >= 0, time - lastClick <= 0.6 {
            count += 1
        } else {
            count = 1
        }
        lastClick = time
        if count == 5 {
            reset()
            return true
        }
        return false
    }
}
