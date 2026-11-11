# DogecoinKit

A Swift SDK for building Dogecoin wallets on iOS, macOS, and Android.

DogecoinKit provides the parts of a self-custody Dogecoin wallet: HD wallet generation, address derivation, coin selection and fees, transaction building and signing, and two ways to follow the chain:

- **Electrum mode** asks an Electrum server about the wallet's addresses. It keeps no copy of the header chain and nothing on disk, and it takes the server's word for what is in the chain.
- **SPV mode** (Simplified Payment Verification) connects to Dogecoin peers directly, keeps the chain of block headers and validates every header it downloads, and finds the wallet's transactions with BIP 37 bloom filters and merkle proofs.

## Features

- **HD Wallet Support** — BIP32/39/44 compliant hierarchical deterministic wallets
- **Mnemonic Phrases** — Generate and restore wallets using 12-24 word recovery phrases
- **Address Management** — P2PKH address generation and derivation; P2PKH + P2SH validation
- **Coin Selection and Fees** — `SpendPlan` chooses inputs and works out the fee and change under Dogecoin Core's fee and dust rules
- **Transaction Building** — Create, sign, and serialize Dogecoin transactions
- **Electrum Sync** — Electrum protocol client (SSL): verified UTXOs, history, address notifications, broadcast, and automatic reconnection
- **SPV Sync** — Native Swift P2P networking: header download and validation (checkpoints, scrypt PoW, AuxPoW, DigiShield difficulty, timestamps), a bloom-filtered scan for the wallet's transactions, and broadcast
- **Secure Storage** — Keychain-backed mnemonic storage (`SecureKeyStorage`, Apple platforms)
- **Swift 6 Ready** — Full concurrency support with Sendable conformance
- **Cross-Platform** — iOS 17+, macOS 14+, and Android (API 28+), over Network.framework on Apple platforms and SwiftNIO on Android

## Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 6.1+ (the package manifest and the GRDB and SwiftNIO releases it depends on require it)
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

There is nothing to initialize: each operation prepares the thread it runs on.
`Dogecoin.initialize()` is optional. It returns whether the library's
cryptography can start, which lets an app find that out at launch instead of
at its first wallet operation. An operation that cannot start it throws
`DogecoinError.initializationFailed`.

### Create a New Wallet

```swift
import DogecoinKit

// Generate a new HD wallet with a 12-word mnemonic
let wallet = try await HDWallet.create(strength: .words12, network: .mainnet)

// IMPORTANT: Back up the mnemonic phrase securely!
print("Recovery phrase: \(wallet.mnemonic)")

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
can't silently open a different, empty wallet. The phrase is normalized first,
so capitals, extra spaces, and line breaks don't matter.

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

// As text with exactly 8 decimal places, or as koinu
print(total.dogeString)  // "175.50000000"
print(total.koinu)       // 17550000000
```

### Build Transactions

`SpendPlan` chooses which outputs to spend and works out the fee and the
change. `createTransaction` builds and signs what was planned:

```swift
func send(
    _ amount: DogecoinAmount,
    to recipient: String,
    from utxos: [UTXO],
    signingKeysByAddress: [String: String],
    changeAddress: String
) async throws -> SignedTransaction {
    // Largest outputs first, at the standard rate of 0.01 DOGE per 1,000
    // bytes; unconfirmed outputs are left alone
    let plan = try SpendPlan(paying: [amount], from: utxos)

    let signed = try await createTransaction(
        inputs: plan.inputs,
        outputs: [(address: recipient, amount: amount)],
        signingKeysByAddress: signingKeysByAddress,
        changeAddress: changeAddress,
        fee: plan.fee
    )

    print("Broadcast this hex: \(signed.rawHex)")
    print("txid: \(signed.txid), fee: \(plan.fee), change: \(plan.change)")
    return signed
}
```

`signingKeysByAddress` maps each input's address to its private key in WIF, as
`HDWallet.derivePrivateKey` returns it. To send everything, ask
`SpendPlan.maximumPayment(from:)` for the amount first.

Before building anything, `createTransaction` rejects duplicate inputs and
outputs below the 0.001 DOGE dust limit, and checks that each signing key
really owns its input's P2PKH address, so a wrong key fails fast instead of
producing an unspendable signature. It raises a fee that is below what nodes
relay, and adds change smaller than 0.01 DOGE to the fee.

Or drive the `TransactionBuilder` actor directly. It applies none of those
rules: the fee, the change, and the right key for each input are yours to get
right.

```swift
let builder = TransactionBuilder()

try await builder.addInput(txid: utxo.txid, vout: utxo.vout)
try await builder.addOutput(address: recipient, amount: DogecoinAmount(doge: 50))

// What the input leaves after the output and the fee goes to the change address
_ = try await builder.finalize(
    fee: FeeEstimation.typicalFee,
    totalAmount: utxo.amount,
    changeAddress: changeAddress
)

try await builder.signInput(index: 0, privateKeyWIF: privateKeyWIF)
let signedHex = try await builder.getRawTransaction()
```

