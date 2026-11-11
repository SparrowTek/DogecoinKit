# Sending Transactions

Build, sign, and broadcast Dogecoin transactions.

@Metadata {
    @PageKind(article)
}

## Overview

Sending Dogecoin involves several steps: selecting unspent outputs (UTXOs), working out the fee, building a transaction, signing it with private keys, and broadcasting it to the network. DogecoinKit provides tools for each step.

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
│  ┌─────────────────────┐        ┌─────────────────────┐     │
│  │ UTXO from TX abc123 │        │ 50 DOGE to DRecip.. │     │
│  │ 100 DOGE            │   →    │                     │     │
│  └─────────────────────┘        ├─────────────────────┤     │
│                                 │ 49.99774 DOGE to    │     │
│                                 │ DChange.. (change)  │     │
│                                 ├─────────────────────┤     │
│                                 │ 0.00226 DOGE fee    │     │
│                                 │ (to miners)         │     │
│                                 └─────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

The fee is not an output: it is what the inputs hold beyond what the outputs pay.

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

In Electrum mode, ``ElectrumSyncManager/fetchUTXOs(for:)`` returns the current set, each output checked against the transaction that created it. See <doc:ElectrumSynchronization>.

### Selecting UTXOs for a Transaction

``SpendPlan`` is DogecoinKit's coin selection. Given the payments to make and the outputs available, it chooses the inputs, largest first, and works out the fee they pay and the change that comes back:

```swift
let plan = try SpendPlan(paying: [DogecoinAmount(doge: 50)], from: utxos)

print(plan.inputs.count)  // How many outputs the transaction spends
print(plan.fee)           // The network fee
print(plan.change)        // What returns to the wallet, or zero
```

- Outputs with fewer confirmations than `minimumConfirmations` (1 unless you say otherwise) are not spent, and neither is an output worth no more than the fee its own input adds. A ``UTXO`` created without `confirmations:` has zero, so set it.
- The fee is for the transaction's estimated size at `feePerKB`, which is ``FeeEstimation/standardFeePerKB`` unless you pass another rate, plus 0.01 DOGE for every payment below ``FeeEstimation/softDustLimit``.
- What the inputs leave over becomes change when it is at least ``FeeEstimation/softDustLimit``. Less than that is added to the fee, and `change` is zero.

The same plan serves every step of a send: the fee shown while the user enters an amount and the transaction that is finally built come out of one calculation, so they can't disagree.

When a payment can't be planned, the initializer throws a ``SpendPlan/Failure``:

| Failure | Meaning |
|---------|---------|
| `.paymentOutOfRange` | There is no payment, or one is below ``FeeEstimation/hardDustLimit``, which nodes don't relay, or above ``DogecoinAmount/maxMoney`` |
| `.insufficientFunds` | The spendable outputs don't cover the payments and the fee |
| `.tooManyInputs` | The funds are there, but spread over more outputs than one standard transaction can spend. A smaller payment first, with its change, gathers them |

### Sending Everything

``SpendPlan/maximumPayment(from:alongside:feePerKB:minimumConfirmations:)`` gives the largest payment one transaction can make: everything worth spending, less the fee, with no change.

```swift
let maximum = SpendPlan.maximumPayment(from: utxos)

if maximum > .zero {
    // Planning that amount spends the same outputs and leaves no change
    let plan = try SpendPlan(paying: [maximum], from: utxos)
    print("Sending \(maximum) costs \(plan.fee)")
}
```

The result is zero when nothing can be sent, including when what the fee leaves is below ``FeeEstimation/softDustLimit``. Plan the payment with the same outputs, fee rate, and `minimumConfirmations` that you asked the maximum for.

## Building Transactions

### Planning, Building, and Signing

``createTransaction(inputs:outputs:signingKeysByAddress:changeAddress:fee:)`` builds and signs the transaction a plan describes:

