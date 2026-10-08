// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpaceKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SpaceKitCore", targets: ["SpaceKitCore"]),
        .library(name: "SpaceKitTUI", targets: ["SpaceKitTUI"]),
        .executable(name: "spacekit", targets: ["SpaceKitCLI"]),
        .executable(name: "SpaceKitApp", targets: ["SpaceKitApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "SpaceKitCore",
            dependencies: [.product(name: "Yams", package: "Yams")],
            plugins: ["EmbedRules"]
        ),
        // Built-in rules are compiled into SpaceKitCore from rules/**/*.yaml, so no folder on disk decides them.
        .executableTarget(name: "RuleEmbedder"),
        .plugin(
            name: "EmbedRules",
            capability: .buildTool(),
            dependencies: ["RuleEmbedder"]
        ),
        .target(
            name: "SpaceKitTUI",
            dependencies: ["SpaceKitCore"]
        ),
        .executableTarget(
            name: "SpaceKitCLI",
            dependencies: [
                "SpaceKitCore",
                "SpaceKitTUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "SpaceKitApp",
            dependencies: ["SpaceKitCore"]
        ),
        .testTarget(
            name: "SpaceKitCoreTests",
            dependencies: ["SpaceKitCore"]
        ),
    ]
)
