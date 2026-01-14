import Foundation
import os.log

/// Delegate for SPV sync events
public protocol SPVSyncDelegate: AnyObject, Sendable {
    /// Called when sync progress updates
    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32)

    /// Called when sync completes
    func spvSyncDidComplete(_ manager: SPVSyncManager)

    /// Called when a new block header is received
    func spvSync(_ manager: SPVSyncManager, didReceiveHeader header: BlockHeader, height: Int32)

    /// Called when an error occurs
    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error)
}

/// Synchronization state
public enum SPVSyncState: Sendable {
    case idle
    case connecting
    case syncing
    case synchronized
    case error(Error)
}

/// Manages SPV synchronization
public final class SPVSyncManager: @unchecked Sendable {
    /// The network
    public let network: DogecoinNetwork

    /// The peer manager
    public let peerManager: PeerManager

    /// The header chain
    public let headerChain: HeaderChain

    /// Delegate for events
    public weak var delegate: SPVSyncDelegate?

    private struct SyncState {
        var state: SPVSyncState = .idle
        var targetHeight: Int32 = 0
        var syncPeer: Peer?
        var waitingForHeaders = false
    }

    private var syncState = SyncState()

    /// Current sync state
    public var state: SPVSyncState {
        withLock { $0.state }
    }

    /// Target height (best height from peers)
    public var targetHeight: Int32 {
        withLock { $0.targetHeight }
    }

    /// Current synced height
    public var currentHeight: Int32 {
        headerChain.height
    }

    /// Sync progress (0.0 to 1.0)
    public var progress: Double {
        guard targetHeight > 0 else { return 0 }
        return Double(currentHeight) / Double(targetHeight)
    }

    /// Lock for thread safety
    private let lock = NSLock()

    /// Logger
    private let logger = Logger(subsystem: "DogecoinKit", category: "SPVSyncManager")

    private func withLock<T>(_ body: (inout SyncState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&syncState)
    }

    private func setState(_ newState: SPVSyncState) {
        withLock { $0.state = newState }
    }

    /// Create an SPV sync manager
    public init(network: DogecoinNetwork = .mainnet, storageDirectory: URL? = nil) {
        self.network = network
        self.peerManager = PeerManager(network: network)
        self.headerChain = HeaderChain(network: network, storageDirectory: storageDirectory)
    }

    /// Start synchronization
    public func start() {
        let canStart = withLock { state in
            guard state.state == .idle else { return false }
            state.state = .connecting
            return true
        }

        guard canStart else {
            logger.warning("Cannot start: already running")
            return
        }

        logger.info("Starting SPV sync")

        peerManager.delegate = self
        peerManager.start()
    }

    /// Stop synchronization
    public func stop() {
        logger.info("Stopping SPV sync")

        peerManager.stop()
        withLock { state in
            state.syncPeer = nil
            state.waitingForHeaders = false
            state.state = .idle
        }
    }

    // MARK: - Transaction Broadcasting

    /// Broadcast a signed transaction to the network
    /// - Parameter rawHex: The raw transaction hex string
    /// - Returns: The transaction ID (txid) as a hex string
    /// - Throws: DogecoinError if broadcast fails
    public func broadcastTransaction(_ rawHex: String) throws -> String {
        try peerManager.broadcastTransaction(rawHex)
    }

    /// Broadcast a signed transaction to the network
    /// - Parameter signedTransaction: The signed transaction
    /// - Returns: The transaction ID (txid) as a hex string
    /// - Throws: DogecoinError if broadcast fails
    public func broadcastTransaction(_ signedTransaction: SignedTransaction) throws -> String {
        try peerManager.broadcastTransaction(signedTransaction.rawHex)
    }

    /// Request headers from a peer
    private func requestHeaders(from peer: Peer) {
        let canRequest = withLock { state in
            guard !state.waitingForHeaders else { return false }
            state.waitingForHeaders = true
            return true
        }

        guard canRequest else { return }

        let locator = headerChain.getBlockLocator()
        logger.info("Requesting headers from \(peer.host), locator has \(locator.count) hashes")

        peer.sendGetHeaders(locatorHashes: locator)
    }

