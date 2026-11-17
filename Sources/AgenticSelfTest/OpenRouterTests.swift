import Foundation
import AgenticCore

/// Records every request a collector makes and answers from a routing table.
/// Fully offline: nothing here touches the network.
final class OpenRouterStubHTTP: @unchecked Sendable {
    enum Reply {
        case json(Int, String)
        case fixture(Int, String)
        case fail(HTTPError)
    }

    private let lock = NSLock()
    private let routes: [String: Reply]
    private(set) var requests: [(url: String, headers: [String: String])] = []

    init(_ routes: [String: Reply]) { self.routes = routes }

    var calls: [(url: String, headers: [String: String])] { lock.lock(); defer { lock.unlock() }; return requests }

    private func record(_ url: String, _ headers: [String: String]) -> Reply? {
        lock.lock(); defer { lock.unlock() }
        requests.append((url, headers))
        return routes[url]
    }

    var client: HTTPClient {
        HTTPClient { [self] url, headers in
            switch record(url, headers) {
            case .json(let status, let body)?: return HTTPResponse(status: status, body: Data(body.utf8))
            case .fixture(let status, let name)?: return HTTPResponse(status: status, body: Fixtures.data("openrouter/" + name))
            case .fail(let e)?: throw e
            case nil: throw HTTPError.transport("no route for \(url)")
            }
        }
    }
}

enum OpenRouterTests {
    static let keyURL = "https://openrouter.ai/api/v1/key"
    static let creditsURL = "https://openrouter.ai/api/v1/credits"
    static let envKey = "sk-or-v1-demo-env-key-0000"

    static func context(home: URL, env: [String: String] = [:], http: OpenRouterStubHTTP,
                        searchPath: [String] = ["/usr/bin", "/bin"],
                        opencode: String = "", authFile: String = "") -> CollectorContext {
        CollectorContext(home: home, environment: env, searchPath: searchPath,
                         opencodeCommand: opencode, authFile: authFile, http: http.client)
    }

    static func standardHTTP(key: String = "key.json") -> OpenRouterStubHTTP {
        OpenRouterStubHTTP([keyURL: .fixture(200, key), creditsURL: .fixture(200, "credits.json")])
    }

    static func writeAuth(_ dir: URL, fixture: String = "auth.json") {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Fixtures.data("openrouter/" + fixture).write(to: dir.appendingPathComponent("auth.json"))
    }

