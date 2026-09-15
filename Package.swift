// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iris-bridge",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "iris-bridge", targets: ["IrisBridge"])],
    targets: [
        .target(name: "IrisBridgeCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "IrisBridge", dependencies: ["IrisBridgeCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "IrisBridgeCoreTests", dependencies: ["IrisBridgeCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
