# SPV Synchronization

Sync with the Dogecoin network using Simplified Payment Verification.

@Metadata {
    @PageKind(article)
}

## Overview

SPV (Simplified Payment Verification) allows mobile wallets to verify transactions without downloading the entire blockchain. Instead of storing every block, an SPV client downloads only block headers. A header is 80 bytes, but DogecoinKit keeps headers in an indexed SQLite database that takes roughly 1.3–2 GB for Dogecoin's 6.3 million+ blocks: about 1.3 GB when the current version creates it, and up to about 2 GB if an earlier version created it, because the indexes dropped since then leave free pages in the file that SQLite reuses but doesn't give back.

DogecoinKit implements SPV with native Swift networking. It is one of the Kit's two ways to follow the chain. The other, <doc:ElectrumSynchronization>, asks a server instead: it downloads no header chain and stores nothing, and trusts that server for what is in the chain.

## How SPV Works

```
┌─────────────────────────────────────────────────────────────────┐
│                        Full Node                                │
│  ┌─────────┬─────────┬─────────┬─────────┬─────────┐            │
│  │ Block 1 │ Block 2 │ Block 3 │   ...   │ Block N │            │
│  │ Header  │ Header  │ Header  │         │ Header  │            │
│  │ Txs     │ Txs     │ Txs     │         │ Txs     │            │
│  │ (many)  │ (many)  │ (many)  │         │ (many)  │            │
│  └─────────┴─────────┴─────────┴─────────┴─────────┘            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                        SPV Client                               │
│  ┌─────────┬─────────┬─────────┬─────────┬─────────┐            │
│  │ Header  │ Header  │ Header  │   ...   │ Header  │            │
│  │ 80 bytes│ 80 bytes│ 80 bytes│         │ 80 bytes│            │
│  └─────────┴─────────┴─────────┴─────────┴─────────┘            │
│                                                                 │
│  Only downloads headers + relevant transactions                 │
└─────────────────────────────────────────────────────────────────┘
```

The client validates every header it downloads, so the chain of headers is one it has checked for itself. It then asks a peer for the blocks in filtered form: the transactions that match the wallet's filter, with a merkle proof that ties them to the block's header. The proof shows that a transaction is in a block. It can't show that the peer included every transaction it should have: a peer can leave one out, and the wallet has no way to tell.

## Getting Started with SPV

### Basic Setup

```swift
import DogecoinKit

final class WalletSyncManager {
    let syncManager: SPVSyncManager

    init(network: DogecoinNetwork = .mainnet) {
        // Initialize SPV manager
        syncManager = SPVSyncManager(network: network)
    }

    func startSync() async {
        await syncManager.setDelegate(self)
        await syncManager.start()
    }

    func stopSync() async {
        await syncManager.stop()
    }
}

extension WalletSyncManager: SPVSyncDelegate {
    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) async {
        let percent = Int(progress * 100)
        print("Syncing: \(percent)% (block \(height))")
    }

    func spvSyncDidComplete(_ manager: SPVSyncManager) async {
        let height = await manager.currentHeight
        print("Sync complete at height \(height)")
    }

    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) async {
        // The header database could not be opened, read, or written: the sync has stopped
        print("Sync error: \(error)")
    }
}
```

``SPVSyncManager`` is an actor. Read its properties and call its methods with `await`, and set the delegate with `setDelegate(_:)`, because actor properties can't be assigned from outside. The manager holds its delegate weakly. Delegates must be `Sendable`, which is why `WalletSyncManager` is a `final` class with only immutable, `Sendable` stored properties. Callbacks are `async` and arrive strictly in order. For example, a transaction's `.confirmed` update never overtakes its `.unconfirmed` one.

`spvSyncDidComplete` fires each time the chain catches up with its peers: once after the initial sync, and again after every new block. With a single peer connected, the manager first waits up to ten seconds for a second one, because a lone peer may be the one that is behind.

