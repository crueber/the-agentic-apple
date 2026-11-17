import CryptoKit
import Darwin
import Foundation
import AgenticCore

/// The updater: versions, feed parsing, signatures, the downloader's redirect
/// and size policy (offline, through a URLProtocol stub), and a real
/// stage + swap of a tiny fake app inside DMGs built here with hdiutil.
enum UpdateTests {
    static let bundleID = "com.crueber.agentic-apple"
    static let appName = "The Agentic Apple.app"
    static let appBase = "The Agentic Apple"

    static func run(_ t: TestRun) async {
        versions(t)
        feed(t)
        await fetch(t)
        signatures(t)
        names(t)
        await downloader(t)
        relaunch(t)
        await endToEnd(t)
    }

    // MARK: versions

    static func versions(_ t: TestRun) {
        t.suite("Update · versions")
        t.check(UpdateVersion.isNewer("v0.2.0", than: "0.1.0"), "v prefix stripped")
        t.check(UpdateVersion.isNewer("0.10.0", than: "0.9.9"), "numeric, not lexical")
        t.check(UpdateVersion.isNewer("1.0", than: "0.99.99"), "major wins")
        t.check(UpdateVersion.isNewer("0.2.1", than: "0.2"), "missing component is zero")
        t.check(!UpdateVersion.isNewer("0.2.0", than: "0.2"), "0.2.0 == 0.2")
        t.check(!UpdateVersion.isNewer("0.2.0", than: "0.2.0"), "equal is not newer")
        t.check(!UpdateVersion.isNewer("0.1.9", than: "0.2.0"), "lower is not newer")
        for bad in ["", "v", "0.2.0-beta", "0.2.0+1", "0..2", ".1", "1.", "a.b", "1.2.3.4.5", "-1.0", "+1.0", " ", "1.2 3", "9999999.0", "0x10"] {
            t.check(UpdateVersion(bad) == nil, "not a version: \(bad)")
            t.check(!UpdateVersion.isNewer(bad, than: "0.0.1"), "unparseable never newer: \(bad)")
        }
        t.equal(UpdateVersion("v1.2.3")?.text, "1.2.3")
        t.check(UpdateVersion("0.2") == UpdateVersion("0.2.0"), "padded equality")
    }

    // MARK: feed

