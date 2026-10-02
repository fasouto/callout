// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnnotatorKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AnnotatorCore", targets: ["AnnotatorCore"]),
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
        .testTarget(
            name: "AnnotatorCoreTests",
            dependencies: ["AnnotatorCore"]
        ),
    ]
)