`finalize` sends whatever `totalAmount` leaves after the outputs and fee to
`changeAddress` and throws if there is change but no change address. After
that the builder is sealed: no more inputs or outputs. Signing requires a
finalized builder (otherwise the leftover would all go to fees), and each
input can be signed only once.

### Sync with an Electrum Server

`ElectrumSyncManager` is an actor that speaks the Electrum protocol and exposes
UTXO, history, and broadcast APIs. Its delegate methods are async:

```swift
final class WalletBackend: ElectrumSyncDelegate {
    let electrum = ElectrumSyncManager(network: .mainnet)
    let addresses: [String]

    init(addresses: [String]) {
        self.addresses = addresses
    }

    func start() async throws {
        await electrum.setDelegate(self)
        try await electrum.start()
    }

    func refresh() async throws {
        // Subscribe before fetching: what changes in between is then reported.
        // Addresses that are already watched are skipped
        try await electrum.subscribeToAddresses(addresses)

        // Every UTXO is checked against its funding transaction
        let utxos = try await electrum.fetchUTXOs(for: addresses)
        let history = try await electrum.fetchTransactionHistory(for: addresses)
        let balance = utxos.reduce(DogecoinAmount.zero) { $0 + DogecoinAmount(koinu: UInt64($1.utxo.value)) }
        print(balance, utxos.count, history.count)
    }

    func send(_ signed: SignedTransaction) async throws -> String {
        // Sent once and never retried; returns the txid
        try await electrum.broadcastTransaction(signed.rawHex)
    }

    // MARK: - ElectrumSyncDelegate

    func electrumSyncDidConnect(_ manager: ElectrumSyncManager) async {
        // Connected, or reconnected after a drop: catch up
        try? await refresh()
    }

    func electrumSync(_ manager: ElectrumSyncManager, didObserveActivityAt address: String) async {
        // A transaction arrived, confirmed, or was dropped at this address
        try? await refresh()
    }
}
```

If the server drops, the manager reconnects on its own with backoff, restores
your address subscriptions, retries an interrupted read once (broadcasts are
never retried), and calls `electrumSyncDidConnect` when it is back so you can
refresh. A server that stops answering is dropped and replaced the same way.
An address whose history changed while the manager was away is reported as
activity.

A broadcast whose connection is lost before the server answers throws
`ElectrumError.broadcastOutcomeUnknown(txid:)`: the transaction may have been
accepted. Ask `isTransactionKnown(txid:)` before spending the same outputs
again.

The built-in server list covers mainnet only; no public testnet Electrum server
is known. For testnet, or to use servers of your own, create the manager with
`ElectrumSyncManager(network:servers:)`. Those servers are tried in the order
given, and one that says it indexes another chain is refused.

Electrum servers are not trusted with amounts. `fetchUTXOs` checks every UTXO
against its funding transaction, which must hash to the claimed txid, and
throws `ElectrumError.invalidResponse` if the server misreports a value or
script. Legacy signatures do not commit to input amounts, so an understated
value could otherwise be signed away as fee. `getTransaction` checks the txid
the same way. That proves an output is what its transaction says, not that the
transaction is in the chain: for that, and for which transactions exist at
all, the server is taken at its word. It also sees every address the wallet
asks about.

### Sync with SPV