```swift
import DogecoinKit

func buildPayment(
    of amount: DogecoinAmount,
    to recipient: String,
    from utxos: [UTXO],
    signingKeysByAddress: [String: String],
    changeAddress: String
) async throws -> SignedTransaction {
    // 1. Choose the inputs and work out the fee
    let plan = try SpendPlan(paying: [amount], from: utxos)

    // 2. Build the transaction and sign every input
    let signedTx = try await createTransaction(
        inputs: plan.inputs,
        outputs: [(address: recipient, amount: amount)],
        signingKeysByAddress: signingKeysByAddress,
        changeAddress: changeAddress,
        fee: plan.fee
    )

    print("Transaction hex: \(signedTx.rawHex)")
    return signedTx
}
```

`signingKeysByAddress` maps the address of each input to its private key in Wallet Import Format. ``HDWallet/derivePrivateKey(account:index:change:)`` returns keys in the form it needs. A key exported for an uncompressed public key is not accepted.

The ``SignedTransaction`` that comes back holds the `rawHex` to broadcast, the `txid`, and the `fee` the transaction pays.

Before building anything, `createTransaction` throws ``DogecoinError/transactionValidationFailed(_:)`` if a check fails:

- There are no inputs or no outputs, or the same output is spent twice.
- An output is zero, below ``FeeEstimation/hardDustLimit``, or above ``DogecoinAmount/maxMoney``.
- The inputs, outputs, and change address are not all on one network.
- The inputs don't cover the outputs and the fee, or the transaction would be larger than ``FeeEstimation/maxStandardTxSize``.
- An input isn't a P2PKH address, or its recorded `scriptPubKey` doesn't pay to that address.
- A signing key is missing, or it doesn't actually own its input's address.

These checks mean a wrong key fails fast instead of producing an unspendable signature. The function also raises a fee that is below the least nodes relay for a transaction of that size, and adds leftover smaller than ``FeeEstimation/softDustLimit`` to the fee instead of making a change output of it. Without a `changeAddress`, change goes back to the first input's address. Outputs can pay P2PKH or P2SH addresses.

### Multiple Recipients

One transaction can pay several recipients. Plan for all of the payments together:

```swift
let payments: [(address: String, amount: DogecoinAmount)] = [
    (address: firstRecipient, amount: DogecoinAmount(doge: 40)),
    (address: secondRecipient, amount: DogecoinAmount(doge: 30))
]

let plan = try SpendPlan(paying: payments.map(\.amount), from: utxos)

let signedTx = try await createTransaction(
    inputs: plan.inputs,
    outputs: payments,
    signingKeysByAddress: signingKeys,
    changeAddress: changeAddress,
    fee: plan.fee
)
```

### Using TransactionBuilder Directly

To decide every input and output yourself, drive the ``TransactionBuilder`` actor:

```swift
func buildByHand(
    spending utxo: UTXO,
    privateKeyWIF: String,
    recipient: String,
    changeAddress: String
) async throws -> String {
    // 1. Create a transaction builder
    let tx = TransactionBuilder()

    // 2. Add inputs (UTXOs you're spending)
    try await tx.addInput(txid: utxo.txid, vout: utxo.vout)

    // 3. Add outputs (recipients)
    try await tx.addOutput(
        address: recipient,
        amount: DogecoinAmount(doge: 50)
    )

    // 4. Finalize with fee and change (what is left over goes to the change address)
    _ = try await tx.finalize(
        fee: FeeEstimation.estimateFee(inputCount: 1, outputCount: 2),
        totalAmount: utxo.amount,  // Total input amount
        changeAddress: changeAddress
    )

    // 5. Sign each input with the private key for its address
    try await tx.signInput(index: 0, privateKeyWIF: privateKeyWIF)

    // 6. Get the signed transaction hex
    return try await tx.getRawTransaction()
}
```

``TransactionBuilder`` is an actor, so every call is `try await`. Keep these rules in mind:

