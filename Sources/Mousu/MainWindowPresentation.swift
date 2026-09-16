import AppKit

/// A registered login item still needs to behave normally when opened from Finder.
enum AppLaunch {
    static func isLoginItem(_ event: NSAppleEventDescriptor?) -> Bool {
        guard event?.eventClass == kCoreEventClass, event?.eventID == kAEOpenApplication else { return false }
        return event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

@MainActor
final class MainWindowPresentation {
    static let shared = MainWindowPresentation()
    private weak var window: NSWindow?
    private var openScene: (() -> Void)?
    private var requestedScreen: NSScreen?
    private var openRequested = false

    func registerOpener(_ action: @escaping () -> Void) {
        let needsOpener = openScene == nil && openRequested
        openScene = action
        if needsOpener {
            DispatchQueue.main.async { [weak self] in self?.openRequestedWindow() }
        }
    }

    func attach(_ window: NSWindow) {
        self.window = window
        prepare(window)
        if openRequested {
            DispatchQueue.main.async { [weak self] in self?.presentRequestedWindow() }
        }
    }

    func show(on screen: NSScreen? = nil) {
        requestedScreen = screen
        openRequested = true
        openRequestedWindow()
    }

    private func openRequestedWindow() {
        guard openRequested, let openScene else { return }
        // Configure an existing window before SwiftUI can order or activate it.
        if let window { prepare(window) }
        AppPresence.shared.openWindow()
        openScene()
        DispatchQueue.main.async { [weak self] in self?.presentRequestedWindow() }
    }

    private func prepare(_ window: NSWindow) {
        window.collectionBehavior.remove(.canJoinAllSpaces)
        window.collectionBehavior.insert(.moveToActiveSpace)
        guard let requestedScreen else { return }
        let screen = NSScreen.screens.first { $0 == requestedScreen } ?? NSScreen.main
        guard let screen else { return }
        window.setFrame(Self.frame(window.frame, fitting: screen.visibleFrame), display: false)
    }

    private func presentRequestedWindow() {
        guard openRequested, let window else { return }
        prepare(window)
        openRequested = false
        requestedScreen = nil
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Keep an existing position on the requested display; center when moving displays.
    static func frame(_ frame: NSRect, fitting visible: NSRect) -> NSRect {
        var result = frame
        result.size.width = min(result.width, visible.width)
        result.size.height = min(result.height, visible.height)
        if !visible.contains(NSPoint(x: frame.midX, y: frame.midY)) {
            result.origin = NSPoint(x: visible.midX - result.width / 2, y: visible.midY - result.height / 2)
        }
        result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
        return result
    }
}
