# Electrum Synchronization

Follow a wallet's addresses through an Electrum server.

@Metadata {
    @PageKind(article)
}

## Overview

In Electrum mode the wallet keeps no copy of the chain. ``ElectrumSyncManager`` connects to an Electrum server, asks it for the unspent outputs and the history of the wallet's addresses, and is told when something happens at one of them. There is no header chain to download and nothing is written to disk, which makes it the lighter of DogecoinKit's two modes. <doc:SPVSynchronization> describes the other.

What you give up is independence from the server:

- **Taken on the server's word:** which transactions exist at an address, whether they are confirmed and at what height, and the height of the chain. A server can leave a transaction out, or report one that is not in the chain.
- **Checked by DogecoinKit:** every unspent output against the transaction that created it, every raw transaction against its txid, and which chain the server says it indexes.
- **Seen by the server:** every address the wallet asks about, and the IP address it asks from.

## Creating and Starting a Manager

```swift
import DogecoinKit

let electrum = ElectrumSyncManager(network: .mainnet)
try await electrum.start()

print(await electrum.state.isConnected)       // true
print(await electrum.currentHeight)           // The height of the chain's tip
print(await electrum.connectedServer?.host ?? "none")
```

``ElectrumSyncManager/start()`` tries the servers in its list until one works: it connects, with ten seconds allowed per server, checks which chain the server indexes, and subscribes to new block headers. If none works it throws whatever stopped the last server it tried, and the manager is not running. The delegate hears nothing of a failed start. Call `start()` again to retry.

``ElectrumSyncManager`` is an actor, so read its properties and call its methods with `await`. ``ElectrumSyncManager/stop()`` disconnects and forgets the addresses being watched. Subscribe to them again after the next `start()`.

## Receiving Events

Give the manager an ``ElectrumSyncDelegate`` with `setDelegate(_:)`. The manager holds it weakly. A delegate must be a `Sendable` reference type, so an actor fits well:

```swift
actor WalletSync: ElectrumSyncDelegate {
    private let electrum = ElectrumSyncManager(network: .mainnet)
    private let addresses: [String]

    private(set) var utxos: [(address: String, utxo: ElectrumUTXO)] = []
    private(set) var history: [ElectrumHistoryItem] = []
    private(set) var height: Int32 = 0

    init(addresses: [String]) {
        self.addresses = addresses
    }

    func start() async throws {
        await electrum.setDelegate(self)
        try await electrum.start()
    }

    private func refresh() async {
        do {
            // Watch first, then fetch. Addresses already watched are skipped
            try await electrum.subscribeToAddresses(addresses)
            utxos = try await electrum.fetchUTXOs(for: addresses)
            history = try await electrum.fetchTransactionHistory(for: addresses)
        } catch {
            // Out of date until the next event brings another refresh
        }
    }

    // MARK: - ElectrumSyncDelegate

    func electrumSyncDidConnect(_ manager: ElectrumSyncManager) async {
        // The first connection, and every reconnection: catch up
        await refresh()
    }

    func electrumSync(_ manager: ElectrumSyncManager, didReachHeight height: Int32) async {
        // A new block: confirmation counts have changed
        self.height = height
    }

    func electrumSync(_ manager: ElectrumSyncManager, didObserveActivityAt address: String) async {
        // A transaction arrived, confirmed, or was dropped at this address
        await refresh()
    }
}
```

Because the callbacks arrive one at a time, refreshing from them alone means two refreshes never overlap, and an older answer can't overwrite a newer one.

| Callback | When it is called | What to do |
|----------|-------------------|------------|
| ``ElectrumSyncDelegate/electrumSyncDidConnect(_:)`` | On the first connection and after every reconnection, once every watched address is being watched again | Fetch whatever may have changed while the manager was not connected |
| ``ElectrumSyncDelegate/electrumSync(_:didReachHeight:)`` | On connecting, and for every block after | Update confirmation counts. Optional: the default does nothing |
| ``ElectrumSyncDelegate/electrumSync(_:didObserveActivityAt:)`` | When a transaction arrives, confirms, or is dropped at a watched address, and for an address whose history changed while the manager was reconnecting | Fetch that address's outputs and history again |

Calls arrive one at a time, in the order things happened, and none begins after `stop()` has returned. The first `electrumSyncDidConnect` follows `start()` at once, when no address is being watched yet, which makes it a good place to subscribe.

## Watching Addresses

``ElectrumSyncManager/subscribeToAddresses(_:)`` asks the server to report activity at each address, P2PKH or P2SH. Addresses that are already watched are skipped, so it is safe to call again with a longer list. An address that is invalid or belongs to the other network throws ``ElectrumError/invalidAddress(_:)``.

