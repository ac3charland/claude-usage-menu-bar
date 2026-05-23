// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Spike0aKeychain", path: "Sources/Spike0aKeychain"),
        .executableTarget(name: "Spike0bUsage", path: "Sources/Spike0bUsage"),
        .executableTarget(name: "Spike0cRefresh", path: "Sources/Spike0cRefresh"),
        .executableTarget(name: "Spike0cForceRefresh", path: "Sources/Spike0cForceRefresh"),
    ]
)
