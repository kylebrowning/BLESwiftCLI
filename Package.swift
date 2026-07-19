// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BLESwiftCLI",
    platforms: [.macOS(.v15)],
    products: [
        // Explicit executable product so `mint install kylebrowning/BLESwiftCLI` works.
        .executable(name: "ble", targets: ["ble"])
    ],
    dependencies: [
        // For local development against a checkout, swap for:
        // .package(name: "BLESwift", path: "../blei"),
        .package(url: "https://github.com/kylebrowning/BLESwift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ble",
            dependencies: [
                .product(name: "BLESwift", package: "BLESwift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Yams", package: "Yams"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "bleTests",
            dependencies: [
                "ble",
                .product(name: "BLESwift", package: "BLESwift"),
                .product(name: "BLESwiftCore", package: "BLESwift"),
                .product(name: "BLESwiftTestSupport", package: "BLESwift"),
            ]
        ),
    ]
)