### Watching Your Addresses

Headers alone don't tell you about your transactions. Give the manager a bloom filter (BIP 37) with ``SPVSyncManager/configureBloomFilter(elements:falsePositiveRate:tweak:flags:startHeight:)`` and it scans filtered blocks from `startHeight`, verifies each merkle proof, and reports the wallet's transactions through `spvSync(_:didUpdateTransaction:state:)`. Without a filter, that callback and `spvSync(_:didScanThrough:targetHeight:)` never fire.

```swift
// A node tests the data each script pushes, never a whole script, so the
// element to insert for a P2PKH address is its 20-byte public key hash
func publicKeyHash(of address: String) -> Data? {
    guard Address.kind(address) == .p2pkh,
          let script = Address.scriptPubKey(for: address) else {
        return nil
    }
    return Data(script[3..<23])  // OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
}

await syncManager.configureBloomFilter(
    elements: addresses.compactMap(publicKeyHash(of:)),
    startHeight: birthdayHeight
)

// Later, when the wallet derives a new address
if let element = publicKeyHash(of: newAddress) {
    await syncManager.addBloomFilterElement(element)
}
```

The `flags` parameter defaults to 1, BIP 37's `BLOOM_UPDATE_ALL`: a peer adds every output it matches to its copy of the filter, so it also matches the transaction that later spends that output.

A bloom filter matches some things it was never given. The manager tests every transaction a peer sends against exactly what you asked it to watch, plus the outputs it has seen paying those elements, and reports only the ones that really are the wallet's. The filter itself still goes to every peer the manager uses. It narrows down which addresses are the wallet's without naming them, and a peer can test any address against it, so treat it as a hint the peers hold, not as a secret.

A transaction arrives as `.unconfirmed` if a peer relays it before it is mined, then as `.confirmed(blockHash:height:)`. After a chain reorganization, each affected transaction is reported as `.reorged`, and as `.confirmed` again once the block that replaced its old one holds it.

### Resuming a Scan

`spvSync(_:didScanThrough:targetHeight:)` reports how far the scan has got without a gap: every block up to that height has been fetched, checked against its header, and searched, and every transaction found in them has already been reported. Save it, and the next launch can start just above it instead of at the wallet's birthday:

```swift
extension WalletSyncManager {
    func spvSync(_ manager: SPVSyncManager, didScanThrough height: Int32, targetHeight: Int32) async {
        // Keep the latest value, not the highest: after a reorganization
        // the scan goes back to the fork, and this height with it
        UserDefaults.standard.set(Int(height), forKey: "scannedHeight")
    }
}
```

A peer that is sent a filter afresh has not seen the wallet's earlier transactions go by, so it can't recognize a transaction that spends one of their outputs. When you start above the birthday, add the outpoint of each unspent output to the filter's elements:

```swift
/// An outpoint as a filter holds it: the txid in internal byte order (the
/// reverse of its hex form), then the output index as four little-endian bytes
func outpointElement(txid: Data, index: UInt32) -> Data {
    var element = txid
    withUnsafeBytes(of: index.littleEndian) { element.append(contentsOf: $0) }
    return element
}

// `unspent` is the wallet's own record of its unspent outputs
let unspentOutpoints = unspent.map { outpointElement(txid: $0.txid, index: $0.index) }
let scannedHeight = UserDefaults.standard.object(forKey: "scannedHeight") as? Int

await syncManager.configureBloomFilter(
    elements: publicKeyHashes + unspentOutpoints,
    startHeight: scannedHeight.map { Int32(clamping: $0 + 1) } ?? birthdayHeight
)
```

``TxMessage/txidInternal`` gives a reported transaction's txid in that byte order.

### SwiftUI Integration

