// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WatchMouse",
    platforms: [.macOS(.v14), .watchOS(.v10)],
    products: [.library(name: "WatchMouseCore", targets: ["WatchMouseCore"])],
    targets: [
        .target(name: "WatchMouseCore"),
        .executableTarget(name: "WatchMouseMac", dependencies: ["WatchMouseCore"]),
        .testTarget(name: "WatchMouseCoreTests", dependencies: ["WatchMouseCore"])
    ]
)
