import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private var signalSources: [DispatchSourceSignal] = []
    private var didStart = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy would fight the first over the sleep setting: leave without touching it.
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1 {
            exit(0)
        }

        installMainMenu()
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
        model.onUpdate = { [weak statusItem] in statusItem?.refresh() }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        model.start()
        didStart = true
        terminateCleanlyOnSignals()

        // Until an agent is connected Lidless has nothing to watch: start where that is done.
        if model.settings.trackedAgents.isEmpty, !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if didStart { model.shutdown() }
    }

    /// Opening the app again while it runs (Finder, Spotlight) brings up its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: - Settings window

    private func showSettings() {
        refreshSettings()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "Lidless Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// The files behind these settings can change while the window is in the background.
    func windowDidBecomeKey(_ notification: Notification) {
        refreshSettings()
    }

    private func refreshSettings() {
        model.refreshIntegrations()
        model.refreshHelperRule()
        model.refreshLoginItem()
    }

    // MARK: - Plumbing

    /// A menu bar app shows no main menu, but its key equivalents still drive the settings
    /// window: ⌘W, ⌘Q, ⌘C.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Lidless", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem()
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    /// `kill`, logout and Ctrl-C must run the same cleanup as Quit, or sleep could stay disabled.
    private func terminateCleanlyOnSignals() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
