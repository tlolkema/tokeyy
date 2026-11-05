// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tokeyy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Tokeyy", targets: ["Tokeyy"])],
    targets: [
        .target(name: "TokeyyCore"),
        .executableTarget(name: "Tokeyy", dependencies: ["TokeyyCore"]),
        .testTarget(name: "TokeyyCoreTests", dependencies: ["TokeyyCore"]),
    ]
)