- The builder does what it is told. It does not reject dust, raise a low fee, fold small change into the fee, or check that a key owns the input it signs. `createTransaction` does all of that.
- Each output must be more than zero and at most ``DogecoinAmount/maxMoney``. All outputs must be on the same network, and they can pay P2PKH or P2SH addresses.
- `finalize` sends whatever `totalAmount` leaves after the outputs and fee to `changeAddress`. It throws if there is change but no change address. When the amounts balance exactly, no change output is needed.
- Finalizing seals the builder, so adding more inputs or outputs throws ``DogecoinError/transactionValidationFailed(_:)``.
- Signing requires a finalized builder. Without `finalize` there is no change output, and everything the outputs leave over would go to miners as fee.
- Each input is signed as P2PKH for the key's own address, and only once. Signing it again throws instead of stacking a second signature that nodes refuse to relay.

The builder hands back hex. To carry it as a ``SignedTransaction``, with its txid worked out, use ``SignedTransaction/init(rawHex:fee:)``, which returns `nil` unless the hex is one whole transaction.

## Calculating Fees

### Network Policy

``FeeEstimation`` holds Dogecoin Core's fee and dust defaults since version 1.14.6, which are what nodes relay and miners include unless their operators changed them:

| Constant | Value | Meaning |
|----------|-------|---------|
| ``FeeEstimation/recommendedFeePerKB`` | 0.01 DOGE per 1,000 bytes | The rate Core recommends and its own wallet pays, and the lowest rate miners include by default |
| ``FeeEstimation/minimumRelayFeePerKB`` | 0.001 DOGE per 1,000 bytes | The lowest rate nodes relay. A transaction paying less than the recommended rate is relayed but may never confirm |
| ``FeeEstimation/softDustLimit`` | 0.01 DOGE | A transaction owes this much extra fee for every output below it |
| ``FeeEstimation/hardDustLimit`` | 0.001 DOGE | Nodes do not relay a transaction with an output below it |
| ``FeeEstimation/maxStandardTxSize`` | 100,000 bytes | The largest standard transaction |

### Fee Estimation

A fee is proportional to the transaction's size, rounded down to the koinu. There is no flat minimum:

```swift
// 1 input and 2 outputs: 148 + 2 × 34 + 10 = 226 bytes at most
let size = FeeEstimation.estimateTransactionSize(inputCount: 1, outputCount: 2)

// At the standard rate: 226 × 0.01 DOGE ÷ 1,000
let fee = FeeEstimation.calculateFee(sizeBytes: size, feePerKB: FeeEstimation.standardFeePerKB)
print("Estimated fee: \(fee)")  // "Estimated fee: 0.00226000 DOGE"

// Both steps at once
let sameFee = FeeEstimation.estimateFee(inputCount: 1, outputCount: 2)

// The least nodes relay for it, including the surcharge for dust outputs
let outputs = [DogecoinAmount(doge: 50), DogecoinAmount(doge: 49)]
let floor = FeeEstimation.minimumRelayFee(sizeBytes: size, outputs: outputs)
print("Relay minimum: \(floor)")  // "Relay minimum: 0.00022600 DOGE"
```

The size estimate is an upper bound for a transaction spending P2PKH outputs: signatures vary by a byte or two and are counted at their longest. These estimates leave out the surcharge for outputs below the soft dust limit, which ``FeeEstimation/dustSurcharge(forOutputs:)`` gives. ``SpendPlan`` includes it.

### Fee Priority

``FeeEstimation/Priority`` has three levels. Nothing below the recommended rate confirms reliably, so `.low` and `.standard` are the same rate:

| Priority | Rate | 1 input, 2 outputs |
|----------|------|--------------------|
| `.high` | 0.05 DOGE per 1,000 bytes | 0.0113 DOGE |
| `.standard` | 0.01 DOGE per 1,000 bytes | 0.00226 DOGE |
| `.low` | 0.01 DOGE per 1,000 bytes | 0.00226 DOGE |