Subscribe before you fetch an address's state. A transaction that arrives between the two is then reported as activity, and you fetch again. The other way round, it would have arrived after your fetch and before the server knew to tell you, and you would not hear of it until something else happened at the address.

```swift
// The wallet handed out a new receiving address
try await electrum.subscribeToAddresses([newAddress])
let received = try await electrum.fetchUTXOs(for: [newAddress])
```

## Unspent Outputs

``ElectrumSyncManager/fetchUTXOs(for:)`` returns the unspent outputs of the addresses, each paired with its address. An ``ElectrumUTXO`` carries the txid (`txHash`), the output index (`txPos`), the `value` in koinu, and the `height` of its block, which is zero or less while the transaction is unconfirmed. The manager has no balance call: a wallet's balance is the sum of these outputs.

```swift
let height = await electrum.currentHeight

// As the UTXO type that SpendPlan and createTransaction take
let spendable = try await electrum.fetchUTXOs(for: addresses).map { address, output in
    UTXO(
        txid: output.txHash,
        vout: output.txPos,
        address: address,
        amount: DogecoinAmount(koinu: UInt64(output.value)),
        confirmations: output.height > 0 ? max(0, Int(height) - output.height + 1) : 0
    )
}

let balance = spendable.reduce(DogecoinAmount.zero) { $0 + $1.amount }
```

### What Is Verified

A server is not trusted with amounts. Before `fetchUTXOs` returns, it fetches the transaction that created each output and checks that:

- the transaction hashes to the txid the server named,
- the output exists in it and pays the address it was listed under, and
- the output carries exactly the value the server reported.

An output that fails any of these throws ``ElectrumError/invalidResponse(_:)``, and so does a set of outputs worth more than ``DogecoinAmount/maxMoney``. The check matters because a Dogecoin signature does not commit to the amounts being spent: a server that understated an output's value could otherwise have the wallet sign the difference away as fee.

The check proves that an output is what its transaction says. It cannot prove that the transaction is in the chain, or that the output is still unspent. Those are taken on the server's word.

The first fetch for a wallet downloads the transaction behind each output, eight at a time. The manager remembers the outputs it has verified, up to 8,192 of them, so later fetches ask only for what is new.

## Transaction History

``ElectrumSyncManager/fetchTransactionHistory(for:)`` returns one ``ElectrumHistoryItem`` per transaction across all the addresses, newest first, with unconfirmed transactions at the top. Each holds the txid and the height of its block, zero or less while unconfirmed. The list is the server's account of the addresses and is not verified.

For the details of a transaction, fetch and decode it:

```swift
for item in try await electrum.fetchTransactionHistory(for: addresses) where item.height > 0 {
    // Checked to hash to the txid that was asked for
    let rawHex = try await electrum.getTransaction(txid: item.txHash)

    // When its block was mined, by the block's own header
    let minedAt = try await electrum.blockTime(atHeight: item.height)

    guard let transaction = RawTransaction(hex: rawHex) else { continue }
    for output in transaction.outputs {
        let recipient = Address.fromScriptPubKey(output.script, network: .mainnet) ?? "(no address)"
        print(minedAt, DogecoinAmount(koinu: output.value), recipient)
    }
}
```

``ElectrumSyncManager/getTransaction(txid:)`` throws ``ElectrumError/invalidResponse(_:)`` if the server sends a different transaction. ``RawTransaction`` decodes untrusted bytes without trapping, and does not bound the values it reads: an output of a transaction that is not known to be in a block can claim any amount.

### Block Times

A history item carries a height, not a time. ``ElectrumSyncManager/blockTime(atHeight:)`` gives the time the block at a height was mined, read from the timestamp in the block's header as the server returns it. Nothing checks that header's proof of work. The manager remembers the times it has fetched, up to 1,024 of them, so dating many transactions from the same blocks asks the server once per block.

## Broadcasting

``ElectrumSyncManager/broadcastTransaction(_:)`` sends a signed transaction to the server once and returns its txid, computed from the transaction itself. It is never retried, and cancelling the calling task does not abandon a broadcast that is under way.

```swift
func send(_ transaction: SignedTransaction, through electrum: ElectrumSyncManager) async throws -> Bool {
    do {
        _ = try await electrum.broadcastTransaction(transaction.rawHex)
        return true
    } catch ElectrumError.broadcastOutcomeUnknown(let txid) {
        // The connection was lost before the server answered. Ask whether
        // it has the transaction, a few times: the manager may have
        // reconnected to another server, which takes a moment to hear of it
        for _ in 0..<5 {
            if try await electrum.isTransactionKnown(txid: txid) {
                return true
            }
            try await Task.sleep(for: .seconds(2))
        }
        return false
    }
}
```

