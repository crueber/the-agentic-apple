import Foundation

/// The release feed: GitHub's "latest release" for this repository.
///
/// Public API:
/// - `UpdateFeed.feedURL`, `UpdateFeed.releasesURL`, `UpdateFeed.dmgName(_:)`, `UpdateFeed.signatureName(_:)`
/// - `UpdateFeed.parse(_:currentVersion:) -> UpdateCheckResult`
/// - `UpdateFeed.fetch(http:feedURL:currentVersion:) async -> Result<UpdateCheckResult, UpdateError>`
/// - `UpdatePolicy.isAllowedDownloadURL(_:)` — HTTPS on github.com / *.githubusercontent.com only
///
/// Feed contract: `GET https://api.github.com/repos/crueber/the-agentic-apple/releases/latest`
/// with `Accept: application/vnd.github+json`. A release qualifies when it is
/// neither a draft nor a prerelease, its tag ("v0.2.0") is a plain numeric
/// version strictly newer than the running one, and it carries both
/// `The-Agentic-Apple-<version>.dmg` and `The-Agentic-Apple-<version>.dmg.sig`.
public enum UpdateFeed {
    public static let repository = "crueber/the-agentic-apple"
    public static let feedURL = "https://api.github.com/repos/\(repository)/releases/latest"
    public static let releasesURL = URL(string: "https://github.com/\(repository)/releases/latest")!
    public static let userAgent = "TheAgenticApple-Updater"
    public static let headers = ["Accept": "application/vnd.github+json", "User-Agent": userAgent]

    /// Hard caps, whatever the feed declares.
    public static let maxDMGBytes = 64 * 1024 * 1024
    public static let maxSignatureBytes = 4096

    public static func dmgName(_ v: UpdateVersion) -> String { "The-Agentic-Apple-\(v.text).dmg" }
    public static func signatureName(_ v: UpdateVersion) -> String { dmgName(v) + ".sig" }

    /// Classify a feed body. Never throws: anything unusable is `.upToDate` or `.rejected`.
    public static func parse(_ body: Data, currentVersion: String) -> UpdateCheckResult {
        guard let json = Sanitize.jsonObject(body) else { return .rejected("The release feed could not be read") }
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return .upToDate }
        guard let tag = json["tag_name"] as? String, let version = UpdateVersion(tag) else {
            return .rejected("The latest release has no usable version number")
        }
        guard let current = UpdateVersion(currentVersion) else { return .rejected("This copy's version is unknown") }
        guard version > current else { return .upToDate }

        let assets = (json["assets"] as? [[String: Any]]) ?? []
        func asset(_ name: String, cap: Int) -> UpdateAsset? {
            let matches = assets.filter { ($0["name"] as? String) == name }
            guard matches.count == 1, let a = matches.first,
                  let raw = a["browser_download_url"] as? String, let url = URL(string: raw),
                  UpdatePolicy.isAllowedDownloadURL(url) else { return nil }
            let size = (a["size"] as? NSNumber)?.intValue ?? 0
            guard size > 0, size <= cap else { return nil }
            return UpdateAsset(name: name, url: url, size: size)
        }
        guard let dmg = asset(dmgName(version), cap: maxDMGBytes) else {
            return .rejected("Release \(version) has no usable disk image")
        }
        guard let sig = asset(signatureName(version), cap: maxSignatureBytes) else {
            return .rejected("Release \(version) is not signed, so it will not be installed")
        }
        var page = releasesURL
        if let raw = json["html_url"] as? String, let url = URL(string: raw), url.scheme == "https",
           url.host?.lowercased() == "github.com", url.path.hasPrefix("/\(repository)/releases/") {
            page = url
        }
        return .available(UpdateRelease(version: version, pageURL: page, dmg: dmg, signature: sig))
    }

    /// Fetch and classify the feed. A 404 means the repository has no release yet.
    public static func fetch(http: HTTPClient, feedURL: String = UpdateFeed.feedURL,
                             currentVersion: String) async -> Result<UpdateCheckResult, UpdateError> {
        let response: HTTPResponse
        do {
            response = try await http.get(feedURL, headers)
        } catch {
            return .failure(.network("Could not reach GitHub"))
        }
        switch response.status {
        case 200: return .success(parse(response.body, currentVersion: currentVersion))
        case 404: return .success(.upToDate)
        case 403, 429: return .failure(.network("GitHub is limiting requests; will try again later"))
        default: return .failure(.network("GitHub answered \(response.status)"))
        }
    }
}

public struct UpdateAsset: Sendable, Equatable {
    public var name: String
    public var url: URL
    public var size: Int
    public init(name: String, url: URL, size: Int) {
        self.name = name
        self.url = url
        self.size = size
    }
}

public struct UpdateRelease: Sendable, Equatable {
    public var version: UpdateVersion
    public var pageURL: URL
    public var dmg: UpdateAsset
    public var signature: UpdateAsset
    public init(version: UpdateVersion, pageURL: URL, dmg: UpdateAsset, signature: UpdateAsset) {
        self.version = version
        self.pageURL = pageURL
        self.dmg = dmg
        self.signature = signature
    }
}

public enum UpdateCheckResult: Sendable, Equatable {
    case upToDate
    case available(UpdateRelease)
    /// A newer release exists but cannot be installed (no signature, bad assets, …).
    case rejected(String)
}

/// Every updater failure, in words fit for the Settings status line.
public enum UpdateError: Error, Sendable, Equatable, CustomStringConvertible {
    case notConfigured
    case network(String)
    case download(String)
    case badSignature
    case badImage(String)
    case badBundle(String)
    case install(String)

    public var description: String {
        switch self {
        case .notConfigured: return "Updates not configured"
        case .network(let m), .download(let m), .badImage(let m), .badBundle(let m), .install(let m): return m
        case .badSignature: return "The download's signature did not verify; nothing was installed"
        }
    }
}

public enum UpdatePolicy {
    /// HTTPS to github.com or a *.githubusercontent.com host, default port, no credentials.
    public static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        guard url.user == nil, url.password == nil else { return false }
        if let port = url.port, port != 443 { return false }
        return host == "github.com" || (host.hasSuffix(".githubusercontent.com") && host.count > ".githubusercontent.com".count)
    }
}
