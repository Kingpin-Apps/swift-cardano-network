// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-cardano-network",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SwiftCardanoNetwork", targets: ["SwiftCardanoNetwork"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.22.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
        .package(url: "https://github.com/Kingpin-Apps/swift-cardano-core.git", from: "0.3.14"),
    ],
    targets: [
        .target(
            name: "SwiftCardanoNetwork",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "SwiftCardanoCore", package: "swift-cardano-core"),
            ],
            path: "Sources/SwiftCardanoNetwork",
            resources: [
                .embedInCode("Resources/version.json")
            ]
        ),
        .testTarget(
            name: "SwiftCardanoNetworkTests",
            dependencies: [
                "SwiftCardanoNetwork",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            path: "Tests/SwiftCardanoNetworkTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
