// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AirPodsMouse",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HeadPointerCore"),
        .executableTarget(name: "AirPodsMouse", dependencies: ["HeadPointerCore"]),
        .testTarget(name: "HeadPointerCoreTests", dependencies: ["HeadPointerCore"])
    ]
)
