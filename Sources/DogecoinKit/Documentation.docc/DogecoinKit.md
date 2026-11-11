# ``DogecoinKit``

Build Dogecoin wallets for iOS, macOS, and Android with a Swift-native SDK.

@Metadata {
    @DisplayName("DogecoinKit")
}

## Overview

DogecoinKit is a Swift SDK for building self-custody Dogecoin wallets. It wraps the [libdogecoin](https://github.com/dogecoinfoundation/libdogecoin) C library for keys, derivation, and signing with a modern, Swift-native API, and adds the networking a wallet needs.

Whether you're building a simple wallet app or integrating Dogecoin payments into an existing application, DogecoinKit provides the tools you need:

- Generate HD wallets with BIP39 mnemonic phrases
- Derive addresses following BIP44 standards
- Choose inputs, work out fees, and build and sign transactions
- Follow the chain through an Electrum server or with SPV

### Two Ways to Sync

A wallet learns about its transactions in one of two modes. The wallet, address, and transaction types are the same in both, and nothing ties a wallet to one of them.

| | Electrum mode | SPV mode |
|---|---|---|
| Start with | <doc:ElectrumSynchronization> | <doc:SPVSynchronization> |
| Entry point | ``ElectrumSyncManager`` | ``SPVSyncManager`` |
| Talks to | One Electrum server at a time | Several Dogecoin peers |
| Keeps on disk | Nothing | Every block header, in a SQLite database |
| Checks | Each unspent output against the transaction that created it | Every header it downloads, and a merkle proof for each confirmed transaction |
| Takes on trust | Which transactions exist and whether they are in the chain | That peers leave none of the wallet's transactions out |
| Shows the other side | The addresses it asks about | A bloom filter that narrows the addresses down |

### Quick Example

```swift
import DogecoinKit

func quickStart() async throws {
    // Create a new wallet
    let wallet = try await HDWallet.create(strength: .words12, network: .mainnet)
    print("Backup these words: \(wallet.mnemonic)")

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

### Wallet Management

- <doc:CreatingAWallet>
- ``HDWallet``
- ``MnemonicStrength``
- ``generateMnemonic(strength:)``
- ``normalizedMnemonic(_:)``
- ``validateMnemonicDetailed(_:)``
- ``verifyMnemonic(_:language:)``
- ``MnemonicValidationResult``
- ``MnemonicValidationError``

### BIP39 Word List

- ``bip39WordCount``
- ``getBIP39Wordlist()``
- ``isValidBIP39Word(_:)``
- ``bip39WordsMatching(prefix:limit:)``

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

### Transactions

- <doc:SendingTransactions>
- ``SpendPlan``
- ``createTransaction(inputs:outputs:signingKeysByAddress:changeAddress:fee:)``
- ``FeeEstimation``
- ``UTXO``
- ``SignedTransaction``
- ``TransactionBuilder``
- ``RawTransaction``

### Electrum Synchronization

- <doc:ElectrumSynchronization>
- ``ElectrumSyncManager``
- ``ElectrumSyncDelegate``
- ``ElectrumSyncState``
- ``ElectrumError``
- ``ElectrumServer``
- ``ElectrumServerList``
- ``ElectrumUTXO``
- ``ElectrumHistoryItem``
- ``ElectrumClient``
- ``ElectrumBalance``
- ``ElectrumHeader``
- ``ElectrumScriptHash``

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
- ``InvMessage``
- ``GetDataMessage``
- ``NotFoundMessage``
- ``InventoryVector``
- ``InventoryType``
- ``HeadersMessage``
- ``GetHeadersMessage``
- ``TxMessage``
- ``MerkleBlockMessage``
- ``MerkleBlockMatches``
- ``MerkleBlockError``
- ``AddrMessage``
- ``FilterLoadMessage``
- ``FilterAddMessage``

### Constants

- ``NetworkConstants``
