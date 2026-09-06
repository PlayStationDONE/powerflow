// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PowerFlow",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PowerFlowKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "PowerFlow",
            dependencies: ["PowerFlowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PowerFlowKitTests",
            dependencies: ["PowerFlowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