```swift
import SwiftUI
import DogecoinKit

@MainActor
@Observable
final class SyncViewModel {
    var progress: Double = 0
    var currentHeight: Int32 = 0
    var targetHeight: Int32 = 0
    var state: SPVSyncState = .idle
    var isConnected: Bool = false

    private let syncManager: SPVSyncManager

    init(network: DogecoinNetwork = .mainnet) {
        self.syncManager = SPVSyncManager(network: network)
    }

    func startSync() async {
        state = .connecting
        await syncManager.setDelegate(self)
        await syncManager.start()
    }

    func stopSync() async {
        await syncManager.stop()
        state = .idle
    }
}

extension SyncViewModel: SPVSyncDelegate {
    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) async {
        self.progress = progress
        self.currentHeight = height
        self.targetHeight = await manager.targetHeight
    }

    func spvSyncDidComplete(_ manager: SPVSyncManager) async {
        state = .synchronized
    }

    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) async {
        // The sync has stopped: the header database could not be opened, read, or written
        state = .error(error)
    }
}

struct SyncProgressView: View {
    @State private var viewModel = SyncViewModel()

    var body: some View {
        VStack(spacing: 20) {
            // Progress indicator
            ProgressView(value: viewModel.progress) {
                Text("Syncing Blockchain")
            } currentValueLabel: {
                Text("\(Int(viewModel.progress * 100))%")
            }

            // Height info
            Text("Block \(viewModel.currentHeight) of \(viewModel.targetHeight)")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Sync button
            Button(viewModel.state == .idle ? "Start Sync" : "Stop Sync") {
                Task {
                    if viewModel.state == .idle {
                        await viewModel.startSync()
                    } else {
                        await viewModel.stopSync()
                    }
                }
            }
        }
        .padding()
    }
}
```

## Understanding Components

### SPVSyncManager

The main coordinator for blockchain synchronization:

```swift
let syncManager = SPVSyncManager(network: .mainnet)

// Check sync state
switch await syncManager.state {
case .idle:
    print("Not syncing")
case .connecting:
    print("Connecting to peers...")
case .syncing:
    print("Downloading headers...")
case .synchronized:
    print("Fully synced!")
case .error(let error):
    print("Error: \(error)")
}

// Access sync info
let currentHeight = await syncManager.currentHeight
let targetHeight = await syncManager.targetHeight
print("Current height: \(currentHeight)")
print("Target height: \(targetHeight)")
```

`targetHeight` is how far the chain is expected to reach: the median of the heights the connected peers announced, or the chain's own height once it is past that.

> Note: The header database is opened by ``SPVSyncManager/start()``, or by creating the manager with ``SPVSyncManager/create(network:storageDirectory:bundledCacheDirectory:)``, which throws if it can't be opened. Until then `currentHeight` is `-1`, and the header chain's lookups throw ``HeaderDatabaseError/databaseNotOpen``.

### PeerManager

Manages connections to multiple Dogecoin nodes:

```swift
let peerManager = await syncManager.peerManager

// Check connected peers
print("Connected peers: \(await peerManager.connectedPeerCount)")

for peer in await peerManager.connectedPeers {
    print("- \(peer.host):\(peer.port)")
    if let version = await peer.peerVersion {
        print("  User agent: \(version.userAgent)")
        print("  Height: \(version.startHeight)")
    }
}

// Manually add a peer
await peerManager.addPeer(host: "seed.dogecoin.com", port: 22556)

// Configure connection limits (actor properties can't be set from outside)
await peerManager.configure(minPeerConnections: 3, maxPeerConnections: 8)
```

``PeerManager`` and ``Peer`` are actors too. A peer's identity (`id`, `host`, `port`, `network`) can be read directly, but its state and methods need `await`. To change a peer's timeouts, call `await peer.configureTimeouts(connection:handshake:ping:)`.

### HeaderChain

Stores and validates block headers:

