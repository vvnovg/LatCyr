// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LatCyr",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LatCyr",
            path: "Sources/LatCyr"
        ),
        .testTarget(
            name: "LatCyrTests",
            dependencies: ["LatCyr"],
            path: "Tests/LatCyrTests"
        ),
    ]
)
