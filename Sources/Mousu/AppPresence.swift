import AppKit
import SwiftUI

/// Dock presence is independent of the input engine and menu-bar item.
@MainActor
final class AppPresence {
    static let shared = AppPresence()
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void
    private(set) var windowOpen = true
    private var lastPolicy: NSApplication.ActivationPolicy?
    var hideDockWhenClosed = true {
        didSet { updatePolicy() }
    }

    init(
        setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = {
            NSApp.setActivationPolicy($0)
        }
    ) {
        self.setPolicy = setPolicy
    }

    func openWindow() {
        windowOpen = true
        updatePolicy()
    }

    func closeWindow() {
        windowOpen = false
        updatePolicy()
    }

    private func updatePolicy() {
        let policy: NSApplication.ActivationPolicy = hideDockWhenClosed && !windowOpen ? .accessory : .regular
        guard policy != lastPolicy else { return }
        lastPolicy = policy
        setPolicy(policy)
    }
}

@MainActor
struct MainWindowPresence: NSViewRepresentable {
    let hideDockWhenClosed: Bool

    func makeNSView(context: Context) -> Reader { Reader() }

    func updateNSView(_ view: Reader, context: Context) {
        AppPresence.shared.hideDockWhenClosed = hideDockWhenClosed
    }

    final class Reader: NSView {
        var presence = AppPresence.shared

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            presence.openWindow()
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowOpened), name: NSWindow.didBecomeMainNotification, object: window)
        }

        @objc private func windowClosed() { presence.closeWindow() }
        @objc private func windowOpened() { presence.openWindow() }
    }
}
