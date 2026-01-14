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

    /// Current sync state
    public private(set) var state: SPVSyncState = .idle

    /// Target height (best height from peers)
    public private(set) var targetHeight: Int32 = 0

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

    /// Peer currently syncing from
    private var syncPeer: Peer?

    /// Whether we're waiting for headers
    private var waitingForHeaders = false

    /// Create an SPV sync manager
    public init(network: DogecoinNetwork = .mainnet, storageDirectory: URL? = nil) {
        self.network = network
        self.peerManager = PeerManager(network: network)
        self.headerChain = HeaderChain(network: network, storageDirectory: storageDirectory)
    }

    /// Start synchronization
    public func start() {
        guard state == .idle else {
            logger.warning("Cannot start: already running")
            return
        }

        logger.info("Starting SPV sync")
        state = .connecting

        peerManager.delegate = self
        peerManager.start()
    }

    /// Stop synchronization
    public func stop() {
        logger.info("Stopping SPV sync")

        peerManager.stop()
        syncPeer = nil
        waitingForHeaders = false
        state = .idle
    }

    /// Request headers from a peer
    private func requestHeaders(from peer: Peer) {
        guard !waitingForHeaders else { return }

        let locator = headerChain.getBlockLocator()
        logger.info("Requesting headers from \(peer.host), locator has \(locator.count) hashes")

        waitingForHeaders = true
        peer.sendGetHeaders(locatorHashes: locator)
    }

    /// Handle received headers
    private func handleHeaders(_ headers: [BlockHeader], from peer: Peer) {
        waitingForHeaders = false

        guard !headers.isEmpty else {
            logger.info("No more headers from \(peer.host)")

            if currentHeight >= targetHeight {
                state = .synchronized
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
            state = .synchronized
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
            if version.startHeight > targetHeight {
                targetHeight = version.startHeight
            }
        }

        // Start syncing if we don't have a sync peer
        if syncPeer == nil && state == .connecting {
            syncPeer = peer
            state = .syncing
            requestHeaders(from: peer)
        }
    }

    public func peerManager(_ manager: PeerManager, peerDidDisconnect peer: Peer) {
        logger.info("Peer disconnected: \(peer.host)")

        if peer == syncPeer {
            syncPeer = nil
            waitingForHeaders = false

            // Try another peer
            if let nextPeer = manager.connectedPeers.first {
                syncPeer = nextPeer
                requestHeaders(from: nextPeer)
            }
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
            if peer == syncPeer {
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
