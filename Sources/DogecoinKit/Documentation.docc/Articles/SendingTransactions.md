# Sending Transactions

Build, sign, and broadcast Dogecoin transactions.

@Metadata {
    @PageKind(article)
}

## Overview

Sending Dogecoin involves several steps: selecting unspent outputs (UTXOs), building a transaction, signing it with private keys, and broadcasting it to the network. DogecoinKit provides tools for each step.

## Understanding Transactions

A Dogecoin transaction consists of:

- **Inputs** — References to previous transaction outputs (UTXOs) being spent
- **Outputs** — New outputs being created (recipients and change)
- **Signatures** — Proof of ownership for each input

```
┌─────────────────────────────────────────────────────────────┐
│                      Transaction                            │
├─────────────────────────────────────────────────────────────┤
│  Inputs                          Outputs                    │
│  ┌─────────────────────┐        ┌─────────────────────┐    │
│  │ UTXO from TX abc123 │        │ 50 DOGE to DRecip.. │    │
│  │ 100 DOGE            │   →    │                     │    │
│  └─────────────────────┘        ├─────────────────────┤    │
│                                 │ 49 DOGE to DChange. │    │
│                                 │ (change)            │    │
│                                 ├─────────────────────┤    │
│                                 │ 1 DOGE fee          │    │
│                                 │ (to miners)         │    │
│                                 └─────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## Managing UTXOs

### What is a UTXO?

An Unspent Transaction Output (UTXO) represents funds you can spend. Each UTXO is the output of a previous transaction that sent funds to your address.

```swift
struct UTXO: Sendable, Equatable, Hashable, Codable {
    let txid: String           // Transaction ID containing this output
    let vout: Int              // Output index within the transaction
    let address: String        // Your address
    let amount: DogecoinAmount // Amount available
    let scriptPubKey: String?  // Locking script, if known (checked before signing)
    let confirmations: Int     // Number of confirmations
}
```

### Tracking UTXOs

Your wallet needs to track UTXOs for each address:

```swift
actor UTXOManager {
    private var utxos: [UTXO] = []

    func addUTXO(_ utxo: UTXO) {
        utxos.append(utxo)
    }

    func markSpent(txid: String, vout: Int) {
        utxos.removeAll { $0.txid == txid && $0.vout == vout }
    }

    var spendableUTXOs: [UTXO] {
        // Only return confirmed UTXOs
        utxos.filter { $0.confirmations >= 1 }
    }

    var balance: DogecoinAmount {
        utxos.reduce(.zero) { $0 + $1.amount }
    }

    var confirmedBalance: DogecoinAmount {
        spendableUTXOs.reduce(.zero) { $0 + $1.amount }
    }
}
```

### Selecting UTXOs for a Transaction

Choose UTXOs that cover the amount plus fee:

```swift
func selectUTXOs(
    from available: [UTXO],
    targetAmount: DogecoinAmount,
    fee: DogecoinAmount
) -> [UTXO]? {
    let needed = targetAmount + fee

    // Sort by amount (largest first for fewer inputs)
    let sorted = available.sorted { $0.amount > $1.amount }

    var selected: [UTXO] = []
    var total = DogecoinAmount.zero

    for utxo in sorted {
        selected.append(utxo)
        total += utxo.amount

        if total >= needed {
            return selected
        }
    }

    return nil  // Insufficient funds
}
```

## Building Transactions

### Basic Transaction

```swift
import DogecoinKit

