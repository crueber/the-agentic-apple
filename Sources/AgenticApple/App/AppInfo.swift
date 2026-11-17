import Foundation
import AgenticCore

/// Identity shared by the app, the CLI and the preview renderer.
enum AppInfo {
    static let name = "The Agentic Apple"
    static let bundleID = "com.crueber.agentic-apple"
    static let repoURL = URL(string: "https://github.com/crueber/the-agentic-apple")!
    /// Fallback when running unbundled (`swift run`); keep in step with VERSION.
    static let fallbackVersion = "1.0.0"

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? fallbackVersion
    }

    static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "dev"
    }

    /// True when running from "The Agentic Apple.app" (not `swift run`).
    static var isBundled: Bool {
        Bundle.main.bundleIdentifier == bundleID && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// The defaults domain. Unbundled runs (`swift run … --text`) would otherwise
    /// read a different domain from the app; a suite named after the main bundle's
    /// own id is rejected, so the bundled app uses `.standard`.
    static let defaults: UserDefaults = {
        if Bundle.main.bundleIdentifier == bundleID { return .standard }
        return UserDefaults(suiteName: bundleID) ?? .standard
    }()

    static var cacheURL: URL { UsageCache.defaultURL() }
    static var cacheDir: URL { cacheURL.deletingLastPathComponent() }
}