    static func run(_ t: TestRun) async {
        t.suite("OpenRouter")
        let c = OpenRouterCollector()

        // No key anywhere: not available, reference wording, no request made.
        do {
            let home = Fixtures.tempHome("or-nokey")
            let http = standardHTTP()
            let p = await c.collect(context(home: home, http: http))
            t.equal(p.id, .openrouter)
            t.equal(p.available, false, "no key → unavailable")
            t.equal(p.error, "no OpenRouter key found")
            t.equal(p.source, "openrouter-api")
            t.check(p.money == nil, "no money without a key")
            t.equal(http.calls.count, 0, "no HTTP without a key")
        }

        // Env key: key + credits, monthly cycle, masked label.
        do {
            let home = Fixtures.tempHome("or-env")
            writeAuth(home.appendingPathComponent(".local/share/opencode"))   // env must win
            let http = standardHTTP()
            let p = await c.collect(context(home: home, env: ["OPENROUTER_API_KEY": "  \(envKey)\n"], http: http))
            t.equal(p.available, true)
            t.equal(p.error, "")
            t.equal(p.limits.count, 0, "limits stay empty for OpenRouter")
            t.equal(p.tier, "key \u{2026}1b2")
            t.equal(p.status, "Key limit")
            t.check(p.readAt > 0, "readAt set")
            let m = p.money
            t.equal(m?.label, "key \u{2026}1b2")
            t.equal(m?.limit, 25)
            t.near(m?.spend ?? -1, 7.75, 0.0001, "monthly spend")
            t.near(m?.credits ?? -1, 62.5, 0.0001, "credits remaining")
            t.near(m?.totalCredits ?? -1, 100, 0.0001, "credits total")
            t.equal(m?.resetInterval, "monthly")
            t.equal(m?.resetsAt, 0)
            let calls = http.calls
            t.equal(calls.map(\.url), [keyURL, creditsURL])
            t.equal(calls.first?.headers["Authorization"], "Bearer \(envKey)", "env key trimmed, wins over auth.json")
            t.equal(calls.first?.headers["Accept"], "application/json")
            // The key never leaves in the provider.
            let encoded = String(decoding: (try? JSONEncoder().encode(p)) ?? Data(), as: UTF8.self)
            t.check(!encoded.contains("sk-or-"), "provider JSON carries no key")
        }

        // effective_budget wins over legacy fields.
        do {
            let home = Fixtures.tempHome("or-budget")
            let p = await c.collect(context(home: home, env: ["OPENROUTER_API_KEY": envKey], http: standardHTTP(key: "key-budget.json")))
            t.equal(p.money?.limit, 50)
            t.near(p.money?.spend ?? -1, 11.5, 0.0001, "effective spend")
            t.equal(p.money?.resetInterval, "weekly")
            t.equal(p.money?.resetsAt, Sanitize.isoDateMs("2026-11-23T00:00:00Z"))
            t.equal(p.money?.label, "key \u{2026}yz9")
        }

        // No limit, weekly cycle; credits failing is not an error.
        do {
            let home = Fixtures.tempHome("or-nolimit")
            let http = OpenRouterStubHTTP([keyURL: .fixture(200, "key-nolimit.json"), creditsURL: .fail(.transport("offline"))])
            let p = await c.collect(context(home: home, env: ["OPENROUTER_API_KEY": envKey], http: http))
            t.equal(p.available, true)
            t.equal(p.error, "", "credits are optional")
            t.check(p.money?.limit == nil, "no limit")
            t.near(p.money?.spend ?? -1, 2.25, 0.0001, "weekly spend")
            t.check(p.money?.credits == nil, "no credits")
            t.equal(p.money?.label, "OpenRouter key")
            t.equal(p.status, "No key limit")
        }

        // Daily cycle picks usage_daily; usage falls back when usage_monthly is absent.
        do {
            let home = Fixtures.tempHome("or-daily")
            let http = OpenRouterStubHTTP([
                keyURL: .json(200, #"{"data":{"label":"x","limit":"5","limit_reset":"day","usage_daily":0.5,"usage":3}}"#),
                creditsURL: .json(200, #"{"data":{}}"#),
            ])
            let p = await c.collect(context(home: home, env: ["OPENROUTER_API_KEY": envKey], http: http))
            t.near(p.money?.spend ?? -1, 0.5, 0.0001, "daily spend")
            t.equal(p.money?.limit, 5, "numeric string limit")
            t.check(p.money?.credits == nil, "empty credits doc → nil")
            let http2 = OpenRouterStubHTTP([keyURL: .json(200, #"{"label":"abc","usage":3}"#), creditsURL: .json(200, "{}")])
            let p2 = await c.collect(context(home: home, env: ["OPENROUTER_API_KEY": envKey], http: http2))
            t.near(p2.money?.spend ?? -1, 3, 0.0001, "unwrapped doc, usage fallback")
            t.equal(p2.money?.label, "key \u{2026}abc")
        }

        // Errors: API message, bare status, invalid JSON, transport; the key is scrubbed.
        do {
            let home = Fixtures.tempHome("or-errors")
            let env = ["OPENROUTER_API_KEY": envKey]
            let p401 = await c.collect(context(home: home, env: env, http: OpenRouterStubHTTP([keyURL: .fixture(401, "error-401.json")])))
            t.equal(p401.available, true, "key found even when rejected")
            t.equal(p401.error, "No auth credentials found")
            t.check(p401.money == nil, "no money on error")

            let p500 = await c.collect(context(home: home, env: env, http: OpenRouterStubHTTP([keyURL: .json(502, "<html>bad gateway</html>")])))
            t.equal(p500.error, "HTTP 502")

            let pBad = await c.collect(context(home: home, env: env, http: OpenRouterStubHTTP([keyURL: .json(200, "not json")])))
            t.equal(pBad.error, "invalid JSON from OpenRouter")

            let pNet = await c.collect(context(home: home, env: env, http: OpenRouterStubHTTP([keyURL: .fail(.transport("The request timed out."))])))
            t.equal(pNet.error, "The request timed out.")

            let leak = #"{"error":{"message":"bad key \#(envKey) <b>"}}"#
            let pLeak = await c.collect(context(home: home, env: env, http: OpenRouterStubHTTP([keyURL: .json(403, leak)])))
            t.check(!pLeak.error.contains(envKey), "error never echoes the key")
            t.check(!pLeak.error.contains("<"), "error is display-safe")
        }

        // OpenCode 1 auth.json under HOME, and under XDG_DATA_HOME.
        do {
            let home = Fixtures.tempHome("or-authjson")
            writeAuth(home.appendingPathComponent(".local/share/opencode"))
            let http = standardHTTP()
            let p = await c.collect(context(home: home, http: http))
            t.equal(p.available, true)
            t.equal(http.calls.first?.headers["Authorization"], "Bearer sk-or-v1-demo-authfile-0000")

            let home2 = Fixtures.tempHome("or-xdg")
            let xdg = home2.appendingPathComponent("xdg-data")
            writeAuth(xdg.appendingPathComponent("opencode"))
            let http2 = standardHTTP()
            let p2 = await c.collect(context(home: home2, env: ["XDG_DATA_HOME": xdg.path], http: http2))
            t.equal(p2.available, true, "XDG_DATA_HOME auth.json")
            t.equal(http2.calls.first?.headers["Authorization"], "Bearer sk-or-v1-demo-authfile-0000")
        }

        // An explicit authFile is the only file consulted (no fallback), and `apiKey` is accepted.
        do {
            let home = Fixtures.tempHome("or-explicit")
            writeAuth(home.appendingPathComponent(".local/share/opencode"))
            let missing = await c.collect(context(home: home, http: standardHTTP(),
                                                  authFile: home.appendingPathComponent("nope.json").path))
            t.equal(missing.available, false, "explicit missing file → no key")
            t.equal(missing.error, "no OpenRouter key found")

            let custom = home.appendingPathComponent("custom.json")
            try? Data(#"{"openrouter":{"apiKey":" sk-or-v1-demo-custom "}}"#.utf8).write(to: custom)
            let http = standardHTTP()
            let p = await c.collect(context(home: home, http: http, authFile: "~/custom.json"))
            t.equal(p.available, true)
            t.equal(http.calls.first?.headers["Authorization"], "Bearer sk-or-v1-demo-custom")

            let viaEnv = await c.collect(context(home: home, env: ["OPENROUTER_AUTH_FILE": custom.path], http: standardHTTP()))
            t.equal(viaEnv.available, true, "OPENROUTER_AUTH_FILE honoured")
        }

        // OpenCode 2: `opencode auth export` — target first, then everything; key never on argv.
        do {
            let home = Fixtures.tempHome("or-export")
            let log = home.appendingPathComponent("args.log")
            let export = Fixtures.url("openrouter/export.json").path
            let fake = Fixtures.fakeBinary(in: home, name: "opencode", script: """
                echo "$@" >> '\(log.path)'
                if [ "$1 $2" = "auth export" ] && [ -z "$3" ]; then cat '\(export)'; exit 0; fi
                exit 1
                """)
            let http = standardHTTP()
            let p = await c.collect(context(home: home, http: http, searchPath: [(fake as NSString).deletingLastPathComponent, "/usr/bin", "/bin"]))
            t.equal(p.available, true, "key from auth export")
            t.equal(http.calls.first?.headers["Authorization"], "Bearer sk-or-v1-demo-export-1111", "skips inactive and other integrations")
            let args = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            t.equal(args, "auth export openrouter\nauth export\n", "target tried first")
            t.check(!args.contains("sk-or"), "key never on a command line")

            // Target export answering with a single item.
            let home2 = Fixtures.tempHome("or-export1")
            let fake2 = Fixtures.fakeBinary(in: home2, name: "opencode", script: """
                if [ "$3" = "openrouter" ]; then echo '{"integrationID":"openrouter","value":{"key":"sk-or-v1-demo-single"}}'; exit 0; fi
                exit 1
                """)
            let http2 = standardHTTP()
            let p2 = await c.collect(context(home: home2, http: http2, opencode: fake2))
            t.equal(p2.available, true)
            t.equal(http2.calls.first?.headers["Authorization"], "Bearer sk-or-v1-demo-single")

            // Export with nothing for OpenRouter.
            let home3 = Fixtures.tempHome("or-export0")
            let fake3 = Fixtures.fakeBinary(in: home3, name: "opencode", script: "echo '[]'")
            let p3 = await c.collect(context(home: home3, http: standardHTTP(), opencode: fake3))
            t.equal(p3.available, false)
            t.equal(p3.error, "no OpenRouter key found")
        }

        // maskKeyLabel matches the reference.
        t.equal(OpenRouterCollector.maskKeyLabel("sk-or-v1-abc...f00d"), "key \u{2026}00d")
        t.equal(OpenRouterCollector.maskKeyLabel("  ab "), "OpenRouter key")
        t.equal(OpenRouterCollector.maskKeyLabel("demo-"), "OpenRouter key")
        t.equal(OpenRouterCollector.maskKeyLabel(nil), "OpenRouter key")
        t.equal(OpenRouterCollector.maskKeyLabel(42), "OpenRouter key")
    }
}
