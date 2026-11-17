// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TheAgenticApple",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentic-apple", targets: ["AgenticApple"]),
        .executable(name: "agentic-selftest", targets: ["AgenticSelfTest"]),
        .library(name: "AgenticCore", targets: ["AgenticCore"]),
    ],
    targets: [
        .target(
            name: "AgenticCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AgenticApple",
            dependencies: ["AgenticCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AgenticSelfTest",
            dependencies: ["AgenticCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
