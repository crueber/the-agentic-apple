import SwiftUI
import AppKit
import AgenticCore

/// Settings: General, Agents, Thresholds & Colours, Advanced, About.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: Store
    @ObservedObject var updater: Updater

    var body: some View {
        TabView {
            GeneralPane(settings: settings, updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }
            AgentsPane(settings: settings, store: store)
                .tabItem { Label("Agents", systemImage: "square.stack.3d.up") }
            ThresholdsPane(settings: settings)
                .tabItem { Label("Thresholds", systemImage: "gauge.with.dots.needle.67percent") }
            AdvancedPane(settings: settings, store: store)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 540)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater: Updater
    @State private var loginError = false

    static let intervals: [(Int, String)] = [
        (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes"), (600, "10 minutes"),
        (900, "15 minutes"), (1800, "30 minutes"), (3600, "1 hour"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Menu bar shows", selection: $settings.barStyle) {
                    ForEach(BarStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(styleCaption).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Refresh every", selection: intervalBinding) {
                    ForEach(Self.intervals, id: \.0) { Text($0.1).tag($0.0) }
                    if !Self.intervals.contains(where: { $0.0 == settings.refreshIntervalSec }) {
                        Text("\(settings.refreshIntervalSec) seconds").tag(settings.refreshIntervalSec)
                    }
                }
                Text("Manual refresh (the panel's button, R, or a middle click) is allowed every 30 seconds. Failed reads back off up to 10 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show each agent's local activity", isOn: $settings.showActivity)
            }
            Section {
                Toggle("Launch at login", isOn: loginBinding)
                    .disabled(!LoginItem.isAvailable)
                if !LoginItem.isAvailable {
                    Text("Available once The Agentic Apple is in your Applications folder.").font(.caption).foregroundStyle(.secondary)
                } else if LoginItem.needsApproval {
                    Text("Approve it in System Settings › General › Login Items.").font(.caption).foregroundStyle(.secondary)
                }
            }
            UpdatesSection(settings: settings, updater: updater)
        }
        .formStyle(.grouped)
    }

    private var styleCaption: String {
        switch settings.barStyle {
        case .bars: return "Each agent's mark with up to three tiny limit meters."
        case .text: return "Each agent's mark with its short percentages."
        case .icon: return "Marks only; the panel has the numbers."
        }
    }

    private var intervalBinding: Binding<Int> {
        Binding(get: { settings.refreshIntervalSec }, set: { settings.refreshIntervalSec = $0 })
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { settings.launchAtLogin },
                set: { settings.launchAtLogin = LoginItem.set($0) })
    }
}

// MARK: - Updates

