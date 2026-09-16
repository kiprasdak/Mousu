import AppKit
import SwiftUI

@main
@MainActor
struct MousuApp: App {
    @NSApplicationDelegateAdaptor(MousuAppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Available even when no window or menu panel has been shown yet.
        let _ = MainWindowPresentation.shared.registerOpener { openWindow(id: "main") }
        Window("Mousü", id: "main") {
            MainView(model: model)
                .background(MainWindowPresence(hideDockWhenClosed: model.hideDockWhenClosed))
        }
        .defaultSize(
            width: model.requiresSetup ? MainWindowSize.intro.width : MainWindowSize.main.width,
            height: model.requiresSetup ? MainWindowSize.intro.height : MainWindowSize.main.height
        )
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    MousuAppDelegate.showMainWindow()
                    model.settingsPresented = true
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(model.requiresSetup || model.settingsPresented)
            }
            CommandGroup(after: .appInfo) {
                Button(model.paused ? "Resume All Devices" : "Pause All Devices") {
                    model.paused.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.requiresSetup)
            }
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra(isInserted: $model.menuBarVisible) {
            MenuPanel(model: model)
                .modifier(MenuBarPanelDismissal())
        } label: {
            Image(nsImage: MenuBarIcon.image(paused: model.paused))
                .accessibilityLabel(model.paused ? "Mousü paused" : "Mousü")
        }
        .menuBarExtraStyle(.window)
    }

}

@MainActor
final class MousuAppDelegate: NSObject, NSApplicationDelegate {
    static func showMainWindow(on screen: NSScreen? = nil) {
        MainWindowPresentation.shared.show(on: screen)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let atLogin = AppLaunch.isLoginItem(NSAppleEventManager.shared().currentAppleEvent)
        AppPresence.shared.configureLaunch(atLogin: atLogin, hideDockWhenClosed: AppModel.shared.hideDockWhenClosed)
        AppIcon.update(paused: AppModel.shared.paused)
        if !atLogin { Self.showMainWindow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showMainWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let failure = AppModel.shared.prepareToQuit() else { return .terminateNow }
        Self.showMainWindow()
        let alert = NSAlert()
        alert.messageText = "Quit anyway?"
        alert.informativeText = failure
        alert.addButton(withTitle: "Keep open")
        alert.addButton(withTitle: "Quit anyway")
        if alert.runModal() == .alertSecondButtonReturn { return .terminateNow }
        AppModel.shared.cancelQuit()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}
