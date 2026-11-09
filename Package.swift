// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AndroidShare",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AndroidShare", path: "Sources/AndroidShare")
    ]
)
