import AppKit
import SwiftUI

/// Hosts SettingsView in a regular titled window (the app is an accessory, so
/// the window is brought forward explicitly).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(settings: AppSettings, store: Store, updater: Updater) {
        let controller = NSHostingController(rootView: SettingsView(settings: settings, store: store, updater: updater))
        let window = NSWindow(contentViewController: controller)
        window.title = "\(AppInfo.name) Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AgenticAppleSettings")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