private struct UpdatesSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater: Updater

    var body: some View {
        Section {
            Toggle("Install updates automatically", isOn: $settings.autoUpdate)
                .disabled(!updater.isSupported || !updater.isConfigured)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(updater.statusText(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let page = updater.releasePage {
                    Link("Release Page", destination: page).font(.caption)
                }
                Spacer(minLength: 4)
                if updater.offersInstall {
                    Button("Install Now") { updater.installPending() }
                }
                Button("Check for Updates Now") { updater.checkNow() }
                    .disabled(!updater.canCheck)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Updates come from this app's GitHub releases and are installed only when their signature verifies.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Agents

private struct AgentsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: Store

    private var fullOrder: [ProviderID] {
        var ids = Ordering.parseOrder(settings.providerOrder)
        for id in ProviderID.defaultOrder where !ids.contains(id) { ids.append(id) }
        return ids
    }

    var body: some View {
        Form {
            Section {
                List {
                    ForEach(fullOrder, id: \.self) { id in
                        AgentRow(id: id, provider: store.providers.first { $0.id == id && $0.available },
                                 shown: Binding(get: { settings.isShown(id) }, set: { settings.setShown(id, $0) }))
                    }
                    .onMove { from, to in
                        var ids = fullOrder
                        ids.move(fromOffsets: from, toOffset: to)
                        settings.providerOrder = Ordering.serializeOrder(ids)
                    }
                }
                .frame(minHeight: 230)
            } header: {
                Text("Order and menu bar")
            } footer: {
                HStack {
                    Text("Drag to reorder. Agents with no plan, key or usage on this Mac stay out of the bar automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Order") { settings.providerOrder = "" }
                        .disabled(settings.providerOrder.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentRow: View {
    let id: ProviderID
    let provider: Provider?
    @Binding var shown: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).font(.system(size: 11))
            ProviderMark(id, size: 16).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(id.displayName)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("Show \(id.displayName)", isOn: $shown)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        guard let p = provider else { return "Not detected on this Mac" }
        return [p.tier, p.status].filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty("Detected")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: - Thresholds & colours

private struct ThresholdsPane: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            Section("Thresholds") {
                LabeledContent("Warning at") {
                    HStack {
                        Slider(value: percentBinding(\.warnPercent), in: 0...100, step: 1)
                        Text("\(settings.warnPercent)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("Critical at") {
                    HStack {
                        Slider(value: percentBinding(\.criticalPercent), in: 0...100, step: 1)
                        Text("\(settings.criticalPercent)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Text("A window the source marks as limited is always critical. OpenRouter turns yellow when this cycle is over the previous one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Colours") {
                colorRow("Warning", hex: $settings.warningColor, state: .warning)
                colorRow("Critical", hex: $settings.criticalColor, state: .critical)
                Text("Agent marks always use the menu bar's own colour.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preview") {
                HStack(spacing: 14) {
                    ForEach(Array([50.0, Double(settings.warnPercent), Double(settings.criticalPercent)].enumerated()), id: \.offset) { _, p in
                        let st = Meters.stateOf(p, warn: Double(settings.warnPercent), critical: Double(settings.criticalPercent))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Format.percentText(p)).font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(palette.color(st, scheme))
                            MeterBar(percent: p, color: palette.color(st, scheme))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var palette: Palette {
        Palette(warningHex: settings.warningColor.isEmpty ? nil : settings.warningColor,
                criticalHex: settings.criticalColor.isEmpty ? nil : settings.criticalColor)
    }

    private func percentBinding(_ key: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(settings[keyPath: key]) }, set: { settings[keyPath: key] = Int($0.rounded()) })
    }

    private func colorRow(_ title: String, hex: Binding<String>, state: MeterState) -> some View {
        LabeledContent(title) {
            HStack {
                if hex.wrappedValue.isEmpty {
                    Text("System default").font(.caption).foregroundStyle(.secondary)
                }
                ColorPicker(title, selection: Binding(
                    get: { Color(hex: hex.wrappedValue) ?? Palette().color(state, scheme) },
                    set: { hex.wrappedValue = $0.hexString }), supportsOpacity: false)
                    .labelsHidden()
                Button("Use Default") { hex.wrappedValue = "" }
                    .disabled(hex.wrappedValue.isEmpty)
            }
        }
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: Store
    @State private var cleared = false

    var body: some View {
        Form {
            OpenRouterKeySection(settings: settings, store: store)
            Section {
                PathField(title: "opencode", text: $settings.opencodeCommand, placeholder: "opencode on the login PATH")
                PathField(title: "codex", text: $settings.codexCommand, placeholder: "codex on the login PATH")
            } header: {
                Text("Commands")
            } footer: {
                Text("Leave empty to find each tool on your login shell's PATH (plus Homebrew, mise and ~/.local/bin).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Locations") {
                PathField(title: "Grok home", text: $settings.grokHome, placeholder: "~/.grok", directory: true)
                PathField(title: "Grok Bot cache", text: $settings.botHome, placeholder: "Grok Bot's app cache", directory: true)
                PathField(title: "OpenCode auth file", text: $settings.authFile, placeholder: "for the OpenRouter key (OpenCode 1)")
            }
            Section {
                HStack {
                    Button("Reveal Cache in Finder") {
                        let url = store.cacheURL
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(url.deletingLastPathComponent().deletingLastPathComponent())
                        }
                    }
                    Button("Clear Cache") {
                        store.clearCache()
                        cleared = true
                    }
                    if cleared { Text("Cleared").font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Cache")
            } footer: {
                Text("Displayed numbers, reset times and OpenRouter's previous-cycle baseline. No keys, prompts or tokens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// OpenRouter management key: stored only in the login Keychain. The field is
/// cleared after Save and the key is never shown again.
private struct OpenRouterKeySection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: Store
    @State private var draft = ""
    @State private var saved = ManagementKeyStore.isSaved()
    @State private var message = ""
    @State private var messageIsError = false
    @State private var working = false

    var body: some View {
        Section {
            LabeledContent("Management key") {
                HStack(spacing: 6) {
                    SecureField("Management key", text: $draft,
                                prompt: Text(saved ? "\u{2022}\u{2022}\u{2022}\u{2022} saved" : "sk-or-v1-…"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { save() }
                    Button("Save") { save() }
                        .disabled(working || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove") { remove() }
                        .disabled(working || !saved)
                }
            }
            Stepper(value: $settings.openrouterKeyRows, in: 0...12) {
                LabeledContent("Show the top \(settings.openrouterKeyRows) keys") {
                    Text(settings.openrouterKeyRows == 0 ? "none" : "by spend this month")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                if working { ProgressView().controlSize(.small) }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(messageIsError ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.managementKeyInEnvironment {
                Text("OPENROUTER_MANAGEMENT_KEY is set in your shell and is used instead of the saved key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("OpenRouter")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("With a management key, OpenRouter's meters, spend and credits cover every key on the account. It is kept only in your login Keychain, never in settings or the cache.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let page = URL(string: OpenRouterCollector.managementKeysPage) {
                    Link("Create a management key", destination: page).font(.caption)
                }
            }
        }
    }

    private var statusText: String {
        if !message.isEmpty { return message }
        return saved ? "Saved in Keychain" : "Not set \u{2014} using the per-key view"
    }

    private func save() {
        let candidate = draft
        if let problem = OpenRouterCollector.managementKeyProblem(candidate) {
            message = problem
            messageIsError = true
            return
        }
        working = true
        message = ""
        Task { @MainActor in
            // Keychain write and verification both run off the main thread.
            let stored: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try ManagementKeyStore.save(candidate); return nil }
                catch { return String(describing: error) }
            }.value
            draft = ""
            saved = ManagementKeyStore.isSaved()
            if let stored {
                working = false
                message = stored
                messageIsError = true
                return
            }
            store.refreshAfterCredentialChange()
            let check = await Task.detached(priority: .userInitiated) {
                await OpenRouterCollector.verifyManagementKey(candidate, http: .live)
            }.value
            working = false
            message = "Saved in Keychain \u{00B7} " + check.message
            messageIsError = !check.ok
        }
    }

    private func remove() {
        working = true
        Task { @MainActor in
            let failure: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try ManagementKeyStore.remove(); return nil }
                catch { return String(describing: error) }
            }.value
            working = false
            draft = ""
            saved = ManagementKeyStore.isSaved()
            message = failure ?? ""
            messageIsError = failure != nil
            store.refreshAfterCredentialChange()
        }
    }
}

private struct PathField: View {
    let title: String
    @Binding var text: String
    var placeholder: String
    var directory = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, text: $text, prompt: Text(placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Button("Choose…") { choose() }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url { text = url.path }
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            AgentMetersGlyph(size: 54)
            Text(AppInfo.name).font(.title2.weight(.semibold))
            Text("Version \(AppInfo.version)").foregroundStyle(.secondary).monospacedDigit()
            Text("OpenRouter, OpenCode, Grok, Codex and Claude limits in the menu bar.\nA port of the Omarchy plugin Agent Meters.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
            Link("github.com/crueber/the-agentic-apple", destination: AppInfo.repoURL)
            Spacer()
            Text("MIT License. Product names and marks belong to their owners.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
