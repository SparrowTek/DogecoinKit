import Foundation
#if canImport(os)
import os.log
#endif

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

    // MARK: - Delegate Events

    private enum DelegateEvent: Sendable {
        case progress(Double, height: Int32)
        case completed
        case header(BlockHeader, height: Int32)
        case failure(any Error)
        case transaction(TxMessage, SPVTransactionState)
        case filteredBlock(height: Int32, targetHeight: Int32)
    }

    /// Delivers delegate callbacks strictly in order — a transaction's
    /// `.confirmed` must never overtake its `.unconfirmed`.
    private lazy var delegateEvents = SerialEventQueue<DelegateEvent> { [weak self] event in
        guard let self, let delegate = await self.delegate else { return }
        switch event {
        case .progress(let progress, let height):
            await delegate.spvSync(self, progressUpdated: progress, height: height)
        case .completed:
            await delegate.spvSyncDidComplete(self)
        case .header(let header, let height):
            await delegate.spvSync(self, didReceiveHeader: header, height: height)
        case .failure(let error):
            await delegate.spvSync(self, didEncounterError: error)
        case .transaction(let transaction, let state):
            await delegate.spvSync(self, didUpdateTransaction: transaction, state: state)
        case .filteredBlock(let height, let targetHeight):
            await delegate.spvSync(self, didProcessFilteredBlock: height, targetHeight: targetHeight)
        }
    }

    // MARK: - Sync State

    /// A `getheaders` awaiting its answer. At most one is outstanding, and
    /// only the answer from the peer it went to steers the sync.
    private struct HeaderRequest: Equatable {
        let peer: Peer
        let sentAt: Date
    }

    private var syncState: SPVSyncState = .idle
    /// Between `start()` and `stop()`; peer events outside it are ignored
    private var isActive = false
    /// Bumped by `start()` and `stop()`, so a start interrupted by a stop gives up
    private var session = 0
    private var _targetHeight: Int32 = 0
    /// Best height each connected peer announced in its `version` message
    private var peerStartHeights: [UUID: Int32] = [:]
    /// The peer whose chain is being followed
    private var syncPeer: Peer?
    private var headerRequest: HeaderRequest?
    /// The peer most recently given up on; the next pick prefers anyone else
    private var lastAbandonedPeer: Peer?
    private var lastProgressTime: Date?
    private var filteredBlockRequestTime: Date?

    // MARK: - Transaction State

    private var bloomFilter: BloomFilter?
    private var pendingMerkleBlocks: [Data: PendingMerkleBlock] = [:]
    private var matchedTxToBlock: [Data: Data] = [:]
    private var pendingTransactions: [Data: TxMessage] = [:]
    private var verifiedTransactions: [Data: VerifiedTransaction] = [:]
    private var nextFilteredHeight: Int32?
    /// Heights of the filtered blocks the scan has requested, by block hash.
    /// When they are lost the scan rewinds to the lowest one, so nothing is
    /// skipped. Blocks fetched because a peer announced them are not counted
    /// here and can never make the scan look further along than it is.
    private var filteredBlocksInFlight: [Data: Int32] = [:]
    /// The peer serving the filtered blocks in flight
    private var filteredWindowPeer: Peer?
    /// Set while a filtered-block request is assembled across awaits, so
    /// overlapping calls cannot request the same range twice
    private var isRequestingFilteredBlocks = false

    /// Current sync state
    public var state: SPVSyncState { syncState }

    /// Target height (best height from peers)
    public var targetHeight: Int32 { _targetHeight }

    /// Current synced height
    public var currentHeight: Int32 {
        get async { await headerChain.height }
    }

    /// Sync progress (0.0 to 1.0)
    ///
    /// Snapshot both values before dividing: reading the chain height and the
    /// target via two separate awaits can land on opposite sides of a header
    /// batch and momentarily yield `progress > 1.0`. Clamp defensively so the
    /// UI can never display a regressive or overshoot value.
    public var progress: Double {
        get async {
            let target = _targetHeight
            let height = await headerChain.height
            return Self.computeProgress(height: height, target: target)
        }
    }

    /// Clamp-and-snapshot helper used by every progress-reporting path in
    /// this manager so a single source of truth governs the calculation.
    nonisolated static func computeProgress(height: Int32, target: Int32) -> Double {
        guard target > 0 else { return 0 }
        let ratio = Double(height) / Double(target)
        return min(max(ratio, 0), 1)
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

    /// Runs every few seconds: expires unanswered requests and restarts a
    /// header sync left without a peer to follow.
    private func checkTimeouts() async {
        let now = Date()

        if let request = headerRequest, now.timeIntervalSince(request.sentAt) > headerRequestTimeout {
            logger.warning("Header request to \(request.peer.host) timed out")
            await handleHeaderRequestTimeout(request)
        }

        if !filteredBlocksInFlight.isEmpty,
           let requestTime = filteredBlockRequestTime,
           now.timeIntervalSince(requestTime) > filteredBlockTimeout {
            logger.warning("Filtered block request timed out")
            await handleFilteredBlockTimeout()
        }

        // Every peer was lost, or none had anything new: start over with
        // whoever is connected now.
        if isActive, syncPeer == nil, headerRequest == nil {
            let peers = await peerManager.connectedPeers
            let others = peers.filter { $0 != lastAbandonedPeer }
            if syncPeer == nil, let peer = others.randomElement() ?? peers.randomElement() {
                await requestHeaders(from: peer)
            }
        }
    }

    private func handleHeaderRequestTimeout(_ request: HeaderRequest) async {
        guard headerRequest == request else { return }
        headerRequest = nil
        abandonSyncPeer(request.peer)

        logger.info("Disconnecting unresponsive peer: \(request.peer.host)")
        await peerManager.removePeer(request.peer)
        await retryWithNextPeer(avoiding: request.peer)
    }

    private func handleFilteredBlockTimeout() async {
        abandonFilteredBlocksInFlight(reason: "request timeout")
        await requestFilteredBlocksIfNeeded()
    }

    /// Moves header sync to another connected peer right away. Without one,
    /// the periodic check picks the sync up again. Does nothing while a
    /// request is outstanding: whoever sent it is in charge.
    private func retryWithNextPeer(avoiding previous: Peer) async {
        guard isActive, headerRequest == nil else { return }

        let candidates = await peerManager.connectedPeers.filter { $0 != previous }
        guard isActive, headerRequest == nil else { return }

        if let nextPeer = candidates.randomElement() {
            logger.info("Switching to peer: \(nextPeer.host)")
            await requestHeaders(from: nextPeer)
        } else {
            logger.info("No other peers available, retrying shortly")
            abandonSyncPeer(previous)
        }
    }

    /// Stops following `peer`; the periodic check chooses a new peer within
    /// a few seconds. Deferring, rather than asking the next peer at once,
    /// keeps peers that agree there is nothing new out of a tight loop.
    private func abandonSyncPeer(_ peer: Peer) {
        if syncPeer == peer {
            syncPeer = nil
        }
        lastAbandonedPeer = peer
    }

    /// Create an SPV sync manager
    public init(network: DogecoinNetwork = .mainnet, storageDirectory: URL? = nil, bundledCacheDirectory: URL? = nil) {
        self.init(
            network: network,
            peerManager: PeerManager(network: network),
            headerChain: HeaderChain(network: network, storageDirectory: storageDirectory, bundledCacheDirectory: bundledCacheDirectory)
        )
    }

    init(network: DogecoinNetwork, peerManager: PeerManager, headerChain: HeaderChain) {
        self.network = network
        self.peerManager = peerManager
        self.headerChain = headerChain
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

        session += 1
        let session = self.session
        isActive = true
        syncState = .connecting
        lastProgressTime = Date()

        logger.info("Starting SPV sync")

        // Ensure header chain is set up (idempotent)
        await headerChain.setup()
        await peerManager.setDelegate(self)

        // stop() ran while we were setting up.
        guard self.session == session else { return }

        startTimeoutTask()
        await peerManager.start()
    }

    /// Stop synchronization
    public func stop() async {
        logger.info("Stopping SPV sync")

        // Peers report disconnecting while they are shut down below; those
        // events must not start new requests.
        session += 1
        isActive = false
        stopTimeoutTask()
        syncPeer = nil
        headerRequest = nil
        abandonFilteredBlocksInFlight(reason: "sync stopped")

        await peerManager.stop()
        await headerChain.flush()

        peerStartHeights.removeAll()
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
        resetFilteredBlocksInFlight()

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
        resetFilteredBlocksInFlight()

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
        guard isActive,
              !isRequestingFilteredBlocks,
              let nextHeight = nextFilteredHeight,
              bloomFilter != nil,
              filteredBlocksInFlight.count < maxFilteredBlocksInFlight else {
            return
        }

        isRequestingFilteredBlocks = true
        defer { isRequestingFilteredBlocks = false }

        let chainHeight = await headerChain.height
        guard nextHeight <= chainHeight else { return }

        // Blocks in flight stay with the peer serving them.
        let windowPeer = filteredWindowPeer
        let peer: Peer
        if let windowPeer {
            peer = windowPeer
        } else if let syncPeer {
            peer = syncPeer
        } else if let connected = await peerManager.connectedPeers.randomElement() {
            peer = connected
        } else {
            return
        }

        var requested: [(hash: Data, height: Int32)] = []
        var height = nextHeight
        while height <= chainHeight,
              requested.count < filteredBlockBatchSize,
              filteredBlocksInFlight.count + requested.count < maxFilteredBlocksInFlight {
            if let stored = await headerChain.getHeader(height: height) {
                requested.append((stored.header.hash, height))
            }
            height += 1
        }

        // A timeout, disconnect, or filter change while the range was read
        // has moved the scan; this request would be stale.
        guard !requested.isEmpty,
              nextFilteredHeight == nextHeight,
              filteredWindowPeer == windowPeer else {
            return
        }

        nextFilteredHeight = height
        for block in requested {
            filteredBlocksInFlight[block.hash] = block.height
        }
        filteredWindowPeer = peer
        filteredBlockRequestTime = Date()

        await peer.sendGetData(inventory: requested.map { InventoryVector(type: .filteredBlock, hash: $0.hash) })
    }

    /// Forgets the filtered blocks in flight after their peer is lost and
    /// rewinds the scan to the lowest of them, so the next peer re-requests
    /// every block that never arrived.
    private func abandonFilteredBlocksInFlight(reason: String) {
        guard let lowest = filteredBlocksInFlight.values.min() else { return }
        nextFilteredHeight = nextFilteredHeight.map { min($0, lowest) }
        logger.info("Abandoning \(self.filteredBlocksInFlight.count) filtered blocks in flight (\(reason)); rewinding to height \(self.nextFilteredHeight ?? -1)")
        resetFilteredBlocksInFlight()
    }

    private func resetFilteredBlocksInFlight() {
        filteredBlocksInFlight.removeAll()
        filteredWindowPeer = nil
        filteredBlockRequestTime = nil
    }

    /// Sends `getheaders` to `peer` and follows it from now on. At most one
    /// request is outstanding at a time.
    private func requestHeaders(from peer: Peer) async {
        guard isActive, headerRequest == nil else { return }

        let request = HeaderRequest(peer: peer, sentAt: Date())
        syncPeer = peer
        headerRequest = request

        let locator = await headerChain.getBlockLocator()

        // Timed out, lost its peer, or stopped while the locator was built.
        guard headerRequest == request else { return }

        logger.info("Requesting headers from \(peer.host), locator has \(locator.count) hashes")
        await peer.sendGetHeaders(locatorHashes: locator)
    }

    /// Whether `peer` still leads the sync with nothing outstanding — false
    /// once a timeout, disconnect, or stop has taken over.
    private func isFollowing(_ peer: Peer) -> Bool {
        isActive && syncPeer == peer && headerRequest == nil
    }

    /// Handle received headers
    private func handleHeaders(_ entries: [HeadersMessage.Entry], from peer: Peer) async {
        guard isActive else { return }

        guard let request = headerRequest, request.peer == peer else {
            // Unsolicited headers (an announcement, or the late answer to an
            // abandoned request) still carry validated data worth keeping,
            // but never steer the sync.
            if !entries.isEmpty {
                let result = await headerChain.addHeaders(entries)
                if result.added > 0 {
                    await didAddHeaders(entries)
                }
                await penalizeIfInvalid(result.failure, from: peer)
            }
            return
        }

        headerRequest = nil
        lastProgressTime = Date()

        guard !entries.isEmpty else {
            logger.info("No more headers from \(peer.host)")

            let chainHeight = await headerChain.height
            guard isFollowing(peer) else { return }

            if chainHeight >= _targetHeight {
                markSynchronized()
            } else {
                logger.info("Still below target height (\(chainHeight) < \(self._targetHeight)), trying another peer")
                abandonSyncPeer(peer)
            }
            return
        }

        logger.info("Received \(entries.count) headers from \(peer.host)")

        let result = await headerChain.addHeaders(entries)
        let chainHeight = await headerChain.height
        logger.info("Added \(result.added) headers, height now \(chainHeight)")

        if result.added > 0 {
            await didAddHeaders(entries)
        }

        if let failure = result.failure {
            await penalizeIfInvalid(failure, from: peer)
            await retryWithNextPeer(avoiding: peer)
            return
        }

        guard isFollowing(peer) else { return }

        // Request more headers or mark as synchronized
        if chainHeight >= _targetHeight {
            markSynchronized()
        } else if result.added > 0 {
            syncState = .syncing
            await requestHeaders(from: peer)
        } else {
            // A full batch of headers we already had: the peer is not
            // helping us advance.
            abandonSyncPeer(peer)
        }
    }

    /// Brings transaction state and the delegate up to date after `entries`
    /// extended (or reorganized) the chain.
    private func didAddHeaders(_ entries: [HeadersMessage.Entry]) async {
        await refreshPendingMerkleBlocks()
        await refreshVerifiedTransactionsForReorg()
        await requestFilteredBlocksIfNeeded()

        for entry in entries {
            if let stored = await headerChain.getHeader(hash: entry.header.hash) {
                delegateEvents.yield(.header(entry.header, height: stored.height))
            }
        }

        let chainHeight = await headerChain.height
        delegateEvents.yield(.progress(Self.computeProgress(height: chainHeight, target: _targetHeight), height: chainHeight))
    }

    /// Reports completion every time the chain catches up — including after
    /// each new block — since delegates record the synced height from it.
    private func markSynchronized() {
        syncState = .synchronized
        delegateEvents.yield(.completed)
    }

    /// Bans a peer whose headers prove it misbehaved.
    private func penalizeIfInvalid(_ failure: HeaderChain.ValidationError?, from peer: Peer) async {
        guard let failure, Self.isBannable(failure) else { return }
        logger.warning("Banning \(peer.host) for invalid headers: \(String(describing: failure))")
        await peerManager.banPeer(peer, reason: .invalidHeaders)
    }

    /// Whether a header failing this way proves its sender misbehaved, as
    /// Dogecoin Core judges it. Spared: headers that do not connect (the
    /// peer may be on a branch we have not seen), timestamps — judged
    /// against our own clock, which may be wrong — and obsolete versions,
    /// none of which Core penalizes either.
    nonisolated static func isBannable(_ failure: HeaderChain.ValidationError) -> Bool {
        switch failure {
        case .checkpointMismatch, .invalidProofOfWork, .invalidDifficulty, .auxPowRequired,
             .auxPowValidationFailed, .forkBelowCheckpoint, .incorrectDifficulty, .invalidVersion:
            true
        case .invalidPreviousBlock, .databaseError, .futureTooFar, .invalidTimestamp, .obsoleteVersion:
            false
        }
    }

    /// The median of connected peers' announced heights, so one peer
    /// claiming an absurd height cannot keep the sync from ever finishing.
    private func updateTargetHeight() {
        let heights = peerStartHeights.values.sorted()
        guard !heights.isEmpty else { return }
        let median = heights[(heights.count - 1) / 2]
        _targetHeight = max(median, 0)
    }
}

