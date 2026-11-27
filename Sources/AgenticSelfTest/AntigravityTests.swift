import Foundation
import AgenticCore

/// Antigravity: every test injects process discovery, loopback RPC, credentials
/// and HTTP, uses a temp HOME and an empty environment, so the real Keychain,
/// running processes, ~/.gemini and the network are never touched. All data is
/// synthetic.
enum AntigravityTests {
    static let token = "ya29.SYNTHETIC-antigravity-test-token"
    static let csrf = "SYNTHETIC-csrf-nonce-12345"

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, [String: String], Data)] = []
        func add(_ target: String, _ headers: [String: String], _ body: Data = Data()) {
            lock.withLock { items.append((target, headers, body)) }
        }
        var all: [(String, [String: String], Data)] { lock.withLock { items } }
    }

    static func httpClient(_ calls: Calls, handler: @escaping @Sendable (String, [String: String], Data) throws -> HTTPResponse) -> HTTPClient {
        HTTPClient(
            get: { url, h in
                calls.add(url, h)
                return HTTPResponse(status: 404, body: Data())
            },
            post: { url, h, body in
                calls.add(url, h, body)
                return try handler(url, h, body)
            }
        )
    }

    static func context(_ home: URL, now: Date = Date(), http: HTTPClient? = nil,
                        env: [String: String] = [:], antigravityHome: String = "") -> CollectorContext {
        CollectorContext(home: home, environment: env, searchPath: [],
                         antigravityHome: antigravityHome, now: now, http: http)
    }

    static func run(_ t: TestRun) async {
        t.suite("Antigravity")
        processDiscovery(t)
        await localQuotaSummary(t)
        await localUserStatusFallback(t)
        await localCommandModelsFallback(t)
        await cloudFallbackSummaryAndModels(t)
        await cloudAuthStatesAndErrors(t)
        credentialSourcesAndInstallation(t)
        planLabelsAndPercentages(t)
    }

    // MARK: process discovery

    static func processDiscovery(_ t: TestRun) {
        let ps = """
          101 /usr/libexec/some-daemon --port 8080
          202 /Applications/Windsurf.app/Contents/Resources/language_server_macos_arm --csrf_token windsurf-tok --app_data_dir windsurf
          303 /Applications/Antigravity.app/Contents/Resources/language_server_macos_arm --csrf_token=\(csrf) --extension_server_port 44123 --app_data_dir antigravity
          404 /Users/demo/.local/share/mise/installs/antigravity-cli/latest/antigravity --csrf_token cli-tok --server_port 55111 --app_data_dir antigravity-cli
        """
        let procs = AntigravityCollector.parseProcessList(ps)
        t.equal(procs.map(\.pid), [303, 404], "Windsurf skipped, Antigravity IDE and CLI matched")
        t.equal(procs[0].csrfToken, csrf, "equals-form csrf_token parsed")
        t.equal(procs[0].hintPorts, [44123], "extension_server_port parsed")
        t.equal(procs[0].appDataDir, "antigravity", "app_data_dir parsed")
        t.equal(procs[1].csrfToken, "cli-tok", "space-form csrf_token parsed")
        t.equal(procs[1].hintPorts, [55111], "server_port parsed")

        // Native libproc socket-only listening port inspection on our own PID (invalid PID → empty).
        t.equal(AntigravityCollector.listeningPorts(for: -1), [], "invalid pid returns empty")
    }

    // MARK: local language server

    static func localQuotaSummary(_ t: TestRun) async {
        let home = Fixtures.tempHome("ag-local-summary")
        let calls = Calls()
        let now = Date()
        let server = AntigravityServerProcess(pid: 303, csrfToken: csrf, ports: [49199, 49200], appDataDir: "antigravity")

        let collector = AntigravityCollector(
            processDiscoverer: { _ in [server] },
            loopbackPost: { scheme, port, path, headers, body in
                calls.add("\(scheme)://127.0.0.1:\(port)\(path)", headers, body)
                // Port 49199 refuses; port 49200 answers on http (testing https -> http fallback).
                if port == 49199 || scheme == "https" {
                    throw HTTPError.transport("connection refused")
                }
                if path == AntigravityCollector.localUserStatusPath {
                    return HTTPResponse(status: 200, body: Fixtures.data("antigravity/user-status.json"))
                }
                if path == AntigravityCollector.localQuotaSummaryPath {
                    return HTTPResponse(status: 200, body: Fixtures.data("antigravity/quota-summary.json"))
                }
                return HTTPResponse(status: 404, body: Data())
            },
            credentialReader: { _ in
                t.check(false, "Keychain must not be touched when local server answers")
                return nil
            }
        )

        let p = await collector.collect(context(home, now: now))
        t.check(p.available, "available from local server")
        t.equal(p.source, "antigravity-local", "local source")
        t.equal(p.tier, "Google AI Pro", "tier from GetUserStatus")
        t.equal(p.error, "", "no error")
        t.near(p.readAt, now.timeIntervalSince1970 * 1000, 1, "readAt set")
        t.equal(p.limits.map(\.key), ["session", "weekly", "claude-gpt-session", "claude-gpt-weekly"], "summary keys + rank")
        t.equal(p.limits.map(\.label), ["Session (5-hour)", "Weekly (7-day)", "Claude & GPT (5-hour)", "Claude & GPT Weekly"], "summary labels")
        t.equal(p.limits.map(\.short), ["5h", "7d", "3p 5h", "3p 7d"], "summary shorts")
        t.near(p.limits[0].percent, 28, 0.01, "1 - 0.72 = 28% used")
        t.near(p.limits[1].percent, 52, 0.01, "1 - 0.48 = 52% used")
        t.near(p.limits[2].percent, 15, 0.01, "1 - 0.85 = 15% used")
        t.near(p.limits[3].percent, 100, 0.01, "0 remaining = 100% used")
        t.check(p.limits[3].limited, "0 remaining marks limited")
        t.check(!p.limits[0].limited, "72% remaining is not limited")

        // Verify CSRF header sent on loopback calls and never leaked into Provider.
        t.check(calls.all.contains { $0.1["X-Codeium-Csrf-Token"] == csrf && $0.1["Connect-Protocol-Version"] == "1" },
                "CSRF and Connect headers sent")
        let encoded = String(decoding: (try? JSONEncoder().encode(p)) ?? Data(), as: UTF8.self)
        t.check(!encoded.contains(csrf), "csrf token never in provider")
    }

    static func localUserStatusFallback(_ t: TestRun) async {
        let home = Fixtures.tempHome("ag-local-models")
        let server = AntigravityServerProcess(pid: 303, csrfToken: csrf, ports: [49200])
        let collector = AntigravityCollector(
            processDiscoverer: { _ in [server] },
            loopbackPost: { _, _, path, _, _ in
                if path == AntigravityCollector.localUserStatusPath {
                    return HTTPResponse(status: 200, body: Fixtures.data("antigravity/user-status.json"))
                }
                return HTTPResponse(status: 404, body: Data())
            },
            credentialReader: { _ in nil }
        )

        let p = await collector.collect(context(home))
        t.check(p.available, "available from GetUserStatus clientModelConfigs")
        t.equal(p.tier, "Google AI Pro")
        // Gemini Pro High (28% used) wins over Gemini Pro Low (20% used); Claude Sonnet (55%) wins over GPT-OSS (40%); tab_autocomplete skipped.
        t.equal(p.limits.map(\.key), ["gemini-pro", "gemini-flash", "claude-gpt"], "grouped model pools")
        t.equal(p.limits.map(\.label), ["Gemini Pro", "Gemini Flash", "Claude & GPT"])
        t.equal(p.limits.map(\.short), ["pro", "flash", "3p"])
        t.near(p.limits[0].percent, 28, 0.01, "worst Gemini Pro")
        t.near(p.limits[1].percent, 9, 0.01, "Gemini Flash")
        t.near(p.limits[2].percent, 55, 0.01, "worst Claude/GPT")
    }

    static func localCommandModelsFallback(_ t: TestRun) async {
        let home = Fixtures.tempHome("ag-local-cmd")
        let server = AntigravityServerProcess(pid: 303, csrfToken: csrf, ports: [49200])
        let statusNoModels = Data(#"{"userStatus":{"planStatus":{"planInfo":{"teamsTier":"TEAMS_TIER_PRO"}}}}"#.utf8)
        let cmdModels = Data(#"{"clientModelConfigs":[{"label":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.5,"resetTime":"2026-11-17T15:00:00Z"}}]}"#.utf8)
        let collector = AntigravityCollector(
            processDiscoverer: { _ in [server] },
            loopbackPost: { _, _, path, _, _ in
                switch path {
                case AntigravityCollector.localUserStatusPath: return HTTPResponse(status: 200, body: statusNoModels)
                case AntigravityCollector.localCommandModelsPath: return HTTPResponse(status: 200, body: cmdModels)
                default: return HTTPResponse(status: 404, body: Data())
                }
            },
            credentialReader: { _ in nil }
        )
        let p = await collector.collect(context(home))
        t.check(p.available, "available from GetCommandModelConfigs")
        t.equal(p.tier, "Pro", "TEAMS_TIER_PRO formatted")
        t.equal(p.limits.map(\.key), ["gemini-pro"])
        t.near(p.limits[0].percent, 50, 0.01)
    }

    // MARK: cloud OAuth fallback

    static func cloudFallbackSummaryAndModels(_ t: TestRun) async {
        let home = Fixtures.tempHome("ag-cloud")
        let now = Date()
        let creds = AntigravityCredentials(accessToken: token,
                                           expiresAt: (now.timeIntervalSince1970 + 3600) * 1000,
                                           hasRefreshToken: true, source: "keychain")

        // 1. Summary succeeds directly.
        let calls1 = Calls()
        let http1 = httpClient(calls1) { url, headers, _ in
            t.equal(headers["Authorization"] ?? "", "Bearer \(token)", "bearer header")
            t.equal(headers["User-Agent"] ?? "", "antigravity/acp/2.0.0", "versioned ACP user-agent for Gemini groups")
            if url == AntigravityCollector.loadCodeAssistEndpoint {
                return HTTPResponse(status: 200, body: Fixtures.data("antigravity/load-code-assist.json"))
            }
            if url == AntigravityCollector.quotaSummaryEndpoint {
                return HTTPResponse(status: 200, body: Fixtures.data("antigravity/quota-summary.json"))
            }
            return HTTPResponse(status: 404, body: Data())
        }
        let collector1 = AntigravityCollector(processDiscoverer: { _ in [] }, credentialReader: { _ in creds })
        let p1 = await collector1.collect(context(home, now: now, http: http1))
        t.check(p1.available, "available from cloud fallback")
        t.equal(p1.source, "antigravity-oauth (keychain)")
        t.equal(p1.tier, "Google AI Ultra")
        t.equal(p1.limits.count, 4, "4 summary buckets")
        t.check(String(decoding: calls1.all[1].2, as: UTF8.self).contains("demo-project-123"), "project forwarded")
        let encoded = String(decoding: (try? JSONEncoder().encode(p1)) ?? Data(), as: UTF8.self)
        t.check(!encoded.contains(token), "OAuth token never in provider")

        // 2. Summary returns 404 → falls back to fetchAvailableModels.
        let calls2 = Calls()
        let http2 = httpClient(calls2) { url, _, _ in
            if url == AntigravityCollector.loadCodeAssistEndpoint {
                return HTTPResponse(status: 200, body: Fixtures.data("antigravity/load-code-assist.json"))
            }
            if url == AntigravityCollector.fetchModelsEndpoint {
                return HTTPResponse(status: 200, body: Fixtures.data("antigravity/fetch-models.json"))
            }
            return HTTPResponse(status: 404, body: Data())
        }
        let p2 = await collector1.collect(context(home, now: now, http: http2))
        t.check(p2.available, "available from fetchAvailableModels")
        t.equal(p2.limits.map(\.key), ["gemini-pro", "gemini-flash", "claude-gpt"])
        t.near(p2.limits[0].percent, 35, 0.01)
        t.near(p2.limits[1].percent, 10, 0.01)
        t.near(p2.limits[2].percent, 70, 0.01)

        // 3. Both summary and fetchAvailableModels return 404 → falls back to retrieveUserQuota.
        let calls3 = Calls()
        let quotaBuckets = Data(#"{"buckets":[{"modelId":"gemini-3-pro","remainingFraction":0.25,"resetTime":"2026-11-17T16:00:00Z"}]}"#.utf8)
        let http3 = httpClient(calls3) { url, _, _ in
            if url == AntigravityCollector.loadCodeAssistEndpoint {
                return HTTPResponse(status: 200, body: Fixtures.data("antigravity/load-code-assist.json"))
            }
            if url == AntigravityCollector.retrieveQuotaEndpoint {
                return HTTPResponse(status: 200, body: quotaBuckets)
            }
            return HTTPResponse(status: 404, body: Data())
        }
        let p3 = await collector1.collect(context(home, now: now, http: http3))
        t.check(p3.available, "available from retrieveUserQuota")
        t.equal(p3.limits.map(\.key), ["gemini-pro"])
        t.near(p3.limits[0].percent, 75, 0.01)
    }

    static func cloudAuthStatesAndErrors(_ t: TestRun) async {
        let home = Fixtures.tempHome("ag-auth-states")
        let now = Date()
        let noNetwork = httpClient(Calls()) { _, _, _ in
            t.check(false, "no HTTP call when expired")
            return HTTPResponse(status: 200, body: Data())
        }

        // Expired with refresh token → Limits paused; ProviderMerge preserves previous limits marked stale.
        let pausedCreds = AntigravityCredentials(accessToken: token,
                                                 expiresAt: (now.timeIntervalSince1970 - 60) * 1000,
                                                 hasRefreshToken: true, source: "keychain")
        let paused = await AntigravityCollector(processDiscoverer: { _ in [] }, credentialReader: { _ in pausedCreds })
            .collect(context(home, now: now, http: noNetwork))
        t.equal(paused.status, "Limits paused", "lapsed access token with refresh token is paused")
        t.equal(paused.error, "", "paused is not an error")

        var prev = Provider(id: .antigravity, available: true, tier: "Google AI Pro", source: "antigravity-local",
                            limits: [Limit(key: "gemini-session", label: "Gemini (5-hour)", short: "gem 5h", percent: 28)])
        prev.readAt = now.timeIntervalSince1970 * 1000 - 60_000
        let mergedPaused = ProviderMerge.merge(previous: [prev], fresh: [paused])[0]
        t.check(mergedPaused.available, "paused merge stays available")
        t.check(mergedPaused.limits.allSatisfy(\.stale), "paused merge marks limits stale")
        t.equal(mergedPaused.tier, "Google AI Pro")

        // Expired without refresh token → Sign-in expired.
        let expiredCreds = AntigravityCredentials(accessToken: token,
                                                  expiresAt: (now.timeIntervalSince1970 - 60) * 1000,
                                                  hasRefreshToken: false, source: "keychain")
        let expired = await AntigravityCollector(processDiscoverer: { _ in [] }, credentialReader: { _ in expiredCreds })
            .collect(context(home, now: now, http: noNetwork))
        t.equal(expired.status, "Sign-in expired", "expired without refresh token")

        // 401/403 → Sign-in expired.
        let liveCreds = AntigravityCredentials(accessToken: token,
                                               expiresAt: (now.timeIntervalSince1970 + 3600) * 1000,
                                               hasRefreshToken: true, source: "keychain")
        for code in [401, 403] {
            let http = httpClient(Calls()) { _, _, _ in HTTPResponse(status: code, body: Data()) }
            let p = await AntigravityCollector(processDiscoverer: { _ in [] }, credentialReader: { _ in liveCreds })
                .collect(context(home, now: now, http: http))
            t.equal(p.status, "Sign-in expired", "\(code) is sign-in expired")
            t.equal(p.error, "", "\(code) is not an error")
        }

        // 429 → rate limited with retry-after.
        let http429 = httpClient(Calls()) { _, _, _ in
            HTTPResponse(status: 429, body: Data(), headers: ["retry-after": "45"])
        }
        let p429 = await AntigravityCollector(processDiscoverer: { _ in [] }, credentialReader: { _ in liveCreds })
            .collect(context(home, now: now, http: http429))
        t.equal(p429.error, "rate limited")
        t.check(p429.hint.contains("retry after 45s"), "retry-after in hint")

        // Transport failure → error.
        let httpErr = httpClient(Calls()) { _, _, _ in throw HTTPError.transport("offline") }
        let pErr = await AntigravityCollector(processDiscoverer: { _ in [] }, credentialReader: { _ in liveCreds })
            .collect(context(home, now: now, http: httpErr))
        t.check(!pErr.error.isEmpty, "transport error recorded")

        // Installed (dir exists) but not running and no credentials → unavailable on fresh run, keeps cached limits on merge.
        let installedHome = Fixtures.tempHome("ag-installed")
        try? FileManager.default.createDirectory(at: installedHome.appendingPathComponent(".gemini/antigravity-cli"),
                                                 withIntermediateDirectories: true)
        let closed = await AntigravityCollector(processDiscoverer: { _ in [] }, credentialReader: { _ in nil })
            .collect(context(installedHome, now: now))
        t.check(!closed.available, "closed without prior limits stays out of bar")
        t.equal(closed.status, "Not running")
        t.check(!closed.error.isEmpty, "not running carries error so merge keeps previous limits")
        let mergedClosed = ProviderMerge.merge(previous: [prev], fresh: [closed])[0]
        t.check(mergedClosed.available, "merge keeps previous limits when closed")
        t.equal(mergedClosed.limits.first?.percent, 28)

        // Not installed at all → quiet, unavailable, no error.
        let bareHome = Fixtures.tempHome("ag-bare")
        let none = await AntigravityCollector(processDiscoverer: { _ in [] }, credentialReader: { _ in nil })
            .collect(context(bareHome, now: now))
        t.check(!none.available, "not installed → unavailable")
        t.equal(none.error, "", "not installed → no error")
        t.equal(none.status, "", "not installed → no status")
    }

    // MARK: credentials & installation

    static func credentialSourcesAndInstallation(_ t: TestRun) {
        let older = #"{"access_token":"old-tok","expiry_date":1000000,"refresh_token":"r1"}"#
        let newer = #"{"oauth_creds":{"accessToken":"new-tok","expiresAt":2000000,"refreshToken":"r2"}}"#
        t.equal(AntigravityCredentials.parse(Data("{}".utf8), source: "x"), nil, "empty object rejected")
        let parsed = AntigravityCredentials.parse(Data(newer.utf8), source: "x")
        t.equal(parsed?.accessToken ?? "", "new-tok")
        t.equal(parsed?.hasRefreshToken, true)
        t.equal(AntigravityCredentials.parse(Data(token.utf8), source: "keychain")?.accessToken ?? "", token, "bare ya29 token parsed")

        // go-keyring-base64: wrapper (Antigravity CLI's macOS Keychain format).
        let goPayload = #"{"token":{"access_token":"go-tok","token_type":"Bearer","refresh_token":"go-ref","expiry":"2026-11-27T06:45:12.123456-06:00","expires_in":3599}}"#
        let goWrapped = "go-keyring-base64:" + Data(goPayload.utf8).base64EncodedString()
        let parsedGo = AntigravityCredentials.parse(Data(goWrapped.utf8), source: "keychain")
        t.equal(parsedGo?.accessToken ?? "", "go-tok", "go-keyring-base64 access_token parsed")
        t.equal(parsedGo?.hasRefreshToken, true, "go-keyring-base64 refresh_token detected")
        t.check((parsedGo?.expiresAt ?? 0) > 0, "go-keyring-base64 RFC3339 expiry parsed")

        // Hex-encoded security -w output wrapping JSON.
        let hexWrapped = Data(older.utf8).map { String(format: "%02x", $0) }.joined()
        t.equal(AntigravityCredentials.parse(Data(hexWrapped.utf8), source: "keychain")?.accessToken ?? "", "old-tok", "hex-encoded keychain parsed")

        // Keychain is NOT queried when Antigravity is not installed.
        let bare = Fixtures.tempHome("ag-no-keychain")
        let kcCalls = Calls()
        let reader = AntigravityCollector.defaultCredentialReader(keychain: {
            kcCalls.add("keychain", [:])
            return Data(newer.utf8)
        })
        t.equal(reader(context(bare)), nil, "not installed returns nil")
        t.check(kcCalls.all.isEmpty, "Keychain untouched when not installed")

        // Installed via antigravityHome: Keychain vs file, later expiry wins.
        let home = Fixtures.tempHome("ag-creds")
        let agDir = home.appendingPathComponent(".gemini/antigravity-cli")
        try? FileManager.default.createDirectory(at: agDir, withIntermediateDirectories: true)
        try? older.write(to: agDir.appendingPathComponent("oauth_creds.json"), atomically: true, encoding: .utf8)
        let ctx = context(home)
        let r1 = AntigravityCollector.defaultCredentialReader(keychain: { Data(newer.utf8) })(ctx)
        t.equal(r1?.accessToken ?? "", "new-tok", "newer keychain wins")
        t.equal(r1?.source ?? "", "keychain")
        try? newer.write(to: agDir.appendingPathComponent("oauth_creds.json"), atomically: true, encoding: .utf8)
        let r2 = AntigravityCollector.defaultCredentialReader(keychain: { Data(older.utf8) })(ctx)
        t.equal(r2?.accessToken ?? "", "new-tok", "newer file wins")
        t.equal(r2?.source ?? "", "credentials-file")

        // ANTIGRAVITY_HOME env override works.
        let custom = Fixtures.tempHome("ag-custom")
        try? older.write(to: custom.appendingPathComponent("oauth_creds.json"), atomically: true, encoding: .utf8)
        let r3 = AntigravityCollector.defaultCredentialReader(keychain: { nil })(
            context(Fixtures.tempHome("ag-empty-home"), env: ["ANTIGRAVITY_HOME": custom.path]))
        t.equal(r3?.accessToken ?? "", "old-tok", "ANTIGRAVITY_HOME respected")
    }

    // MARK: plan labels & percentage edge cases

    static func planLabelsAndPercentages(_ t: TestRun) {
        t.equal(AntigravityCollector.planLabel("g1-pro-tier"), "Google AI Pro")
        t.equal(AntigravityCollector.planLabel("g1-ultra-tier"), "Google AI Ultra")
        t.equal(AntigravityCollector.planLabel("free-tier"), "Free")
        t.equal(AntigravityCollector.planLabel("TEAMS_TIER_ENTERPRISE"), "Enterprise")
        t.equal(AntigravityCollector.planLabel("Google AI Pro"), "Google AI Pro")
        t.equal(AntigravityCollector.planLabel(""), "")

        t.near(AntigravityCollector.usedPercent(from: ["remainingFraction": 1.0])?.percent ?? -1, 0, 0.001)
        t.equal(AntigravityCollector.usedPercent(from: ["remainingFraction": 0.0])?.limited, true)
        t.near(AntigravityCollector.usedPercent(from: ["remainingFraction": 0.0])?.percent ?? -1, 100, 0.001)
        t.near(AntigravityCollector.usedPercent(from: ["usedFraction": 0.42])?.percent ?? -1, 42, 0.001)
        t.near(AntigravityCollector.usedPercent(from: ["usedPercent": 88])?.percent ?? -1, 88, 0.001)
        t.equal(AntigravityCollector.usedPercent(from: ["isExhausted": true])?.limited, true)
        t.equal(AntigravityCollector.usedPercent(from: ["resetTime": "2026-11-17T15:00:00Z"])?.limited, true, "exhausted bucket omitting remainingFraction")
        t.check(AntigravityCollector.usedPercent(from: [:]) == nil, "empty quota dropped")

        // Live retrieveUserQuotaSummary shape (top-level groups, bucketId, window: "weekly"/"5h", no modelGroup).
        let liveShape: [String: Any] = [
            "groups": [
                [
                    "displayName": "Gemini Models",
                    "buckets": [
                        ["bucketId": "gemini-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly", "remainingFraction": 0.84, "resetTime": "2026-12-04T11:30:00Z"],
                        ["bucketId": "gemini-5h", "displayName": "Five Hour Limit Remaining", "window": "5h", "remainingFraction": 0.40, "resetTime": "2026-11-27T16:30:00Z"],
                    ],
                ],
                [
                    "displayName": "Claude and GPT models",
                    "buckets": [
                        ["bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly", "remainingFraction": 1],
                        ["bucketId": "3p-5h", "displayName": "Five Hour Limit Remaining", "window": "5h", "remainingFraction": 1],
                    ],
                ],
            ],
        ]
        let liveLimits = AntigravityCollector.limitsFromQuotaSummary(liveShape)
        // Unused 0% 3P buckets with no reset are omitted when primary Gemini limits exist.
        t.equal(liveLimits.map(\.key), ["session", "weekly"], "live shape keys + rank")
        t.equal(liveLimits.map(\.label), ["Session (5-hour)", "Weekly (7-day)"], "live shape labels")
        t.equal(liveLimits.map(\.short), ["5h", "7d"], "live shape shorts")
        t.near(liveLimits[0].percent, 60, 0.01, "live Gemini 5h used percent")
        t.near(liveLimits[1].percent, 16, 0.01, "live Gemini weekly used percent")
    }
}