Pass a priority's rate to a plan with `SpendPlan(paying:from:feePerKB:)`, as in `feePerKB: FeeEstimation.Priority.high.feePerKB`.

## Complete Transaction Flow

Here's a complete example of sending Dogecoin:

```swift
enum TransactionError: Error {
    case invalidRecipientAddress
    case unknownAddress(String)
    case broadcastFailed
}

/// Where one of the wallet's addresses sits in its BIP44 account
struct AddressPath: Sendable {
    let index: UInt32
    let isChange: Bool
}

final class TransactionService {
    private let wallet: HDWallet
    private let utxoManager: UTXOManager
    private let paths: [String: AddressPath]

    init(wallet: HDWallet, utxoManager: UTXOManager, paths: [String: AddressPath]) {
        self.wallet = wallet
        self.utxoManager = utxoManager
        self.paths = paths
    }

    func send(
        to recipientAddress: String,
        amount: DogecoinAmount,
        changeIndex: UInt32
    ) async throws -> (transaction: SignedTransaction, inputs: [UTXO]) {
        // 1. Validate the recipient address
        guard Address.detectNetwork(recipientAddress) == wallet.network else {
            throw TransactionError.invalidRecipientAddress
        }

        // 2. Select UTXOs and work out the fee for that many inputs
        let availableUTXOs = await utxoManager.spendableUTXOs
        let plan = try SpendPlan(paying: [amount], from: availableUTXOs)

        // 3. Use a fresh change address for every transaction
        let changeAddress = try await wallet.deriveAddress(account: 0, index: changeIndex, change: true)

        // 4. Derive the key for each address being spent from
        var signingKeys: [String: String] = [:]
        for utxo in plan.inputs where signingKeys[utxo.address] == nil {
            guard let path = paths[utxo.address] else {
                throw TransactionError.unknownAddress(utxo.address)
            }
            signingKeys[utxo.address] = try await wallet.derivePrivateKey(
                account: 0,
                index: path.index,
                change: path.isChange
            )
        }

        // 5. Build and sign. createTransaction checks every key against its
        //    input and pays the fee the plan worked out.
        let transaction = try await createTransaction(
            inputs: plan.inputs,
            outputs: [(address: recipientAddress, amount: amount)],
            signingKeysByAddress: signingKeys,
            changeAddress: changeAddress,
            fee: plan.fee
        )
        return (transaction, plan.inputs)
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
enum BroadcastOutcome {
    case accepted(txid: String)
    /// The connection was lost before the server answered, and the server
    /// asked afterwards does not know the transaction
    case unsettled(txid: String)
}

func broadcastTransaction(_ tx: SignedTransaction, via electrum: ElectrumSyncManager) async throws -> BroadcastOutcome {
    do {
        // Sent once and never retried
        return .accepted(txid: try await electrum.broadcastTransaction(tx.rawHex))
    } catch ElectrumError.broadcastOutcomeUnknown(let txid) {
        // The server may have accepted it: ask before anything else spends
        // the same outputs
        let isKnown = try await electrum.isTransactionKnown(txid: txid)
        return isKnown ? .accepted(txid: txid) : .unsettled(txid: txid)
    }
}
```

The txid it returns is computed from the transaction itself, not taken from the server's reply. Cancelling the calling task doesn't abandon a broadcast that is already under way. What it throws tells you where the transaction stands:

- ``ElectrumError/requestFailed(code:message:)``: the server refused the transaction.
- ``ElectrumError/broadcastOutcomeUnknown(txid:)``: the connection was lost after the transaction was sent and before the server answered. It may have been accepted. Keep its inputs out of any new transaction until ``ElectrumSyncManager/isTransactionKnown(txid:)`` has settled the question. A transaction can take a few seconds to reach a server other than the one it was sent to, so a "no" right after the broadcast is not final: ask again.
- Any other error: the transaction was never sent.

### Via Peer Network

