import Foundation

/// Antigravity OAuth credentials, read-only. Never refreshed, written back,
/// cached, logged, printed or passed on a command line.
public struct AntigravityCredentials: Sendable, Equatable {
    public var accessToken: String
    /// Epoch ms; 0 when unknown (treated as not expired).
    public var expiresAt: Double
    /// Whether a refresh token is present (only used to tell "Limits paused"
    /// apart from "Sign-in expired"; the refresh token itself is never kept).
    public var hasRefreshToken: Bool
    /// Where it came from: "keychain" or "credentials-file".
    public var source: String

    public init(accessToken: String, expiresAt: Double = 0, hasRefreshToken: Bool = false, source: String = "") {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.hasRefreshToken = hasRefreshToken
        self.source = source
    }

    /// Parse JSON credentials (`oauth_creds.json` or Keychain JSON, including
    /// `go-keyring-base64:` and hex-encoded `security -w` blobs) or a bare
    /// OAuth2 bearer token (`ya29.…`). nil when unreadable or empty.
    public static func parse(_ data: Data?, source: String) -> AntigravityCredentials? {
        guard let data, !data.isEmpty else { return nil }
        let decoded = unwrapKeychainEncoding(data)
        if let root = Sanitize.jsonObject(decoded) {
            let box = (root["oauth_creds"] as? [String: Any])
                ?? (root["credentials"] as? [String: Any])
                ?? (root["token"] as? [String: Any])
                ?? root
            let token = nonEmptyString(box["access_token"])
                ?? nonEmptyString(box["accessToken"])
                ?? nonEmptyString(box["token"])
                ?? ""
            let refresh = nonEmptyString(box["refresh_token"])
                ?? nonEmptyString(box["refreshToken"])
                ?? ""
            guard !token.isEmpty || !refresh.isEmpty else { return nil }
            let expiresAt = parseExpiry(box["expiry_date"])
                ?? parseExpiry(box["expiresAt"])
                ?? parseExpiry(box["expires_at"])
                ?? parseExpiry(box["expiry"])
                ?? 0
            return AntigravityCredentials(accessToken: token, expiresAt: expiresAt,
                                          hasRefreshToken: !refresh.isEmpty, source: source)
        }
        let raw = String(decoding: decoded, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("ya29."), !raw.contains(where: \.isWhitespace), raw.count <= 4096 else { return nil }
        return AntigravityCredentials(accessToken: raw, expiresAt: 0, hasRefreshToken: false, source: source)
    }

    /// Unwrap `go-keyring-base64:<b64>` (used by Antigravity CLI's Go keyring)
    /// and hex-encoded output from `/usr/bin/security … -w` when a Keychain
    /// item contains newlines or non-ASCII bytes.
    static func unwrapKeychainEncoding(_ data: Data) -> Data {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if trimmed.hasPrefix(prefix) {
            let b64 = String(trimmed.dropFirst(prefix.count))
            if let decoded = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]), !decoded.isEmpty {
                return decoded
            }
        }
        if trimmed.count >= 4, trimmed.count % 2 == 0,
           trimmed.allSatisfy({ $0.isHexDigit }) {
            var bytes = Data(capacity: trimmed.count / 2)
            var idx = trimmed.startIndex
            while idx < trimmed.endIndex {
                let next = trimmed.index(idx, offsetBy: 2)
                if let b = UInt8(trimmed[idx..<next], radix: 16) {
                    bytes.append(b)
                } else {
                    return data
                }
                idx = next
            }
            if !bytes.isEmpty { return unwrapKeychainEncoding(bytes) }
        }
        return data
    }

    /// Of two credentials, the one with the later expiry (preferring a non-empty access token).
    public static func newest(_ a: AntigravityCredentials?, _ b: AntigravityCredentials?) -> AntigravityCredentials? {
        guard let a else { return b }
        guard let b else { return a }
        if a.accessToken.isEmpty != b.accessToken.isEmpty { return a.accessToken.isEmpty ? b : a }
        return b.expiresAt > a.expiresAt ? b : a
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseExpiry(_ value: Any?) -> Double? {
        let ms = Sanitize.dateMs(value)
        return ms > 0 ? ms : nil
    }
}

/// One running Antigravity language server discovered on this Mac.
public struct AntigravityServerProcess: Sendable, Equatable {
    public var pid: Int32
    /// Ephemeral per-process CSRF nonce; sent only in `X-Codeium-Csrf-Token` to 127.0.0.1.
    public var csrfToken: String
    /// Candidate loopback TCP ports (from `lsof`, plus `--extension_server_port` / `--https_server_port`).
    public var ports: [Int]
    public var appDataDir: String

    public init(pid: Int32, csrfToken: String, ports: [Int], appDataDir: String = "") {
        self.pid = pid
        self.csrfToken = csrfToken
        self.ports = ports
        self.appDataDir = appDataDir
    }
}