    static func feedJSON(tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false,
                         assets: [[String: Any]]? = nil, html: String? = nil) -> Data {
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let defaultAssets: [[String: Any]] = [
            ["name": "The-Agentic-Apple-\(v).dmg", "size": 1234,
             "browser_download_url": "https://github.com/crueber/the-agentic-apple/releases/download/\(tag)/The-Agentic-Apple-\(v).dmg"],
            ["name": "The-Agentic-Apple-\(v).dmg.sig", "size": 89,
             "browser_download_url": "https://github.com/crueber/the-agentic-apple/releases/download/\(tag)/The-Agentic-Apple-\(v).dmg.sig"],
        ]
        var obj: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": assets ?? defaultAssets]
        obj["html_url"] = html ?? "https://github.com/crueber/the-agentic-apple/releases/tag/\(tag)"
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    static func feed(_ t: TestRun) {
        t.suite("Update · feed")
        guard case .available(let r) = UpdateFeed.parse(feedJSON(), currentVersion: "0.1.0") else {
            t.check(false, "newer signed release is available"); return
        }
        t.equal(r.version.text, "0.2.0")
        t.equal(r.dmg.name, "The-Agentic-Apple-0.2.0.dmg")
        t.equal(r.signature.name, "The-Agentic-Apple-0.2.0.dmg.sig")
        t.equal(r.dmg.size, 1234)
        t.equal(r.pageURL.absoluteString, "https://github.com/crueber/the-agentic-apple/releases/tag/v0.2.0")

        t.equal(UpdateFeed.parse(feedJSON(draft: true), currentVersion: "0.1.0"), .upToDate, "draft skipped")
        t.equal(UpdateFeed.parse(feedJSON(prerelease: true), currentVersion: "0.1.0"), .upToDate, "prerelease skipped")
        t.equal(UpdateFeed.parse(feedJSON(tag: "v0.1.0"), currentVersion: "0.1.0"), .upToDate, "equal")
        t.equal(UpdateFeed.parse(feedJSON(tag: "v0.0.9"), currentVersion: "0.1.0"), .upToDate, "lower")
        t.check(isRejected(UpdateFeed.parse(feedJSON(tag: "v0.2.0-rc1"), currentVersion: "0.1.0")), "pre-release tag text")

        let dmgOnly: [[String: Any]] = [["name": "The-Agentic-Apple-0.2.0.dmg", "size": 10,
                                         "browser_download_url": "https://github.com/x/y/releases/download/v0.2.0/The-Agentic-Apple-0.2.0.dmg"]]
        t.check(isRejected(UpdateFeed.parse(feedJSON(assets: dmgOnly), currentVersion: "0.1.0")), "missing .sig ⇒ no update")
        let badSig: [[String: Any]] = dmgOnly + [["name": "The-Agentic-Apple-0.2.0.dmg.sig", "size": 0,
                                                 "browser_download_url": "https://github.com/x/y/s.sig"]]
        t.check(isRejected(UpdateFeed.parse(feedJSON(assets: badSig), currentVersion: "0.1.0")), "zero-size .sig ⇒ no update")
        let wrongVersionAssets: [[String: Any]] = [
            ["name": "The-Agentic-Apple-0.1.5.dmg", "size": 10, "browser_download_url": "https://github.com/a.dmg"],
            ["name": "The-Agentic-Apple-0.1.5.dmg.sig", "size": 10, "browser_download_url": "https://github.com/a.sig"],
        ]
        t.check(isRejected(UpdateFeed.parse(feedJSON(assets: wrongVersionAssets), currentVersion: "0.1.0")), "assets of another version")
        let evil: [[String: Any]] = [
            ["name": "The-Agentic-Apple-0.2.0.dmg", "size": 10, "browser_download_url": "https://evil.example/a.dmg"],
            ["name": "The-Agentic-Apple-0.2.0.dmg.sig", "size": 10, "browser_download_url": "https://github.com/a.sig"],
        ]
        t.check(isRejected(UpdateFeed.parse(feedJSON(assets: evil), currentVersion: "0.1.0")), "non-GitHub asset host")
        let http: [[String: Any]] = [
            ["name": "The-Agentic-Apple-0.2.0.dmg", "size": 10, "browser_download_url": "http://github.com/a.dmg"],
            ["name": "The-Agentic-Apple-0.2.0.dmg.sig", "size": 10, "browser_download_url": "https://github.com/a.sig"],
        ]
        t.check(isRejected(UpdateFeed.parse(feedJSON(assets: http), currentVersion: "0.1.0")), "http asset")
        let huge: [[String: Any]] = [
            ["name": "The-Agentic-Apple-0.2.0.dmg", "size": 65 * 1024 * 1024, "browser_download_url": "https://github.com/a.dmg"],
            ["name": "The-Agentic-Apple-0.2.0.dmg.sig", "size": 10, "browser_download_url": "https://github.com/a.sig"],
        ]
        t.check(isRejected(UpdateFeed.parse(feedJSON(assets: huge), currentVersion: "0.1.0")), "over 64 MB")
        if case .available(let r2) = UpdateFeed.parse(feedJSON(html: "https://evil.example/x"), currentVersion: "0.1.0") {
            t.equal(r2.pageURL, UpdateFeed.releasesURL, "foreign html_url replaced")
        } else { t.check(false, "html_url fallback") }
        t.check(isRejected(UpdateFeed.parse(Data("nope".utf8), currentVersion: "0.1.0")), "garbage body")

        for (s, ok) in [("https://github.com/a", true), ("https://release-assets.githubusercontent.com/x", true),
                        ("https://objects.githubusercontent.com/x", true), ("https://GITHUB.com/a", true),
                        ("http://github.com/a", false), ("https://githubusercontent.com/x", false),
                        ("https://evilgithubusercontent.com/x", false), ("https://github.com.evil.example/x", false),
                        ("https://github.com:8443/a", false), ("https://user:pw@github.com/a", false),
                        ("https://api.github.com/a", false), ("file:///etc/passwd", false)] {
            t.equal(UpdatePolicy.isAllowedDownloadURL(URL(string: s)!), ok, "download policy \(s)")
        }
    }

    static func isRejected(_ r: UpdateCheckResult) -> Bool { if case .rejected = r { return true }; return false }

    static func fetch(_ t: TestRun) async {
        t.suite("Update · fetch")
        let seen = Box<[String: String]>([:])
        let ok = HTTPClient { url, headers in
            seen.value = headers
            return HTTPResponse(status: url == UpdateFeed.feedURL ? 200 : 500, body: feedJSON())
        }
        let r = await UpdateFeed.fetch(http: ok, currentVersion: "0.1.0")
        if case .success(.available) = r {} else { t.check(false, "feed fetched: \(r)") }
        t.equal(seen.value["Accept"], "application/vnd.github+json")
        t.equal(seen.value["User-Agent"], "TheAgenticApple-Updater")
        t.check(seen.value["Authorization"] == nil, "no credentials sent")

        let notFound = HTTPClient { _, _ in HTTPResponse(status: 404, body: Data()) }
        t.equal(await UpdateFeed.fetch(http: notFound, currentVersion: "0.1.0"), .success(.upToDate), "404 = no release")
        let limited = HTTPClient { _, _ in HTTPResponse(status: 403, body: Data()) }
        if case .failure(.network) = await UpdateFeed.fetch(http: limited, currentVersion: "0.1.0") {} else { t.check(false, "403 is an error") }
        let down = HTTPClient { _, _ in throw HTTPError.transport("offline") }
        if case .failure(.network) = await UpdateFeed.fetch(http: down, currentVersion: "0.1.0") {} else { t.check(false, "transport error") }

        // No trusted keys: not configured, and the network is never touched.
        let called = Box(false)
        let spy = HTTPClient { _, _ in called.value = true; return HTTPResponse(status: 200, body: feedJSON()) }
        let engine = UpdateEngine(http: spy, installer: UpdateInstaller(.init(
            installedApp: URL(fileURLWithPath: "/nonexistent/\(appName)"), currentVersion: "0.1.0",
            bundleID: bundleID, trustedKeys: [])))
        t.equal(await engine.check(), .failure(.notConfigured), "empty trusted list")
        t.check(!called.value, "no network without keys")
        t.check(!UpdateSignature.isConfigured(UpdateKeys.trusted) || UpdateSignature.publicKeys(UpdateKeys.trusted).count == UpdateKeys.trusted.count,
                "every shipped trusted key is a valid 32-byte Ed25519 key")
    }

    // MARK: signatures

    static func signatures(_ t: TestRun) {
        t.suite("Update · signatures")
        let key = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let otherPub = other.publicKey.rawRepresentation.base64EncodedString()
        let message = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sigFile = Data(((try? key.signature(for: message)) ?? Data()).base64EncodedString().utf8) + Data("\n".utf8)
        guard let sig = UpdateSignature.decodeSignature(sigFile) else { t.check(false, "signature decodes"); return }
        t.check(UpdateSignature.verify(message, signature: sig, trustedKeys: [pub]), "valid")
        t.check(UpdateSignature.verify(message, signature: sig, trustedKeys: [otherPub, pub]), "any trusted key suffices")
        var tampered = message
        tampered[100] ^= 0x01
        t.check(!UpdateSignature.verify(tampered, signature: sig, trustedKeys: [pub]), "tampered")
        t.check(!UpdateSignature.verify(message, signature: sig, trustedKeys: [otherPub]), "wrong key")
        t.check(!UpdateSignature.verify(message, signature: sig, trustedKeys: []), "empty trusted list")
        t.check(!UpdateSignature.verify(message, signature: sig, trustedKeys: ["", "bm90IGEga2V5", "!!"]), "garbage keys")
        t.check(UpdateSignature.decodeSignature(Data("not base64".utf8)) == nil, "garbage .sig")
        t.check(UpdateSignature.decodeSignature(Data(Data(count: 32).base64EncodedString().utf8)) == nil, "short .sig")
        t.check(UpdateSignature.decodeSignature(Data(count: 5000)) == nil, "oversized .sig")
        t.check(!UpdateSignature.isConfigured([]), "no keys")
        t.check(UpdateSignature.isConfigured([pub]), "one key")
    }

    // MARK: names

    static func names(_ t: TestRun) {
        t.suite("Update · names")
        t.check(UpdateInstaller.isStagingName(".The Agentic Apple.update-0a1b2c3d.app", appBase: appBase), "staging")
        t.check(UpdateInstaller.isBackupName(".The Agentic Apple.backup-0a1b2c3d.app", appBase: appBase), "backup")
        for bad in ["The Agentic Apple.app", ".The Agentic Apple.backup-0a1b2c3.app", ".The Agentic Apple.backup-0A1B2C3D.app",
                    ".The Agentic Apple.backup-0a1b2c3d9.app", ".Other.backup-0a1b2c3d.app", ".The Agentic Apple.backup-../../x.app",
                    "The Agentic Apple.backup-0a1b2c3d.app", ".The Agentic Apple.backup-0a1b2c3d.app.x"] {
            t.check(!UpdateInstaller.isBackupName(bad, appBase: appBase) && !UpdateInstaller.isStagingName(bad, appBase: appBase),
                    "not ours: \(bad)")
        }
    }

    // MARK: downloader

    static func downloader(_ t: TestRun) async {
        t.suite("Update · downloader")
        let dl = UpdateDownloader(requestTimeout: 5, resourceTimeout: 10, protocolClasses: [StubURLProtocol.self])
        let dir = privateDir("dl")
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
        StubURLProtocol.set("https://github.com/o/r/releases/download/v1/a.dmg", .redirect("https://release-assets.githubusercontent.com/a"))
        StubURLProtocol.set("https://release-assets.githubusercontent.com/a", .body(body, 200))
        StubURLProtocol.set("https://github.com/evil", .redirect("https://evil.example/a"))
        StubURLProtocol.set("https://github.com/downgrade", .redirect("http://release-assets.githubusercontent.com/a"))
        StubURLProtocol.set("https://github.com/missing", .body(Data("nope".utf8), 404))
        StubURLProtocol.set("https://github.com/loop", .redirect("https://github.com/loop"))

        func get(_ url: String, _ name: String, max: Int = 1 << 20, expected: Int? = nil) async -> Result<Data, UpdateError> {
            let dest = dir.appendingPathComponent(name)
            do {
                try await dl.download(URL(string: url)!, to: dest, maxBytes: max, expectedSize: expected)
                return .success((try? Data(contentsOf: dest)) ?? Data())
            } catch let e as UpdateError {
                return .failure(e)
            } catch {
                return .failure(.download("\(error)"))
            }
        }

        let good = await get("https://github.com/o/r/releases/download/v1/a.dmg", "good", expected: body.count)
        t.equal((try? good.get()) ?? Data(), body, "follows the GitHub redirect and streams the body")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("good").path) {
            t.equal((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "download file is 0600")
        }
        t.check(failed(await get("https://github.com/evil", "evil"), "Refused a redirect away from GitHub"), "refuses a redirect to a foreign host")
        t.check(failed(await get("https://github.com/downgrade", "downgrade"), "Refused a redirect"), "refuses a redirect to http")
        t.check(failed(await get("http://github.com/o/r/a.dmg", "http"), "Refused to download"), "refuses http")
        t.check(failed(await get("https://evil.example/a.dmg", "foreign"), "Refused to download from outside GitHub"), "refuses a foreign first host")
        t.check(failed(await get("https://github.com/missing", "missing"), "answered 404"), "refuses a 404")
        t.check(failed(await get("https://github.com/loop", "loop"), "Too many redirects"), "bounded redirects")
        t.check(failed(await get("https://github.com/o/r/releases/download/v1/a.dmg", "cap", max: 1000), "larger than expected"), "size cap")
        t.check(failed(await get("https://github.com/o/r/releases/download/v1/a.dmg", "declared", expected: 1000), "larger than expected"), "declared size caps")
        t.check(failed(await get("https://github.com/o/r/releases/download/v1/a.dmg", "short", expected: body.count + 1), "expected 300001"), "size must equal the declared size")
        // An existing file is never overwritten or followed.
        try? Data("x".utf8).write(to: dir.appendingPathComponent("exists"))
        t.check(failed(await get("https://github.com/o/r/releases/download/v1/a.dmg", "exists"), "Could not create the download file"), "O_EXCL destination")
    }

    static func failed<T>(_ r: Result<T, UpdateError>, _ reason: String) -> Bool {
        if case .failure(let e) = r, e.description.contains(reason) { return true }
        print("    (expected a failure containing \"\(reason)\", got \(r))")
        return false
    }

    // MARK: relaunch helper

    static func relaunch(_ t: TestRun) {
        t.suite("Update · relaunch")
        let dir = privateDir("relaunch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("opened.txt")
        let opener = Fixtures.fakeBinary(in: dir, name: "open", script: "printf '%s\\n' \"$@\" > \"\(out.path)\"\n")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        guard (try? sleeper.run()) != nil else { t.check(false, "sleeper started"); return }
        let path = dir.appendingPathComponent("A $(touch pwned) ';'.app").path
        t.check(UpdateRelaunch.spawn(waitingFor: sleeper.processIdentifier, appPath: path, fixture: true, opener: opener), "helper spawned")
        usleep(300_000)
        t.check(!FileManager.default.fileExists(atPath: out.path), "waits for the old process to exit")
        sleeper.terminate()
        sleeper.waitUntilExit()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: out.path), Date() < deadline { usleep(50_000) }
        usleep(100_000)
        let lines = ((try? String(contentsOf: out, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        t.equal(lines, ["--env", "AGENTIC_APPLE_FIXTURE=1", path], "opens the app, path passed verbatim")
        t.check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pwned").path), "no interpolation")
        t.check(!UpdateRelaunch.arguments(pid: 1, appPath: "/x.app", fixture: false).contains("--env"), "no fixture env unless set")
    }

    // MARK: end to end

    struct FakeApp {
        var id = bundleID
        var version: String
        var printed: String? = nil
    }

    static func endToEnd(_ t: TestRun) async {
        t.suite("Update · stage and swap")
        let root = privateDir("e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let otherKey = Curve25519.Signing.PrivateKey()

        // Build the images concurrently (hdiutil create takes a few seconds each).
        let variants: [(String, FakeApp)] = [
            ("good", FakeApp(version: "0.2.0")),
            ("wrongid", FakeApp(id: "com.example.other", version: "0.2.0")),
            ("lower", FakeApp(version: "0.0.9")),
            ("mismatch", FakeApp(version: "0.3.0")),
            ("liar", FakeApp(version: "0.2.0", printed: "0.1.0")),
        ]
        let built: [String: URL] = await withTaskGroup(of: (String, URL?).self) { group in
            for (name, app) in variants {
                group.addTask {
                    await Blocking.run { (name, makeDMG(name: name, app: app, in: root)) }
                }
            }
            var out: [String: URL] = [:]
            for await (name, url) in group { if let url { out[name] = url } }
            return out
        }
        guard built.count == variants.count, let good = built["good"] else {
            t.check(false, "test DMGs built with hdiutil (\(built.keys.sorted()))"); return
        }

        func sign(_ dmg: URL, with k: Curve25519.Signing.PrivateKey = key) -> Data {
            let data = (try? Data(contentsOf: dmg)) ?? Data()
            return Data(((try? k.signature(for: data)) ?? Data()).base64EncodedString().utf8)
        }

        // A fresh "Applications" with an installed 0.1.0 for each case.
        func freshInstall(_ label: String) -> (installer: UpdateInstaller, apps: URL, installed: URL) {
            let apps = root.appendingPathComponent("Applications-\(label)", isDirectory: true)
            try? fm.createDirectory(at: apps, withIntermediateDirectories: true)
            let installed = apps.appendingPathComponent(appName, isDirectory: true)
            _ = makeApp(at: installed, FakeApp(version: "0.1.0"), sign: false)
            try? Data("keep me".utf8).write(to: installed.appendingPathComponent("Contents/Resources-marker"))
            let installer = UpdateInstaller(.init(installedApp: installed, currentVersion: "0.1.0", bundleID: bundleID,
                                                  trustedKeys: [pub], workRoot: root, toolTimeout: 120))
            return (installer, apps, installed)
        }

        func expectRejected(_ label: String, dmg: URL, sig: Data, version: String = "0.2.0", keys: [String]? = nil,
                            mustNotMount: Bool = false, reason: String, file: StaticString = #fileID, line: UInt = #line) {
            var (installer, apps, installed) = freshInstall(label)
            if let keys {
                installer = UpdateInstaller(.init(installedApp: installed, currentVersion: "0.1.0", bundleID: bundleID,
                                                  trustedKeys: keys, workRoot: root))
            }
            let before = treeDigest(installed)
            guard let work = try? installer.makeWorkDirectory() else { t.check(false, "\(label): work dir"); return }
            var message = ""
            do { try installer.install(dmg: dmg, signatureFile: sig, expectedVersion: version, workDirectory: work) } catch { message = "\(error)" }
            t.check(message.contains(reason), "\(label): rejected for \"\(reason)\", got \"\(message)\"", file: file, line: line)
            t.equal(treeDigest(installed), before, "\(label): installed app untouched", file: file, line: line)
            t.equal(leftovers(apps), [], "\(label): no staging or backup left", file: file, line: line)
            let mnt = work.appendingPathComponent("mnt")
            if mustNotMount { t.check(!fm.fileExists(atPath: mnt.path), "\(label): never mounted", file: file, line: line) }
            t.check(!isMountPoint(mnt), "\(label): detached", file: file, line: line)
            UpdateInstaller.removeWorkDirectory(work)
        }

        // Rejections.
        let tampered = root.appendingPathComponent("tampered.dmg")
        if var bytes = try? Data(contentsOf: good) {
            bytes[bytes.count / 2] ^= 0x5a
            try? bytes.write(to: tampered)
        }
        expectRejected("tampered", dmg: tampered, sig: sign(good), mustNotMount: true, reason: "signature did not verify")
        expectRejected("wrong key", dmg: good, sig: sign(good, with: otherKey), mustNotMount: true, reason: "signature did not verify")
        expectRejected("no trusted keys", dmg: good, sig: sign(good), keys: [], mustNotMount: true, reason: "not configured")
        expectRejected("garbage sig", dmg: good, sig: Data("AAAA".utf8), mustNotMount: true, reason: "signature did not verify")
        expectRejected("wrong bundle id", dmg: built["wrongid"]!, sig: sign(built["wrongid"]!), reason: "different app")
        expectRejected("lower bundle version", dmg: built["lower"]!, sig: sign(built["lower"]!), reason: "not newer than this copy")
        expectRejected("equal version", dmg: good, sig: sign(good), version: "0.1.0", mustNotMount: true, reason: "not newer")
        expectRejected("feed/bundle mismatch", dmg: built["mismatch"]!, sig: sign(built["mismatch"]!), reason: "is version 0.3.0, not 0.2.0")
        expectRejected("old signed release replayed under a newer tag", dmg: good, sig: sign(good), version: "0.3.0", reason: "is version 0.2.0, not 0.3.0")
        expectRejected("binary reports another version", dmg: built["liar"]!, sig: sign(built["liar"]!), reason: "did not start correctly")

        // The good update, through the engine: feed → stub downloads → verify → stage → swap.
        let (installer, apps, installed) = freshInstall("good")
        let dmgBytes = (try? Data(contentsOf: good)) ?? Data()
        let sigBytes = sign(good)
        let base = "https://github.com/crueber/the-agentic-apple/releases/download/v0.2.0/"
        StubURLProtocol.set(base + "The-Agentic-Apple-0.2.0.dmg", .redirect("https://release-assets.githubusercontent.com/dmg"))
        StubURLProtocol.set("https://release-assets.githubusercontent.com/dmg", .body(dmgBytes, 200))
        StubURLProtocol.set(base + "The-Agentic-Apple-0.2.0.dmg.sig", .redirect("https://release-assets.githubusercontent.com/sig"))
        StubURLProtocol.set("https://release-assets.githubusercontent.com/sig", .body(sigBytes, 200))
        let feedBody = feedJSON(assets: [
            ["name": "The-Agentic-Apple-0.2.0.dmg", "size": dmgBytes.count, "browser_download_url": base + "The-Agentic-Apple-0.2.0.dmg"],
            ["name": "The-Agentic-Apple-0.2.0.dmg.sig", "size": sigBytes.count, "browser_download_url": base + "The-Agentic-Apple-0.2.0.dmg.sig"],
        ])
        let engine = UpdateEngine(http: HTTPClient { _, _ in HTTPResponse(status: 200, body: feedBody) },
                                  downloader: UpdateDownloader(requestTimeout: 10, resourceTimeout: 30, protocolClasses: [StubURLProtocol.self]),
                                  installer: installer)
        guard case .success(.available(let release)) = await engine.check() else { t.check(false, "engine finds 0.2.0"); return }
        let tempBefore = workDirs(root)
        let staged: URL
        do { staged = try await engine.prepare(release) } catch { t.check(false, "prepare: \(error)"); return }
        t.equal(workDirs(root), tempBefore, "work folder removed after staging")
        t.check(UpdateInstaller.isStagingName(staged.lastPathComponent, appBase: appBase), "staged beside the app: \(staged.lastPathComponent)")
        t.equal(staged.deletingLastPathComponent().path, apps.path)
        t.check(getxattr(staged.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) < 0, "no quarantine on the staged app")
        t.equal(bundleVersion(installed), "0.1.0", "still the old app before the swap")

        let backup: URL
        do { backup = try installer.swap(staged: staged) } catch { t.check(false, "swap: \(error)"); return }
        t.equal(bundleVersion(installed), "0.2.0", "installed app is the new version")
        t.equal(bundleVersion(backup), "0.1.0", "backup holds the old version")
        t.check(fm.fileExists(atPath: backup.appendingPathComponent("Contents/Resources-marker").path), "backup is the old bundle")
        t.check(UpdateInstaller.isBackupName(backup.lastPathComponent, appBase: appBase), "backup named \(backup.lastPathComponent)")
        t.check(!fm.fileExists(atPath: staged.path), "staging name gone")
        t.check(Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", installed.path]).ok, "installed copy verifies")

        // The new version's launch cleanup: only our exact names, never through symlinks.
        let decoyName = ".The Agentic Apple.backup-notours.app"
        try? fm.createDirectory(at: apps.appendingPathComponent(decoyName), withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkName = ".The Agentic Apple.update-abcdef01.app"
        try? fm.createSymbolicLink(atPath: apps.appendingPathComponent(linkName).path, withDestinationPath: outside.path)
        let removed = UpdateInstaller.cleanupLeftovers(beside: installed)
        t.equal(removed.map(\.lastPathComponent), [backup.lastPathComponent], "removes the backup only")
        t.check(fm.fileExists(atPath: apps.appendingPathComponent(decoyName).path), "decoy kept")
        t.check(fm.fileExists(atPath: outside.path), "symlink target untouched")
        t.check(fm.fileExists(atPath: installed.path), "installed app kept")

        // A staged copy anywhere but beside the app, or not named like ours, is refused and left alone.
        let (installer2, apps2, installed2) = freshInstall("refuse")
        let elsewhere = root.appendingPathComponent(".The Agentic Apple.update-0000aaaa.app", isDirectory: true)
        _ = makeApp(at: elsewhere, FakeApp(version: "0.2.0"), sign: false)
        let misnamed = apps2.appendingPathComponent("Other.app", isDirectory: true)
        _ = makeApp(at: misnamed, FakeApp(version: "0.2.0"), sign: false)
        let before2 = treeDigest(installed2)
        t.check((try? installer2.swap(staged: elsewhere)) == nil, "swap refuses a copy outside the app's folder")
        t.check((try? installer2.swap(staged: misnamed)) == nil, "swap refuses a copy not named like ours")
        t.check(fm.fileExists(atPath: elsewhere.path) && fm.fileExists(atPath: misnamed.path), "refused paths are not deleted")
        t.equal(treeDigest(installed2), before2, "installed app untouched by a refused swap")

        // The two-rename fallback (volumes without RENAME_SWAP).
        let (installer3, apps3, installed3) = freshInstall("twostep")
        let twoStep = UpdateInstaller(.init(installedApp: installed3, currentVersion: "0.1.0", bundleID: bundleID,
                                            trustedKeys: [pub], workRoot: root, forceTwoStepSwap: true))
        _ = installer3
        let staged3 = apps3.appendingPathComponent(".The Agentic Apple.update-12345678.app", isDirectory: true)
        _ = makeApp(at: staged3, FakeApp(version: "0.2.0"), sign: false)
        if let backup3 = try? twoStep.swap(staged: staged3) {
            t.equal(bundleVersion(installed3), "0.2.0", "two-step: new version installed")
            t.equal(bundleVersion(backup3), "0.1.0", "two-step: backup kept")
            t.check(!fm.fileExists(atPath: staged3.path), "two-step: staging name gone")
        } else { t.check(false, "two-step swap") }
        t.check(UpdateInstaller.canReplace(installed2), "writable install can be replaced")
        t.check(!UpdateInstaller.canReplace(root.appendingPathComponent("missing.app")), "missing app cannot")
    }

    // MARK: fixtures

    static func privateDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentic-selftest-update-\(label)-\(UUID().uuidString.prefix(8))")
        mkdir(dir.path, 0o700)
        return dir
    }

    @discardableResult
    static func makeApp(at app: URL, _ spec: FakeApp, sign: Bool = true) -> Bool {
        let fm = FileManager.default
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        guard (try? fm.createDirectory(at: macos, withIntermediateDirectories: true)) != nil else { return false }
        let plist: [String: Any] = [
            "CFBundleIdentifier": spec.id, "CFBundleShortVersionString": spec.version, "CFBundleVersion": "1",
            "CFBundleExecutable": "agentic-apple", "CFBundlePackageType": "APPL", "CFBundleName": "The Agentic Apple",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? data.write(to: app.appendingPathComponent("Contents/Info.plist"))) != nil else { return false }
        let exe = macos.appendingPathComponent("agentic-apple")
        let script = "#!/bin/sh\necho \"The Agentic Apple \(spec.printed ?? spec.version)\"\n"
        guard (try? script.write(to: exe, atomically: true, encoding: .utf8)) != nil else { return false }
        chmod(exe.path, 0o755)
        guard sign else { return true }
        return Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path], timeout: 60).ok
    }

    static func makeDMG(name: String, app spec: FakeApp, in root: URL) -> URL? {
        let stage = root.appendingPathComponent("stage-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        guard makeApp(at: stage.appendingPathComponent(appName), spec) else { return nil }
        try? FileManager.default.createSymbolicLink(atPath: stage.appendingPathComponent("Applications").path,
                                                    withDestinationPath: "/Applications")
        let dmg = root.appendingPathComponent("\(name).dmg")
        // hdiutil can report "Resource busy" when several images are created at once; retry.
        var ok = false
        for attempt in 0..<4 where !ok {
            if attempt > 0 { sleep(UInt32(attempt * 2)) }
            ok = Shell.run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "The Agentic Apple", "-srcfolder", stage.path,
                                                "-fs", "HFS+", "-format", "UDZO", "-ov", dmg.path], timeout: 180).ok
        }
        try? FileManager.default.removeItem(at: stage)
        return ok ? dmg : nil
    }

    static func bundleVersion(_ app: URL) -> String? {
        guard let d = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return p["CFBundleShortVersionString"] as? String
    }

    /// Paths and contents of every file in the tree.
    static func treeDigest(_ root: URL) -> String {
        var hasher = SHA256()
        let fm = FileManager.default
        let rels = ((fm.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []).sorted()
        for rel in rels {
            hasher.update(data: Data(rel.utf8))
            if let d = fm.contents(atPath: root.appendingPathComponent(rel).path) { hasher.update(data: d) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() + ":\(rels.count)"
    }

    static func leftovers(_ apps: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? [])
            .filter { $0.contains(".update-") || $0.contains(".backup-") }.sorted()
    }

    static func workDirs(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix("agentic-apple-update-") }.sorted()
    }

    static func isMountPoint(_ url: URL) -> Bool {
        var a = stat(), b = stat()
        guard lstat(url.path, &a) == 0, lstat(url.deletingLastPathComponent().path, &b) == 0 else { return false }
        return a.st_dev != b.st_dev
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Offline HTTP for the downloader: canned redirects and bodies by URL.
final class StubURLProtocol: URLProtocol {
    enum Route { case redirect(String), body(Data, Int) }
    private static let routes = Box<[String: Route]>([:])
    static func set(_ url: String, _ route: Route) { routes.value[url] = route }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let route = Self.routes.value[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch route {
        case .redirect(let to):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": to])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: to)!), redirectResponse: response)
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        case .body(let data, let status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "\(data.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var offset = 0
            while offset < data.count {
                let end = min(offset + 65536, data.count)
                client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
                offset = end
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
