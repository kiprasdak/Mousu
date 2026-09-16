import AppKit
import SwiftUI

/// Gives the native settings sheet a content-only attachment area while preserving
/// SwiftUI's window delegate and its other sheet/window behavior.
@MainActor
struct SettingsSheetAlignment: NSViewRepresentable {
    let sidebarWidth: CGFloat
    var isPresented: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: Reader, context: Context) {
        context.coordinator.sidebarWidth = sidebarWidth
        context.coordinator.isPresented = isPresented
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: Reader, coordinator: Coordinator) {
        coordinator.attach(to: nil)
    }

    final class Reader: NSView {
        var coordinator: Coordinator?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var sidebarWidth: CGFloat = 0
        var isPresented: () -> Bool = { false }
        private weak var window: NSWindow?
        private weak var originalDelegate: (any NSWindowDelegate)?

        func attach(to window: NSWindow?) {
            guard self.window !== window else { return }
            if self.window?.delegate === self { self.window?.delegate = originalDelegate }
            self.window = window
            originalDelegate = window?.delegate
            window?.delegate = self
        }

        override nonisolated func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated { originalDelegate?.responds(to: selector) == true }
        }

        // NSObject's forwarding API is nonisolated. The thread guard proves this
        // reference stays on the main thread; the box only bridges that API boundary.
        private struct DelegateTarget: @unchecked Sendable {
            let value: (any NSWindowDelegate)?
        }

        override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
            guard Thread.isMainThread else { return nil }
            return MainActor.assumeIsolated { DelegateTarget(value: originalDelegate) }.value
        }

        func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
            var attachment = originalDelegate?.window?(window, willPositionSheet: sheet, using: rect) ?? rect
            guard isPresented() else { return attachment }
            let inset = min(sidebarWidth, attachment.width)
            attachment.origin.x += inset
            attachment.size.width -= inset
            return attachment
        }
    }
}
