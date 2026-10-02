// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnnotatorKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AnnotatorCore", targets: ["AnnotatorCore"]),
        .library(name: "AnnotatorUI", targets: ["AnnotatorUI"]),
        .library(name: "AnnotatorCLIKit", targets: ["AnnotatorCLIKit"]),
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
            name: "AnnotatorCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        // The socket protocol between the app and the command-line tool.
        .target(
            name: "AnnotatorIPC",
            dependencies: ["AnnotatorCore"]
        ),
        // Everything that knows Claude Code's formats: hook input and output,
        // transcripts, settings.json.
        .target(
            name: "ClaudeCodeAdapter",
            dependencies: ["AnnotatorCore"]
        ),
        // The command-line tool's logic, as a library so it can be tested.
        .target(
            name: "AnnotatorCLIKit",
            dependencies: ["AnnotatorCore", "AnnotatorIPC", "ClaudeCodeAdapter"]
        ),
        .executableTarget(
            name: "annotator",
            dependencies: ["AnnotatorCLIKit"]
        ),
        // What the app remembers: plan versions, history, snippets.
        .target(
            name: "AnnotatorStore",
            dependencies: ["AnnotatorCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // The whole app except its bundle. A library so it also builds without Xcode.
        .target(
            name: "AnnotatorUI",
            dependencies: ["AnnotatorCore", "AnnotatorIPC", "AnnotatorStore"]
        ),
        // Runs the app unbundled, for development without Xcode.
        .executableTarget(
            name: "AnnotatorApp",
            dependencies: ["AnnotatorUI"]
        ),
        .testTarget(
            name: "AnnotatorCoreTests",
            dependencies: ["AnnotatorCore"]
        ),
        .testTarget(
            name: "AnnotatorStoreTests",
            dependencies: ["AnnotatorStore"]
        ),
        .testTarget(
            name: "ClaudeCodeAdapterTests",
            dependencies: ["ClaudeCodeAdapter"]
        ),
        .testTarget(
            name: "AnnotatorIPCTests",
            dependencies: ["AnnotatorIPC", "AnnotatorCLIKit"]
        ),
        .testTarget(
            name: "AnnotatorUITests",
            dependencies: ["AnnotatorUI", "AnnotatorIPC"]
        ),
    ]
)
