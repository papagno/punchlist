// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GitHubIssues",
    // macOS 26 is the Liquid Glass baseline (safeAreaBar, glass sidebars, scroll edge effects).
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1")
    ],
    targets: [
        .executableTarget(
            name: "GitHubIssues",
            dependencies: [.product(name: "MarkdownUI", package: "swift-markdown-ui")]
        )
    ]
)
