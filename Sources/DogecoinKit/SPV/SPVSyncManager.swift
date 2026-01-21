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

    /// Called when a transaction changes state (unconfirmed, confirmed, or reorged)
    func spvSync(_ manager: SPVSyncManager, didUpdateTransaction transaction: TxMessage, state: SPVTransactionState)
}

/// Synchronization state
public enum SPVSyncState: Sendable {
    case idle
    case connecting
    case syncing
    case synchronized
    case error(Error)
}

/// SPV transaction lifecycle state
public enum SPVTransactionState: Sendable {
    case unconfirmed
    case confirmed(blockHash: Data, height: Int32)
    case reorged(previousBlockHash: Data, previousHeight: Int32)
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
        var headerRequestTime: Date?
        var lastProgressTime: Date?
        var filteredBlockRequestTime: Date?
    }

    private struct PendingMerkleBlock: Sendable {
        var header: BlockHeader
        var remainingMatches: Set<Data>
        var height: Int32?
        var isOnBestChain: Bool
    }

    private struct VerifiedTransaction: Sendable {
        let transaction: TxMessage
        let blockHash: Data
        let height: Int32
    }

    private struct TransactionState: Sendable {
        var bloomFilter: BloomFilter?
        var pendingMerkleBlocks: [Data: PendingMerkleBlock] = [:]
        var matchedTxToBlock: [Data: Data] = [:]
        var pendingTransactions: [Data: TxMessage] = [:]
        var verifiedTransactions: [Data: VerifiedTransaction] = [:]
        var nextFilteredHeight: Int32?
        var filteredBlocksInFlight: Int = 0
    }

    private var syncState = SyncState()
    private var txState = TransactionState()

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
    private let txLock = NSLock()

    /// Logger
    private let logger = Logger(subsystem: "DogecoinKit", category: "SPVSyncManager")

    private let filteredBlockBatchSize = 32
    private let maxFilteredBlocksInFlight = 128

    /// Timeout for header requests (seconds)
    private let headerRequestTimeout: TimeInterval = 60

    /// Timeout for filtered block requests (seconds)
    private let filteredBlockTimeout: TimeInterval = 120

    /// Interval between timeout checks (seconds)
    private let timeoutCheckInterval: TimeInterval = 5

    /// Timer for periodic timeout checks
    private var timeoutTimer: DispatchSourceTimer?

    private func withLock<T>(_ body: (inout SyncState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&syncState)
    }

    private func withTxLock<T>(_ body: (inout TransactionState) -> T) -> T {
        txLock.lock()
        defer { txLock.unlock() }
        return body(&txState)
    }

    private func setState(_ newState: SPVSyncState) {
        withLock { $0.state = newState }
    }

    private func startTimeoutTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(
            deadline: .now() + timeoutCheckInterval,
            repeating: timeoutCheckInterval
        )
        timer.setEventHandler { [weak self] in
            self?.checkTimeouts()
        }
        timeoutTimer = timer
        timer.resume()
    }

    private func stopTimeoutTimer() {
        timeoutTimer?.cancel()
        timeoutTimer = nil
    }

    private func checkTimeouts() {
        let now = Date()

        // Check header request timeout
        let headerTimeout = withLock { state -> Bool in
            guard state.waitingForHeaders,
                  let requestTime = state.headerRequestTime,
                  now.timeIntervalSince(requestTime) > headerRequestTimeout else {
                return false
            }
            return true
        }

        if headerTimeout {
            logger.warning("Header request timed out")
            handleHeaderRequestTimeout()
        }

        // Check filtered block timeout
        let filteredTimeout = withTxLock { state -> Bool in
            guard state.filteredBlocksInFlight > 0,
                  let requestTime = withLock({ $0.filteredBlockRequestTime }),
                  now.timeIntervalSince(requestTime) > filteredBlockTimeout else {
                return false
            }
            return true
        }

        if filteredTimeout {
            logger.warning("Filtered block request timed out")
            handleFilteredBlockTimeout()
        }
    }

    private func handleHeaderRequestTimeout() {
        let currentPeer = withLock { state -> Peer? in
            state.waitingForHeaders = false
            state.headerRequestTime = nil
            let peer = state.syncPeer
            state.syncPeer = nil
            return peer
        }

        // Disconnect the unresponsive peer
        if let peer = currentPeer {
            logger.info("Disconnecting unresponsive peer: \(peer.host)")
            peerManager.removePeer(peer)
        }

        // Try to find another peer
        retryWithNextPeer()
    }

    private func handleFilteredBlockTimeout() {
        // Reset the counter to allow new requests
        withTxLock { state in
            state.filteredBlocksInFlight = 0
        }
        withLock { state in
            state.filteredBlockRequestTime = nil
        }

        logger.info("Resetting filtered blocks and retrying")
        requestFilteredBlocksIfNeeded()
    }

    private func retryWithNextPeer() {
        if let nextPeer = peerManager.connectedPeers.first {
            withLock { $0.syncPeer = nextPeer }
            logger.info("Switching to peer: \(nextPeer.host)")
            requestHeaders(from: nextPeer)
        } else {
            logger.info("No peers available, waiting for connection")
            scheduleRetryWhenPeersAvailable()
        }
    }

    private func scheduleRetryWhenPeersAvailable() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }

            let shouldRetry = withLock { state in
                state.syncPeer == nil && state.state == .syncing
            }

            guard shouldRetry else { return }

            if let peer = peerManager.connectedPeers.first {
                withLock { $0.syncPeer = peer }
                requestHeaders(from: peer)
            } else {
                scheduleRetryWhenPeersAvailable()
            }
        }
    }

    /// Create an SPV sync manager
    /// - Parameters:
    ///   - network: The Dogecoin network (mainnet or testnet)
    ///   - storageDirectory: Optional custom storage directory for header cache
    ///   - bundledCacheDirectory: Optional directory containing pre-bundled headers.bin.lzfse and metadata.json
    public init(network: DogecoinNetwork = .mainnet, storageDirectory: URL? = nil, bundledCacheDirectory: URL? = nil) {
        self.network = network
        self.peerManager = PeerManager(network: network)
        self.headerChain = HeaderChain(network: network, storageDirectory: storageDirectory, bundledCacheDirectory: bundledCacheDirectory)
    }

    /// Start synchronization
    public func start() {
        let canStart = withLock { state in
            guard state.state == .idle else { return false }
            state.state = .connecting
            state.lastProgressTime = Date()
            return true
        }

        guard canStart else {
            logger.warning("Cannot start: already running")
            return
        }

        logger.info("Starting SPV sync")

        startTimeoutTimer()
        peerManager.delegate = self
        peerManager.start()
    }

    /// Stop synchronization
    public func stop() {
        logger.info("Stopping SPV sync")

        stopTimeoutTimer()
        peerManager.stop()
        withLock { state in
            state.syncPeer = nil
            state.waitingForHeaders = false
            state.headerRequestTime = nil
            state.filteredBlockRequestTime = nil
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

    // MARK: - Bloom Filter Configuration

    /// Configure the bloom filter for SPV transaction matching
    public func configureBloomFilter(
        elements: [Data],
        falsePositiveRate: Double = 0.001,
        tweak: UInt32 = UInt32.random(in: 0...UInt32.max),
        flags: UInt8 = 0,
        startHeight: Int32 = 0
    ) {
        var filter = BloomFilter(
            elementCount: max(1, elements.count),
            falsePositiveRate: falsePositiveRate,
            tweak: tweak,
            flags: flags
        )

        for element in elements {
            filter.insert(element)
        }

        let clampedStart = max(Int32(0), startHeight)
        withTxLock { state in
            state.bloomFilter = filter
            state.nextFilteredHeight = clampedStart
            state.filteredBlocksInFlight = 0
        }
        sendFilterLoadToPeers()
        requestFilteredBlocksIfNeeded()
    }

    /// Add an element to the active bloom filter
    public func addBloomFilterElement(_ element: Data) {
        let shouldSend: Bool = withTxLock { state in
            guard var filter = state.bloomFilter else { return false }
            filter.insert(element)
            state.bloomFilter = filter
            return true
        }

        guard shouldSend else { return }
        for peer in peerManager.connectedPeers {
            peer.sendFilterAdd(element: element)
        }
    }

    /// Clear the bloom filter and disable transaction filtering
    public func clearBloomFilter() {
        let hadFilter = withTxLock { state -> Bool in
            let hasFilter = state.bloomFilter != nil
            state.bloomFilter = nil
            state.nextFilteredHeight = nil
            state.filteredBlocksInFlight = 0
            return hasFilter
        }

        guard hadFilter else { return }
        for peer in peerManager.connectedPeers {
            peer.sendFilterClear()
        }
    }

    private func sendFilterLoadToPeers() {
        guard let filter = withTxLock({ $0.bloomFilter }) else { return }
        for peer in peerManager.connectedPeers {
            peer.sendFilterLoad(filter)
        }
    }

    private func requestFilteredBlocksIfNeeded() {
        guard let nextHeight = withTxLock({ $0.nextFilteredHeight }),
              withTxLock({ $0.bloomFilter }) != nil else {
            return
        }

        let inFlight = withTxLock { $0.filteredBlocksInFlight }
        guard inFlight < maxFilteredBlocksInFlight else { return }

        let currentHeight = headerChain.height
        guard nextHeight <= currentHeight else { return }

        let peer = withLock { $0.syncPeer } ?? peerManager.connectedPeers.first
        guard let peer else { return }

        var inventory: [InventoryVector] = []
        var height = nextHeight

        while height <= currentHeight,
              inventory.count < filteredBlockBatchSize,
              inFlight + inventory.count < maxFilteredBlocksInFlight {
            if let stored = headerChain.getHeader(height: height) {
                inventory.append(InventoryVector(type: .filteredBlock, hash: stored.header.hash))
            }
            height += 1
        }

        guard !inventory.isEmpty else { return }

        withTxLock { state in
            state.nextFilteredHeight = height
            state.filteredBlocksInFlight += inventory.count
        }
        withLock { state in
            state.filteredBlockRequestTime = Date()
        }

        peer.sendGetData(inventory: inventory)
    }

    /// Request headers from a peer
    private func requestHeaders(from peer: Peer) {
        let canRequest = withLock { state in
            guard !state.waitingForHeaders else { return false }
            state.waitingForHeaders = true
            state.headerRequestTime = Date()
            return true
        }

        guard canRequest else { return }

        let locator = headerChain.getBlockLocator()
        logger.info("Requesting headers from \(peer.host), locator has \(locator.count) hashes")

        peer.sendGetHeaders(locatorHashes: locator)
    }

    /// Handle received headers
    private func handleHeaders(_ headers: [BlockHeader], from peer: Peer) {
        withLock { state in
            state.waitingForHeaders = false
            state.headerRequestTime = nil
            state.lastProgressTime = Date()
        }

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

        if added > 0 {
            refreshPendingMerkleBlocks()
            refreshVerifiedTransactionsForReorg()
            requestFilteredBlocksIfNeeded()
        }

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

        if let filter = withTxLock({ $0.bloomFilter }) {
            peer.sendFilterLoad(filter)
            requestFilteredBlocksIfNeeded()
        }
    }

    public func peerManager(_ manager: PeerManager, peerDidDisconnect peer: Peer) {
        logger.info("Peer disconnected: \(peer.host)")

        let shouldReconnect = withLock { state in
            guard peer == state.syncPeer else { return false }
            state.syncPeer = nil
            state.waitingForHeaders = false
            state.headerRequestTime = nil
            return true
        }

        guard shouldReconnect else { return }

        // Try another peer with retry logic if none available
        retryWithNextPeer()
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

        case ProtocolMessage.Command.merkleblock:
            if let merkleBlock = MerkleBlockMessage.parse(from: message.payload) {
                handleMerkleBlock(merkleBlock, from: peer)
            } else {
                peerManager.banPeer(peer, reason: .invalidMessage)
            }

        case ProtocolMessage.Command.tx:
            if let txMessage = TxMessage.parse(from: message.payload) {
                handleTransaction(txMessage, from: peer)
            } else {
                peerManager.banPeer(peer, reason: .invalidTransaction)
            }

        case ProtocolMessage.Command.block:
            if let block = BlockMessage.parse(from: message.payload) {
                handleBlock(block, from: peer)
            } else {
                peerManager.banPeer(peer, reason: .invalidMessage)
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
        let txInv = inventory.filter { $0.type == .transaction }
        if !txInv.isEmpty {
            peer.sendGetData(inventory: txInv)
        }

        let hasFilter = withTxLock { $0.bloomFilter != nil }
        if hasFilter {
            var requested = Set<Data>()
            var filteredRequests: [InventoryVector] = []

            let filteredInv = inventory.filter { $0.type == .filteredBlock }
            for item in filteredInv where requested.insert(item.hash).inserted {
                filteredRequests.append(item)
            }

            let blockInv = inventory.filter { $0.type == .block }
            for item in blockInv where requested.insert(item.hash).inserted {
                filteredRequests.append(InventoryVector(type: .filteredBlock, hash: item.hash))
            }

            if !filteredRequests.isEmpty {
                peer.sendGetData(inventory: filteredRequests)
            }
        }

        let blockInv = inventory.filter { $0.type == .block }
        if !blockInv.isEmpty {
            logger.debug("Received inventory with \(blockInv.count) blocks")

            let isSyncPeer = withLock { $0.syncPeer == peer }
            if isSyncPeer {
                requestHeaders(from: peer)
            }
        }
    }

    private func handleMerkleBlock(_ merkleBlock: MerkleBlockMessage, from peer: Peer) {
        let matches: MerkleBlockMatches
        do {
            matches = try merkleBlock.extractMatches()
        } catch {
            peerManager.banPeer(peer, reason: .invalidTransaction)
            delegate?.spvSync(self, didEncounterError: error)
            return
        }

        guard matches.merkleRoot == merkleBlock.header.merkleRoot else {
            peerManager.banPeer(peer, reason: .invalidTransaction)
            delegate?.spvSync(self, didEncounterError: DogecoinError.syncFailed("Invalid merkle proof"))
            return
        }

        let blockHash = merkleBlock.header.hash
        let isOnBestChain = headerChain.isHeaderInBestChain(blockHash)
        let height = headerChain.getHeader(hash: blockHash)?.height
        let matchedSet = Set(matches.matchedHashes)

        let events: [(TxMessage, SPVTransactionState)] = withTxLock { state in
            var pending = state.pendingMerkleBlocks[blockHash] ?? PendingMerkleBlock(
                header: merkleBlock.header,
                remainingMatches: matchedSet,
                height: height,
                isOnBestChain: isOnBestChain
            )

            pending.header = merkleBlock.header
            pending.remainingMatches.formUnion(matchedSet)
            pending.isOnBestChain = isOnBestChain
            if pending.height == nil {
                pending.height = height
            }

            state.pendingMerkleBlocks[blockHash] = pending

            for txid in matchedSet where state.matchedTxToBlock[txid] == nil {
                state.matchedTxToBlock[txid] = blockHash
            }

            var events: [(TxMessage, SPVTransactionState)] = []
            if pending.isOnBestChain, let blockHeight = pending.height {
                for txid in matchedSet {
                    guard state.verifiedTransactions[txid] == nil,
                          let tx = state.pendingTransactions[txid] else {
                        continue
                    }

                    state.verifiedTransactions[txid] = VerifiedTransaction(
                        transaction: tx,
                        blockHash: blockHash,
                        height: blockHeight
                    )
                    state.pendingTransactions.removeValue(forKey: txid)
                    state.matchedTxToBlock.removeValue(forKey: txid)
                    pending.remainingMatches.remove(txid)
                    events.append((tx, .confirmed(blockHash: blockHash, height: blockHeight)))
                }
            }

            if pending.remainingMatches.isEmpty {
                state.pendingMerkleBlocks.removeValue(forKey: blockHash)
            } else {
                state.pendingMerkleBlocks[blockHash] = pending
            }

            return events
        }

        for event in events {
            delegate?.spvSync(self, didUpdateTransaction: event.0, state: event.1)
        }

        withTxLock { state in
            state.filteredBlocksInFlight = max(0, state.filteredBlocksInFlight - 1)
        }
        requestFilteredBlocksIfNeeded()
    }

    private func handleTransaction(_ txMessage: TxMessage, from peer: Peer) {
        let txid = txMessage.txidInternal
        let events: [(TxMessage, SPVTransactionState)] = withTxLock { state in
            guard state.verifiedTransactions[txid] == nil else { return [] }

            if let blockHash = state.matchedTxToBlock[txid],
               var pendingBlock = state.pendingMerkleBlocks[blockHash],
               pendingBlock.isOnBestChain,
               let height = pendingBlock.height {
                state.verifiedTransactions[txid] = VerifiedTransaction(
                    transaction: txMessage,
                    blockHash: blockHash,
                    height: height
                )
                state.pendingTransactions.removeValue(forKey: txid)
                state.matchedTxToBlock.removeValue(forKey: txid)
                pendingBlock.remainingMatches.remove(txid)

                if pendingBlock.remainingMatches.isEmpty {
                    state.pendingMerkleBlocks.removeValue(forKey: blockHash)
                } else {
                    state.pendingMerkleBlocks[blockHash] = pendingBlock
                }

                return [(txMessage, .confirmed(blockHash: blockHash, height: height))]
            }

            if state.pendingTransactions[txid] == nil {
                state.pendingTransactions[txid] = txMessage
            }

            if state.bloomFilter != nil {
                return [(txMessage, .unconfirmed)]
            }

            return []
        }

        for event in events {
            delegate?.spvSync(self, didUpdateTransaction: event.0, state: event.1)
        }
    }

    private func handleBlock(_ block: BlockMessage, from peer: Peer) {
        guard let merkleRoot = block.merkleRoot,
              merkleRoot == block.header.merkleRoot else {
            peerManager.banPeer(peer, reason: .invalidTransaction)
            delegate?.spvSync(self, didEncounterError: DogecoinError.syncFailed("Invalid block merkle root"))
            return
        }

        let blockHash = block.header.hash
        guard headerChain.isHeaderInBestChain(blockHash),
              let height = headerChain.getHeader(hash: blockHash)?.height else {
            return
        }

        let txMessages = block.transactions.map { TxMessage(rawData: $0) }
        let events: [(TxMessage, SPVTransactionState)] = withTxLock { state in
            var events: [(TxMessage, SPVTransactionState)] = []

            for txMessage in txMessages {
                let txid = txMessage.txidInternal
                guard state.verifiedTransactions[txid] == nil else { continue }

                let shouldConfirm = state.pendingTransactions[txid] != nil || state.matchedTxToBlock[txid] != nil
                guard shouldConfirm else { continue }

                state.verifiedTransactions[txid] = VerifiedTransaction(
                    transaction: txMessage,
                    blockHash: blockHash,
                    height: height
                )
                state.pendingTransactions.removeValue(forKey: txid)
                state.matchedTxToBlock.removeValue(forKey: txid)

                if var pendingBlock = state.pendingMerkleBlocks[blockHash] {
                    pendingBlock.remainingMatches.remove(txid)
                    if pendingBlock.remainingMatches.isEmpty {
                        state.pendingMerkleBlocks.removeValue(forKey: blockHash)
                    } else {
                        state.pendingMerkleBlocks[blockHash] = pendingBlock
                    }
                }

                events.append((txMessage, .confirmed(blockHash: blockHash, height: height)))
            }

            return events
        }

        for event in events {
            delegate?.spvSync(self, didUpdateTransaction: event.0, state: event.1)
        }
    }

    private func refreshPendingMerkleBlocks() {
        let events: [(TxMessage, SPVTransactionState)] = withTxLock { state in
            var events: [(TxMessage, SPVTransactionState)] = []
            let blockHashes = Array(state.pendingMerkleBlocks.keys)

            for blockHash in blockHashes {
                guard var pending = state.pendingMerkleBlocks[blockHash] else { continue }

                pending.isOnBestChain = headerChain.isHeaderInBestChain(blockHash)
                if pending.height == nil {
                    pending.height = headerChain.getHeader(hash: blockHash)?.height
                }

                if pending.isOnBestChain, let height = pending.height {
                    let matches = pending.remainingMatches
                    for txid in matches {
                        guard state.verifiedTransactions[txid] == nil,
                              let tx = state.pendingTransactions[txid] else {
                            continue
                        }

                        state.verifiedTransactions[txid] = VerifiedTransaction(
                            transaction: tx,
                            blockHash: blockHash,
                            height: height
                        )
                        state.pendingTransactions.removeValue(forKey: txid)
                        state.matchedTxToBlock.removeValue(forKey: txid)
                        pending.remainingMatches.remove(txid)
                        events.append((tx, .confirmed(blockHash: blockHash, height: height)))
                    }
                }

                if pending.remainingMatches.isEmpty {
                    state.pendingMerkleBlocks.removeValue(forKey: blockHash)
                } else {
                    state.pendingMerkleBlocks[blockHash] = pending
                }
            }

            return events
        }

        for event in events {
            delegate?.spvSync(self, didUpdateTransaction: event.0, state: event.1)
        }
    }

    private func refreshVerifiedTransactionsForReorg() {
        let events: [(TxMessage, SPVTransactionState)] = withTxLock { state in
            var events: [(TxMessage, SPVTransactionState)] = []
            let txids = Array(state.verifiedTransactions.keys)

            for txid in txids {
                guard let verified = state.verifiedTransactions[txid] else { continue }
                guard !headerChain.isHeaderInBestChain(verified.blockHash) else { continue }

                state.verifiedTransactions.removeValue(forKey: txid)
                events.append((
                    verified.transaction,
                    .reorged(previousBlockHash: verified.blockHash, previousHeight: verified.height)
                ))
            }

            return events
        }

        for event in events {
            delegate?.spvSync(self, didUpdateTransaction: event.0, state: event.1)
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

public extension SPVSyncDelegate {
    func spvSync(_ manager: SPVSyncManager, didUpdateTransaction transaction: TxMessage, state: SPVTransactionState) {}
}
