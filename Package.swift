// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ccwatch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ccwatch", path: "Sources/ccwatch")
    ]
)
