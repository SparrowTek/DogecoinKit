# DogecoinKit

A Swift SDK for building Dogecoin wallets on iOS, macOS, and Android.

DogecoinKit provides a complete toolkit for creating SPV (Simplified Payment Verification) Dogecoin wallets, including HD wallet generation, address derivation, transaction building, and peer-to-peer network synchronization.

## Features

- **HD Wallet Support** — BIP32/39/44 compliant hierarchical deterministic wallets
- **Mnemonic Phrases** — Generate and restore wallets using 12-24 word recovery phrases
- **Address Management** — P2PKH address generation and derivation; P2PKH + P2SH validation
- **Transaction Building** — Create, sign, and serialize Dogecoin transactions
- **Electrum + SPV Networking** — Electrum protocol client (SSL) and native Swift P2P networking, over Network.framework on Apple platforms and SwiftNIO on Android
- **Header Sync** — Download and validate block headers (checkpoints, scrypt PoW, AuxPoW, DigiShield difficulty, timestamps) for lightweight verification
- **Secure Storage** — Keychain-backed mnemonic storage (`SecureKeyStorage`, Apple platforms)
- **Swift 6 Ready** — Full concurrency support with Sendable conformance
- **Cross-Platform** — iOS 17+, macOS 14+, and Android (API 28+)

## Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 6.1+ (the GRDB and SwiftNIO releases it depends on require it)
- Xcode 16.3+
- Android: API 28+, built with the Swift SDK for Android (tested with Swift 6.4.1); see [Android](#android)

## Installation

### Swift Package Manager

Add DogecoinKit to your project using Xcode:

1. File → Add Package Dependencies...
2. Enter `https://github.com/SparrowTek/DogecoinKit`
3. Set **Dependency Rule** to **Branch** → `main` (there are no tagged releases yet)
4. Select the "DogecoinKit" library

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/SparrowTek/DogecoinKit", branch: "main")
    // Or a local checkout:
    // .package(path: "../DogecoinKit")
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourApp",
    dependencies: ["DogecoinKit"]
)
```

## Quick Start

### Initialize the Library

`Dogecoin.initialize()` is async — kick it off once when your app launches:

```swift
import SwiftUI
import DogecoinKit