`SPVSyncManager` is an actor too, with async delegate methods:

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

    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) async {
        // The header database could not be opened, read, or written; the sync has stopped
        print("Sync error: \(error)")
    }

    func spvSync(_ manager: SPVSyncManager, didUpdateTransaction transaction: TxMessage, state: SPVTransactionState) async {
        // One of the wallet's transactions is unconfirmed, confirmed, or reorged
    }

    func spvSync(_ manager: SPVSyncManager, didScanThrough height: Int32, targetHeight: Int32) async {
        // Every block up to `height` has been searched: a later scan can start above it
    }
}
```

Callbacks arrive in order, and `spvSyncDidComplete` fires each time the chain
catches up, including after every new block. Every header is validated before
it is accepted (checkpoints, scrypt or AuxPoW proof of work, timestamps, and,
on mainnet, DigiShield difficulty and version rules). Peers that send headers
breaking consensus are banned; headers that merely fail a clock-based check are
not held against the peer, matching Dogecoin Core.

The last two callbacks need a bloom filter. Give the manager the wallet's
public key hashes with `configureBloomFilter(elements:startHeight:)` and it
scans filtered blocks from `startHeight`, verifying each merkle proof. The
filter narrows the wallet's addresses down for the peers that receive it; it
does not hide them.

## Architecture

DogecoinKit is built on top of [libdogecoin](https://github.com/dogecoinfoundation/libdogecoin), a C implementation of Dogecoin primitives by the Dogecoin Foundation. The package pulls it from the [radmakr/libdogecoin](https://github.com/radmakr/libdogecoin) fork, pinned to revision `3350908af0f9a492a54fed8f6e0fa3a5ace72ffb` of its `0.1.5-dev-swiftpm` branch.

```
┌───────────────────────────────────────────────────────────────────────┐
│                                Your App                               │
├───────────────────────────────────────────────────────────────────────┤
│                              DogecoinKit                              │
│  ┌────────────────────┐ ┌─────────────────────┐ ┌──────────────────┐  │
│  │       Wallet       │ │    Electrum mode    │ │     SPV mode     │  │
│  ├────────────────────┤ ├─────────────────────┤ ├──────────────────┤  │
│  │      HDWallet      │ │ ElectrumSyncManager │ │  SPVSyncManager  │  │
│  │      Address       │ │    ElectrumClient   │ │   PeerManager    │  │
│  │     SpendPlan      │ │                     │ │   HeaderChain    │  │
│  │ TransactionBuilder │ │                     │ │   BloomFilter    │  │
│  │  SecureKeyStorage  │ │  → Electrum server  │ │ → Dogecoin peers │  │
│  └────────────────────┘ └─────────────────────┘ └──────────────────┘  │
├───────────────────────────────────────────────────────────────────────┤
│                        clibdogecoin (C Library)                       │
│               Cryptography • BIP32/39/44 • Transactions               │
└───────────────────────────────────────────────────────────────────────┘
```

The wallet types work the same in either mode. An app picks one mode, or
offers both: nothing in the package ties a wallet to one of them.

### Key Components

| Component | Description |
|-----------|-------------|
| `Dogecoin` | Optional start-up check of the library's cryptography |
| `HDWallet` | BIP32/39/44 hierarchical deterministic wallet |
| `Address` / `DogecoinAddress` | Address validation and conversion utilities |
| `DogecoinAmount` | Type-safe amount representation |
| `SpendPlan` | Coin selection: the inputs, fee, and change for a payment |
| `TransactionBuilder` / `createTransaction` | Transaction construction and signing |
| `FeeEstimation` | Dogecoin Core's fee and dust policy, and fee estimates |
| `RawTransaction` | Decodes transactions received from a server or a peer |
| `SecureKeyStorage` | Keychain storage for mnemonics (Apple platforms) |
| `ElectrumSyncManager` | Electrum mode: verified UTXOs, history, notifications, broadcast |
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

- No start-up call is needed. Each operation prepares the thread it runs on,
  so the wallet functions can be called from any task
- Value types such as `DogecoinAmount`, `DogecoinAddress`, `UTXO`,
  `SignedTransaction`, and `SpendPlan` are `Sendable`
- `TransactionBuilder`, `SecureKeyStorage`, `SPVSyncManager`, `PeerManager`,
  `Peer`, `HeaderChain`, and the Electrum client and sync manager are actors.
  `await` their methods and properties, and use methods like `setDelegate(_:)`,
  because actor properties can't be assigned from outside
- `HDWallet` is a `Sendable` final class safe for concurrent reads
- Delegates are held weakly and must be `Sendable`. Their callbacks arrive one
  at a time, in order

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
- Neither sync mode hides the wallet from the network. An Electrum server sees
  the addresses it is asked about and the IP address that asks; SPV peers see
  that IP address and a bloom filter that lets them guess at the addresses

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
transaction, peer-broadcast, and keychain APIs throw `DogecoinError`, and
`SpendPlan` throws `SpendPlan.Failure`. The Electrum types throw
`ElectrumError`, plus `DecodingError` when a server sends a malformed payload
and `CancellationError` when the calling task is cancelled during a request. A
broadcast already under way is not abandoned. `SPVSyncManager.create` and the
`HeaderChain` lookups throw whatever kept the header database from being
opened or read: `HeaderDatabaseError`, or the file-system or SQLite error
underneath.

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
- [Electrum Synchronization](Sources/DogecoinKit/Documentation.docc/Articles/ElectrumSynchronization.md)
- [SPV Synchronization](Sources/DogecoinKit/Documentation.docc/Articles/SPVSynchronization.md)
- [Using DogecoinKit on Android](Sources/DogecoinKit/Documentation.docc/Articles/UsingDogecoinKitOnAndroid.md)

## Contributing

Contributions are welcome! Open an issue or pull request at https://github.com/SparrowTek/DogecoinKit.

## License

DogecoinKit is available under the MIT license. See [LICENSE](LICENSE).

libdogecoin is developed by the Dogecoin Foundation and is also MIT licensed.

## Acknowledgments

- [Dogecoin Foundation](https://foundation.dogecoin.com/) for libdogecoin
- [libdogecoin](https://github.com/dogecoinfoundation/libdogecoin) contributors

---

**Much Crypto. Very Swift. Wow.**