    /// Handle received headers
    private func handleHeaders(_ headers: [BlockHeader], from peer: Peer) {
        withLock { $0.waitingForHeaders = false }

        guard !headers.isEmpty else {
            logger.info("No more headers from \(peer.host)")

            if currentHeight >= targetHeight {
                setState(.synchronized)
                delegate?.spvSyncDidComplete(self)
            }
            return
        }

        logger.info("Received \(headers.count) headers from \(peer.host)")

        let added = headerChain.addHeaders(headers)
        logger.info("Added \(added) headers, height now \(self.currentHeight)")

        // Notify delegate
        for header in headers.prefix(added) {
            if let stored = headerChain.getHeader(hash: header.hash) {
                delegate?.spvSync(self, didReceiveHeader: header, height: stored.height)
            }
        }

        // Update progress
        delegate?.spvSync(self, progressUpdated: progress, height: currentHeight)

        // Request more if we got a full batch
        if headers.count >= 2000 {
            requestHeaders(from: peer)
        } else if currentHeight >= targetHeight {
            setState(.synchronized)
            delegate?.spvSyncDidComplete(self)
        }
    }
}

// MARK: - PeerManagerDelegate

extension SPVSyncManager: PeerManagerDelegate {
    public func peerManager(_ manager: PeerManager, peerDidBecomeReady peer: Peer) {
        logger.info("Peer ready: \(peer.host)")

        // Update target height from peer version
        if let version = peer.peerVersion {
            withLock { state in
                if version.startHeight > state.targetHeight {
                    state.targetHeight = version.startHeight
                }
            }
        }

        // Start syncing if we don't have a sync peer
        let shouldStart = withLock { state in
            guard state.syncPeer == nil, state.state == .connecting else { return false }
            state.syncPeer = peer
            state.state = .syncing
            return true
        }

        if shouldStart {
            requestHeaders(from: peer)
        }
    }

    public func peerManager(_ manager: PeerManager, peerDidDisconnect peer: Peer) {
        logger.info("Peer disconnected: \(peer.host)")

        let shouldReconnect = withLock { state in
            guard peer == state.syncPeer else { return false }
            state.syncPeer = nil
            state.waitingForHeaders = false
            return true
        }

        guard shouldReconnect else { return }

        // Try another peer
        if let nextPeer = manager.connectedPeers.first {
            withLock { $0.syncPeer = nextPeer }
            requestHeaders(from: nextPeer)
        }
    }

    public func peerManager(_ manager: PeerManager, peer: Peer, didReceiveMessage message: ProtocolMessage) {
        switch message.command {
        case ProtocolMessage.Command.headers:
            if let headersMsg = HeadersMessage.parse(from: message.payload) {
                handleHeaders(headersMsg.headers, from: peer)
            }

        case ProtocolMessage.Command.inv:
            if let invMsg = InvMessage.parse(from: message.payload) {
                handleInventory(invMsg.inventory, from: peer)
            }

        case ProtocolMessage.Command.reject:
            logger.warning("Received reject from \(peer.host)")

        default:
            break
        }
    }

    public func peerManager(_ manager: PeerManager, connectedPeerCountChanged count: Int) {
        logger.info("Connected peers: \(count)")
    }

    private func handleInventory(_ inventory: [InventoryVector], from peer: Peer) {
        // Filter for blocks
        let blockInv = inventory.filter { $0.type == .block }
        if !blockInv.isEmpty {
            logger.debug("Received inventory with \(blockInv.count) blocks")

            // Request headers for new blocks
            let isSyncPeer = withLock { $0.syncPeer == peer }
            if isSyncPeer {
                requestHeaders(from: peer)
            }
        }
    }
}

// MARK: - Equatable for SPVSyncState

extension SPVSyncState: Equatable {
    public static func == (lhs: SPVSyncState, rhs: SPVSyncState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.connecting, .connecting), (.syncing, .syncing), (.synchronized, .synchronized):
            return true
        case (.error, .error):
            return true
        default:
            return false
        }
    }
}
