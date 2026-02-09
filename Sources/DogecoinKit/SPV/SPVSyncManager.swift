import Foundation
import os.log

/// Delegate for SPV sync events
public protocol SPVSyncDelegate: AnyObject, Sendable {
    /// Called when sync progress updates
    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) async

    /// Called when sync completes
    func spvSyncDidComplete(_ manager: SPVSyncManager) async

    /// Called when a new block header is received
    func spvSync(_ manager: SPVSyncManager, didReceiveHeader header: BlockHeader, height: Int32) async

    /// Called when an error occurs
    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) async

    /// Called when a transaction changes state (unconfirmed, confirmed, or reorged)
    func spvSync(_ manager: SPVSyncManager, didUpdateTransaction transaction: TxMessage, state: SPVTransactionState) async

    /// Called when a filtered block is processed (for tracking bloom filter scan progress)
    func spvSync(_ manager: SPVSyncManager, didProcessFilteredBlock height: Int32, targetHeight: Int32) async
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
public actor SPVSyncManager {
    /// The network
    public nonisolated let network: DogecoinNetwork

    /// The peer manager
    public let peerManager: PeerManager

    /// The header chain
    public let headerChain: HeaderChain

    /// Delegate for events
    public weak var delegate: (any SPVSyncDelegate)?

    /// Set the delegate
    public func setDelegate(_ delegate: (any SPVSyncDelegate)?) {
        self.delegate = delegate
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

    // MARK: - Sync State

    private var syncState: SPVSyncState = .idle
    private var _targetHeight: Int32 = 0
    private var syncPeer: Peer?
    private var waitingForHeaders = false
    private var headerRequestTime: Date?
    private var lastProgressTime: Date?
    private var filteredBlockRequestTime: Date?

    // MARK: - Transaction State

    private var bloomFilter: BloomFilter?
    private var pendingMerkleBlocks: [Data: PendingMerkleBlock] = [:]
    private var matchedTxToBlock: [Data: Data] = [:]
    private var pendingTransactions: [Data: TxMessage] = [:]
    private var verifiedTransactions: [Data: VerifiedTransaction] = [:]
    private var nextFilteredHeight: Int32?
    private var filteredBlocksInFlight: Int = 0

    /// Current sync state
    public var state: SPVSyncState { syncState }

    /// Target height (best height from peers)
    public var targetHeight: Int32 { _targetHeight }

    /// Current synced height
    public var currentHeight: Int32 {
        get async { await headerChain.height }
    }

    /// Sync progress (0.0 to 1.0)
    public var progress: Double {
        get async {
            guard _targetHeight > 0 else { return 0 }
            let height = await headerChain.height
            return Double(height) / Double(_targetHeight)
        }
    }

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

    /// Task for periodic timeout checks
    private var timeoutTask: Task<Void, Never>?

    private func startTimeoutTask() {
        timeoutTask?.cancel()
        let interval = timeoutCheckInterval
        timeoutTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.checkTimeouts()
            }
        }
    }

    private func stopTimeoutTask() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func checkTimeouts() async {
        let now = Date()

        // Check header request timeout
        if waitingForHeaders,
           let requestTime = headerRequestTime,
           now.timeIntervalSince(requestTime) > headerRequestTimeout {
            logger.warning("Header request timed out")
            await handleHeaderRequestTimeout()
        }

        // Check filtered block timeout
        if filteredBlocksInFlight > 0,
           let requestTime = filteredBlockRequestTime,
           now.timeIntervalSince(requestTime) > filteredBlockTimeout {
            logger.warning("Filtered block request timed out")
            await handleFilteredBlockTimeout()
        }
    }

    private func handleHeaderRequestTimeout() async {
        waitingForHeaders = false
        headerRequestTime = nil
        let currentPeer = syncPeer
        syncPeer = nil

        if let peer = currentPeer {
            logger.info("Disconnecting unresponsive peer: \(peer.host)")
            await peerManager.removePeer(peer)
        }

        await retryWithNextPeer()
    }

    private func handleFilteredBlockTimeout() async {
        filteredBlocksInFlight = 0
        filteredBlockRequestTime = nil

        logger.info("Resetting filtered blocks and retrying")
        await requestFilteredBlocksIfNeeded()
    }

    private func retryWithNextPeer() async {
        let peers = await peerManager.connectedPeers
        if let nextPeer = peers.first {
            syncPeer = nextPeer
            logger.info("Switching to peer: \(nextPeer.host)")
            await requestHeaders(from: nextPeer)
        } else {
            logger.info("No peers available, waiting for connection")
            scheduleRetryWhenPeersAvailable()
        }
    }

    private func scheduleRetryWhenPeersAvailable() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard let self else { return }

            guard await self.syncPeer == nil,
                  case .syncing = await self.syncState else { return }

            let peers = await self.peerManager.connectedPeers
            if let peer = peers.first {
                await self.setSyncPeer(peer)
                await self.requestHeaders(from: peer)
            } else {
                await self.scheduleRetryWhenPeersAvailable()
            }
        }
    }

    private func setSyncPeer(_ peer: Peer) {
        syncPeer = peer
    }

    /// Create an SPV sync manager
    public init(network: DogecoinNetwork = .mainnet, storageDirectory: URL? = nil, bundledCacheDirectory: URL? = nil) {
        self.network = network
        self.peerManager = PeerManager(network: network)
        self.headerChain = HeaderChain(network: network, storageDirectory: storageDirectory, bundledCacheDirectory: bundledCacheDirectory)
    }

    /// Create an SPV sync manager asynchronously, offloading the heavy
    /// `HeaderChain` initialization to a background thread.
    public static func create(
        network: DogecoinNetwork = .mainnet,
        storageDirectory: URL? = nil,
        bundledCacheDirectory: URL? = nil
    ) async -> SPVSyncManager {
        let manager = SPVSyncManager(
            network: network,
            storageDirectory: storageDirectory,
            bundledCacheDirectory: bundledCacheDirectory
        )
        await manager.headerChain.setup()
        return manager
    }

    /// Start synchronization
    public func start() async {
        guard syncState == .idle else {
            logger.warning("Cannot start: already running")
            return
        }

        // Ensure header chain is set up (idempotent)
        await headerChain.setup()

        syncState = .connecting
        lastProgressTime = Date()

        logger.info("Starting SPV sync")

        startTimeoutTask()
        await peerManager.setDelegate(self)
        await peerManager.start()
    }

    /// Stop synchronization
    public func stop() async {
        logger.info("Stopping SPV sync")

        stopTimeoutTask()
        await peerManager.stop()

        await headerChain.flush()

        syncPeer = nil
        waitingForHeaders = false
        headerRequestTime = nil
        filteredBlockRequestTime = nil
        syncState = .idle
    }

    // MARK: - Transaction Broadcasting

    /// Broadcast a signed transaction to the network
    public func broadcastTransaction(_ rawHex: String) async throws -> String {
        try await peerManager.broadcastTransaction(rawHex)
    }

    /// Broadcast a signed transaction to the network
    public func broadcastTransaction(_ signedTransaction: SignedTransaction) async throws -> String {
        try await peerManager.broadcastTransaction(signedTransaction.rawHex)
    }

    // MARK: - Bloom Filter Configuration

    /// Configure the bloom filter for SPV transaction matching
    public func configureBloomFilter(
        elements: [Data],
        falsePositiveRate: Double = 0.001,
        tweak: UInt32 = UInt32.random(in: 0...UInt32.max),
        flags: UInt8 = 0,
        startHeight: Int32 = 0
    ) async {
        var filter = BloomFilter(
            elementCount: max(1, elements.count),
            falsePositiveRate: falsePositiveRate,
            tweak: tweak,
            flags: flags
        )

        for element in elements {
            filter.insert(element)
        }

        bloomFilter = filter
        nextFilteredHeight = max(Int32(0), startHeight)
        filteredBlocksInFlight = 0

        await sendFilterLoadToPeers()
        await requestFilteredBlocksIfNeeded()
    }

    /// Add an element to the active bloom filter
    public func addBloomFilterElement(_ element: Data) async {
        guard bloomFilter != nil else { return }
        bloomFilter?.insert(element)

        let peers = await peerManager.connectedPeers
        for peer in peers {
            await peer.sendFilterAdd(element: element)
        }
    }

    /// Clear the bloom filter and disable transaction filtering
    public func clearBloomFilter() async {
        guard bloomFilter != nil else { return }
        bloomFilter = nil
        nextFilteredHeight = nil
        filteredBlocksInFlight = 0

        let peers = await peerManager.connectedPeers
        for peer in peers {
            await peer.sendFilterClear()
        }
    }

    private func sendFilterLoadToPeers() async {
        guard let filter = bloomFilter else { return }
        let peers = await peerManager.connectedPeers
        for peer in peers {
            await peer.sendFilterLoad(filter)
        }
    }

    private func requestFilteredBlocksIfNeeded() async {
        guard let nextHeight = nextFilteredHeight,
              bloomFilter != nil else {
            return
        }

        guard filteredBlocksInFlight < maxFilteredBlocksInFlight else { return }

        let chainHeight = await headerChain.height
        guard nextHeight <= chainHeight else { return }

        let peer: Peer
        if let sp = syncPeer {
            peer = sp
        } else if let first = await peerManager.connectedPeers.first {
            peer = first
        } else {
            return
        }

        var inventory: [InventoryVector] = []
        var height = nextHeight

        while height <= chainHeight,
              inventory.count < filteredBlockBatchSize,
              filteredBlocksInFlight + inventory.count < maxFilteredBlocksInFlight {
            if let stored = await headerChain.getHeader(height: height) {
                inventory.append(InventoryVector(type: .filteredBlock, hash: stored.header.hash))
            }
            height += 1
        }

        guard !inventory.isEmpty else { return }

        nextFilteredHeight = height
        filteredBlocksInFlight += inventory.count
        filteredBlockRequestTime = Date()

        await peer.sendGetData(inventory: inventory)
    }

    /// Request headers from a peer
    private func requestHeaders(from peer: Peer) async {
        guard !waitingForHeaders else { return }
        waitingForHeaders = true
        headerRequestTime = Date()

        let locator = await headerChain.getBlockLocator()
        logger.info("Requesting headers from \(peer.host), locator has \(locator.count) hashes")

        await peer.sendGetHeaders(locatorHashes: locator)
    }

    /// Handle received headers
    private func handleHeaders(_ headers: [BlockHeader], from peer: Peer) async {
        waitingForHeaders = false
        headerRequestTime = nil
        lastProgressTime = Date()

        guard !headers.isEmpty else {
            logger.info("No more headers from \(peer.host)")

            let chainHeight = await headerChain.height
            if chainHeight >= _targetHeight {
                syncState = .synchronized
                let delegate = self.delegate
                Task { [weak self] in
                    guard let self else { return }
                    await delegate?.spvSyncDidComplete(self)
                }
            } else {
                logger.info("Still below target height (\(chainHeight) < \(self._targetHeight)), trying next peer")
                await retryWithNextPeer()
            }
            return
        }

        logger.info("Received \(headers.count) headers from \(peer.host)")

        let added = await headerChain.addHeaders(headers)
        let chainHeight = await headerChain.height
        logger.info("Added \(added) headers, height now \(chainHeight)")

        if added > 0 {
            await refreshPendingMerkleBlocks()
            await refreshVerifiedTransactionsForReorg()
            await requestFilteredBlocksIfNeeded()
        }

        // Notify delegate
        for header in headers.prefix(added) {
            if let stored = await headerChain.getHeader(hash: header.hash) {
                let delegate = self.delegate
                let h = stored.height
                Task { [weak self] in
                    guard let self else { return }
                    await delegate?.spvSync(self, didReceiveHeader: header, height: h)
                }
            }
        }

        // Update progress
        let prog = _targetHeight > 0 ? Double(chainHeight) / Double(_targetHeight) : 0
        let delegate = self.delegate
        Task { [weak self] in
            guard let self else { return }
            await delegate?.spvSync(self, progressUpdated: prog, height: chainHeight)
        }

        // Request more headers or mark as synchronized
        if chainHeight >= _targetHeight {
            syncState = .synchronized
            Task { [weak self] in
                guard let self else { return }
                await delegate?.spvSyncDidComplete(self)
            }
        } else {
            await requestHeaders(from: peer)
        }
    }
}

