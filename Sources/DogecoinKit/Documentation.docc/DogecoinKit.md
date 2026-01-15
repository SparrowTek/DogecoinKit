# ``DogecoinKit``

Build Dogecoin wallets for iOS and macOS with a pure Swift SDK.

@Metadata {
    @DisplayName("DogecoinKit")
    @PageImage(purpose: icon, source: "dogecoin-icon", alt: "The DogecoinKit framework icon")
}

## Overview

DogecoinKit is a comprehensive Swift SDK for building Dogecoin SPV (Simplified Payment Verification) wallets. It wraps the battle-tested [libdogecoin](https://github.com/dogecoinfoundation/libdogecoin) C library with a modern, Swift-native API.

Whether you're building a simple wallet app or integrating Dogecoin payments into an existing application, DogecoinKit provides all the tools you need:

- Generate HD wallets with BIP39 mnemonic phrases
- Derive addresses following BIP44 standards
- Build and sign transactions
- Sync with the Dogecoin network using SPV

### Quick Example

```swift
import DogecoinKit

// Initialize the library
Dogecoin.initialize()

// Create a new wallet
let wallet = try HDWallet.create(strength: .words12, network: .mainnet)
print("Backup these words: \(wallet.mnemonic!)")

// Generate a receiving address
let address = try wallet.deriveAddress(account: 0, index: 0)
print("Send DOGE to: \(address)")
```

## Topics

### Essentials

- <doc:GettingStarted>
- ``Dogecoin``
- ``DogecoinNetwork``
- ``DogecoinError``

### Wallet Management

- <doc:CreatingAWallet>
- ``HDWallet``
- ``KeyPair``
- ``MnemonicStrength``
- ``generateMnemonic(strength:)``
- ``validateMnemonic(_:)``

### Addresses

- <doc:WorkingWithAddresses>
- ``Address``
- ``DogecoinAddress``

### Amounts & Currency

- <doc:HandlingAmounts>
- ``DogecoinAmount``
- ``koinuToDogeString(_:)``
- ``dogeStringToKoinu(_:)``

### Transactions

- <doc:SendingTransactions>
- ``TransactionBuilder``
- ``UTXO``
- ``SignedTransaction``
- ``createTransaction(inputs:outputs:privateKey:changeAddress:fee:)``
- ``createTransaction(inputs:outputs:signingKeysByAddress:changeAddress:fee:)``

### Network & Synchronization

- <doc:SPVSynchronization>
- ``SPVSyncManager``
- ``SPVSyncDelegate``
- ``SPVSyncState``
- ``PeerManager``
- ``PeerManagerDelegate``
- ``Peer``
- ``PeerDelegate``

### Block Headers

- ``HeaderChain``
- ``BlockHeader``
- ``StoredHeader``

### Protocol Messages

- ``ProtocolMessage``
- ``VersionMessage``
- ``NetworkAddress``
- ``VarInt``
- ``PingMessage``
- ``PongMessage``
- ``VerackMessage``
- ``InvMessage``
- ``GetDataMessage``
- ``InventoryVector``
- ``InventoryType``
- ``HeadersMessage``
- ``GetHeadersMessage``
- ``GetBlocksMessage``

### Constants

- ``NetworkConstants``
