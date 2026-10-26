// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "WatchMindCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [.library(name: "WatchMindCore", targets: ["WatchMindCore"])],
    targets: [.target(name: "WatchMindCore", resources: [.process("Resources")]), .testTarget(name: "WatchMindCoreTests", dependencies: ["WatchMindCore"])],
    swiftLanguageModes: [.v5]
)
