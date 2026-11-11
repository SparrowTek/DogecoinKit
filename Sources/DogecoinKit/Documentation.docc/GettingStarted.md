# Getting Started with DogecoinKit

Add Dogecoin wallet functionality to your iOS or macOS app.

@Metadata {
    @PageKind(article)
}

## Overview

This guide walks you through integrating DogecoinKit into your iOS or macOS project. By the end, you'll have a working foundation for a Dogecoin wallet. To build for Android, see <doc:UsingDogecoinKitOnAndroid>.

## Adding DogecoinKit to Your Project

### Using Xcode

1. Open your project in Xcode
2. Select **File → Add Package Dependencies...**
3. Enter `https://github.com/SparrowTek/DogecoinKit` and set **Dependency Rule** to **Branch** → `main`, or navigate to a local checkout
4. Click **Add Package**
5. Select the **DogecoinKit** library and add it to your target

### Using Package.swift

If you're building a Swift package, add DogecoinKit as a dependency. DogecoinKit needs Swift 6.1 or later:

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MyWalletApp",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/SparrowTek/DogecoinKit", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "MyWalletApp",
            dependencies: ["DogecoinKit"]
        )
    ]
)
```

## Nothing to Initialize

DogecoinKit needs no start-up call. Each operation prepares the thread it runs on, and throws ``DogecoinError/initializationFailed`` if the secp256k1 context it needs can't be created.

``Dogecoin/initialize()`` is optional. It checks that the library's cryptography can start and returns the answer, so an app can find out at launch instead of at its first wallet operation:

```swift
if await !Dogecoin.initialize() {
    // The cryptography did not start: expect wallet operations to throw
    // DogecoinError.initializationFailed
}
```

## Your First Wallet

Let's create a simple wallet and generate an address:

```swift
import DogecoinKit

func createWallet() async throws -> (wallet: HDWallet, address: String) {
    // Create a new HD wallet with a 12-word mnemonic
    let wallet = try await HDWallet.create(
        strength: .words12,
        network: .mainnet
    )

    // The mnemonic is the user's recovery phrase - store it securely!
    print("Recovery phrase: \(wallet.mnemonic)")

    // Derive the first receiving address
    let address = try await wallet.deriveAddress(account: 0, index: 0)
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
m / 44' / coin' / account' / change / index
        │       │          │        │
        │       │          │        └── Address index (0, 1, 2, ...)
        │       │          └── 0 for receiving, 1 for change
        │       └── Account number (0, 1, 2, ...)
        └── Coin type: 3 on mainnet, 1 on testnet
```

### Deriving Multiple Addresses

A wallet can derive as many addresses as it needs from a single mnemonic:

```swift
// Generate 10 receiving addresses
let receivingAddresses = try await wallet.deriveAddresses(
    count: 10,
    account: 0,
    change: false,
    startIndex: 0
)

// Generate change addresses
let changeAddresses = try await wallet.deriveAddresses(
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
let mainnetWallet = try await HDWallet.create(network: .mainnet)
// Addresses start with 'D'

// For development - test Dogecoin
let testnetWallet = try await HDWallet.create(network: .testnet)
// Addresses start with 'n'
```

> Tip: Always use testnet during development. You can get free testnet DOGE from faucets. DogecoinKit's built-in Electrum server list covers mainnet only, so to sync through Electrum on testnet, pass your own servers to ``ElectrumSyncManager/init(network:servers:)``.

## Next Steps

Now that you have the basics, explore these guides:

- <doc:CreatingAWallet> — Deep dive into wallet creation and restoration
- <doc:WorkingWithAddresses> — Address validation and management
- <doc:HandlingAmounts> — Working with Dogecoin amounts safely
- <doc:SendingTransactions> — Build and broadcast transactions
- <doc:ElectrumSynchronization> — Follow your addresses through an Electrum server
- <doc:SPVSynchronization> — Follow them on the peer-to-peer network, validating block headers yourself

## See Also

- ``Dogecoin``
- ``HDWallet``
- ``DogecoinNetwork``
