# Getting Started with DogecoinKit

Add Dogecoin wallet functionality to your iOS or macOS app.

@Metadata {
    @PageKind(article)
    @PageImage(purpose: card, source: "getting-started-card", alt: "Getting started with DogecoinKit")
}

## Overview

This guide walks you through integrating DogecoinKit into your iOS or macOS project. By the end, you'll have a working foundation for a Dogecoin wallet.

## Adding DogecoinKit to Your Project

### Using Xcode

1. Open your project in Xcode
2. Select **File → Add Package Dependencies...**
3. Enter the DogecoinKit repository URL or navigate to the local package
4. Click **Add Package**
5. Select the **DogecoinKit** library and add it to your target

### Using Package.swift

If you're building a Swift package, add DogecoinKit as a dependency:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyWalletApp",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../DogecoinKit")
    ],
    targets: [
        .executableTarget(
            name: "MyWalletApp",
            dependencies: ["DogecoinKit"]
        )
    ]
)
```

## Initializing the Library

DogecoinKit requires one-time initialization before using cryptographic functions. The best place to do this is at app launch.

### SwiftUI App

```swift
import SwiftUI
import DogecoinKit

@main
struct MyWalletApp: App {
    init() {
        // Initialize DogecoinKit's cryptographic context
        Dogecoin.initialize()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

### UIKit App

```swift
import UIKit
import DogecoinKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Initialize DogecoinKit's cryptographic context
        Dogecoin.initialize()
        return true
    }
}
```

> Important: Call ``Dogecoin/initialize()`` before using any wallet, key, or transaction functions. It's safe to call multiple times—subsequent calls are no-ops.

## Your First Wallet

Let's create a simple wallet and generate an address:

```swift
import DogecoinKit

func createWallet() throws -> (wallet: HDWallet, address: String) {
    // Create a new HD wallet with a 12-word mnemonic
    let wallet = try HDWallet.create(
        strength: .words12,
        network: .mainnet
    )

    // The mnemonic is the user's recovery phrase - store it securely!
    guard let mnemonic = wallet.mnemonic else {
        throw WalletError.noMnemonic
    }
    print("Recovery phrase: \(mnemonic)")

    // Derive the first receiving address
    let address = try wallet.deriveAddress(account: 0, index: 0)
    print("Address: \(address)")

    return (wallet, address)
}
```

## Understanding HD Wallets

DogecoinKit uses Hierarchical Deterministic (HD) wallets following industry standards:

| Standard | Purpose |
|----------|---------|
| BIP39 | Mnemonic phrase generation |
| BIP32 | Key derivation hierarchy |
| BIP44 | Multi-account structure |

The derivation path for Dogecoin addresses follows this structure:

```
m / 44' / 3' / account' / change / index
        │    │          │        │
        │    │          │        └── Address index (0, 1, 2, ...)
        │    │          └── 0 for receiving, 1 for change
        │    └── Account number (0, 1, 2, ...)
        └── Dogecoin coin type
```

### Deriving Multiple Addresses

A wallet can generate unlimited addresses from a single mnemonic:

```swift
// Generate 10 receiving addresses
let receivingAddresses = try wallet.deriveAddresses(
    count: 10,
    account: 0,
    change: false,
    startIndex: 0
)

// Generate change addresses
let changeAddresses = try wallet.deriveAddresses(
    count: 5,
    account: 0,
    change: true,
    startIndex: 0
)
```

## Choosing a Network

DogecoinKit supports both mainnet (real Dogecoin) and testnet (for development):

```swift
// For production - real Dogecoin
let mainnetWallet = try HDWallet.create(network: .mainnet)
// Addresses start with 'D'

// For development - test Dogecoin
let testnetWallet = try HDWallet.create(network: .testnet)
// Addresses start with 'n'
```

> Tip: Always use testnet during development. You can get free testnet DOGE from faucets.

## Next Steps

Now that you have the basics, explore these guides:

- <doc:CreatingAWallet> — Deep dive into wallet creation and restoration
- <doc:WorkingWithAddresses> — Address validation and management
- <doc:HandlingAmounts> — Working with Dogecoin amounts safely
- <doc:SendingTransactions> — Build and broadcast transactions
- <doc:SPVSynchronization> — Sync with the Dogecoin network

## See Also

- ``Dogecoin``
- ``HDWallet``
- ``DogecoinNetwork``
