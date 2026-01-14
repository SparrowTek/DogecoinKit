# Sending Transactions

Build, sign, and broadcast Dogecoin transactions.

@Metadata {
    @PageKind(article)
    @PageImage(purpose: card, source: "transactions-card", alt: "Sending Dogecoin transactions")
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
│                                 │ 48 DOGE to DChange. │    │
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
struct UTXO: Sendable, Codable {
    let txid: String           // Transaction ID containing this output
    let vout: Int              // Output index within the transaction
    let address: String        // Your address
    let amount: DogecoinAmount // Amount available
    let scriptPubKey: String?  // Locking script (for signing)
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

// 1. Create a transaction builder
let tx = try TransactionBuilder()

// 2. Add inputs (UTXOs you're spending)
try tx.addInput(txid: "abc123def456...", vout: 0)

// 3. Add outputs (recipients)
try tx.addOutput(
    address: "DRecipientAddress...",
    amount: DogecoinAmount(doge: 50)
)

// 4. Finalize with fee and change
let rawTx = try tx.finalize(
    destinationAddress: "DRecipientAddress...",
    fee: DogecoinAmount(doge: 1),
    totalAmount: DogecoinAmount(doge: 100),  // Total input amount
    changeAddress: "DMyChangeAddress..."
)

// 5. Sign with your private key
try tx.sign(privateKeyWIF: "QPrivateKeyInWIF...")

// 6. Get the signed transaction hex
let signedHex = try tx.getRawTransaction()
print("Broadcast this: \(signedHex)")
```

### Multiple Inputs and Outputs

```swift
let tx = try TransactionBuilder()

// Multiple inputs
try tx.addInput(txid: "txid1...", vout: 0)  // 50 DOGE
try tx.addInput(txid: "txid2...", vout: 1)  // 30 DOGE
try tx.addInput(txid: "txid3...", vout: 0)  // 20 DOGE
// Total: 100 DOGE

// Multiple outputs
try tx.addOutput(address: "DRecipient1...", amount: DogecoinAmount(doge: 40))
try tx.addOutput(address: "DRecipient2...", amount: DogecoinAmount(doge: 30))
// Total outputs: 70 DOGE

// Finalize
_ = try tx.finalize(
    destinationAddress: "DRecipient1...",
    fee: DogecoinAmount(doge: 1),
    totalAmount: DogecoinAmount(doge: 100),
    changeAddress: "DMyChange..."
)
// Change: 100 - 70 - 1 = 29 DOGE
```

### Using the Convenience Function

For simpler cases, use the ``createTransaction(inputs:outputs:privateKey:changeAddress:fee:)`` function:

```swift
let utxos = [
    UTXO(txid: "abc...", vout: 0, address: "DMyAddr...",
         amount: DogecoinAmount(doge: 100), scriptPubKey: nil, confirmations: 6)
]

let outputs: [(address: String, amount: DogecoinAmount)] = [
    ("DRecipient...", DogecoinAmount(doge: 50))
]

let signedTx = try createTransaction(
    inputs: utxos,
    outputs: outputs,
    privateKey: "QPrivateKey...",
    changeAddress: "DMyChange...",
    fee: DogecoinAmount(doge: 1)
)

print("Transaction hex: \(signedTx.rawHex)")
```

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

### Fee Priority

Unlike Bitcoin, Dogecoin has low and predictable fees:

| Priority | Fee | Confirmation |
|----------|-----|--------------|
| Standard | 1 DOGE | 1-2 blocks |
| Economy | 0.1 DOGE | 2-5 blocks |
| Minimum | 0.01 DOGE | 5+ blocks |

## Complete Transaction Flow

Here's a complete example of sending Dogecoin:

```swift
class TransactionService {
    private let wallet: HDWallet
    private let utxoManager: UTXOManager

    init(wallet: HDWallet, utxoManager: UTXOManager) {
        self.wallet = wallet
        self.utxoManager = utxoManager
    }

    func send(
        to recipientAddress: String,
        amount: DogecoinAmount
    ) async throws -> SignedTransaction {
        // 1. Validate the recipient address
        guard Address.isValid(recipientAddress) else {
            throw TransactionError.invalidRecipientAddress
        }

        // 2. Estimate fee
        let estimatedFee = DogecoinAmount(doge: 1)

        // 3. Select UTXOs
        let availableUTXOs = await utxoManager.spendableUTXOs
        guard let selectedUTXOs = selectUTXOs(
            from: availableUTXOs,
            targetAmount: amount,
            fee: estimatedFee
        ) else {
            throw TransactionError.insufficientFunds
        }

        // 4. Get a change address
        let changeAddress = try wallet.deriveAddress(account: 0, index: 0, change: true)

        // 5. Build the transaction
        let tx = try TransactionBuilder()

        for utxo in selectedUTXOs {
            try tx.addInput(txid: utxo.txid, vout: utxo.vout)
        }

        try tx.addOutput(address: recipientAddress, amount: amount)

        let totalInput = selectedUTXOs.reduce(.zero) { $0 + $1.amount }

        _ = try tx.finalize(
            destinationAddress: recipientAddress,
            fee: estimatedFee,
            totalAmount: totalInput,
            changeAddress: changeAddress
        )

        // 6. Sign the transaction
        // In a real app, you'd retrieve the private key securely
        let privateKey = try getPrivateKey(for: selectedUTXOs.first!.address)
        try tx.sign(privateKeyWIF: privateKey)

        // 7. Get the raw transaction
        let rawHex = try tx.getRawTransaction()

        // 8. Mark UTXOs as spent (pending)
        for utxo in selectedUTXOs {
            await utxoManager.markSpent(txid: utxo.txid, vout: utxo.vout)
        }

        return SignedTransaction(rawHex: rawHex)
    }
}
```

## Broadcasting Transactions

### Via Peer Network

Broadcast through connected peers:

```swift
func broadcastTransaction(_ tx: SignedTransaction, via peerManager: PeerManager) {
    // Create the tx message
    let txData = Data(hexString: tx.rawHex)!
    let message = ProtocolMessage(
        network: .mainnet,
        command: ProtocolMessage.Command.tx,
        payload: txData
    )

    // Send to all connected peers
    peerManager.broadcast(message)
}
```

### Via Block Explorer API

Many wallets broadcast via HTTP API for reliability:

```swift
func broadcastViaAPI(_ tx: SignedTransaction) async throws {
    let url = URL(string: "https://api.blockcypher.com/v1/doge/main/txs/push")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body = ["tx": tx.rawHex]
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await URLSession.shared.data(for: request)

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
    let tx = try TransactionBuilder()
    try tx.addInput(txid: txid, vout: vout)
    try tx.addOutput(address: recipient, amount: amount)
    // ...
} catch DogecoinError.transactionCreationFailed {
    showError("Failed to create transaction")
} catch DogecoinError.addInputFailed {
    showError("Invalid input - UTXO may already be spent")
} catch DogecoinError.addOutputFailed {
    showError("Invalid output - check the recipient address")
} catch DogecoinError.transactionSigningFailed {
    showError("Failed to sign transaction - check your private key")
} catch DogecoinError.finalizationFailed {
    showError("Failed to finalize transaction - check amounts")
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