// MARK: - PeerManagerDelegate

extension SPVSyncManager: PeerManagerDelegate {
    public func peerManager(_ manager: PeerManager, peerDidBecomeReady peer: Peer) async {
        logger.info("Peer ready: \(peer.host)")
        guard isActive else { return }

        // Update target height from peer version
        if let version = await peer.peerVersion {
            peerStartHeights[peer.id] = version.startHeight
            updateTargetHeight()
        }

        // Follow this peer if the sync has nobody to follow — at the start,
        // or after every earlier peer was lost.
        if isActive, syncPeer == nil, headerRequest == nil {
            if syncState == .connecting {
                syncState = .syncing
            }
            await requestHeaders(from: peer)
        }

        if let filter = bloomFilter {
            logger.info("Sending bloom filter to \(peer.host) before requesting filtered blocks")
            await peer.sendFilterLoad(filter)
            await requestFilteredBlocksIfNeeded()
        }
    }

    public func peerManager(_ manager: PeerManager, peerDidDisconnect peer: Peer) async {
        logger.info("Peer disconnected: \(peer.host)")

        peerStartHeights.removeValue(forKey: peer.id)
        updateTargetHeight()

        guard isActive else { return }

        if peer == filteredWindowPeer {
            abandonFilteredBlocksInFlight(reason: "peer \(peer.host) disconnected")
        }

        if headerRequest?.peer == peer {
            headerRequest = nil
        }
        if peer == syncPeer {
            syncPeer = nil
            await retryWithNextPeer(avoiding: peer)
        }

        await requestFilteredBlocksIfNeeded()
    }

