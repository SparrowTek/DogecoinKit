# SPV Synchronization

Sync with the Dogecoin network using Simplified Payment Verification.

@Metadata {
    @PageKind(article)
    @PageImage(purpose: card, source: "spv-card", alt: "SPV Synchronization")
}

## Overview

SPV (Simplified Payment Verification) allows mobile wallets to verify transactions without downloading the entire blockchain. Instead of storing all block data (~100 GB), an SPV client downloads only block headers (80 bytes each, roughly 500 MB for Dogecoin's 6 million+ blocks).

DogecoinKit provides a complete SPV implementation using native Swift networking.

## How SPV Works

```
┌─────────────────────────────────────────────────────────────────┐
│                        Full Node                                │
│  ┌─────────┬─────────┬─────────┬─────────┬─────────┐          │
│  │ Block 1 │ Block 2 │ Block 3 │   ...   │Block N  │          │
│  │ Header  │ Header  │ Header  │         │ Header  │          │
│  │ Txs     │ Txs     │ Txs     │         │ Txs     │          │
│  │ (many)  │ (many)  │ (many)  │         │ (many)  │          │
│  └─────────┴─────────┴─────────┴─────────┴─────────┘          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                        SPV Client                               │
│  ┌─────────┬─────────┬─────────┬─────────┬─────────┐          │
│  │ Header  │ Header  │ Header  │   ...   │ Header  │          │
│  │ 80 bytes│ 80 bytes│ 80 bytes│         │ 80 bytes│          │
│  └─────────┴─────────┴─────────┴─────────┴─────────┘          │
│                                                                 │
│  Only downloads headers + relevant transactions                 │
└─────────────────────────────────────────────────────────────────┘
```

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

    func spvSync(_ manager: SPVSyncManager, didReceiveHeader header: BlockHeader, height: Int32) async {
        // New block header received
    }

    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) async {
        print("Sync error: \(error)")
    }
}
```

``SPVSyncManager`` is an actor. Read its properties and call its methods with `await`, and set the delegate with `setDelegate(_:)`, because actor properties can't be assigned from outside. The manager holds its delegate weakly. Delegates must be `Sendable`, which is why `WalletSyncManager` is a `final` class with only immutable, `Sendable` stored properties. Callbacks are `async` and arrive strictly in order. For example, a transaction's `.confirmed` update never overtakes its `.unconfirmed` one. `spvSyncDidComplete` fires each time the chain catches up with its peers: once after the initial sync, and again after every new block.

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

    func spvSync(_ manager: SPVSyncManager, didReceiveHeader header: BlockHeader, height: Int32) async {
        // Handle new header if needed
    }

    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) async {
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
let progress = await syncManager.progress
print("Current height: \(currentHeight)")
print("Target height: \(targetHeight)")
print("Progress: \(progress * 100)%")
```

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
if let header = await headerChain.getHeader(height: 1_000_000) {
    print("Block 1,000,000 hash: \(header.header.hashHex)")
    print("Timestamp: \(Date(timeIntervalSince1970: Double(header.header.timestamp)))")
}

// Get block locator for sync
let locator = await headerChain.getBlockLocator()
print("Locator has \(locator.count) hashes")
```

### Header Validation

``HeaderChain`` checks every header the way Dogecoin Core does before the header can extend or replace the best chain:

- **Checkpoints**: A header at a checkpoint height must match the checkpoint, and no branch may fork below a checkpoint the chain has already passed.
- **Proof of work**: A merge-mined header must carry a valid AuxPoW proof, in which the parent block's scrypt hash meets the Dogecoin header's target. Any other header's own scrypt hash must meet its target. The parent coinbase may arrive in segregated-witness form, and it is matched to the parent block by its witness-free txid, as Core does. Headers that arrive without their proof are trusted only at or below the highest checkpoint.
- **Version and difficulty (mainnet)**: Block versions must carry Dogecoin's chain ID, merge-mined versions may only appear from the merged-mining start (and legacy versions only before it), and base versions must meet the BIP 66 and BIP 65 minimums. `nBits` must be exactly what DigiShield's `GetNextWorkRequired` demands. Testnet headers are held only to the target they claim.
- **Time**: Each header must be later than the median time of the previous 11 blocks and no more than two hours in the future.

A competing branch replaces the tip only when it has strictly more cumulative work. When the work is equal, the current tip stays. ``SPVSyncManager`` bans any peer that sends consensus-invalid headers and continues syncing from another peer. Some failures don't get a peer banned, matching Dogecoin Core: headers that fail to connect (the peer may be on a branch you haven't seen yet), timestamps (they're judged against your device's clock, which may be wrong), and obsolete versions.

## Peer Discovery

DogecoinKit automatically discovers peers via DNS seeds:

| Network | Seeds |
|---------|-------|
| Mainnet | seed.multidoge.org, seed2.multidoge.org, seed.dogecoin.com, seed.dogechain.info |
| Testnet | testnetseed.jrn.me.uk |

The discovery process:

1. Query DNS seeds for peer IP addresses
2. Connect to discovered peers
3. Exchange version messages (handshake)
4. Begin header synchronization

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

let locator = await headerChain.getBlockLocator()
// Example: [tip, tip-1, tip-2, ..., tip-9, tip-11, tip-15, ..., genesis]
```

## Custom Storage Location

Specify where to store headers:

```swift
let storageURL = URL.documentsDirectory.appending(path: "DogecoinWallet")

let syncManager = SPVSyncManager(
    network: .mainnet,
    storageDirectory: storageURL
)
```

## Background Sync

For iOS apps, register for background fetch:

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

Headers are processed in batches of up to 2000:

```swift
extension WalletSyncManager: SPVSyncDelegate {
    func spvSync(_ manager: SPVSyncManager, didReceiveHeader header: BlockHeader, height: Int32) async {
        // Don't process every header individually
        // Instead, wait for batch completion
    }

    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) async {
        // Update UI after each batch
        // Avoid heavy UI updates for every single header
    }
}
```

### Throttling UI Updates

```swift
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

Handle sync errors gracefully. The manager recovers from network trouble on its own. It drops peers that time out or disconnect, backs off before retrying them, bans peers that send invalid headers, and keeps syncing from the peers that remain. If every peer is lost, syncing resumes as soon as a new one connects. The delegate hears about problems with the data your wallet depends on, such as a block or merkle proof that fails verification. By the time the delegate is called, the peer that sent it has already been banned.

```swift
extension WalletSyncManager: SPVSyncDelegate {
    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) async {
        switch error {
        case DogecoinError.syncFailed, is MerkleBlockError:
            // A peer sent a block or merkle proof that failed verification.
            // It has already been banned; sync continues with other peers.
            print("Discarded invalid data: \(error.localizedDescription)")

        default:
            // Other error - notify user
            showError("Sync failed: \(error.localizedDescription)")
        }
    }
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
4. **Implement retry logic** — Network issues are common on mobile
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
