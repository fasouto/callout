// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnnotatorKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AnnotatorCore", targets: ["AnnotatorCore"]),
        .library(name: "AnnotatorUI", targets: ["AnnotatorUI"]),
    ],
    dependencies: [
        // Markdown parsing with source ranges for every node. 0.x minors may break API.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.9.0")),
    ],
    targets: [
        .target(
            name: "AnnotatorCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        // The whole app except its bundle. A library so it also builds without Xcode.
        .target(
            name: "AnnotatorUI",
            dependencies: ["AnnotatorCore"]
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
            name: "AnnotatorUITests",
            dependencies: ["AnnotatorUI"]
        ),
    ]
)