// MARK: - PeerManagerDelegate

extension SPVSyncManager: PeerManagerDelegate {
    public func peerManager(_ manager: PeerManager, peerDidBecomeReady peer: Peer) async {
        logger.info("Peer ready: \(peer.host)")

        // Update target height from peer version
        if let version = await peer.peerVersion {
            if version.startHeight > _targetHeight {
                _targetHeight = version.startHeight
            }
        }

        // Start syncing if we don't have a sync peer
        if syncPeer == nil, syncState == .connecting {
            syncPeer = peer
            syncState = .syncing
            await requestHeaders(from: peer)
        }

        if let filter = bloomFilter {
            await peer.sendFilterLoad(filter)
            await requestFilteredBlocksIfNeeded()
        }
    }

    public func peerManager(_ manager: PeerManager, peerDidDisconnect peer: Peer) async {
        logger.info("Peer disconnected: \(peer.host)")

        guard peer == syncPeer else { return }
        syncPeer = nil
        waitingForHeaders = false
        headerRequestTime = nil

        await retryWithNextPeer()
    }

    public func peerManager(_ manager: PeerManager, peer: Peer, didReceiveMessage message: ProtocolMessage) async {
        switch message.command {
        case ProtocolMessage.Command.headers:
            if let headersMsg = HeadersMessage.parse(from: message.payload) {
                await handleHeaders(headersMsg.headers, from: peer)
            }

        case ProtocolMessage.Command.inv:
            if let invMsg = InvMessage.parse(from: message.payload) {
                await handleInventory(invMsg.inventory, from: peer)
            }

        case ProtocolMessage.Command.merkleblock:
            if let merkleBlock = MerkleBlockMessage.parse(from: message.payload) {
                await handleMerkleBlock(merkleBlock, from: peer)
            } else {
                await peerManager.banPeer(peer, reason: .invalidMessage)
            }

        case ProtocolMessage.Command.tx:
            if let txMessage = TxMessage.parse(from: message.payload) {
                await handleTransaction(txMessage, from: peer)
            } else {
                await peerManager.banPeer(peer, reason: .invalidTransaction)
            }

        case ProtocolMessage.Command.block:
            if let block = BlockMessage.parse(from: message.payload) {
                await handleBlock(block, from: peer)
            } else {
                await peerManager.banPeer(peer, reason: .invalidMessage)
            }

        case ProtocolMessage.Command.reject:
            logger.warning("Received reject from \(peer.host)")

        default:
            break
        }
    }

