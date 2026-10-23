// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Punchlist",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1")
    ],
    targets: [
        .executableTarget(
            name: "Punchlist",
            dependencies: [.product(name: "MarkdownUI", package: "swift-markdown-ui")]
        )
    ]
)
