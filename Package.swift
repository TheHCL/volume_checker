// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VolumeChecker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VolumeChecker",
            path: "Sources/VolumeChecker"
        )
    ]
)
