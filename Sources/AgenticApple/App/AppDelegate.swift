import AppKit
import SwiftUI
import AgenticCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var store: Store!
    private var statusController: StatusItemController!
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: a second copy hands over to the first and quits.
        if AppInfo.isBundled {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        installMainMenu()
        settings = AppSettings()
        if LoginItem.isAvailable { settings.launchAtLogin = LoginItem.isEnabled }
        store = Store(settings: settings)
        statusController = StatusItemController(store: store)
        statusController.openSettings = { [weak self] in self?.showSettings() }
        statusController.showAbout = { [weak self] in self?.showAbout() }
        statusController.toggleLaunchAtLogin = { [weak self] in
            guard let self else { return }
            self.settings.launchAtLogin = LoginItem.set(!LoginItem.isEnabled)
        }
        statusController.launchAtLoginState = { (LoginItem.isAvailable, LoginItem.isEnabled) }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.didWake() }
        }
        store.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusController?.showPanel()
        return false
    }

    /// An accessory app has no menu bar of its own, but key equivalents still go
    /// through `NSApp.mainMenu`: without one, ⌘C/⌘V/⌘A/⌘Z/⌘X do nothing in the
    /// Settings text fields and ⌘W does not close the window.
    private func installMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu(title: AppInfo.name)
        appMenu.addItem(withTitle: "About \(AppInfo.name)", action: #selector(aboutFromMenu(_:)), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(settingsFromMenu(_:)), keyEquivalent: ",")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: AppInfo.name, action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    @objc private func aboutFromMenu(_ sender: Any?) { showAbout() }
    @objc private func settingsFromMenu(_ sender: Any?) { showSettings() }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings, store: store)
        }
        settingsWindow?.show()
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(
            string: "AI agent limits in the menu bar.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(
            string: "github.com/crueber/the-agentic-apple",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: AppInfo.repoURL]))
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        credits.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .version: AppInfo.build,
            .credits: credits,
            .applicationIcon: Self.aboutIcon(),
        ])
    }

    /// The robot glyph as an icon when the bundle has none.
    static func aboutIcon() -> NSImage {
        if let icon = NSApp.applicationIconImage, AppInfo.isBundled,
           Bundle.main.path(forResource: "AppIcon", ofType: "icns") != nil { return icon }
        let renderer = ImageRenderer(content:
            AgentMetersGlyph(size: 56)
                .foregroundStyle(Color.white)
                .frame(width: 96, height: 96)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.25, blue: 0.3), Color(red: 0.1, green: 0.1, blue: 0.12)],
                                         startPoint: .top, endPoint: .bottom))))
        renderer.scale = 2
        return renderer.nsImage ?? NSImage()
    }
}