@main
struct MyApp: App {
    init() {
        Task { await Dogecoin.initialize() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

APIs that reach into libdogecoin (`HDWallet`, `generateMnemonic`, `KeyPair`,
`TransactionBuilder`, and the `Address` key conversions) do not wait for
initialization. They throw `DogecoinError.initializationFailed` until it has
finished, and the `Task` above may still be running when your first view
appears. Repeat calls are no-ops, so `await Dogecoin.initialize()` again before
your first wallet call.

### Create a New Wallet

```swift
// Generate a new HD wallet with a 12-word mnemonic
let wallet = try await HDWallet.create(strength: .words12, network: .mainnet)

// IMPORTANT: Back up the mnemonic phrase securely!
if let mnemonic = wallet.mnemonic {
    print("Recovery phrase: \(mnemonic)")
}

// Derive your first receiving address
let address = try await wallet.deriveAddress(account: 0, index: 0)
print("Your Dogecoin address: \(address)")
```

### Restore an Existing Wallet

```swift
let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
let wallet = try await HDWallet(mnemonic: mnemonic, network: .mainnet)

// Derive multiple addresses (external chain, starting at index 0)
let addresses = try await wallet.deriveAddresses(count: 10, account: 0, change: false, startIndex: 0)
```

`HDWallet(mnemonic:)` rejects any phrase that fails full BIP39 validation (an
unknown word or a bad checksum) with `DogecoinError.invalidMnemonic`, so a typo
can't silently open a different, empty wallet.

### Store Credentials in the Keychain

```swift
let storage = SecureKeyStorage(serviceName: "com.example.mywallet")

// Import a mnemonic, persist it, and get a wallet plus its keychain ID
let (wallet, keychainID) = try await storage.importAndStoreWallet(
    mnemonic: mnemonic,
    passphrase: "",
    network: .mainnet
)

// Later — rebuild the wallet from the Keychain
let restored = try await storage.restoreWallet(keychainID: keychainID)
```

### Validate Addresses

```swift
let address = "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"

if Address.isValid(address) {
    if Address.isMainnet(address) {
        print("Valid mainnet address")
    }
}

// Distinguish P2PKH from P2SH
switch Address.kind(address) {
case .p2pkh: print("Pay-to-public-key-hash")
case .p2sh: print("Pay-to-script-hash")
case nil: print("Invalid address")
}

// Or use the type-safe wrapper
let validatedAddress = try DogecoinAddress(address)
print("Network: \(validatedAddress.network)")
```

### Work with Amounts

```swift
// Create amounts in various ways
let amount1 = DogecoinAmount(doge: 100.0)
let amount2 = DogecoinAmount(koinu: 5_000_000_000)  // 50 DOGE in koinu
let amount3 = try DogecoinAmount(dogeString: "25.5")

// Arithmetic operations
let total = amount1 + amount2 + amount3
print("Total: \(total)")  // "Total: 175.50000000 DOGE"

// Format for display
print(total.formatted(decimals: 2))  // "175.50"
```

### Build Transactions

The simplest path is the `createTransaction` convenience, which plans the fee
and change, builds, and signs in one call:

```swift
let utxo = UTXO(
    txid: "abc123...",
    vout: 0,
    address: "DMyAddress...",
    amount: DogecoinAmount(doge: 100),
    scriptPubKey: "76a914...88ac",
    confirmations: 12
)

let signed = try await createTransaction(
    inputs: [utxo],
    outputs: [(address: "DRecipientAddress...", amount: DogecoinAmount(doge: 50))],
    signingKeysByAddress: ["DMyAddress...": "QPrivateKeyInWIF..."],
    changeAddress: "DMyChangeAddress...",
    fee: FeeEstimation.estimateSendFee(inputCount: 1)
)

print("Broadcast this hex: \(signed.rawHex)")
print("txid: \(signed.txid)")
```

Before building anything, `createTransaction` rejects duplicate inputs and
checks that each signing key really owns its input's P2PKH address, so a wrong
key fails fast instead of producing an unspendable signature.

Or drive the `TransactionBuilder` actor directly:

```swift
let tx = try await TransactionBuilder()

try await tx.addInput(txid: "abc123...", vout: 0)
try await tx.addOutput(address: "DRecipientAddress...", amount: DogecoinAmount(doge: 50))

// The 49 DOGE left after the output and fee goes to the change address
_ = try await tx.finalize(
    destinationAddress: "DRecipientAddress...",
    fee: DogecoinAmount(doge: 1),
    totalAmount: DogecoinAmount(doge: 100),
    changeAddress: "DMyChangeAddress..."
)

try await tx.sign(privateKeyWIF: "QPrivateKeyInWIF...")
let signedHex = try await tx.getRawTransaction()
```

`finalize` sends whatever `totalAmount` leaves after the outputs and fee to
`changeAddress` and throws if there is change but no change address. After
that the builder is sealed: no more inputs or outputs. Signing requires a
finalized builder (otherwise the leftover would all go to fees), and each
input can be signed only once.

### Sync with the Network

`SPVSyncManager` is an actor and its delegate methods are async:

```swift
final class WalletSync: SPVSyncDelegate {
    let syncManager = SPVSyncManager(network: .mainnet)

    func startSync() async {
        await syncManager.setDelegate(self)
        await syncManager.start()
    }

    // MARK: - SPVSyncDelegate

    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) async {
        print("Sync: \(Int(progress * 100))% (height \(height))")
    }

    func spvSyncDidComplete(_ manager: SPVSyncManager) async {
        print("Blockchain sync complete!")
    }

    func spvSync(_ manager: SPVSyncManager, didReceiveHeader header: BlockHeader, height: Int32) async {
        // New block header received
    }

    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) async {
        print("Sync error: \(error)")
    }

    func spvSync(_ manager: SPVSyncManager, didUpdateTransaction transaction: TxMessage, state: SPVTransactionState) async {
        // A transaction relevant to the bloom filter was confirmed/unconfirmed/reorged
    }

    func spvSync(_ manager: SPVSyncManager, didProcessFilteredBlock height: Int32, targetHeight: Int32) async {
        // Filtered-block scan progress
    }
}
```

Callbacks arrive in order, and `spvSyncDidComplete` fires each time the chain
catches up, including after every new block. Every header is validated before
it is accepted (checkpoints, scrypt or AuxPoW proof of work, timestamps, and,
on mainnet, DigiShield difficulty and version rules). Peers that send headers
breaking consensus are banned; headers that merely fail a clock-based check are
not held against the peer, matching Dogecoin Core.

For the default lightweight mode, `ElectrumSyncManager` speaks the Electrum
protocol over SSL and exposes balance, UTXO, history, and broadcast APIs. If the
server drops, it reconnects on its own with backoff, restores your address
subscriptions, retries an interrupted read once (broadcasts are never retried),
and calls `syncManagerDidComplete` when it is back so you can refresh. A server
that stops answering is dropped and replaced the same way.

```swift
final class WalletBackend: BlockchainSyncDelegate {
    let electrum = ElectrumSyncManager(network: .mainnet)

    func start(watching addresses: [String]) async throws {
        await electrum.setDelegate(self)
        try await electrum.start()
        try await electrum.subscribeToAddresses(addresses)
    }

    func refresh(_ addresses: [String]) async throws {
        // Koinu, confirmed plus unconfirmed
        let balance = try await electrum.refreshBalance(for: addresses)
        // Every UTXO is checked against its funding transaction
        let utxos = try await electrum.fetchUTXOs(for: addresses)
        let history = try await electrum.fetchTransactionHistory(for: addresses)
        print(DogecoinAmount(koinu: UInt64(max(0, balance))), utxos.count, history.count)
    }

    func send(_ signed: SignedTransaction) async throws -> String {
        // Sent once and never retried; returns the txid
        try await electrum.broadcastTransaction(signed.rawHex)
    }

    // MARK: - BlockchainSyncDelegate

    func syncManagerDidComplete(_ manager: any BlockchainSyncManager) async {
        // Connected, or reconnected after a drop: refresh balances, UTXOs, and history
    }

    func syncManager(_ manager: any BlockchainSyncManager, didEncounterError error: Error) async {
        print("Electrum error: \(error)")
    }
}
```

The built-in server list covers mainnet only; no public testnet Electrum server
is known. For testnet, or to use servers of your own, create the manager with
`ElectrumSyncManager(network:servers:)`. Those servers are tried in the order
given.

Electrum servers are not trusted with amounts. `fetchUTXOs` checks every UTXO
against its funding transaction, which must hash to the claimed txid, and
throws `ElectrumError.invalidResponse` if the server misreports a value or
script. Legacy signatures do not commit to input amounts, so an understated
value could otherwise be signed away as fee. `getTransaction` checks the txid
the same way.

## Architecture

DogecoinKit is built on top of [libdogecoin](https://github.com/dogecoinfoundation/libdogecoin), a C implementation of Dogecoin primitives by the Dogecoin Foundation. The package pulls it from the [radmakr/libdogecoin](https://github.com/radmakr/libdogecoin) fork, branch `0.1.5-dev-swiftpm`.

```
┌─────────────────────────────────────────────────────┐
│                     Your App                         │
├─────────────────────────────────────────────────────┤
│                   DogecoinKit                        │
│  ┌─────────────┐ ┌─────────────┐ ┌───────────────┐  │
│  │   Wallet    │ │ Networking  │ │   SPV Sync    │  │
│  │  HDWallet   │ │    Peer     │ │  HeaderChain  │  │
│  │  KeyPair    │ │ PeerManager │ │SPVSyncManager │  │
│  │  Address    │ │  Protocol   │ │               │  │
│  │Transaction  │ │  Messages   │ │               │  │
│  └─────────────┘ └─────────────┘ └───────────────┘  │
├─────────────────────────────────────────────────────┤
│              clibdogecoin (C Library)               │
│    Cryptography • BIP32/39/44 • Transactions        │
└─────────────────────────────────────────────────────┘
```

### Key Components

| Component | Description |
|-----------|-------------|
| `Dogecoin` | Library initialization |
| `HDWallet` | BIP32/39/44 hierarchical deterministic wallet |
| `KeyPair` | A single private key (WIF) and its P2PKH address |
| `Address` / `DogecoinAddress` | Address validation and conversion utilities |
| `DogecoinAmount` | Type-safe amount representation |
| `TransactionBuilder` / `createTransaction` | Transaction construction and signing |
| `FeeEstimation` | Fee estimates, the minimum fee, and UTXO selection |
| `SecureKeyStorage` | Keychain storage for mnemonics and keys (Apple platforms) |
| `ElectrumSyncManager` | Electrum mode: balances, UTXOs, history, broadcast |
| `SPVSyncManager` | SPV mode: header sync, filtered blocks, broadcast |
| `PeerManager` | P2P peer connection management |
| `HeaderChain` | Block header storage and validation |

## Android

DogecoinKit builds for Android with the
[Swift SDK for Android](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html).
The wallet, transaction, SPV, and Electrum code is the same as on Apple
platforms; SwiftNIO and NIOSSL replace Network.framework, swift-crypto
replaces CryptoKit, and logs go to logcat. `SecureKeyStorage` (Keychain) stays
Apple-only. There is no Kotlin interface yet: an app calls DogecoinKit through
a JNI bridge such as swift-java.

GRDB needs SQLite, which the NDK doesn't ship, so build it first, then point
`swift build` at it:

```sh
Scripts/build-android-sqlite.sh arm64-v8a
swift build \
    --swift-sdk swift-6.4.1-RELEASE_android \
    --triple aarch64-unknown-linux-android28 \
    -Xcc -I.build/android-sqlite/include \
    -Xlinker -L.build/android-sqlite/arm64-v8a
```

Ship `libsqlite3.so` in the app's `jniLibs/<ABI>` folder with the Swift
runtime libraries and the NDK's `libc++_shared.so`. Android apps have no home
directory, so pass a `storageDirectory` inside the app's files directory to
`SPVSyncManager` or `HeaderChain`. To run the test suite on a connected device
or emulator:

```sh
SWIFT=/path/to/swift-6.4.1-RELEASE/usr/bin/swift Scripts/test-android.sh arm64-v8a
```

See [Using DogecoinKit on Android](Sources/DogecoinKit/Documentation.docc/Articles/UsingDogecoinKitOnAndroid.md)
for the details.

## Network Support

| Network | Port | Address Prefix |
|---------|------|----------------|
| Mainnet | 22556 | D |
| Testnet | 44556 | n |

## Thread Safety

DogecoinKit is designed with Swift concurrency in mind:

- `Dogecoin.initialize()` is thread-safe and idempotent
- Core types (`KeyPair`, `DogecoinAmount`, `DogecoinAddress`) are `Sendable`
- `TransactionBuilder`, `SecureKeyStorage`, `SPVSyncManager`, `PeerManager`,
  `Peer`, `HeaderChain`, and the Electrum client and sync manager are actors.
  `await` their methods and properties, and use methods like `setDelegate(_:)`,
  because actor properties can't be assigned from outside
- `HDWallet` is a `Sendable` final class safe for concurrent reads

For mutable wallet state management, we recommend using Swift actors:

```swift
actor WalletState {
    private var utxos: [UTXO] = []
    private var transactions: [SignedTransaction] = []

    func addUTXO(_ utxo: UTXO) {
        utxos.append(utxo)
    }

    var balance: DogecoinAmount {
        utxos.reduce(.zero) { $0 + $1.amount }
    }
}
```

## Security Considerations

- **Never** log or display private keys or mnemonic phrases in production
- Store mnemonic phrases with `SecureKeyStorage` — it writes to the Keychain
  (iOS and macOS) as `WhenUnlockedThisDeviceOnly` and non-synchronizable, and
  decodes the stored bytes without an intermediate `String`. The phrase itself
  still reaches you as a Swift `String`, which can't be zeroized. On Android,
  use the Android Keystore
- Use the **same `serviceName`** for every `SecureKeyStorage` you construct in
  an app — the Keychain scopes items by service, so mismatched names read as
  "key not found"
- Validate all addresses before sending transactions

```swift
// Example: Secure mnemonic storage
let storage = SecureKeyStorage(serviceName: "com.example.mywallet")
let (wallet, keychainID) = try await storage.importAndStoreWallet(
    mnemonic: mnemonic,
    passphrase: "",
    network: .mainnet
)
// Persist `keychainID` (not the mnemonic!) in your app's database
```

## Error Handling

DogecoinKit uses Swift's native error handling. Wallet, key, address, amount,
transaction, peer-broadcast, and keychain APIs throw `DogecoinError`. The
Electrum types throw `ElectrumError`, plus `DecodingError` when a server sends
a malformed payload and `CancellationError` when the calling task is cancelled
during a request. A broadcast already under way is not abandoned.

```swift
do {
    let wallet = try await HDWallet(mnemonic: userInput, network: .mainnet)
} catch DogecoinError.invalidMnemonic {
    showAlert("Invalid recovery phrase. Please check and try again.")
} catch {
    showAlert("An error occurred: \(error.localizedDescription)")
}
```

## Documentation

Full API documentation is available in DocC format. To view:

1. Open the project in Xcode
2. Product → Build Documentation
3. Navigate to DogecoinKit in the documentation browser

## Examples

See the [Documentation](Sources/DogecoinKit/Documentation.docc) for comprehensive guides:

- [Getting Started](Sources/DogecoinKit/Documentation.docc/GettingStarted.md)
- [Creating a Wallet](Sources/DogecoinKit/Documentation.docc/Articles/CreatingAWallet.md)
- [Working with Addresses](Sources/DogecoinKit/Documentation.docc/Articles/WorkingWithAddresses.md)
- [Handling Amounts](Sources/DogecoinKit/Documentation.docc/Articles/HandlingAmounts.md)
- [Sending Transactions](Sources/DogecoinKit/Documentation.docc/Articles/SendingTransactions.md)
- [SPV Synchronization](Sources/DogecoinKit/Documentation.docc/Articles/SPVSynchronization.md)
- [Using DogecoinKit on Android](Sources/DogecoinKit/Documentation.docc/Articles/UsingDogecoinKitOnAndroid.md)

## Contributing

Contributions are welcome! Open an issue or pull request at https://github.com/SparrowTek/DogecoinKit.

## License

DogecoinKit is available under the MIT license.

libdogecoin is developed by the Dogecoin Foundation and is also MIT licensed.

## Acknowledgments

- [Dogecoin Foundation](https://foundation.dogecoin.com/) for libdogecoin
- [libdogecoin](https://github.com/dogecoinfoundation/libdogecoin) contributors

---

**Much Crypto. Very Swift. Wow.**