/// Antigravity collector:
///
/// 1. Local running Antigravity language server (`language_server_macos*` for
///    Antigravity IDE, Desktop App 2.0 or CLI): discovered via `/bin/ps` and
///    `/usr/sbin/lsof`, queried over loopback (`127.0.0.1`) Connect-RPC using
///    `GetUserStatus`, `RetrieveUserQuotaSummary` and `GetCommandModelConfigs`
///    (no Keychain prompt while Antigravity is running).
/// 2. Read-only OAuth fallback when no local language server answers and
///    Antigravity is installed on this Mac: reads the Keychain item
///    `gemini` / `antigravity` via `/usr/bin/security … -w` or local
///    `oauth_creds.json` under `~/.gemini/antigravity*` (or `ANTIGRAVITY_HOME`),
///    and queries `https://daily-cloudcode-pa.googleapis.com`
///    (`v1internal:loadCodeAssist`, `v1internal:retrieveUserQuotaSummary`,
///    `v1internal:fetchAvailableModels`, `v1internal:retrieveUserQuota`).
///    Tokens are read-only and never refreshed, cached, logged or printed.
public struct AntigravityCollector: ProviderCollector {
    public typealias ProcessDiscoverer = @Sendable (CollectorContext) -> [AntigravityServerProcess]
    public typealias LoopbackPost = @Sendable (_ scheme: String, _ port: Int, _ path: String,
                                               _ headers: [String: String], _ body: Data) async throws -> HTTPResponse
    public typealias CredentialReader = @Sendable (CollectorContext) -> AntigravityCredentials?

    public static let keychainService = "gemini"
    public static let keychainAccount = "antigravity"
    public static let cloudCodeBase = "https://daily-cloudcode-pa.googleapis.com"
    public static let loadCodeAssistEndpoint = cloudCodeBase + "/v1internal:loadCodeAssist"
    public static let quotaSummaryEndpoint = cloudCodeBase + "/v1internal:retrieveUserQuotaSummary"
    public static let fetchModelsEndpoint = cloudCodeBase + "/v1internal:fetchAvailableModels"
    public static let retrieveQuotaEndpoint = cloudCodeBase + "/v1internal:retrieveUserQuota"

    public static let localUserStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    public static let localQuotaSummaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    public static let localCommandModelsPath = "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"

    static let localMetadataBody = Data(
        #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#.utf8
    )
    static let loadCodeAssistBody = Data(
        #"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8
    )

    static let authHelp = "Open Antigravity, or run `antigravity` to sign in."
    static let pausedHelp = "Antigravity's access token has lapsed. Open Antigravity or run `antigravity` to refresh it."
    static let expiredHelp = "Antigravity's saved sign-in expired. Open Antigravity or run `antigravity` to sign in again."
    static let refusedHelp = "Google refused Antigravity's sign-in. Open Antigravity or run `antigravity` to sign in again."
    static let notRunningError = "Antigravity language server is not running"
    static let notRunningHelp = "Open Antigravity (or start `antigravity`) to read live usage."

    public let processDiscoverer: ProcessDiscoverer
    public let loopbackPost: LoopbackPost
    public let credentialReader: CredentialReader

    public init(processDiscoverer: @escaping ProcessDiscoverer = AntigravityCollector.defaultProcessDiscoverer,
                loopbackPost: @escaping LoopbackPost = AntigravityCollector.liveLoopbackPost,
                credentialReader: @escaping CredentialReader = AntigravityCollector.defaultCredentialReader()) {
        self.processDiscoverer = processDiscoverer
        self.loopbackPost = loopbackPost
        self.credentialReader = credentialReader
    }

    public var id: ProviderID { .antigravity }

    // MARK: - Collect

    public func collect(_ context: CollectorContext) async -> Provider {
        var provider = Provider(id: .antigravity, source: "antigravity-local")
        let discoverer = processDiscoverer
        let servers = await Blocking.run { discoverer(context) }

        // 1. Prefer the running local language server: live numbers, zero Keychain prompts.
        if !servers.isEmpty, let local = await probeLocalServers(servers, context: context) {
            return local
        }

        // 2. Fallback: read-only OAuth credentials (only probes Keychain when Antigravity is installed).
        let reader = credentialReader
        let (installed, credentials) = await Blocking.run { () -> (Bool, AntigravityCredentials?) in
            let installed = Self.isInstalled(context)
            let creds = reader(context)
            return (installed, creds)
        }

        if let creds = credentials {
            provider.source = "antigravity-oauth (\(creds.source))"
            provider = await probeCloud(provider, creds: creds, context: context)
            provider.available = !provider.limits.isEmpty || !provider.tier.isEmpty
            return provider
        }

        // Antigravity is present on this Mac, just not running (or Keychain was denied/empty).
        // Reporting an error lets ProviderMerge preserve the last good limits when previously seen,
        // while staying out of the bar (`available = false`) if never seen.
        if installed || !servers.isEmpty {
            provider.status = "Not running"
            provider.hint = Self.notRunningHelp
            provider.error = Self.notRunningError
        }
        return provider
    }

    // MARK: - Local language server discovery & probing

