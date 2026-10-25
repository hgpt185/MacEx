// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacEx",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacEx", targets: ["MacEx"]), .library(name: "MacExCore", targets: ["MacExCore"])],
    targets: [
        .target(name: "CFileOps", publicHeadersPath: "include"),
        .binaryTarget(name: "SSHDependencies", path: "Vendor/SSHDependencies.xcframework"),
        .target(name: "CSFTP", dependencies: ["SSHDependencies"], publicHeadersPath: "include"),
        .target(name: "MacExCore", dependencies: ["CFileOps", "CSFTP"]),
        .executableTarget(name: "MacEx", dependencies: ["MacExCore"]),
        .testTarget(name: "MacExCoreTests", dependencies: ["MacExCore"])
    ]
)