In SPV mode, broadcast through connected peers:

```swift
func broadcastTransaction(_ tx: SignedTransaction, via syncManager: SPVSyncManager) async throws -> String {
    // Announces the transaction to every connected peer and returns its txid
    // once one of them has fetched it
    try await syncManager.broadcastTransaction(tx.rawHex)
}
```

This throws ``DogecoinError/internalError(_:)`` when the string isn't a transaction and ``DogecoinError/noPeersAvailable`` when no peer is connected. If no peer asks for the transaction within 15 seconds, or every peer that fetched it answers with a rejection, it throws ``DogecoinError/broadcastFailed(_:)`` and withdraws the transaction, so it can't go out later.

After a successful broadcast, ``SPVSyncManager`` keeps offering the transaction, to peers that connect later and to all of them every ten minutes, until the scan for the wallet's transactions finds it in a block or two days have passed. That state lives in memory. For a transaction sent in an earlier session that has not confirmed yet, call ``SPVSyncManager/announceUntilConfirmed(_:)`` after starting the sync. ``PeerManager`` has the same `broadcastTransaction(_:)` method without the repeated offers.

### Via Block Explorer API

A signed transaction can also be handed to a service that accepts raw transactions over HTTP:

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
    let plan = try SpendPlan(paying: [amount], from: utxos)
    let signedTx = try await createTransaction(
        inputs: plan.inputs,
        outputs: [(address: recipient, amount: amount)],
        signingKeysByAddress: signingKeys,
        changeAddress: changeAddress,
        fee: plan.fee
    )
    print("Ready to broadcast \(signedTx.txid)")
} catch SpendPlan.Failure.insufficientFunds {
    showError("Not enough funds for this amount and its fee")
} catch SpendPlan.Failure.paymentOutOfRange {
    showError("That amount is too small or too large to send")
} catch SpendPlan.Failure.tooManyInputs {
    showError("Your funds are in too many small pieces to send at once - try a smaller amount first")
} catch DogecoinError.transactionValidationFailed(let reason) {
    showError("Transaction rejected: \(reason)")
} catch DogecoinError.transactionSigningFailed, DogecoinError.invalidPrivateKey {
    showError("Failed to sign transaction - check your private key")
} catch {
    showError("Transaction error: \(error.localizedDescription)")
}
```

``TransactionBuilder`` reports its own steps: ``DogecoinError/addInputFailed`` for a malformed txid or output index, ``DogecoinError/addOutputFailed`` for an invalid address or amount, ``DogecoinError/finalizationFailed`` when there are no inputs or outputs, the amounts don't balance, or there is change and no usable change address, and ``DogecoinError/transactionValidationFailed(_:)`` for misuse such as changing a finalized builder or signing an input twice.

## Best Practices

1. **Always validate addresses** before building transactions
2. **Use confirmed UTXOs** (at least 1 confirmation) for spending
3. **Include adequate fees** to ensure timely confirmation
4. **Generate new change addresses** for each transaction
5. **Store transaction history** for user reference
6. **Handle failures gracefully** and allow retry
7. **Wait for broadcast confirmation** before marking UTXOs as spent, and while a broadcast's outcome is unknown, keep its inputs out of the next transaction

## Transaction Lifecycle

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  Build   │ →  │   Sign   │ →  │Broadcast │ →  │ Confirm  │
└──────────┘    └──────────┘    └──────────┘    └──────────┘
     │               │               │               │
     │               │               │               │
  Select          Private        Server or        Blocks
  UTXOs           Key(s)          Peers           Mined
```

## See Also

- ``SpendPlan``
- ``createTransaction(inputs:outputs:signingKeysByAddress:changeAddress:fee:)``
- ``FeeEstimation``
- ``TransactionBuilder``
- ``UTXO``
- ``SignedTransaction``
- <doc:HandlingAmounts>
- <doc:ElectrumSynchronization>
- <doc:SPVSynchronization>