    @Sendable public static func defaultProcessDiscoverer(_ context: CollectorContext) -> [AntigravityServerProcess] {
        let ps = Shell.run("/bin/ps", ["-ww", "-eo", "pid=,args="], timeout: 5)
        guard ps.ok else { return [] }
        let candidates = parseProcessList(ps.stdoutText)
        guard !candidates.isEmpty else { return [] }
        return candidates.compactMap { entry in
            var ports: [Int] = []
            var seen = Set<Int>()
            let lsof = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(entry.pid)], timeout: 5)
            if lsof.ok {
                for p in parseListeningPorts(lsof.stdoutText) where seen.insert(p).inserted {
                    ports.append(p)
                }
            }
            for p in entry.hintPorts where seen.insert(p).inserted {
                ports.append(p)
            }
            guard !ports.isEmpty else { return nil }
            return AntigravityServerProcess(pid: entry.pid, csrfToken: entry.csrfToken,
                                            ports: ports, appDataDir: entry.appDataDir)
        }
    }

    public struct ParsedProcess: Sendable, Equatable {
        public var pid: Int32
        public var csrfToken: String
        public var hintPorts: [Int]
        public var appDataDir: String
    }

    /// Parse `/bin/ps -ww -eo pid=,args=` output for Antigravity language servers.
    public static func parseProcessList(_ output: String) -> [ParsedProcess] {
        var found: [ParsedProcess] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let splitIdx = line.firstIndex(where: \.isWhitespace) else { continue }
            guard let pid = Int32(line[..<splitIdx]), pid > 0 else { continue }
            let cmd = String(line[splitIdx...]).trimmingCharacters(in: .whitespaces)
            let lower = cmd.lowercased()

            let isLanguageServer = lower.contains("language_server_macos")
            let isAntigravity = lower.contains("antigravity")
            guard isAntigravity && (isLanguageServer || lower.contains("--csrf_token")) else { continue }

            let csrf = extractFlag(cmd, names: ["--csrf_token", "--csrf-token"]) ?? ""
            let appDataDir = extractFlag(cmd, names: ["--app_data_dir", "--app-data-dir"]) ?? ""
            var hintPorts: [Int] = []
            for flag in ["--https_server_port", "--server_port", "--extension_server_port", "--extension-server-port"] {
                if let rawPort = extractFlag(cmd, names: [flag]), let port = Int(rawPort), port > 0, port <= 65535,
                   !hintPorts.contains(port) {
                    hintPorts.append(port)
                }
            }
            found.append(ParsedProcess(pid: pid, csrfToken: csrf, hintPorts: hintPorts, appDataDir: appDataDir))
        }
        // Prefer processes with an explicit csrfToken and antigravity app_data_dir.
        return found.sorted { a, b in
            let aScore = (a.csrfToken.isEmpty ? 0 : 2) + (a.appDataDir.lowercased().contains("antigravity") ? 1 : 0)
            let bScore = (b.csrfToken.isEmpty ? 0 : 2) + (b.appDataDir.lowercased().contains("antigravity") ? 1 : 0)
            if aScore != bScore { return aScore > bScore }
            return a.pid < b.pid
        }
    }

    /// Parse `/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>` output for local TCP ports.
    public static func parseListeningPorts(_ output: String) -> [Int] {
        var ports: [Int] = []
        var seen = Set<Int>()
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.contains("(LISTEN)") else { continue }
            for token in line.split(whereSeparator: \.isWhitespace) {
                let s = String(token)
                guard let colon = s.lastIndex(of: ":") else { continue }
                let host = String(s[..<colon])
                let portStr = String(s[s.index(after: colon)...])
                guard host == "127.0.0.1" || host == "[::1]" || host == "localhost" || host == "*" else { continue }
                if let port = Int(portStr), port > 0, port <= 65535, seen.insert(port).inserted {
                    ports.append(port)
                }
            }
        }
        return ports.sorted()
    }

    static func extractFlag(_ cmd: String, names: [String]) -> String? {
        let tokens = tokenize(cmd)
        for (i, tok) in tokens.enumerated() {
            for name in names {
                if tok == name, i + 1 < tokens.count {
                    let next = tokens[i + 1]
                    if !next.hasPrefix("--") { return next }
                } else if tok.hasPrefix(name + "=") {
                    return String(tok.dropFirst(name.count + 1))
                }
            }
        }
        return nil
    }

    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch.isWhitespace {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    func probeLocalServers(_ servers: [AntigravityServerProcess], context: CollectorContext) async -> Provider? {
        for server in servers {
            var headers = [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Connect-Protocol-Version": "1",
            ]
            if !server.csrfToken.isEmpty {
                headers["X-Codeium-Csrf-Token"] = server.csrfToken
            }
            for port in server.ports {
                for scheme in ["https", "http"] {
                    guard let statusResp = try? await loopbackPost(scheme, port, Self.localUserStatusPath,
                                                                   headers, Self.localMetadataBody),
                          (200..<300).contains(statusResp.status),
                          let statusJSON = statusResp.json else { continue }

                    let tier = Self.tierFromUserStatus(statusJSON)
                    var limits: [Limit] = []

                    // Try the newer RetrieveUserQuotaSummary first on the same working port.
                    if let summaryResp = try? await loopbackPost(scheme, port, Self.localQuotaSummaryPath,
                                                                 headers, Self.localMetadataBody),
                       (200..<300).contains(summaryResp.status),
                       let summaryJSON = summaryResp.json {
                        limits = Self.limitsFromQuotaSummary(summaryJSON)
                    }

                    // Fall back to GetUserStatus's own embedded quota summary or clientModelConfigs.
                    if limits.isEmpty {
                        limits = Self.limitsFromUserStatus(statusJSON)
                    }

                    // Last local fallback: GetCommandModelConfigs.
                    if limits.isEmpty,
                       let cmdResp = try? await loopbackPost(scheme, port, Self.localCommandModelsPath,
                                                             headers, Self.localMetadataBody),
                       (200..<300).contains(cmdResp.status),
                       let cmdJSON = cmdResp.json {
                        limits = Self.limitsFromModelConfigs(cmdJSON)
                    }

                    if !limits.isEmpty || !tier.isEmpty {
                        var provider = Provider(id: .antigravity, source: "antigravity-local")
                        provider.tier = tier
                        provider.limits = limits
                        provider.readAt = context.nowMs
                        provider.available = true
                        return provider
                    }
                }
            }
        }
        return nil
    }

    /// Loopback-only HTTP/HTTPS POST for the local language server (`127.0.0.1` ONLY).
    /// Accepts a self-signed certificate strictly for `127.0.0.1`. No redirects, no cookies, 5 s timeout, 1 MB cap.
    @Sendable public static func liveLoopbackPost(_ scheme: String, _ port: Int, _ path: String,
                                                  _ headers: [String: String], _ body: Data) async throws -> HTTPResponse {
        guard (scheme == "https" || scheme == "http"), port > 0, port <= 65535, path.hasPrefix("/") else {
            throw HTTPError.invalidURL
        }
        guard body.count <= HTTPClient.maxRequestBody else { throw HTTPError.tooLarge }
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(path)") else { throw HTTPError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.urlCache = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: LoopbackSessionDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= HTTPClient.maxBody else { throw HTTPError.tooLarge }
            let http = response as? HTTPURLResponse
            var h: [String: String] = [:]
            for (k, v) in http?.allHeaderFields ?? [:] { h[String(describing: k).lowercased()] = String(describing: v) }
            return HTTPResponse(status: http?.statusCode ?? 0, body: data, headers: h)
        } catch let e as HTTPError {
            throw e
        } catch {
            throw HTTPError.transport((error as NSError).localizedDescription)
        }
    }

    // MARK: - Installation & Credentials (read-only)

    static func expand(_ path: String, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }

    /// Configured Antigravity home(s) to check for installation and local credential files.
    static func homeDirectories(_ context: CollectorContext) -> [URL] {
        let explicit = context.antigravityHome.trimmingCharacters(in: .whitespaces)
        if !explicit.isEmpty { return [expand(explicit, home: context.home)] }
        if let env = context.environment["ANTIGRAVITY_HOME"]?.trimmingCharacters(in: .whitespaces), !env.isEmpty {
            return [expand(env, home: context.home)]
        }
        return [
            context.home.appendingPathComponent(".gemini/antigravity-cli"),
            context.home.appendingPathComponent(".gemini/antigravity"),
            context.home.appendingPathComponent("Library/Application Support/Antigravity"),
        ]
    }

    /// Whether Antigravity (CLI, Desktop App, or IDE) is present on this Mac.
    /// Keeps Keychain untouched for users who do not use Antigravity.
    public static func isInstalled(_ context: CollectorContext) -> Bool {
        let fm = FileManager.default
        for dir in homeDirectories(context) {
            if fm.fileExists(atPath: dir.path) { return true }
        }
        for app in [context.home.appendingPathComponent("Applications/Antigravity.app"),
                    URL(fileURLWithPath: "/Applications/Antigravity.app")] {
            if fm.fileExists(atPath: app.path) { return true }
        }
        if Shell.which("antigravity", searchPath: context.searchPath) != nil
            || Shell.which("agy", searchPath: context.searchPath) != nil {
            return true
        }
        return false
    }

    /// Keychain first (only when Antigravity is installed), then local `oauth_creds.json` files.
    /// `keychain` is injectable so tests never touch the real Keychain.
    public static func defaultCredentialReader(keychain: @escaping @Sendable () -> Data? = readKeychain) -> CredentialReader {
        return { context in
            guard isInstalled(context) else { return nil }
            var best = AntigravityCredentials.parse(keychain(), source: "keychain")
            for dir in homeDirectories(context) {
                let file = dir.appendingPathComponent("oauth_creds.json")
                let fromFile = AntigravityCredentials.parse(boundedData(file, max: 256 * 1024), source: "credentials-file")
                best = AntigravityCredentials.newest(best, fromFile)
            }
            return best
        }
    }

    @Sendable public static func readKeychain() -> Data? {
        let r = Shell.run("/usr/bin/security",
                          ["find-generic-password", "-s", keychainService, "-a", keychainAccount, "-w"],
                          timeout: 15)
        guard r.ok else { return nil }
        let text = r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : Data(text.utf8)
    }

    static func boundedData(_ url: URL, max: Int) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue <= max else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Cloud Code OAuth fallback

    func probeCloud(_ start: Provider, creds: AntigravityCredentials, context: CollectorContext) async -> Provider {
        var provider = start
        if creds.accessToken.isEmpty {
            provider.status = "Waiting for auth"
            provider.hint = Self.authHelp
            return provider
        }
        if creds.expiresAt > 0 && creds.expiresAt <= context.nowMs {
            // Never refresh: only Antigravity mints a new token.
            if creds.hasRefreshToken {
                provider.status = "Limits paused"
                provider.hint = Self.pausedHelp
            } else {
                provider.status = "Sign-in expired"
                provider.hint = Self.expiredHelp
            }
            return provider
        }
        guard let post = context.httpClient.post else {
            provider.error = "HTTP client cannot POST"
            return provider
        }

        let headers = [
            "Authorization": "Bearer " + creds.accessToken,
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "antigravity/acp",
        ]

        // 1. Resolve plan tier and companion project (best-effort, unless 401/403).
        var projectID = ""
        do {
            let loadResp = try await post(Self.loadCodeAssistEndpoint, headers, Self.loadCodeAssistBody)
            if loadResp.status == 401 || loadResp.status == 403 {
                provider.status = "Sign-in expired"
                provider.hint = Self.refusedHelp
                return provider
            }
            if loadResp.status == 429 {
                return rateLimited(provider, response: loadResp)
            }
            if (200..<300).contains(loadResp.status), let json = loadResp.json {
                provider.tier = Self.tierFromLoadCodeAssist(json)
                projectID = Self.projectFromLoadCodeAssist(json)
            }
        } catch {
            provider.error = "Couldn't reach Google's Antigravity endpoint"
            provider.hint = "Retrying shortly."
            return provider
        }

        let projectBody: Data
        if projectID.isEmpty {
            projectBody = Data("{}".utf8)
        } else {
            projectBody = (try? JSONSerialization.data(withJSONObject: ["project": projectID])) ?? Data("{}".utf8)
        }

        // 2. Try quota summary, then fetchAvailableModels, then retrieveUserQuota.
        var lastError = ""
        for (endpoint, parser): (String, ([String: Any]) -> [Limit]) in [
            (Self.quotaSummaryEndpoint, Self.limitsFromQuotaSummary),
            (Self.fetchModelsEndpoint, Self.limitsFromFetchAvailableModels),
            (Self.retrieveQuotaEndpoint, Self.limitsFromQuotaSummary),
        ] {
            let response: HTTPResponse
            do {
                response = try await post(endpoint, headers, projectBody)
            } catch {
                lastError = "Couldn't reach Google's Antigravity endpoint"
                continue
            }
            switch response.status {
            case 200..<300:
                if let json = response.json {
                    let limits = parser(json)
                    if !limits.isEmpty {
                        provider.limits = limits
                        provider.readAt = context.nowMs
                        return provider
                    }
                }
            case 401, 403:
                provider.status = "Sign-in expired"
                provider.hint = Self.refusedHelp
                return provider
            case 429:
                return rateLimited(provider, response: response)
            default:
                lastError = "Antigravity's usage endpoint returned status \(response.status)"
            }
        }

        provider.error = lastError.isEmpty ? "Antigravity returned no usage limits" : lastError
        provider.status = "Antigravity limits unavailable"
        return provider
    }

    private func rateLimited(_ start: Provider, response: HTTPResponse) -> Provider {
        var provider = start
        provider.error = "rate limited"
        let retry = Sanitize.number(response.headers["retry-after"]).map { " (retry after \(Int($0))s)" } ?? ""
        provider.hint = "Antigravity's usage endpoint is rate limiting checks right now\(retry)."
        return provider
    }

    // MARK: - Plan labels

    public static func tierFromUserStatus(_ payload: [String: Any]) -> String {
        let userStatus = (payload["userStatus"] as? [String: Any]) ?? payload
        if let userTier = userStatus["userTier"] as? [String: Any] {
            for key in ["name", "displayName", "id"] {
                let raw = Sanitize.text(userTier[key], max: 80)
                if !raw.isEmpty { return planLabel(raw) }
            }
        }
        if let planStatus = userStatus["planStatus"] as? [String: Any],
           let planInfo = planStatus["planInfo"] as? [String: Any] {
            for key in ["planDisplayName", "planName", "teamsTier"] {
                let raw = Sanitize.text(planInfo[key], max: 80)
                if !raw.isEmpty { return planLabel(raw) }
            }
        }
        return ""
    }

    public static func tierFromLoadCodeAssist(_ payload: [String: Any]) -> String {
        for tierKey in ["paidTier", "currentTier"] {
            if let tier = payload[tierKey] as? [String: Any] {
                for field in ["name", "displayName", "id"] {
                    let raw = Sanitize.text(tier[field], max: 80)
                    if !raw.isEmpty { return planLabel(raw) }
                }
            }
        }
        return ""
    }

    static func projectFromLoadCodeAssist(_ payload: [String: Any]) -> String {
        if let s = payload["cloudaicompanionProject"] as? String {
            return Sanitize.text(s, max: 120)
        }
        if let dict = payload["cloudaicompanionProject"] as? [String: Any] {
            return Sanitize.text(dict["id"] ?? dict["name"], max: 120)
        }
        return ""
    }

    static let knownPlans: [String: String] = [
        "free-tier": "Free",
        "standard-tier": "Standard",
        "legacy-tier": "Legacy",
        "g1-plus-tier": "Google AI Plus",
        "g1-pro-tier": "Google AI Pro",
        "g1-ultra-tier": "Google AI Ultra",
        "teams_tier_free": "Free",
        "teams_tier_pro": "Pro",
        "teams_tier_teams": "Teams",
        "teams_tier_enterprise": "Enterprise",
    ]

    public static func planLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let mapped = knownPlans[trimmed.lowercased()] { return mapped }
        if trimmed.hasPrefix("TEAMS_TIER_") {
            let suffix = trimmed.dropFirst("TEAMS_TIER_".count).lowercased().replacingOccurrences(of: "_", with: " ")
            return Sanitize.plain(suffix.prefix(1).uppercased() + suffix.dropFirst(), max: 60)
        }
        return Sanitize.plain(trimmed, max: 60)
    }

    // MARK: - Quota parsing

    /// Parse remaining/used percentage from a quota object.
    /// Antigravity reports `remainingFraction` (0…1 where 1 = 0% used, 0 = 100% used).
    public static func usedPercent(from quota: [String: Any]) -> (percent: Double, limited: Bool)? {
        let exhausted = (quota["isExhausted"] as? Bool) == true
        if let remaining = Sanitize.number(quota["remainingFraction"]), remaining >= 0 {
            let clamped = Sanitize.clamp(remaining, 0, 1)
            let used = Sanitize.clamp((1 - clamped) * 100, 0, 100)
            return (used, exhausted || clamped <= 0)
        }
        if let usedFrac = Sanitize.number(quota["usedFraction"]), usedFrac >= 0 {
            let clamped = Sanitize.clamp(usedFrac, 0, 1)
            return (clamped * 100, exhausted || clamped >= 1)
        }
        if let pct = Sanitize.number(quota["usedPercent"] ?? quota["percent"]), pct >= 0 {
            let clamped = Sanitize.clamp(pct, 0, 100)
            return (clamped, exhausted || clamped >= 100)
        }
        if exhausted { return (100, true) }
        // Some responses omit `remainingFraction` when a bucket is fully exhausted
        // while still populating `resetTime`.
        if Sanitize.dateMs(quota["resetTime"]) > 0, quota["remainingFraction"] == nil {
            return (100, true)
        }
        return nil
    }

    /// Parse `RetrieveUserQuotaSummary` or `retrieveUserQuota` responses.
    /// Supports `{ response: { groups: [...] } }`, `{ groups: [...] }`, and `{ buckets: [...] }`.
    public static func limitsFromQuotaSummary(_ payload: [String: Any]) -> [Limit] {
        let root = (payload["response"] as? [String: Any])
            ?? (payload["quotaSummary"] as? [String: Any])
            ?? payload

        if let groups = root["groups"] as? [Any], !groups.isEmpty {
            return parseGroups(groups)
        }
        if let buckets = root["buckets"] as? [Any], !buckets.isEmpty {
            return parseFlatBuckets(buckets)
        }
        return []
    }

    /// Parse `GetUserStatus`: checks for an embedded `quotaSummary`/`groups`,
    /// otherwise maps `cascadeModelConfigData.clientModelConfigs` (or `clientModelConfigs`).
    public static func limitsFromUserStatus(_ payload: [String: Any]) -> [Limit] {
        let userStatus = (payload["userStatus"] as? [String: Any]) ?? payload
        let summaryLimits = limitsFromQuotaSummary(userStatus)
        if !summaryLimits.isEmpty { return summaryLimits }
        return limitsFromModelConfigs(userStatus)
    }

    /// Parse `GetCommandModelConfigs` or `userStatus` model configs into grouped quota pools.
    public static func limitsFromModelConfigs(_ payload: [String: Any]) -> [Limit] {
        let configs: [Any]
        if let cascade = payload["cascadeModelConfigData"] as? [String: Any],
           let list = cascade["clientModelConfigs"] as? [Any] {
            configs = list
        } else if let list = payload["clientModelConfigs"] as? [Any] {
            configs = list
        } else {
            return []
        }
        return groupModels(configs.compactMap { entry -> ModelQuota? in
            guard let obj = entry as? [String: Any],
                  let quota = obj["quotaInfo"] as? [String: Any],
                  let (used, limited) = usedPercent(from: quota) else { return nil }
            let modelAlias = (obj["modelOrAlias"] as? [String: Any])?["model"] as? String ?? ""
            let label = (obj["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (obj["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? modelAlias
            guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return ModelQuota(name: label, modelID: modelAlias, percent: used,
                              resetsAt: Sanitize.dateMs(quota["resetTime"]), limited: limited)
        })
    }

    /// Parse `v1internal:fetchAvailableModels` (`models` dictionary or array).
    public static func limitsFromFetchAvailableModels(_ payload: [String: Any]) -> [Limit] {
        var entries: [ModelQuota] = []
        if let dict = payload["models"] as? [String: Any] {
            for key in dict.keys.sorted() {
                guard let obj = dict[key] as? [String: Any],
                      let quota = obj["quotaInfo"] as? [String: Any],
                      let (used, limited) = usedPercent(from: quota) else { continue }
                let name = (obj["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (obj["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? key
                entries.append(ModelQuota(name: name, modelID: key, percent: used,
                                          resetsAt: Sanitize.dateMs(quota["resetTime"]), limited: limited))
            }
        } else if let list = payload["models"] as? [Any] {
            for case let obj as [String: Any] in list {
                guard let quota = obj["quotaInfo"] as? [String: Any],
                      let (used, limited) = usedPercent(from: quota) else { continue }
                let id = (obj["id"] as? String) ?? (obj["modelId"] as? String) ?? ""
                let name = (obj["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (obj["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? id
                guard !name.isEmpty else { continue }
                entries.append(ModelQuota(name: name, modelID: id, percent: used,
                                          resetsAt: Sanitize.dateMs(quota["resetTime"]), limited: limited))
            }
        }
        return groupModels(entries)
    }

    // MARK: - Grouping & ranking

    struct ModelQuota {
        var name: String
        var modelID: String
        var percent: Double
        var resetsAt: Double
        var limited: Bool
    }

    private struct GroupMeta {
        var key: String
        var label: String
        var shortPrefix: String
        var rank: Int
    }

    private static func classifyGroup(id: String, displayName: String) -> GroupMeta {
        let probe = (id + " " + displayName).lowercased()
        if probe.contains("gemini") {
            if probe.contains("flash") || probe.contains("hydrogen") {
                return GroupMeta(key: "gemini-flash", label: "Gemini Flash", shortPrefix: "flash", rank: 1)
            }
            if probe.contains("pro") || probe.contains("neon") || probe.contains("carbon") {
                return GroupMeta(key: "gemini-pro", label: "Gemini Pro", shortPrefix: "pro", rank: 0)
            }
            return GroupMeta(key: "gemini", label: "Gemini", shortPrefix: "gem", rank: 0)
        }
        if probe.contains("3p") || probe.contains("claude") || probe.contains("gpt") || probe.contains("third") {
            return GroupMeta(key: "claude-gpt", label: "Claude & GPT", shortPrefix: "3p", rank: 2)
        }
        let clean = Sanitize.plain(displayName.isEmpty ? id : displayName, max: 50)
        let key = slug(clean)
        return GroupMeta(key: key, label: clean.isEmpty ? "Quota" : clean,
                         shortPrefix: String(key.prefix(8)), rank: 3)
    }

    private static func classifyWindow(window: String, displayName: String, id: String) -> (key: String, label: String, short: String, rank: Int) {
        let probe = (window + " " + displayName + " " + id).lowercased()
        if probe.contains("5h") || probe.contains("5-hour") || probe.contains("five_hour") || probe.contains("session") {
            return ("session", "(5-hour)", "5h", 0)
        }
        if probe.contains("7d") || probe.contains("week") || probe.contains("7-day") {
            return ("weekly", "Weekly", "7d", 1)
        }
        if probe.contains("day") || probe.contains("daily") || probe.contains("24h") || probe.contains("1d") {
            return ("daily", "Daily", "1d", 2)
        }
        if probe.contains("month") || probe.contains("1m") {
            return ("monthly", "Monthly", "1m", 3)
        }
        let clean = Sanitize.plain(displayName.isEmpty ? window : displayName, max: 32)
        let s = slug(clean)
        return (s, clean, String(s.prefix(6)), 4)
    }

    private static func parseGroups(_ groups: [Any]) -> [Limit] {
        let dictGroups = groups.compactMap { $0 as? [String: Any] }
        let singleGroup = dictGroups.count == 1
        var ranked: [(rank: Int, subRank: Int, index: Int, limit: Limit)] = []
        var keys = Set<String>()

        for group in dictGroups {
            let groupID = Sanitize.text(group["modelGroup"] ?? group["id"], max: 60)
            let groupName = Sanitize.text(group["displayName"] ?? group["label"], max: 80)
            let meta = classifyGroup(id: groupID, displayName: groupName)
            guard let buckets = group["buckets"] as? [Any] else { continue }
            for case let bucket as [String: Any] in buckets {
                guard let (used, limited) = usedPercent(from: bucket) else { continue }
                let bWin = Sanitize.text(bucket["window"] ?? bucket["windowType"], max: 40)
                let bName = Sanitize.text(bucket["displayName"] ?? bucket["label"], max: 60)
                let bID = Sanitize.text(bucket["id"], max: 60)
                let win = classifyWindow(window: bWin, displayName: bName, id: bID)

                let key = "\(meta.key)-\(win.key)"
                guard keys.insert(key).inserted else { continue }
                let label = win.label.isEmpty ? meta.label : "\(meta.label) \(win.label)"
                let short = singleGroup ? win.short : "\(meta.shortPrefix) \(win.short)"
                let resetsAt = Sanitize.dateMs(bucket["resetTime"])
                let limit = Limit(key: key, label: Sanitize.plain(label, max: 80),
                                  short: Sanitize.plain(short, max: 14),
                                  percent: used, resetsAt: resetsAt, limited: limited)
                ranked.append((meta.rank, win.rank, ranked.count, limit))
            }
        }
        return ranked
            .sorted { a, b in
                if a.rank != b.rank { return a.rank < b.rank }
                if a.subRank != b.subRank { return a.subRank < b.subRank }
                return a.index < b.index
            }
            .map(\.limit)
    }

    /// Flat `buckets` from `v1internal:retrieveUserQuota`: each bucket carries `modelId`, `remainingFraction`, `resetTime`.
    private static func parseFlatBuckets(_ buckets: [Any]) -> [Limit] {
        var entries: [ModelQuota] = []
        for case let bucket as [String: Any] in buckets {
            guard let (used, limited) = usedPercent(from: bucket) else { continue }
            let modelID = Sanitize.text(bucket["modelId"] ?? bucket["id"], max: 80)
            let name = Sanitize.text(bucket["displayName"] ?? bucket["label"], max: 80)
            let resolved = name.isEmpty ? modelID : name
            guard !resolved.isEmpty else { continue }
            entries.append(ModelQuota(name: resolved, modelID: modelID, percent: used,
                                      resetsAt: Sanitize.dateMs(bucket["resetTime"]), limited: limited))
        }
        return groupModels(entries)
    }

    /// Collapse per-model readings into Antigravity's shared quota pools
    /// (Gemini Pro, Gemini Flash, Claude & GPT, plus any other distinct pool).
    /// Within a pool, keeps the highest used percent (tie-break: earliest reset).
    private static func groupModels(_ models: [ModelQuota]) -> [Limit] {
        struct Pool {
            var rank: Int
            var key: String
            var label: String
            var short: String
            var percent: Double
            var resetsAt: Double
            var limited: Bool
            var index: Int
        }
        var pools: [String: Pool] = [:]
        var nextIndex = 0
        for m in models {
            let probe = (m.name + " " + m.modelID).lowercased()
            // Skip image/tab-only entries if any slip into model lists.
            if probe.contains("imagen") || probe.contains("autocomplete") || probe.contains("tab_") { continue }
            let key: String
            let label: String
            let short: String
            let rank: Int
            if probe.contains("flash") || probe.contains("hydrogen") {
                key = "gemini-flash"; label = "Gemini Flash"; short = "flash"; rank = 1
            } else if probe.contains("gemini") || probe.contains("neon") || probe.contains("carbon") {
                key = "gemini-pro"; label = "Gemini Pro"; short = "pro"; rank = 0
            } else if probe.contains("claude") || probe.contains("sonnet") || probe.contains("opus")
                || probe.contains("haiku") || probe.contains("gpt") || probe.contains("oss") {
                key = "claude-gpt"; label = "Claude & GPT"; short = "3p"; rank = 2
            } else {
                let clean = Sanitize.plain(m.name, max: 60)
                key = slug(clean)
                label = clean
                short = String(key.prefix(10))
                rank = 3
            }

            if var existing = pools[key] {
                let moreUsed = m.percent > existing.percent
                let sameEarlier = m.percent == existing.percent && m.resetsAt > 0
                    && (existing.resetsAt == 0 || m.resetsAt < existing.resetsAt)
                if moreUsed || sameEarlier || (m.limited && !existing.limited) {
                    existing.percent = max(existing.percent, m.percent)
                    if m.resetsAt > 0 { existing.resetsAt = m.resetsAt }
                    existing.limited = existing.limited || m.limited
                    pools[key] = existing
                }
            } else {
                pools[key] = Pool(rank: rank, key: key, label: label, short: short,
                                  percent: m.percent, resetsAt: m.resetsAt, limited: m.limited, index: nextIndex)
                nextIndex += 1
            }
        }
        return pools.values
            .sorted { a, b in
                if a.rank != b.rank { return a.rank < b.rank }
                return a.index < b.index
            }
            .map { Limit(key: $0.key, label: $0.label, short: $0.short,
                         percent: $0.percent, resetsAt: $0.resetsAt, limited: $0.limited) }
    }

    static func slug(_ name: String) -> String {
        var out = ""
        var dash = false
        for ch in name.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch); dash = false }
            else if !dash && !out.isEmpty { out.append("-"); dash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String((out.isEmpty ? "quota" : out).prefix(40))
    }
}

/// URLSession delegate strictly for the local Antigravity language server on
/// `127.0.0.1`: refuses redirects and accepts the server's self-signed TLS
/// certificate only for `127.0.0.1`.
private final class LoopbackSessionDelegate: NSObject, URLSessionTaskDelegate, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == "127.0.0.1",
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
