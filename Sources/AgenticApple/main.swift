import AppKit
import AgenticCore

// CLI modes (--text, --json, --render-preview, --help, --version) never start the UI.
if let exitCode = CLI.run(Array(CommandLine.arguments.dropFirst())) { exit(exitCode) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
