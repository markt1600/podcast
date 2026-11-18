// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PodcastCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "PodcastCore", targets: ["PodcastCore"]),
    ],
    targets: [
        .target(name: "PodcastCore"),
        .executableTarget(name: "adscan", dependencies: ["PodcastCore"]),
        .testTarget(name: "PodcastCoreTests", dependencies: ["PodcastCore"]),
    ]
)
