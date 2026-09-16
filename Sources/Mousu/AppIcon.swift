import AppKit

@MainActor
enum AppIcon {
    /// Nil restores the system-managed primary icon, including its appearance variants.
    static func update(paused: Bool) {
        if paused {
            guard let icon = Bundle.main.image(forResource: "MousuPaused") else {
                NSLog("Missing compiled MousuPaused icon; build with scripts/bundle.")
                return
            }
            NSApplication.shared.applicationIconImage = icon
        } else {
            NSApplication.shared.applicationIconImage = nil
        }
    }
}
