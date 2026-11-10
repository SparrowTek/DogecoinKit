# ``DogecoinKit``

Build Dogecoin wallets for iOS, macOS, and Android with a Swift-native SDK.

@Metadata {
    @DisplayName("DogecoinKit")
}

## Overview

DogecoinKit is a comprehensive Swift SDK for building Dogecoin SPV (Simplified Payment Verification) wallets. It wraps the battle-tested [libdogecoin](https://github.com/dogecoinfoundation/libdogecoin) C library with a modern, Swift-native API.

Whether you're building a simple wallet app or integrating Dogecoin payments into an existing application, DogecoinKit provides all the tools you need:

- Generate HD wallets with BIP39 mnemonic phrases
- Derive addresses following BIP44 standards
- Build and sign transactions
- Sync with the Dogecoin network through Electrum servers or with SPV

### Quick Example

```swift
import DogecoinKit

func quickStart() async throws {
    // Initialize the library
    await Dogecoin.initialize()

    // Create a new wallet
    let wallet = try await HDWallet.create(strength: .words12, network: .mainnet)
    if let mnemonic = wallet.mnemonic {
        print("Backup these words: \(mnemonic)")
    }

    // Generate a receiving address
    let address = try await wallet.deriveAddress(account: 0, index: 0)
    print("Send DOGE to: \(address)")
}
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:UsingDogecoinKitOnAndroid>
- ``Dogecoin``
- ``DogecoinNetwork``
- ``DogecoinError``
- ``WalletMode``

### Wallet Management

- <doc:CreatingAWallet>
- ``HDWallet``
- ``KeyPair``
- ``MnemonicStrength``
- ``generateMnemonic(strength:)``
- ``validateMnemonic(_:)``
- ``validateMnemonicDetailed(_:)``
- ``verifyMnemonic(_:language:)``
- ``MnemonicValidationResult``
- ``MnemonicValidationError``

### BIP39 Word List

- ``bip39WordCount``
- ``getBIP39Wordlist()``
- ``isValidBIP39Word(_:)``
- ``bip39WordsMatching(prefix:limit:)``
- ``bip39WordIndex(_:)``
- ``bip39Word(at:)``

### Secure Storage

- ``SecureKeyStorage``
- ``StoredWalletCredentials``

### Addresses

- <doc:WorkingWithAddresses>
- ``Address``
- ``AddressKind``
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
- ``FeeEstimation``
- ``createTransaction(inputs:outputs:privateKey:changeAddress:fee:)``
- ``createTransaction(inputs:outputs:signingKeysByAddress:changeAddress:fee:)``

### Electrum Synchronization

- ``ElectrumSyncManager``
- ``ElectrumSyncState``
- ``BlockchainSyncManager``
- ``BlockchainSyncDelegate``
- ``SyncState``
- ``ElectrumClient``
- ``ElectrumServer``
- ``ElectrumServerList``
- ``ElectrumError``
- ``ElectrumBalance``
- ``ElectrumUTXO``
- ``ElectrumHistoryItem``
- ``ElectrumHeader``
- ``ElectrumTransaction``
- ``ElectrumScriptHash``
- ``ElectrumSubscription``
- ``ElectrumServerInfo``

### Electrum JSON-RPC

- ``ElectrumMethod``
- ``ElectrumRequest``
- ``ElectrumParam``
- ``ElectrumResponse``
- ``ElectrumRPCError``
- ``ElectrumNull``

### SPV Synchronization

- <doc:SPVSynchronization>
- ``SPVSyncManager``
- ``SPVSyncDelegate``
- ``SPVSyncState``
- ``SPVTransactionState``
- ``BloomFilter``
- ``PeerManager``
- ``PeerManagerDelegate``
- ``Peer``
- ``PeerDelegate``

### Block Headers

- ``HeaderChain``
- ``BlockHeader``
- ``StoredHeader``
- ``AuxPoW``
- ``HeaderDatabase``
- ``HeaderRecord``
- ``HeaderDatabaseError``

### Bundled Header Caches

- ``HeaderCacheMetadata``

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
- ``NotFoundMessage``
- ``InventoryVector``
- ``InventoryType``
- ``HeadersMessage``
- ``GetHeadersMessage``
- ``GetBlocksMessage``
- ``TxMessage``
- ``BlockMessage``
- ``MerkleBlockMessage``
- ``MerkleBlockMatches``
- ``MerkleBlockError``
- ``AddrMessage``
- ``FilterLoadMessage``
- ``FilterAddMessage``
- ``FilterClearMessage``

### Constants & Utilities

- ``NetworkConstants``
- ``LRUCache``
