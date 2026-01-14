# SPV Synchronization

Sync with the Dogecoin network using Simplified Payment Verification.

@Metadata {
    @PageKind(article)
    @PageImage(purpose: card, source: "spv-card", alt: "SPV Synchronization")
}

## Overview

SPV (Simplified Payment Verification) allows mobile wallets to verify transactions without downloading the entire blockchain. Instead of storing all block data (~100 GB), an SPV client downloads only block headers (~100 MB for Dogecoin's entire history).

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

class WalletSyncManager {
    let syncManager: SPVSyncManager

    init(network: DogecoinNetwork = .mainnet) {
        // Initialize SPV manager
        syncManager = SPVSyncManager(network: network)
        syncManager.delegate = self
    }

    func startSync() {
        syncManager.start()
    }

    func stopSync() {
        syncManager.stop()
    }
}

extension WalletSyncManager: SPVSyncDelegate {
    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) {
        let percent = Int(progress * 100)
        print("Syncing: \(percent)% (block \(height))")
    }

    func spvSyncDidComplete(_ manager: SPVSyncManager) {
        print("Sync complete at height \(manager.currentHeight)")
    }

    func spvSync(_ manager: SPVSyncManager, didReceiveHeader header: BlockHeader, height: Int32) {
        // New block header received
    }

    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) {
        print("Sync error: \(error)")
    }
}
```

### SwiftUI Integration

```swift
import SwiftUI
import DogecoinKit

@Observable
class SyncViewModel {
    var progress: Double = 0
    var currentHeight: Int32 = 0
    var targetHeight: Int32 = 0
    var state: SPVSyncState = .idle
    var isConnected: Bool = false

    private let syncManager: SPVSyncManager

    init(network: DogecoinNetwork = .mainnet) {
        self.syncManager = SPVSyncManager(network: network)
        setupDelegate()
    }

    private func setupDelegate() {
        syncManager.delegate = self
    }

    func startSync() {
        state = .connecting
        syncManager.start()
    }

    func stopSync() {
        syncManager.stop()
        state = .idle
    }
}

extension SyncViewModel: SPVSyncDelegate {
    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) {
        Task { @MainActor in
            self.progress = progress
            self.currentHeight = height
            self.targetHeight = manager.targetHeight
        }
    }

    func spvSyncDidComplete(_ manager: SPVSyncManager) {
        Task { @MainActor in
            self.state = .synchronized
        }
    }

    func spvSync(_ manager: SPVSyncManager, didReceiveHeader header: BlockHeader, height: Int32) {
        // Handle new header if needed
    }

    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) {
        Task { @MainActor in
            self.state = .error(error)
        }
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
                if viewModel.state == .idle {
                    viewModel.startSync()
                } else {
                    viewModel.stopSync()
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
switch syncManager.state {
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
print("Current height: \(syncManager.currentHeight)")
print("Target height: \(syncManager.targetHeight)")
print("Progress: \(syncManager.progress * 100)%")
```

### PeerManager

Manages connections to multiple Dogecoin nodes:

```swift
let peerManager = syncManager.peerManager

// Check connected peers
print("Connected peers: \(peerManager.connectedPeerCount)")

for peer in peerManager.connectedPeers {
    print("- \(peer.host):\(peer.port)")
    if let version = peer.peerVersion {
        print("  User agent: \(version.userAgent)")
        print("  Height: \(version.startHeight)")
    }
}

// Manually add a peer
peerManager.addPeer(host: "seed.dogecoin.com", port: 22556)

// Configure connection limits
peerManager.minPeerConnections = 3
peerManager.maxPeerConnections = 8
```

### HeaderChain

Stores and validates block headers:

```swift
let headerChain = syncManager.headerChain

// Get chain height
print("Chain height: \(headerChain.height)")

// Get a specific header
if let header = headerChain.getHeader(height: 1000000) {
    print("Block 1,000,000 hash: \(header.header.hashHex)")
    print("Timestamp: \(Date(timeIntervalSince1970: Double(header.header.timestamp)))")
}

// Get block locator for sync
let locator = headerChain.getBlockLocator()
print("Locator has \(locator.count) hashes")
```

## Peer Discovery

DogecoinKit automatically discovers peers via DNS seeds:

| Network | Seeds |
|---------|-------|
| Mainnet | seed.multidoge.org, seed.dogecoin.com, seed.dogechain.info |
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

let locator = headerChain.getBlockLocator()
// Example: [tip, tip-1, tip-2, ..., tip-9, tip-11, tip-15, ..., genesis]
```

## Custom Storage Location

Specify where to store headers:

```swift
let documentsURL = FileManager.default.urls(
    for: .documentDirectory,
    in: .userDomainMask
).first!

let storageURL = documentsURL.appendingPathComponent("DogecoinWallet")

let syncManager = SPVSyncManager(
    network: .mainnet,
    storageDirectory: storageURL
)
```

## Background Sync

For iOS apps, register for background fetch:

```swift
import BackgroundTasks

func registerBackgroundSync() {
    BGTaskScheduler.shared.register(
        forTaskWithIdentifier: "com.yourapp.blockchain-sync",
        using: nil
    ) { task in
        handleBackgroundSync(task: task as! BGProcessingTask)
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

    task.expirationHandler = {
        syncManager.stop()
    }

    syncManager.delegate = BackgroundSyncDelegate { completed in
        task.setTaskCompleted(success: completed)
    }

    syncManager.start()
}
```

Don't forget to add the background mode capability and task identifier to your Info.plist.

## Performance Optimization

### Batch Header Processing

Headers are processed in batches of up to 2000:

```swift
extension WalletSyncManager: SPVSyncDelegate {
    func spvSync(_ manager: SPVSyncManager, didReceiveHeader header: BlockHeader, height: Int32) {
        // Don't process every header individually
        // Instead, wait for batch completion
    }

    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) {
        // Update UI after each batch
        // Avoid heavy UI updates for every single header
    }
}
```

### Throttling UI Updates

```swift
@Observable
class ThrottledSyncViewModel {
    var progress: Double = 0
    var currentHeight: Int32 = 0

    private var lastUpdateTime: Date = .distantPast
    private let updateInterval: TimeInterval = 0.5

    func updateProgress(_ progress: Double, height: Int32) {
        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= updateInterval else { return }

        Task { @MainActor in
            self.progress = progress
            self.currentHeight = height
        }

        lastUpdateTime = now
    }
}
```

## Error Recovery

Handle sync errors gracefully:

```swift
extension WalletSyncManager: SPVSyncDelegate {
    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) {
        switch error {
        case let nsError as NSError where nsError.domain == NSURLErrorDomain:
            // Network error - retry after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                manager.start()
            }

        default:
            // Other error - notify user
            showError("Sync failed: \(error.localizedDescription)")
        }
    }
}
```

## Monitoring Sync Health

```swift
class SyncHealthMonitor {
    private let syncManager: SPVSyncManager
    private var lastHeight: Int32 = 0
    private var stuckCount = 0

    func checkHealth() {
        let currentHeight = syncManager.currentHeight

        if currentHeight == lastHeight && syncManager.state == .syncing {
            stuckCount += 1
            if stuckCount >= 3 {
                // Sync appears stuck - restart
                syncManager.stop()
                syncManager.start()
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
6. **Monitor peer health** — Reconnect to peers that become unresponsive
7. **Validate headers** — DogecoinKit validates proof-of-work automatically

## See Also

- ``SPVSyncManager``
- ``SPVSyncDelegate``
- ``SPVSyncState``
- ``PeerManager``
- ``HeaderChain``
- ``BlockHeader``
- <doc:SendingTransactions>
