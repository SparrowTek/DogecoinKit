# DogecoinKit

A pure Swift SDK for building Dogecoin wallets on iOS and macOS.

DogecoinKit provides a complete toolkit for creating SPV (Simplified Payment Verification) Dogecoin wallets, including HD wallet generation, address derivation, transaction building, and peer-to-peer network synchronization.

## Features

- **HD Wallet Support** — BIP32/39/44 compliant hierarchical deterministic wallets
- **Mnemonic Phrases** — Generate and restore wallets using 12-24 word recovery phrases
- **Address Management** — P2PKH address generation, validation, and derivation
- **Transaction Building** — Create, sign, and serialize Dogecoin transactions
- **SPV Networking** — Native Swift P2P networking using Network.framework
- **Header Sync** — Download and validate block headers for lightweight verification
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

Call `Dogecoin.initialize()` once when your app launches:

```swift
import DogecoinKit

@main
struct MyApp: App {
    init() {
        Dogecoin.initialize()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

### Create a New Wallet

```swift
// Generate a new HD wallet with a 12-word mnemonic
let wallet = try HDWallet.create(strength: .words12, network: .mainnet)

// IMPORTANT: Back up the mnemonic phrase securely!
print("Recovery phrase: \(wallet.mnemonic!)")

// Derive your first receiving address
let address = try wallet.deriveAddress(account: 0, index: 0)
print("Your Dogecoin address: \(address)")
```

### Restore an Existing Wallet

```swift
let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
let wallet = try HDWallet(mnemonic: mnemonic, network: .mainnet)

// Derive multiple addresses
let addresses = try wallet.deriveAddresses(count: 10, account: 0)
```

### Validate Addresses

```swift
let address = "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"

if Address.isValid(address) {
    if Address.isMainnet(address) {
        print("Valid mainnet address")
    }
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

```swift
// Create a transaction builder
let tx = try TransactionBuilder()

// Add inputs (UTXOs you're spending)
try tx.addInput(txid: "abc123...", vout: 0)
try tx.addInput(txid: "def456...", vout: 1)

// Add outputs (recipients)
try tx.addOutput(address: "DRecipientAddress...", amount: DogecoinAmount(doge: 50))

// Finalize with fee and change address
let rawTx = try tx.finalize(
    destinationAddress: "DRecipientAddress...",
    fee: DogecoinAmount(doge: 1),
    totalAmount: DogecoinAmount(doge: 100),
    changeAddress: "DMyChangeAddress..."
)

// Sign with your private key
try tx.sign(privateKeyWIF: "QPrivateKeyInWIF...")

// Get the signed transaction hex for broadcasting
let signedHex = try tx.getRawTransaction()
```

### Sync with the Network

```swift
class WalletManager: SPVSyncDelegate {
    let syncManager = SPVSyncManager(network: .mainnet)

    func startSync() {
        syncManager.delegate = self
        syncManager.start()
    }

    // MARK: - SPVSyncDelegate

    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) {
        print("Sync: \(Int(progress * 100))% (height \(height))")
    }

    func spvSyncDidComplete(_ manager: SPVSyncManager) {
        print("Blockchain sync complete!")
    }

    func spvSync(_ manager: SPVSyncManager, didReceiveHeader header: BlockHeader, height: Int32) {
        // New block header received
    }

    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) {
        print("Sync error: \(error)")
    }
}
```

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
- Store mnemonic phrases in the iOS Keychain with appropriate protection levels
- Use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for sensitive data
- Consider using Secure Enclave for additional key protection on supported devices
- Validate all addresses before sending transactions

```swift
// Example: Secure mnemonic storage
import Security

func storeMnemonic(_ mnemonic: String, identifier: String) throws {
    let data = Data(mnemonic.utf8)
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: identifier,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ]

    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
        throw WalletError.keychainError(status)
    }
}
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
