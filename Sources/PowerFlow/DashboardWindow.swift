import AppKit
import SwiftUI

/// Owns the dashboard window. By default the app is a regular app (Dock tile,
/// Cmd-Tab, menu bar) with the status item alongside. In menu-bar-only mode
/// ("Show in Dock" off) it is `.accessory` and only becomes a regular app while
/// this window is open.
@MainActor
final class DashboardController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let monitor: PowerMonitor

    init(monitor: PowerMonitor) {
        self.monitor = monitor
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: DashboardView(monitor: monitor))
            let w = NSWindow(contentViewController: host)
            w.title = "PowerFlow"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 820, height: 720))
            w.contentMinSize = NSSize(width: 720, height: 600)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("PowerFlowDashboard")
            w.delegate = self
            w.center()
            window = w
        }
        installMainMenuIfNeeded()
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        // Menu-bar-only mode goes back to having no Dock tile; otherwise the app
        // stays a regular app so the Dock tile can reopen the window.
        if !Settings.shared.showInDock { NSApp.setActivationPolicy(.accessory) }
    }

    /// A regular app needs a main menu for Cmd-Q and Cmd-W to work.
    func installMainMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit PowerFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
