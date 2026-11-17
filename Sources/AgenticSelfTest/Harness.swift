import Foundation

/// A tiny assertion harness: Command Line Tools ship neither XCTest nor
/// swift-testing, so the self-test is a plain executable.
final class TestRun: @unchecked Sendable {
    private(set) var passed = 0
    private(set) var failed = 0
    private var current = ""
    private let filter: String?

    init(filter: String?) { self.filter = filter }

    func shouldRun(_ suite: String) -> Bool {
        guard let filter, !filter.isEmpty else { return true }
        return suite.lowercased().contains(filter.lowercased())
    }

    func suite(_ name: String) {
        current = name
        print("▸ \(name)")
    }

    func check(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) {
        if condition { passed += 1 } else {
            failed += 1
            print("  ✗ [\(current)] \(message())  (\(file):\(line))")
        }
    }

    func equal<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
        check(a == b, "\(message()) — expected \(b), got \(a)", file: file, line: line)
    }

    func near(_ a: Double, _ b: Double, _ tol: Double = 0.001, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
        check(abs(a - b) <= tol, "\(message()) — expected ≈\(b), got \(a)", file: file, line: line)
    }
}

/// Paths and scratch space shared by every suite.
enum Fixtures {
    /// Tests/Fixtures in the repository.
    static let root: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures")
    }()

    static func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    static func data(_ relative: String) -> Data { (try? Data(contentsOf: url(relative))) ?? Data() }

    /// A fresh temporary HOME.
    static func tempHome(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentic-selftest-\(label)-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write an executable shell script (a fake `opencode`, `codex`, …) and return its path.
    @discardableResult
    static func fakeBinary(in dir: URL, name: String, script: String) -> String {
        let bin = dir.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let path = bin.appendingPathComponent(name)
        try? ("#!/bin/sh\n" + script).write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }
}
