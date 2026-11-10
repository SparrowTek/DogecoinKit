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
//        .package(path: "../libdogecoin"),
        .package(url: "https://github.com/radmakr/libdogecoin", branch: "0.1.5-dev-swiftpm"),
        // 7.10 is the first GRDB release that builds for Android.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.10.0"),
        .package(url: "https://github.com/apple/swift-crypto", "3.0.0"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.37.0"),
    ],
    targets: [
        .target(
            name: "DogecoinKitShims",
            dependencies: [
                .product(name: "clibdogecoin", package: "libdogecoin"),
            ]
        ),
        .target(
            name: "DogecoinKit",
            dependencies: [
                "DogecoinKitShims",
                .product(name: "clibdogecoin", package: "libdogecoin"),
                .product(name: "GRDB", package: "GRDB.swift"),
                // Android has neither Network.framework nor CryptoKit: SwiftNIO
                // and NIOSSL carry the P2P and Electrum connections there, and
                // swift-crypto does the hashing.
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.android])),
                .product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.android])),
                .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.android])),
                .product(name: "NIOTLS", package: "swift-nio", condition: .when(platforms: [.android])),
                .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(platforms: [.android])),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                // Logging goes to logcat on Android.
                .linkedLibrary("log", .when(platforms: [.android]))
            ]
        ),
        .testTarget(
            name: "DogecoinKitTests",
            dependencies: ["DogecoinKit"]
        )
    ]
)
