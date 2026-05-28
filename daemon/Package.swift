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
        .library(name: "ValueGuardCore", targets: ["ValueGuardCore"]),
    ],
    targets: [
        .target(
            name: "ValueGuardCore",
            path: "Sources/ValueGuard"
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
    ]
)
