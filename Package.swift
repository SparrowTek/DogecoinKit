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
        // Secure keychain storage
        .package(url: "https://github.com/SparrowTek/Vault", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "DogecoinKit",
            dependencies: [
                .product(name: "clibdogecoin", package: "libdogecoin"),
                .product(name: "Vault", package: "Vault")
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