func sendDoge() async throws {
    // 1. Create a transaction builder
    let tx = try await TransactionBuilder()

    // 2. Add inputs (UTXOs you're spending)
    try await tx.addInput(txid: "abc123def456...", vout: 0)

    // 3. Add outputs (recipients)
    try await tx.addOutput(
        address: "DRecipientAddress...",
        amount: DogecoinAmount(doge: 50)
    )

    // 4. Finalize with fee and change (the 49 DOGE left over goes to the change address)
    _ = try await tx.finalize(
        destinationAddress: "DRecipientAddress...",
        fee: DogecoinAmount(doge: 1),
        totalAmount: DogecoinAmount(doge: 100),  // Total input amount
        changeAddress: "DMyChangeAddress..."
    )

    // 5. Sign with your private key
    try await tx.sign(privateKeyWIF: "QPrivateKeyInWIF...")

    // 6. Get the signed transaction hex
    let signedHex = try await tx.getRawTransaction()
    print("Broadcast this: \(signedHex)")
}
```

``TransactionBuilder`` is an actor, so every call is `try await`. Keep these rules in mind:

- Each output must be more than zero and at most ``DogecoinAmount/maxMoney``. All outputs must be on the same network, and they can pay P2PKH or P2SH addresses.
- `finalize` sends whatever `totalAmount` leaves after the outputs and fee to `changeAddress`. It throws if there is change but no change address. When the amounts balance exactly, no change output is needed.
- Finalizing seals the builder, so adding more inputs or outputs throws ``DogecoinError/internalError(_:)``.
- Signing requires a finalized builder. Without `finalize` there is no change output, and everything the outputs leave over would go to miners as fee.
- Each input can be signed once. Signing it again throws instead of stacking a second signature that nodes refuse to relay.

### Multiple Inputs and Outputs

```swift
let tx = try await TransactionBuilder()

// Multiple inputs
try await tx.addInput(txid: "txid1...", vout: 0)  // 50 DOGE
try await tx.addInput(txid: "txid2...", vout: 1)  // 30 DOGE
try await tx.addInput(txid: "txid3...", vout: 0)  // 20 DOGE
// Total: 100 DOGE

// Multiple outputs
try await tx.addOutput(address: "DRecipient1...", amount: DogecoinAmount(doge: 40))
try await tx.addOutput(address: "DRecipient2...", amount: DogecoinAmount(doge: 30))
// Total outputs: 70 DOGE

// Finalize
_ = try await tx.finalize(
    destinationAddress: "DRecipient1...",
    fee: DogecoinAmount(doge: 1),
    totalAmount: DogecoinAmount(doge: 100),
    changeAddress: "DMyChange..."
)
// Change: 100 - 70 - 1 = 29 DOGE
```

### Using the Convenience Function

For simpler cases where all inputs belong to the same address, use the
``createTransaction(inputs:outputs:privateKey:changeAddress:fee:)`` function:

```swift
let utxos = [
    UTXO(txid: "abc...", vout: 0, address: "DMyAddr...",
         amount: DogecoinAmount(doge: 100), scriptPubKey: nil, confirmations: 6)
]

let outputs: [(address: String, amount: DogecoinAmount)] = [
    ("DRecipient...", DogecoinAmount(doge: 50))
]

let signedTx = try await createTransaction(
    inputs: utxos,
    outputs: outputs,
    privateKey: "QPrivateKey...",
    changeAddress: "DMyChange...",
    fee: DogecoinAmount(doge: 1)
)

print("Transaction hex: \(signedTx.rawHex)")
```

For wallets that spend from multiple addresses, use
``createTransaction(inputs:outputs:signingKeysByAddress:changeAddress:fee:)``:

```swift
let utxos = [
    UTXO(txid: "abc...", vout: 0, address: "DMyAddr1...", amount: DogecoinAmount(doge: 60)),
    UTXO(txid: "def...", vout: 1, address: "DMyAddr2...", amount: DogecoinAmount(doge: 40))
]

let signingKeys = [
    "DMyAddr1...": "QPrivateKey1...",
    "DMyAddr2...": "QPrivateKey2..."
]