```swift
let headerChain = await syncManager.headerChain

// Get chain height
print("Chain height: \(await headerChain.height)")

// Get a specific header
if let header = try await headerChain.getHeader(height: 1_000_000) {
    print("Block 1,000,000 hash: \(header.header.hashHex)")
    print("Timestamp: \(Date(timeIntervalSince1970: Double(header.header.timestamp)))")
}

// Get block locator for sync
let locator = try await headerChain.getBlockLocator()
print("Locator has \(locator.count) hashes")
```

The lookups throw when the database can't be read. A `nil` header means it isn't stored, not that reading failed.

### Header Validation

``HeaderChain`` checks every header the way Dogecoin Core does before the header can extend or replace the best chain:

- **Checkpoints**: A header at a checkpoint height must match the checkpoint, and no branch may fork below a checkpoint the chain has already passed.
- **Proof of work**: A merge-mined header must carry a valid AuxPoW proof, in which the parent block's scrypt hash meets the Dogecoin header's target. Any other header's own scrypt hash must meet its target. The parent coinbase may arrive in segregated-witness form, and it is matched to the parent block by its witness-free txid, as Core does. Headers that arrive without their proof are trusted only at or below the highest checkpoint.
- **Version and difficulty (mainnet)**: Block versions must carry Dogecoin's chain ID, merge-mined versions may only appear from the merged-mining start (and legacy versions only before it), and base versions must meet the BIP 66 and BIP 65 minimums. `nBits` must be exactly what DigiShield's `GetNextWorkRequired` demands. Testnet headers are held only to the target they claim.
- **Time**: Each header must be later than the median time of the previous 11 blocks and no more than two hours in the future.

A competing branch replaces the tip only when it has strictly more cumulative work. When the work is equal, the current tip stays. ``SPVSyncManager`` bans any peer that sends consensus-invalid headers and continues syncing from another peer. Some failures don't get a peer banned, matching Dogecoin Core: headers that fail to connect (the peer may be on a branch you haven't seen yet), timestamps (they're judged against your device's clock, which may be wrong), and obsolete versions.

## Starting from a Bundled Header Cache

A first sync downloads more than six million headers, up to 2,000 at a time. To skip most of that, give the chain a header database built ahead of time. Pass the directory that holds it as `bundledCacheDirectory`:

```swift
// A directory holding headers.sqlite and metadata.json: in the app bundle,
// an on-demand resource, or a download
let syncManager = try await SPVSyncManager.create(
    network: .mainnet,
    bundledCacheDirectory: cacheDirectory
)

print("Starting at height \(await syncManager.currentHeight)")
```

The cache is a `headers.sqlite` file in the format ``HeaderDatabase`` writes, next to a `metadata.json` that decodes as ``HeaderCacheMetadata``, with its date in ISO 8601. When the header database is opened, ``HeaderChain`` installs the cache if all of this holds:

- Both files are there, and `network` in the metadata is `"mainnet"` or `"testnet"` to match the chain.
- There is no local database yet, or the local chain is shorter than the metadata's `tipHeight`. A local file that SQLite can't read counts as none and is deleted. One that can't be inspected for some other reason is left alone, and the cache is skipped.
- A copy of the cache, made next to the live database, opens, reaches at least `tipHeight`, and holds this network's genesis block and the highest checkpoint the cache reaches.

Only then does the copy replace the local database. If any step fails, the database that was there stays in place and the sync carries on from it, or from the genesis block if there was none. An install that doesn't happen throws nothing and tells the delegate nothing, so check ``HeaderChain/height`` when you need to know.

Keep in mind what that verification covers:

- The headers in a cache are not validated one by one. The file has to hold this network's genesis block and the highest checkpoint it reaches. Every other header in it, above that checkpoint in particular, is taken as the cache's builder left it. Ship a cache you built from a sync of your own.
- The metadata's other fields have to be present for the file to decode, but they are not compared with anything. In particular `checksumSHA256` is not checked against the file.
- The cache is copied into the storage directory, not moved. The original stays where it was.

## Sending Transactions

