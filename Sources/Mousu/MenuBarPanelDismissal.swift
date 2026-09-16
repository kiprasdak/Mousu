import AppKit
import SwiftUI

@MainActor
protocol MenuPanelEscapeHandling: AnyObject {
    func cancelMenuInteraction() -> Bool
}

/// Owns one dismissal from start to finish, including SwiftUI's status-button
/// action. Closing only its NSWindow leaves the menu-bar selection behind.
@MainActor
final class MenuPanelWindowReference {
    weak var window: NSWindow?
    weak var catalogEscapeHandler: (any MenuPanelEscapeHandling)?
    private weak var statusButton: NSButton?
    var reduceMotion = false {
        didSet { window?.animationBehavior = reduceMotion ? .none : .utilityWindow }
    }
    var buttonProvider: () -> NSButton? = { MenuPanelWindowReference.findStatusButton() }

    func didShow() {
        window?.animationBehavior = reduceMotion ? .none : .utilityWindow
        statusButton = buttonProvider()
    }

    func didHide() { clearHighlight() }

    func dismiss() {
        guard let window, window.isVisible else { return }
        if statusButton == nil { statusButton = buttonProvider() }
        // Finish through SwiftUI's existing menu action, then clear the button's
        // selected state. AppKit owns the utility-window fade and its timing.
        if let button = statusButton, let action = button.action {
            button.sendAction(action, to: button.target)
        } else {
            window.close()
        }
        clearHighlight()
    }

    private func clearHighlight() {
        statusButton?.state = .off
        statusButton?.highlight(false)
    }

    func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, window.isVisible else { return event }
        if event.type == .keyDown {
            guard event.window === window, event.keyCode == 53, window.attachedSheet == nil,
                event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                !(window.firstResponder is NSTextView)
            else { return event }
            if catalogEscapeHandler?.cancelMenuInteraction() != true { dismiss() }
            return nil
        }

        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        return handleMouseDown(event, at: point)
    }

    func handleMouseDown(_ event: NSEvent, at screenPoint: NSPoint) -> NSEvent? {
        guard let window, window.isVisible, window.attachedSheet == nil,
            !window.frame.contains(screenPoint)
        else { return event }
        if let clickedWindow = event.window, clickedWindow !== window,
            isRelatedWindow(clickedWindow) || clickedWindow is NSPanel
        {
            return event
        }

        let button = statusButton ?? buttonProvider()
        let clickedButton =
            button.map {
                $0.window?.convertToScreen($0.convert($0.bounds, to: nil)).contains(screenPoint) == true
            } ?? false
        if clickedButton { return event }  // Let the status item toggle normally.
        dismiss()
        return event  // The click still reaches the menu bar or other window.
    }

    func mainWindowBecameKey(_ candidate: NSWindow) {
        guard candidate !== window, candidate.canBecomeMain, !isRelatedWindow(candidate) else { return }
        dismiss()
    }

    private func isRelatedWindow(_ candidate: NSWindow) -> Bool {
        var parent: NSWindow? = candidate
        while let current = parent {
            if current === window { return true }
            parent = current.parent
        }
        return false
    }

    /// Mousü has one status item. Discover its public NSStatusBarButton view,
    /// without private class names, selectors, or key-value lookups.
    static func findStatusButton() -> NSStatusBarButton? {
        func buttons(in view: NSView) -> [NSStatusBarButton] {
            if let button = view as? NSStatusBarButton { return [button] }
            return view.subviews.flatMap { buttons(in: $0) }
        }
        let buttons = NSApp.windows.flatMap { $0.contentView.map { buttons(in: $0) } ?? [] }
        return buttons.count == 1 ? buttons.first : nil
    }
}

@MainActor
struct MenuBarPanelDismissal: ViewModifier {
    @State private var reference: MenuPanelWindowReference
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(reference: MenuPanelWindowReference = MenuPanelWindowReference()) {
        _reference = State(initialValue: reference)
    }

    func body(content: Content) -> some View {
        content
            .background(MenuPanelWindowReader(reference: reference, handlesDismissal: true).frame(width: 0, height: 0))
            .environment(\.menuPanelDismissal, reference)
            .onExitCommand { reference.dismiss() }
            .onAppear {
                reference.reduceMotion = reduceMotion
                reference.didShow()
            }
            .onChange(of: reduceMotion) { _, value in reference.reduceMotion = value }
            .onDisappear { reference.didHide() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                reference.dismiss()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willHideNotification)) { _ in
                reference.dismiss()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                if let window = notification.object as? NSWindow { reference.mainWindowBecameKey(window) }
            }
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            ) { _ in
                // Includes Command-Tab back to Mousü. Opening its nonactivating
                // menu panel does not itself activate the application.
                reference.dismiss()
            }
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            ) { _ in reference.dismiss() }
    }
}

private struct MenuPanelDismissalKey: EnvironmentKey {
    static let defaultValue: MenuPanelWindowReference? = nil
}

extension EnvironmentValues {
    var menuPanelDismissal: MenuPanelWindowReference? {
        get { self[MenuPanelDismissalKey.self] }
        set { self[MenuPanelDismissalKey.self] = newValue }
    }
}

@MainActor
struct MenuPanelWindowReader: NSViewRepresentable {
    let reference: MenuPanelWindowReference
    var handlesDismissal = false

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.reference = reference
        view.handlesDismissal = handlesDismissal
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}
    static func dismantleNSView(_ view: ReaderView, coordinator: ()) { view.stop() }

    final class ReaderView: NSView {
        var reference: MenuPanelWindowReference?
        var handlesDismissal = false
        private var localMonitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            reference?.window = window
            guard handlesDismissal, window != nil else { return }
            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let reference = self?.reference else { return event }
                return reference.handleLocalEvent(event)
            }

        }

        func stop() {
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            localMonitor = nil
        }
    }
}
