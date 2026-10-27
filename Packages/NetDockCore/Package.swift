// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetDockCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "NetDockCore", targets: ["NetDockCore"])],
    targets: [
        .target(name: "NetDockCore"),
        .testTarget(name: "NetDockCoreTests", dependencies: ["NetDockCore"])
    ]
)
