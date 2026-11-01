// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalloutKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CalloutCore", targets: ["CalloutCore"]),
        .library(name: "CalloutUI", targets: ["CalloutUI"]),
        .library(name: "CalloutCLIKit", targets: ["CalloutCLIKit"]),
    ],
    dependencies: [
        // Markdown parsing with source ranges for every node. 0.x minors may break API.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.9.0")),
        // SQLite for plan versions, history and snippets: migrations, full-text
        // search, and the aggregate queries a later version needs.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CalloutCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        // The socket protocol between the app and the command-line tool.
        .target(
            name: "CalloutIPC",
            dependencies: ["CalloutCore"]
        ),
        // Everything that knows Claude Code's formats: hook input and output,
        // transcripts, settings.json.
        .target(
            name: "ClaudeCodeAdapter",
            dependencies: ["CalloutCore"]
        ),
        // The command-line tool's logic, as a library so it can be tested.
        .target(
            name: "CalloutCLIKit",
            dependencies: ["CalloutCore", "CalloutIPC", "ClaudeCodeAdapter"]
        ),
        .executableTarget(
            name: "callout",
            dependencies: ["CalloutCLIKit"]
        ),
        // What the app remembers: plan versions, history, snippets.
        .target(
            name: "CalloutStore",
            dependencies: ["CalloutCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // The whole app except its bundle. A library so it also builds without Xcode.
        .target(
            name: "CalloutUI",
            dependencies: ["CalloutCore", "CalloutIPC", "CalloutStore"]
        ),
        // Runs the app unbundled, for development without Xcode.
        .executableTarget(
            name: "CalloutApp",
            dependencies: ["CalloutUI"]
        ),
        .testTarget(
            name: "CalloutCoreTests",
            dependencies: ["CalloutCore"]
        ),
        .testTarget(
            name: "CalloutStoreTests",
            dependencies: ["CalloutStore", "CalloutCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "ClaudeCodeAdapterTests",
            dependencies: ["ClaudeCodeAdapter"]
        ),
        .testTarget(
            name: "CalloutIPCTests",
            dependencies: ["CalloutIPC", "CalloutCLIKit", "ClaudeCodeAdapter"]
        ),
        .testTarget(
            name: "CalloutUITests",
            dependencies: ["CalloutUI", "CalloutIPC"]
        ),
    ]
)
