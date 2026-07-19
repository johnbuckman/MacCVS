// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacCVS",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MacCVS",
            path: "Sources/MacCVS"
        )
    ]
)
