// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ValueGuard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "valueguard", targets: ["ValueGuardCLI"]),
        .executable(name: "blur_overlay", targets: ["ValueGuardOverlay"]),
        .executable(name: "vg", targets: ["vg"]),
        .library(name: "ValueGuardCore", targets: ["ValueGuardCore"]),
        .library(name: "ValueGuardMarketplace", targets: ["ValueGuardMarketplace"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "ValueGuardCore",
            path: "Sources/ValueGuard"
        ),
        .target(
            name: "ValueGuardMarketplace",
            dependencies: ["ValueGuardCore"],
            path: "Sources/ValueGuardMarketplace"
        ),
        .executableTarget(
            name: "vg",
            dependencies: [
                "ValueGuardMarketplace",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/vg"
        ),
        .executableTarget(
            name: "ValueGuardCLI",
            dependencies: ["ValueGuardCore"],
            path: "Sources/ValueGuardCLI"
        ),
        .executableTarget(
            name: "ValueGuardOverlay",
            path: "Sources/ValueGuardOverlay"
        ),
        .testTarget(
            name: "ValueGuardMarketplaceTests",
            dependencies: ["ValueGuardMarketplace"],
            path: "Tests/ValueGuardMarketplaceTests"
        ),
    ]
)
