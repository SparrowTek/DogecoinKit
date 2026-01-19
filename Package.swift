// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DogecoinKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DogecoinKit",
            targets: ["DogecoinKit"]
        )
    ],
    dependencies: [
        // Local dependency on libdogecoin C library
        .package(path: "../libdogecoin"),
    ],
    targets: [
        .target(
            name: "DogecoinKit",
            dependencies: [
                .product(name: "clibdogecoin", package: "libdogecoin"),
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "DogecoinKitTests",
            dependencies: ["DogecoinKit"]
        )
    ]
)