What the call throws tells you where the transaction stands:

| Error | The transaction |
|-------|-----------------|
| ``ElectrumError/requestFailed(code:message:)`` | Was refused by the server. `message` is the server's reason |
| ``ElectrumError/broadcastOutcomeUnknown(txid:)`` | May have been accepted: the connection was lost after it was sent and before the server answered |
| Anything else | Was never sent |

After ``ElectrumError/broadcastOutcomeUnknown(txid:)``, send nothing that spends the same outputs until the question is settled. A second transaction built from other inputs would pay twice if the first went through. ``ElectrumSyncManager/isTransactionKnown(txid:)`` returns whether the server has the transaction, in a block or waiting for one. It returns `false` only when the server says it has no such transaction, and throws when the server can't be asked or answers with any other error — being busy is not an answer. In the example above, `false` after several tries still isn't proof that the transaction is gone, so keep its inputs set aside and ask again later.

## Reconnecting

The manager looks after its connection:

- A connection that goes quiet is pinged, and a request the server leaves unanswered for a minute counts as a lost connection.
- When the connection is lost, ``ElectrumSyncManager/state`` becomes `.connecting` and the manager reconnects in the background, starting with the server after the one that failed and pausing between rounds for one second at first and up to a minute.
- Once connected, it subscribes to every watched address again. An address whose history differs from what the manager last saw is reported through ``ElectrumSyncDelegate/electrumSync(_:didObserveActivityAt:)``, then ``ElectrumSyncDelegate/electrumSyncDidConnect(_:)`` is called.
- A fetch that was interrupted by the loss is repeated once on the new connection. A broadcast is not.
- A call made while the manager is disconnected reconnects first, and throws if that fails. After `stop()`, or before `start()`, calls throw ``ElectrumError/serverDisconnected``.

## Using Your Own Servers

The built-in list, ``ElectrumServerList/mainnetServers``, holds two mainnet servers on one domain, and ``ElectrumServerList/testnetServers`` is empty, so on testnet `start()` throws ``ElectrumError/noServersAvailable``. To use other servers, or testnet, pass your own:

```swift
let electrum = ElectrumSyncManager(
    network: .testnet,
    servers: [
        ElectrumServer(host: "electrum.example.com", port: 50002, network: .testnet),
        ElectrumServer(host: "backup.example.com", port: 50002, network: .testnet)
    ]
)
```

Servers you pass are tried in the order given. The built-in list is shuffled each time a manager is created.

An ``ElectrumServer`` uses TLS unless you pass `useSSL: false`. With TLS the connection needs TLS 1.2 or later and a certificate the system trusts for that host name. Without it, everything the wallet asks and is told crosses the network in the clear.

On connecting, the manager asks the server which chain it indexes and refuses one whose genesis block is another chain's, the other Dogecoin network included. A server reached by mistake would otherwise answer every query with nothing. If that was the last server tried, `start()` throws ``ElectrumError/invalidResponse(_:)``. A server that does not answer the question is accepted. The check rests on the server's own statement: it catches a mistake, not a server that lies.

## Handling Errors

The manager's methods throw ``ElectrumError``:

| Error | Meaning |
|-------|---------|
| ``ElectrumError/connectionFailed(_:)`` | A server could not be reached |
| ``ElectrumError/connectionTimeout`` | A server did not connect or answer in time |
| ``ElectrumError/serverDisconnected`` | The connection is gone, or the manager is not running |
| ``ElectrumError/noServersAvailable`` | The server list is empty |
| ``ElectrumError/invalidAddress(_:)`` | An address is invalid or on the other network |
| ``ElectrumError/invalidResponse(_:)`` | The server sent something that failed a check: a misreported output, the wrong transaction, another chain. Also thrown when `broadcastTransaction(_:)` is given something that is not a transaction |
| ``ElectrumError/requestFailed(code:message:)`` | The server answered a request with an error |
| ``ElectrumError/broadcastOutcomeUnknown(txid:)`` | A broadcast's connection was lost before the server answered |

They can also throw `DecodingError`, when a server's reply is not what the protocol calls for, and `CancellationError`, when the calling task is cancelled during a request.

```swift
do {
    try await electrum.start()
} catch ElectrumError.noServersAvailable {
    showError("No Electrum server is configured for this network")
} catch {
    // Not connected, and not retrying: start() can be called again
    showError("Could not connect: \(error.localizedDescription)")
}
```

## See Also

- ``ElectrumSyncManager``
- ``ElectrumSyncDelegate``
- ``ElectrumError``
- ``ElectrumServer``
- ``RawTransaction``
- <doc:SendingTransactions>
- <doc:SPVSynchronization>
