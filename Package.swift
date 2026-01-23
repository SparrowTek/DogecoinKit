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
        // SQLite database via GRDB
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "DogecoinKit",
            dependencies: [
                .product(name: "clibdogecoin", package: "libdogecoin"),
                .product(name: "GRDB", package: "GRDB.swift"),
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
