# DogecoinKit

A pure Swift SDK for building Dogecoin wallets on iOS and macOS.

DogecoinKit provides a complete toolkit for creating SPV (Simplified Payment Verification) Dogecoin wallets, including HD wallet generation, address derivation, transaction building, and peer-to-peer network synchronization.

## Features

- **HD Wallet Support** — BIP32/39/44 compliant hierarchical deterministic wallets
- **Mnemonic Phrases** — Generate and restore wallets using 12-24 word recovery phrases
- **Address Management** — P2PKH address generation and derivation; P2PKH + P2SH validation
- **Transaction Building** — Create, sign, and serialize Dogecoin transactions
- **Electrum + SPV Networking** — Electrum protocol client (SSL) and native Swift P2P networking using Network.framework
- **Header Sync** — Download and validate block headers (scrypt PoW, AuxPoW, checkpoints) for lightweight verification
- **Secure Storage** — Keychain-backed mnemonic storage (`SecureKeyStorage`)
- **Swift 6 Ready** — Full concurrency support with Sendable conformance
- **Cross-Platform** — iOS 17+ and macOS 14+

## Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 6.0+
- Xcode 16.0+

## Installation

### Swift Package Manager

Add DogecoinKit to your project using Xcode:

1. File → Add Package Dependencies...
2. Enter the repository URL or local path
3. Select "DogecoinKit" library

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(path: "../DogecoinKit")
    // Or from a git repository:
    // .package(url: "https://github.com/your-org/DogecoinKit.git", from: "1.0.0")
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

Every API that touches libdogecoin awaits initialization internally, so it is safe to call wallet APIs immediately.

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
let amount2 = DogecoinAmount(koinu: 50_000_000_00)  // 50 DOGE in koinu
let amount3 = try DogecoinAmount(dogeString: "25.5")

// Arithmetic operations
let total = amount1 + amount2 + amount3
print("Total: \(total)")  // "175.50000000 DOGE"

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

Or drive the `TransactionBuilder` actor directly:

```swift
let tx = try await TransactionBuilder()

try await tx.addInput(txid: "abc123...", vout: 0)
try await tx.addOutput(address: "DRecipientAddress...", amount: DogecoinAmount(doge: 50))

_ = try await tx.finalize(
    destinationAddress: "DRecipientAddress...",
    fee: DogecoinAmount(doge: 1),
    totalAmount: DogecoinAmount(doge: 100),
    changeAddress: "DMyChangeAddress..."
)

try await tx.sign(privateKeyWIF: "QPrivateKeyInWIF...")
let signedHex = try await tx.getRawTransaction()
```

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

For the default lightweight mode, `ElectrumSyncManager` speaks the Electrum
protocol over SSL and exposes balance, UTXO, history, and broadcast APIs.

## Architecture

DogecoinKit is built on top of [libdogecoin](https://github.com/dogecoinfoundation/libdogecoin), a C implementation of Dogecoin primitives by the Dogecoin Foundation.

```
┌─────────────────────────────────────────────────────┐
│                   Your iOS App                       │
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
| `Dogecoin` | Library initialization and configuration |
| `HDWallet` | BIP32/39/44 hierarchical deterministic wallet |
| `KeyPair` | Simple public/private key pair |
| `Address` | Address validation and conversion utilities |
| `DogecoinAmount` | Type-safe amount representation |
| `TransactionBuilder` | Transaction construction and signing |
| `PeerManager` | P2P peer connection management |
| `SPVSyncManager` | Block header synchronization |
| `HeaderChain` | Block header storage and validation |

## Network Support

| Network | Port | Address Prefix |
|---------|------|----------------|
| Mainnet | 22556 | D |
| Testnet | 44556 | n |

## Thread Safety

DogecoinKit is designed with Swift concurrency in mind:

- `Dogecoin.initialize()` is thread-safe and idempotent
- Core types (`KeyPair`, `DogecoinAmount`, `DogecoinAddress`) are `Sendable`
- `PeerManager` and `HeaderChain` use internal synchronization
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
- Store mnemonic phrases with `SecureKeyStorage` — it writes to the iOS Keychain
  as `WhenUnlockedThisDeviceOnly`, non-synchronizable, and reads raw `Data` to
  avoid leaving non-zeroizable `String` copies around
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

DogecoinKit uses Swift's native error handling. All throwing functions use `DogecoinError`:

```swift
do {
    let wallet = try HDWallet(mnemonic: userInput, network: .mainnet)
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
- [Sending Transactions](Sources/DogecoinKit/Documentation.docc/Articles/SendingTransactions.md)
- [SPV Synchronization](Sources/DogecoinKit/Documentation.docc/Articles/SPVSynchronization.md)

## Contributing

Contributions are welcome! Please read our contributing guidelines before submitting pull requests.

## License

DogecoinKit is available under the MIT license. See the LICENSE file for more info.

libdogecoin is developed by the Dogecoin Foundation and is also MIT licensed.

## Acknowledgments

- [Dogecoin Foundation](https://foundation.dogecoin.com/) for libdogecoin
- [libdogecoin](https://github.com/dogecoinfoundation/libdogecoin) contributors

---

**Much Crypto. Very Swift. Wow.**
