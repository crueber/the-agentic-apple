import AppKit
import SwiftUI
import Combine
import AgenticCore

/// A hosting view that never takes the mouse, so clicks reach the status button.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The live bar: re-renders whenever the store or settings change.
struct LiveBar: View {
    @ObservedObject var store: Store
    var body: some View { BarView(state: store.display) }
}

/// The live panel.
struct LivePanel: View {
    @ObservedObject var store: Store
    let actions: PanelActions
    var body: some View {
        let maxHeight = max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 120)
        PanelView(state: store.display, actions: actions, scrollable: true, maxHeight: maxHeight)
    }
}

/// Owns the NSStatusItem, its SwiftUI content, the panel popover and the
/// right-click menu. Left click toggles the panel, right click (or ⌃-click)
/// opens the menu, middle click refreshes.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let store: Store
    private let statusItem: NSStatusItem
    private let hosting: PassthroughHostingView<LiveBar>
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var lastSize: CGSize = .zero
    private var lastClosed = Date.distantPast

    var openSettings: () -> Void = {}
    var showAbout: () -> Void = {}
    var toggleLaunchAtLogin: () -> Void = {}
    var launchAtLoginState: () -> (available: Bool, enabled: Bool) = { (false, false) }
    var checkForUpdates: () -> Void = {}
    var canCheckForUpdates: () -> Bool = { false }

    static let sidePadding: CGFloat = 5

    init(store: Store) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hosting = PassthroughHostingView(rootView: LiveBar(store: store))
        super.init()
        statusItem.autosaveName = "AgenticAppleStatusItem"
        statusItem.behavior = []

        if let button = statusItem.button {
            button.title = ""
            button.image = nil
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.addSubview(hosting)
            button.setAccessibilityLabel(AppInfo.name)
            button.setAccessibilityRole(.menuButton)
        }
        hosting.translatesAutoresizingMaskIntoConstraints = true
        if #available(macOS 13.0, *) { hosting.sizingOptions = [.intrinsicContentSize] }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let controller = NSHostingController(rootView: LivePanel(store: store, actions: panelActions))
        if #available(macOS 13.0, *) { controller.sizingOptions = [.preferredContentSize] }
        popover.contentViewController = controller

        // Middle click: status buttons don't reliably send otherMouseUp actions,
        // so watch for it on the button's own window.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self, let window = self.statusItem.button?.window, event.window === window else { return event }
            self.store.refreshNow()
            return nil
        }

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshItem() }
            .store(in: &cancellables)
        refreshItem()
    }

    private var panelActions: PanelActions {
        PanelActions(
            refresh: { [weak self] in self?.store.refreshNow() },
            setShown: { [weak self] id, shown in self?.store.setShown(id, shown) },
            reorder: { [weak self] id, index in self?.store.reorder(id, to: index) },
            openSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.openSettings()
            })
    }

    /// Re-measure the SwiftUI content, size the item to it, update tooltip and accessibility.
    private func refreshItem() {
        guard let button = statusItem.button else { return }
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        let width = ceil(fit.width) + Self.sidePadding * 2
        if abs(width - statusItem.length) > 0.5 { statusItem.length = width }
        let height = button.bounds.height > 0 ? button.bounds.height : NSStatusBar.system.thickness
        hosting.frame = NSRect(x: Self.sidePadding, y: floor((height - fit.height) / 2),
                               width: ceil(fit.width), height: ceil(fit.height))
        let state = store.display
        button.toolTip = state.tooltip
        let lines = state.textLines
        button.setAccessibilityValue(lines.isEmpty ? Summary.noAgents : lines.joined(separator: "; "))
        // Re-run once the item has its final size (first layout, display changes).
        if fit != lastSize {
            lastSize = fit
            DispatchQueue.main.async { [weak self] in self?.refreshItem() }
        }
    }

    // MARK: clicks

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { togglePanel(); return }
        let isRight = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        if isRight { showMenu() } else { togglePanel() }
    }

    func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        // A transient popover closes on mouse-down; don't reopen it on the same click's mouse-up.
        if Date().timeIntervalSince(lastClosed) < 0.25 { return }
        showPanel()
    }

    func showPanel() {
        guard let button = statusItem.button else { return }
        store.panelOpened()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
        installKeyMonitor()
    }

    func closePanel() { popover.performClose(nil) }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.keyCode == 53 { self.popover.performClose(nil); return nil }   // Esc
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            if mods.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "r" {
                self.store.refreshNow()
                return nil
            }
            if mods == .command, event.charactersIgnoringModifiers == "," {
                self.popover.performClose(nil); self.openSettings(); return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            removeKeyMonitor()
            lastClosed = Date()
            statusItem.button?.highlight(false)
            store.panelClosed()
        }
    }

    // MARK: menu

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(menuRefresh), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !store.busy && !store.refreshCoolingDown
        if store.refreshCoolingDown { refresh.toolTip = "Refreshed just now — available again shortly" }
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(menuLogin), keyEquivalent: "")
        login.target = self
        let ls = launchAtLoginState()
        login.state = ls.enabled ? .on : .off
        login.isEnabled = ls.available
        if !ls.available { login.toolTip = "Available when running The Agentic Apple.app" }
        menu.addItem(login)
        menu.addItem(.separator())
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(menuCheckUpdates), keyEquivalent: "")
        updates.target = self
        updates.isEnabled = canCheckForUpdates()
        if !AppInfo.isBundled { updates.toolTip = "Available when running The Agentic Apple.app" }
        menu.addItem(updates)
        let about = NSMenuItem(title: "About \(AppInfo.name)", action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        if popover.isShown { popover.performClose(nil) }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuRefresh() { store.refreshNow() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuAbout() { showAbout() }
    @objc private func menuCheckUpdates() { checkForUpdates() }
    @objc private func menuLogin() { toggleLaunchAtLogin() }
}