``SPVSyncManager/broadcastTransaction(_:)`` announces a signed transaction to the connected peers and returns once one of them has fetched it. The manager then keeps offering it until the scan finds it in a block. ``SPVSyncManager/announceUntilConfirmed(_:)`` does the same for a transaction sent in an earlier session. <doc:SendingTransactions> covers both.

## Peer Discovery

DogecoinKit automatically discovers peers via DNS seeds:

| Network | Seeds |
|---------|-------|
| Mainnet | seed.multidoge.org, seed2.multidoge.org, seed.dogecoin.com, seed.dogechain.info |
| Testnet | testnetseed.jrn.me.uk |

If no seed yields a peer, mainnet falls back to the hard-coded nodes in ``NetworkConstants/mainnetFallbackNodes``.

The discovery process:

1. Query DNS seeds for peer IP addresses
2. Connect to discovered peers
3. Exchange version messages (handshake)
4. Begin header synchronization

A peer has to advertise that it serves the whole chain (`NODE_NETWORK`) and, once a bloom filter is set, that it serves filtered blocks (`NODE_BLOOM`). Peers that don't are disconnected. When no peer is connected and none of the known addresses can be tried, the seeds are asked again.

## Sync Process

### Initial Sync

The first sync downloads all block headers from genesis:

```
Genesis → Block 1 → Block 2 → ... → Current Tip
   │         │         │              │
   └─────────┴─────────┴──────────────┘
              Download all headers
```

### Incremental Sync

Subsequent syncs only download new headers:

```
                    Previously Synced          New Blocks
                    ┌──────────────────┐      ┌─────────┐
Genesis → ... →     │ Block N-10       │  →   │Block N-1│ → Block N
                    │ (already have)   │      │ (new)   │
                    └──────────────────┘      └─────────┘
```

### Block Locator Algorithm

To resume sync efficiently, SPV uses block locators:

```swift
// Block locator includes hashes at exponentially decreasing heights:
// - Last 10 blocks (every block)
// - Then every 2nd block
// - Then every 4th block
// - etc.
// - Always includes genesis

let locator = try await headerChain.getBlockLocator()
// Example: [tip, tip-1, tip-2, ..., tip-9, tip-11, tip-15, ..., genesis]
```

## Custom Storage Location

By default headers are stored in `Caches/DogecoinKit/headers/<network>/headers.sqlite`. Specify where to store headers:

```swift
let storageURL = URL.documentsDirectory.appending(path: "DogecoinWallet")

let syncManager = SPVSyncManager(
    network: .mainnet,
    storageDirectory: storageURL
)
```

## Background Sync

For iOS apps, schedule a background processing task:

```swift
@preconcurrency import BackgroundTasks

func registerBackgroundSync() {
    BGTaskScheduler.shared.register(
        forTaskWithIdentifier: "com.yourapp.blockchain-sync",
        using: nil
    ) { task in
        guard let processingTask = task as? BGProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        handleBackgroundSync(task: processingTask)
    }
}

func scheduleBackgroundSync() {
    let request = BGProcessingTaskRequest(identifier: "com.yourapp.blockchain-sync")
    request.requiresNetworkConnectivity = true
    request.requiresExternalPower = false

    try? BGTaskScheduler.shared.submit(request)
}

func handleBackgroundSync(task: BGProcessingTask) {
    let syncManager = SPVSyncManager(network: .mainnet)

    // SPVSyncManager holds its delegate weakly; the expiration handler
    // keeps this one alive for as long as the task runs
    let delegate = BackgroundSyncDelegate { completed in
        task.setTaskCompleted(success: completed)
    }

    task.expirationHandler = {
        Task {
            await syncManager.stop()
            withExtendedLifetime(delegate) {}
        }
    }

    Task {
        await syncManager.setDelegate(delegate)
        await syncManager.start()
    }
}
```