let signedTx = try await createTransaction(
    inputs: utxos,
    outputs: outputs,
    signingKeysByAddress: signingKeys,
    changeAddress: "DMyChange...",
    fee: DogecoinAmount(doge: 1)
)
```

Before building anything, `createTransaction` throws ``DogecoinError/transactionValidationFailed(_:)`` if a check fails:

- The same output is spent twice.
- An input isn't a P2PKH address, or its recorded `scriptPubKey` doesn't pay to that address.
- A signing key is missing, or it doesn't actually own its input's address.

These checks mean a wrong key fails fast instead of producing an unspendable signature. The function also raises a fee below ``FeeEstimation/minimumFee`` to that minimum and adds change smaller than the dust threshold to the fee. Without a `changeAddress`, change goes back to the first input's address.

## Calculating Fees

### Fee Estimation

Dogecoin transaction fees are based on transaction size:

```swift
func estimateFee(inputCount: Int, outputCount: Int) -> DogecoinAmount {
    // Estimate transaction size in bytes
    // Input: ~148 bytes, Output: ~34 bytes, Overhead: ~10 bytes
    let estimatedSize = inputCount * 148 + outputCount * 34 + 10

    // Recommended fee: 1 DOGE per KB (generous for Dogecoin)
    // Minimum: 0.01 DOGE
    let feePerKB = DogecoinAmount(doge: 1)
    let calculatedFee = DogecoinAmount(koinu: UInt64(estimatedSize) * feePerKB.koinu / 1000)

    let minimumFee = DogecoinAmount(doge: 0.01)
    return max(calculatedFee, minimumFee)
}

// Example
let fee = estimateFee(inputCount: 2, outputCount: 2)
print("Estimated fee: \(fee)")  // ~0.37 DOGE
```

``FeeEstimation`` performs this same calculation. `FeeEstimation.estimateFee(inputCount: 2, outputCount: 2)` returns the same 0.374 DOGE, and the type also offers priority levels and UTXO selection helpers.

### Fee Priority

Unlike Bitcoin, Dogecoin has low and predictable fees. ``FeeEstimation/Priority`` has three levels. Fees scale with transaction size and never drop below ``FeeEstimation/minimumFee`` (0.01 DOGE):

| Priority | Display name | Rate | 1 input, 2 outputs | `estimatedTime` |
|----------|--------------|------|--------------------|-----------------|
| `.high` | Priority | 2 DOGE per KB | 0.452 DOGE | ~1-2 minutes |
| `.standard` | Standard | 1 DOGE per KB | 0.226 DOGE | ~10 minutes |
| `.low` | Economy | 0.1 DOGE per KB | 0.0226 DOGE | ~30+ minutes |

## Complete Transaction Flow

Here's a complete example of sending Dogecoin:

```swift
enum TransactionError: Error {
    case invalidRecipientAddress
    case insufficientFunds
    case broadcastFailed
}

final class TransactionService {
    private let wallet: HDWallet
    private let utxoManager: UTXOManager

    init(wallet: HDWallet, utxoManager: UTXOManager) {
        self.wallet = wallet
        self.utxoManager = utxoManager
    }

    func send(
        to recipientAddress: String,
        amount: DogecoinAmount,
        changeIndex: UInt32
    ) async throws -> SignedTransaction {
        // 1. Validate the recipient address
        guard Address.isValid(recipientAddress) else {
            throw TransactionError.invalidRecipientAddress
        }

        // 2. Select UTXOs and estimate the fee for that many inputs
        let availableUTXOs = await utxoManager.spendableUTXOs
        guard let selection = FeeEstimation.selectUTXOsWithFee(
            targetAmount: amount,
            utxos: availableUTXOs
        ) else {
            throw TransactionError.insufficientFunds
        }

        // 3. Use a fresh change address for every transaction
        let changeAddress = try await wallet.deriveAddress(account: 0, index: changeIndex, change: true)

        // 4. Look up the key for each address being spent from
        // In a real app, you'd retrieve the private keys securely
        var signingKeys: [String: String] = [:]
        for utxo in selection.utxos {
            signingKeys[utxo.address] = try getPrivateKey(for: utxo.address)
        }

        // 5. Build and sign. createTransaction checks every key against its
        //    input, enforces the minimum fee, and adds dust change to the fee.
        return try await createTransaction(
            inputs: selection.utxos,
            outputs: [(address: recipientAddress, amount: amount)],
            signingKeysByAddress: signingKeys,
            changeAddress: changeAddress,
            fee: selection.fee
        )
    }

