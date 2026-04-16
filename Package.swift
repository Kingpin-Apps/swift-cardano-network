// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-cardano-network",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "swift-cardano-network",
            targets: ["swift-cardano-network"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "swift-cardano-network"
        ),
        .testTarget(
            name: "swift-cardano-networkTests",
            dependencies: ["swift-cardano-network"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
