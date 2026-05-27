// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ValueGuard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "valueguard", targets: ["ValueGuardCLI"])
    ],
    targets: [
        .target(
            name: "ValueGuard",
            path: "Sources/ValueGuard"
        ),
        .executableTarget(
            name: "ValueGuardCLI",
            dependencies: ["ValueGuard"],
            path: "Sources/ValueGuardCLI"
        ),
    ]
)