`BackgroundSyncDelegate` stands for your own `SPVSyncDelegate` that calls its closure once, the first time sync completes or fails. Later `spvSyncDidComplete` calls for new blocks must not complete the task again. Delegates must be `Sendable`, so that closure is `@Sendable`. `BGProcessingTask` isn't marked `Sendable`, so the example imports `BackgroundTasks` with `@preconcurrency` to let the closure capture `task`.

Don't forget to add the background mode capability and task identifier to your Info.plist.

## Performance Optimization

### Batch Header Processing

Headers arrive in batches of up to 2,000. Each batch is validated in memory and stored in one database transaction, and progress is reported once per batch:

```swift
// In your SPVSyncDelegate:
func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) async {
    // Called once per batch: update the UI here
}
```

Callbacks are delivered one at a time, so a slow delegate holds up the ones behind it. Progress reports don't pile up, though: while one is still waiting to be delivered, a newer one takes its place.

### Throttling UI Updates

```swift
import Observation

@MainActor
@Observable
final class ThrottledSyncViewModel {
    var progress: Double = 0
    var currentHeight: Int32 = 0

    private var lastUpdateTime: Date = .distantPast
    private let updateInterval: TimeInterval = 0.5

    func updateProgress(_ progress: Double, height: Int32) {
        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= updateInterval else { return }

        self.progress = progress
        self.currentHeight = height

        lastUpdateTime = now
    }
}
```

## Error Recovery

The manager recovers from trouble with peers on its own, and doesn't report it. It drops peers that time out, disconnect, or don't deliver the blocks they were asked for, backs off before retrying them, bans peers that send invalid headers, merkle proofs, or transactions, and keeps syncing from the peers that remain. If every peer is lost, syncing resumes as soon as a new one connects.

`spvSync(_:didEncounterError:)` means something else: the sync cannot go on, because the header database could not be opened, read, or written. By the time it is called, `state` is `.error` and the manager has stopped. Fix what is wrong with the storage, then call `start()` again.

```swift
// In your SPVSyncDelegate:
func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) async {
    // Nothing is syncing any more. Once the storage problem is fixed,
    // start() tries again.
    showError("Sync stopped: \(error.localizedDescription)")
}
```

## Monitoring Sync Health

```swift
actor SyncHealthMonitor {
    private let syncManager: SPVSyncManager
    private var lastHeight: Int32 = 0
    private var stuckCount = 0

    init(syncManager: SPVSyncManager) {
        self.syncManager = syncManager
    }

    func checkHealth() async {
        let currentHeight = await syncManager.currentHeight
        let state = await syncManager.state

        if currentHeight == lastHeight && state == .syncing {
            stuckCount += 1
            if stuckCount >= 3 {
                // Sync appears stuck - restart
                await syncManager.stop()
                await syncManager.start()
                stuckCount = 0
            }
        } else {
            stuckCount = 0
        }

        lastHeight = currentHeight
    }
}
```

## Best Practices

1. **Start sync early** — Begin sync when app launches or enters foreground
2. **Handle interruptions** — Save state when app backgrounds
3. **Show meaningful progress** — Display blocks synced, not just percentage
4. **Save the scan height** — Store what `spvSync(_:didScanThrough:targetHeight:)` reports so the next launch doesn't rescan from the wallet's birthday
5. **Use background sync** — Keep wallet updated via background tasks
6. **Monitor peer health** — DogecoinKit pings peers, drops unresponsive ones, and tops up connections automatically. Surface `connectedPeerCount` in your UI
7. **Validate headers** — DogecoinKit validates checkpoints, proof of work, difficulty, and timestamps automatically (see Header Validation above)

## See Also

- ``SPVSyncManager``
- ``SPVSyncDelegate``
- ``SPVSyncState``
- ``PeerManager``
- ``HeaderChain``
- ``BlockHeader``
- <doc:SendingTransactions>
- <doc:ElectrumSynchronization>