    public func peerManager(_ manager: PeerManager, peer: Peer, didReceiveMessage message: ProtocolMessage) async {
        switch message.command {
        case ProtocolMessage.Command.headers:
            if let headersMsg = HeadersMessage.parse(from: message.payload) {
                await handleHeaders(headersMsg.entries, from: peer)
            } else {
                await peerManager.banPeer(peer, reason: .invalidMessage)
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
        // Without a bloom filter nothing can match the wallet; fetching every
        // announced transaction would only waste bandwidth.
        let txInv = inventory.filter { $0.type == .transaction }
        if !txInv.isEmpty, bloomFilter != nil {
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
            delegateEvents.yield(.failure(error))
            return
        }

        guard matches.merkleRoot == merkleBlock.header.merkleRoot else {
            await peerManager.banPeer(peer, reason: .invalidTransaction)
            delegateEvents.yield(.failure(DogecoinError.syncFailed("Invalid merkle proof")))
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

        for event in events {
            delegateEvents.yield(.transaction(event.0, event.1))
        }

        // Report filtered block scan progress
        if let height {
            delegateEvents.yield(.filteredBlock(height: height, targetHeight: _targetHeight))
        }

        if filteredBlocksInFlight.removeValue(forKey: blockHash) != nil, filteredBlocksInFlight.isEmpty {
            filteredWindowPeer = nil
            filteredBlockRequestTime = nil
        }
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
        } else if let filter = bloomFilter {
            // Unsolicited (mempool) transaction — a peer can send arbitrary
            // `tx` messages; BIP 37 only guarantees that the server *attempts*
            // to filter, it does not guarantee correctness. Re-check matches
            // on our side before surfacing anything to the delegate, otherwise
            // a hostile or buggy peer could inject transactions unrelated to
            // the wallet as "incoming."
            guard Self.transactionMatchesBloomFilter(txMessage.rawData, filter: filter) else {
                logger.debug("Dropping unsolicited tx from \(peer.host) — no bloom match")
                return
            }

            if pendingTransactions[txid] == nil {
                pendingTransactions[txid] = txMessage
            }
            events.append((txMessage, .unconfirmed))
        }

        for event in events {
            delegateEvents.yield(.transaction(event.0, event.1))
        }
    }

    /// Returns `true` if the raw transaction contains **any** element that
    /// matches the given bloom filter. Follows BIP 37 matching for P2PKH:
    ///
    /// - input outpoints (32-byte prev-txid ‖ 4-byte vout, little-endian)
    /// - each data push inside every output's scriptPubKey
    /// - the entire scriptPubKey bytes for every output
    ///
    /// Returns `false` if parsing fails — a malformed tx is definitely not a
    /// hit and should be dropped.
    nonisolated static func transactionMatchesBloomFilter(_ raw: Data, filter: BloomFilter) -> Bool {
        var offset = 0
        let bytes = raw

        // version (4)
        guard bytes.count >= offset + 4 else { return false }
        offset += 4

        // input count — peer-supplied, bounded by remaining bytes so a
        // fabricated VarInt can only fail the match, never trap.
        guard let (inputCount, inputCountSize) = bytes.readBoundedCount(at: offset, minItemSize: 41) else { return false }
        offset += inputCountSize

        for _ in 0..<inputCount {
            // prev txid (32) + vout (4)
            guard bytes.count >= offset + 36 else { return false }
            let outpoint = bytes.subdata(in: offset..<(offset + 36))
            if filter.contains(outpoint) { return true }
            offset += 36

            // script length + script (sequence follows)
            guard let (scriptLen, scriptStart) = bytes.readBoundedLength(at: offset, trailing: 4) else { return false }
            offset = scriptStart + scriptLen

            // sequence (4)
            offset += 4
        }

        // output count
        guard let (outputCount, outputCountSize) = bytes.readBoundedCount(at: offset, minItemSize: 9) else { return false }
        offset += outputCountSize

        for _ in 0..<outputCount {
            // value (8)
            guard bytes.count >= offset + 8 else { return false }
            offset += 8

            // script length + script
            guard let (scriptLen, scriptStart) = bytes.readBoundedLength(at: offset) else { return false }
            offset = scriptStart
            let scriptEnd = offset + scriptLen

            let script = bytes.subdata(in: offset..<scriptEnd)
            if filter.contains(script) { return true }
            for push in scriptDataPushes(in: script) where filter.contains(push) {
                return true
            }

            offset = scriptEnd
        }

        return false
    }

    /// Extracts each data push from a Bitcoin script. Recognizes direct
    /// pushes (opcodes 0x01..0x4b) and `OP_PUSHDATA1/2/4` (0x4c/0x4d/0x4e).
    /// Other opcodes are skipped. Stops early on malformed script rather
    /// than throwing — a malformed script simply yields no matches.
    nonisolated private static func scriptDataPushes(in script: Data) -> [Data] {
        var pushes: [Data] = []
        var i = script.startIndex
        while i < script.endIndex {
            let op = script[i]
            i += 1
            let pushLen: Int
            if op >= 0x01 && op <= 0x4b {
                pushLen = Int(op)
            } else if op == 0x4c {
                guard i < script.endIndex else { return pushes }
                pushLen = Int(script[i])
                i += 1
            } else if op == 0x4d {
                guard script.endIndex - i >= 2 else { return pushes }
                pushLen = Int(script[i]) | (Int(script[i + 1]) << 8)
                i += 2
            } else if op == 0x4e {
                guard script.endIndex - i >= 4 else { return pushes }
                pushLen = Int(script[i])
                    | (Int(script[i + 1]) << 8)
                    | (Int(script[i + 2]) << 16)
                    | (Int(script[i + 3]) << 24)
                i += 4
            } else {
                continue
            }
            guard pushLen >= 0, script.endIndex - i >= pushLen else { return pushes }
            pushes.append(script.subdata(in: i..<(i + pushLen)))
            i += pushLen
        }
        return pushes
    }

    private func handleBlock(_ block: BlockMessage, from peer: Peer) async {
        guard let merkleRoot = block.merkleRoot,
              merkleRoot == block.header.merkleRoot else {
            await peerManager.banPeer(peer, reason: .invalidTransaction)
            delegateEvents.yield(.failure(DogecoinError.syncFailed("Invalid block merkle root")))
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

        for event in events {
            delegateEvents.yield(.transaction(event.0, event.1))
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

        for event in events {
            delegateEvents.yield(.transaction(event.0, event.1))
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

        for event in events {
            delegateEvents.yield(.transaction(event.0, event.1))
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