    /// Call this once the broadcast has succeeded.
    func markSpent(_ inputs: [UTXO]) async {
        for utxo in inputs {
            await utxoManager.markSpent(txid: utxo.txid, vout: utxo.vout)
        }
    }
}
```

## Broadcasting Transactions

### Via Electrum

In Electrum mode, hand the transaction to the connected server:

```swift
func broadcastTransaction(_ tx: SignedTransaction, via electrum: ElectrumSyncManager) async throws -> String {
    // Sent once and never retried: if the connection drops before the server
    // answers, check the transaction's status before sending it again
    try await electrum.broadcastTransaction(tx.rawHex)
}
```

The txid it returns is computed from the transaction itself, not taken from the server's reply. Cancelling the calling task doesn't abandon a broadcast that is already under way.

### Via Peer Network

Broadcast through connected peers:

```swift
func broadcastTransaction(_ tx: SignedTransaction, via peerManager: PeerManager) async throws -> String {
    // Announces the transaction to every connected peer and returns its txid
    // once one of them has fetched it
    try await peerManager.broadcastTransaction(tx.rawHex)
}
```

This throws ``DogecoinError/noPeersAvailable`` when no peer is connected and ``DogecoinError/internalError(_:)`` when the string isn't hex. If no peer asks for the transaction within 15 seconds, it throws ``DogecoinError/broadcastFailed(_:)`` and withdraws the transaction, so it can't go out later. ``SPVSyncManager`` has the same `broadcastTransaction(_:)` method, which also accepts a ``SignedTransaction``.

### Via Block Explorer API

Many wallets broadcast via HTTP API for reliability:

```swift
func broadcastViaAPI(_ tx: SignedTransaction) async throws {
    guard let url = URL(string: "https://api.blockcypher.com/v1/doge/main/txs/push") else {
        throw URLError(.badURL)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body = ["tx": tx.rawHex]
    request.httpBody = try JSONEncoder().encode(body)

    let (_, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode) else {
        throw TransactionError.broadcastFailed
    }

    print("Transaction broadcast successfully!")
}
```

## Error Handling

Handle transaction errors gracefully:

```swift
do {
    let tx = try await TransactionBuilder()
    try await tx.addInput(txid: txid, vout: vout)
    try await tx.addOutput(address: recipient, amount: amount)
    // ...
} catch DogecoinError.transactionCreationFailed {
    showError("Failed to create transaction")
} catch DogecoinError.addInputFailed {
    showError("Invalid input - check the txid and output index")
} catch DogecoinError.addOutputFailed {
    showError("Invalid output - check the recipient address and amount")
} catch DogecoinError.transactionValidationFailed(let reason) {
    showError("Transaction rejected: \(reason)")
} catch DogecoinError.transactionSigningFailed, DogecoinError.invalidPrivateKey {
    showError("Failed to sign transaction - check your private key")
} catch DogecoinError.finalizationFailed {
    showError("Failed to finalize transaction - check amounts and the change address")
} catch DogecoinError.internalError(let reason) {
    showError("Builder misuse: \(reason)")  // e.g. "Transaction already finalized"
} catch {
    showError("Transaction error: \(error.localizedDescription)")
}
```

## Best Practices

1. **Always validate addresses** before building transactions
2. **Use confirmed UTXOs** (at least 1 confirmation) for spending
3. **Include adequate fees** to ensure timely confirmation
4. **Generate new change addresses** for each transaction
5. **Store transaction history** for user reference
6. **Handle failures gracefully** and allow retry
7. **Wait for broadcast confirmation** before marking UTXOs as spent

## Transaction Lifecycle

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  Build   │ →  │   Sign   │ →  │Broadcast │ →  │ Confirm  │
└──────────┘    └──────────┘    └──────────┘    └──────────┘
     │               │               │               │
     │               │               │               │
  Select          Private        Network          Blocks
  UTXOs           Key(s)         Peers            Mined
```

## See Also

- ``TransactionBuilder``
- ``UTXO``
- ``SignedTransaction``
- ``createTransaction(inputs:outputs:privateKey:changeAddress:fee:)``
- <doc:HandlingAmounts>
- <doc:SPVSynchronization>