    public func peerManager(_ manager: PeerManager, connectedPeerCountChanged count: Int) async {
        logger.info("Connected peers: \(count)")
    }

    private func handleInventory(_ inventory: [InventoryVector], from peer: Peer) async {
        let txInv = inventory.filter { $0.type == .transaction }
        if !txInv.isEmpty {
            await peer.sendGetData(inventory: txInv)
        }

        if bloomFilter != nil {
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
                await peer.sendGetData(inventory: filteredRequests)
            }
        }

        let blockInv = inventory.filter { $0.type == .block }
        if !blockInv.isEmpty {
            logger.debug("Received inventory with \(blockInv.count) blocks")

            if syncPeer == peer {
                await requestHeaders(from: peer)
            }
        }
    }

    private func handleMerkleBlock(_ merkleBlock: MerkleBlockMessage, from peer: Peer) async {
        let matches: MerkleBlockMatches
        do {
            matches = try merkleBlock.extractMatches()
        } catch {
            await peerManager.banPeer(peer, reason: .invalidTransaction)
            let delegate = self.delegate
            Task { [weak self] in
                guard let self else { return }
                await delegate?.spvSync(self, didEncounterError: error)
            }
            return
        }

        guard matches.merkleRoot == merkleBlock.header.merkleRoot else {
            await peerManager.banPeer(peer, reason: .invalidTransaction)
            let delegate = self.delegate
            Task { [weak self] in
                guard let self else { return }
                await delegate?.spvSync(self, didEncounterError: DogecoinError.syncFailed("Invalid merkle proof"))
            }
            return
        }

        let blockHash = merkleBlock.header.hash
        let isOnBestChain = await headerChain.isHeaderInBestChain(blockHash)
        let height = await headerChain.getHeader(hash: blockHash)?.height
        let matchedSet = Set(matches.matchedHashes)

        var pending = pendingMerkleBlocks[blockHash] ?? PendingMerkleBlock(
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

        pendingMerkleBlocks[blockHash] = pending

        for txid in matchedSet where matchedTxToBlock[txid] == nil {
            matchedTxToBlock[txid] = blockHash
        }

        var events: [(TxMessage, SPVTransactionState)] = []
        if pending.isOnBestChain, let blockHeight = pending.height {
            for txid in matchedSet {
                guard verifiedTransactions[txid] == nil,
                      let tx = pendingTransactions[txid] else {
                    continue
                }

                verifiedTransactions[txid] = VerifiedTransaction(
                    transaction: tx,
                    blockHash: blockHash,
                    height: blockHeight
                )
                pendingTransactions.removeValue(forKey: txid)
                matchedTxToBlock.removeValue(forKey: txid)
                pending.remainingMatches.remove(txid)
                events.append((tx, .confirmed(blockHash: blockHash, height: blockHeight)))
            }
        }

        if pending.remainingMatches.isEmpty {
            pendingMerkleBlocks.removeValue(forKey: blockHash)
        } else {
            pendingMerkleBlocks[blockHash] = pending
        }

        let delegate = self.delegate
        for event in events {
            Task { [weak self] in
                guard let self else { return }
                await delegate?.spvSync(self, didUpdateTransaction: event.0, state: event.1)
            }
        }

        // Report filtered block scan progress
        if let height {
            let target = _targetHeight
            Task { [weak self] in
                guard let self else { return }
                await delegate?.spvSync(self, didProcessFilteredBlock: height, targetHeight: target)
            }
        }

        filteredBlocksInFlight = max(0, filteredBlocksInFlight - 1)
        await requestFilteredBlocksIfNeeded()
    }

    private func handleTransaction(_ txMessage: TxMessage, from peer: Peer) async {
        let txid = txMessage.txidInternal
        guard verifiedTransactions[txid] == nil else { return }

        var events: [(TxMessage, SPVTransactionState)] = []

        if let blockHash = matchedTxToBlock[txid],
           var pendingBlock = pendingMerkleBlocks[blockHash],
           pendingBlock.isOnBestChain,
           let height = pendingBlock.height {
            verifiedTransactions[txid] = VerifiedTransaction(
                transaction: txMessage,
                blockHash: blockHash,
                height: height
            )
            pendingTransactions.removeValue(forKey: txid)
            matchedTxToBlock.removeValue(forKey: txid)
            pendingBlock.remainingMatches.remove(txid)

            if pendingBlock.remainingMatches.isEmpty {
                pendingMerkleBlocks.removeValue(forKey: blockHash)
            } else {
                pendingMerkleBlocks[blockHash] = pendingBlock
            }

            events.append((txMessage, .confirmed(blockHash: blockHash, height: height)))
        } else {
            if pendingTransactions[txid] == nil {
                pendingTransactions[txid] = txMessage
            }

            if bloomFilter != nil {
                events.append((txMessage, .unconfirmed))
            }
        }

        let delegate = self.delegate
        for event in events {
            Task { [weak self] in
                guard let self else { return }
                await delegate?.spvSync(self, didUpdateTransaction: event.0, state: event.1)
            }
        }
    }

    private func handleBlock(_ block: BlockMessage, from peer: Peer) async {
        guard let merkleRoot = block.merkleRoot,
              merkleRoot == block.header.merkleRoot else {
            await peerManager.banPeer(peer, reason: .invalidTransaction)
            let delegate = self.delegate
            Task { [weak self] in
                guard let self else { return }
                await delegate?.spvSync(self, didEncounterError: DogecoinError.syncFailed("Invalid block merkle root"))
            }
            return
        }

        let blockHash = block.header.hash
        guard await headerChain.isHeaderInBestChain(blockHash),
              let height = await headerChain.getHeader(hash: blockHash)?.height else {
            return
        }

        let txMessages = block.transactions.map { TxMessage(rawData: $0) }
        var events: [(TxMessage, SPVTransactionState)] = []

        for txMessage in txMessages {
            let txid = txMessage.txidInternal
            guard verifiedTransactions[txid] == nil else { continue }

            let shouldConfirm = pendingTransactions[txid] != nil || matchedTxToBlock[txid] != nil
            guard shouldConfirm else { continue }

            verifiedTransactions[txid] = VerifiedTransaction(
                transaction: txMessage,
                blockHash: blockHash,
                height: height
            )
            pendingTransactions.removeValue(forKey: txid)
            matchedTxToBlock.removeValue(forKey: txid)

            if var pendingBlock = pendingMerkleBlocks[blockHash] {
                pendingBlock.remainingMatches.remove(txid)
                if pendingBlock.remainingMatches.isEmpty {
                    pendingMerkleBlocks.removeValue(forKey: blockHash)
                } else {
                    pendingMerkleBlocks[blockHash] = pendingBlock
                }
            }

            events.append((txMessage, .confirmed(blockHash: blockHash, height: height)))
        }

        let delegate = self.delegate
        for event in events {
            Task { [weak self] in
                guard let self else { return }
                await delegate?.spvSync(self, didUpdateTransaction: event.0, state: event.1)
            }
        }
    }

    private func refreshPendingMerkleBlocks() async {
        var events: [(TxMessage, SPVTransactionState)] = []
        let blockHashes = Array(pendingMerkleBlocks.keys)

        for blockHash in blockHashes {
            guard var pending = pendingMerkleBlocks[blockHash] else { continue }

            pending.isOnBestChain = await headerChain.isHeaderInBestChain(blockHash)
            if pending.height == nil {
                pending.height = await headerChain.getHeader(hash: blockHash)?.height
            }

            if pending.isOnBestChain, let height = pending.height {
                let matches = pending.remainingMatches
                for txid in matches {
                    guard verifiedTransactions[txid] == nil,
                          let tx = pendingTransactions[txid] else {
                        continue
                    }

                    verifiedTransactions[txid] = VerifiedTransaction(
                        transaction: tx,
                        blockHash: blockHash,
                        height: height
                    )
                    pendingTransactions.removeValue(forKey: txid)
                    matchedTxToBlock.removeValue(forKey: txid)
                    pending.remainingMatches.remove(txid)
                    events.append((tx, .confirmed(blockHash: blockHash, height: height)))
                }
            }

            if pending.remainingMatches.isEmpty {
                pendingMerkleBlocks.removeValue(forKey: blockHash)
            } else {
                pendingMerkleBlocks[blockHash] = pending
            }
        }

        let delegate = self.delegate
        for event in events {
            Task { [weak self] in
                guard let self else { return }
                await delegate?.spvSync(self, didUpdateTransaction: event.0, state: event.1)
            }
        }
    }

    private func refreshVerifiedTransactionsForReorg() async {
        var events: [(TxMessage, SPVTransactionState)] = []
        let txids = Array(verifiedTransactions.keys)

        for txid in txids {
            guard let verified = verifiedTransactions[txid] else { continue }
            guard await !headerChain.isHeaderInBestChain(verified.blockHash) else { continue }

            verifiedTransactions.removeValue(forKey: txid)
            events.append((
                verified.transaction,
                .reorged(previousBlockHash: verified.blockHash, previousHeight: verified.height)
            ))
        }

        let delegate = self.delegate
        for event in events {
            Task { [weak self] in
                guard let self else { return }
                await delegate?.spvSync(self, didUpdateTransaction: event.0, state: event.1)
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

public extension SPVSyncDelegate {
    func spvSync(_ manager: SPVSyncManager, didUpdateTransaction transaction: TxMessage, state: SPVTransactionState) async {}
    func spvSync(_ manager: SPVSyncManager, didProcessFilteredBlock height: Int32, targetHeight: Int32) async {}
}
