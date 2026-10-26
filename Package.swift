// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "WatchMindCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [.library(name: "WatchMindCore", targets: ["WatchMindCore"])],
    targets: [.target(name: "WatchMindCore"), .testTarget(name: "WatchMindCoreTests", dependencies: ["WatchMindCore"])],
    swiftLanguageModes: [.v5]
)
