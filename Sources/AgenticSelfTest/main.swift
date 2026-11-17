import Foundation

let filter = CommandLine.arguments.dropFirst().first
let t = TestRun(filter: filter)

let suites: [(String, (TestRun) async -> Void)] = [
    ("Logic", LogicTests.run),
    ("OpenRouter", OpenRouterTests.run),
    ("OpenCode", OpenCodeTests.run),
    ("Grok", GrokTests.run),
    ("Codex", CodexTests.run),
    ("Claude", ClaudeTests.run),
    ("Shell", ShellTests.run),
    ("Update", UpdateTests.run),
]
for (name, run) in suites where t.shouldRun(name) {
    await run(t)
}
print("\n\(t.passed) passed, \(t.failed) failed")
exit(t.failed == 0 ? 0 : 1)
