import Foundation
#if canImport(os)
import os.log
#endif

/// Delegate for SPV sync events
public protocol SPVSyncDelegate: AnyObject, Sendable {
    /// Called when sync progress updates
    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) async

    /// Called when the chain catches up with its peers, and again each time
    /// it has grown since. A reply that leaves the height unchanged does not
    /// repeat it.
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
    /// The chain height last reported as complete
    private var lastSynchronizedHeight: Int32?
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

    /// Merkle blocks still waiting for a header or a transaction
    var pendingMerkleBlockCount: Int { pendingMerkleBlocks.count }

    /// Target height (the median of the heights connected peers announced)
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

    /// How many of an announcement's blocks are looked up, newest first. A
    /// real one names a block or two; the bound keeps a peer from buying
    /// thousands of database reads with a single message.
    private static let announcedBlocksChecked = 8

    /// The size of the largest block, which no transaction can exceed
    private static let maximumTransactionSize = 1_000_000

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
        // A start that failed before syncing may simply be tried again.
        if case .error = syncState {
            syncState = .idle
        }

        guard syncState == .idle else {
            logger.warning("Cannot start: already running")
            return
        }

        session += 1
        let session = self.session
        isActive = true
        syncState = .connecting

        logger.info("Starting SPV sync")

        // Ensure header chain is set up (idempotent)
        await headerChain.setup()
        await peerManager.setDelegate(self)

        // stop() ran while we were setting up.
        guard self.session == session else { return }

        // Without its database the chain can neither read nor store a
        // header: every request would time out, peer after peer, with the
        // state stuck on "syncing". Say so instead.
        guard await headerChain.isOpen else {
            let error = DogecoinError.syncFailed("The block header database could not be opened")
            logger.error("Cannot start: \(error.localizedDescription)")
            isActive = false
            syncState = .error(error)
            delegateEvents.yield(.failure(error))
            return
        }

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
        lastSynchronizedHeight = nil
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
                    await didAddHeaders(entries, replacingChainAbove: result.forkHeight)
                }
                await penalizeIfInvalid(result.failure, from: peer)
            }
            return
        }

        headerRequest = nil

        guard !entries.isEmpty else {
            logger.info("No more headers from \(peer.host)")

            let chainHeight = await headerChain.height
            guard isFollowing(peer) else { return }

            if chainHeight >= _targetHeight {
                markSynchronized(at: chainHeight)
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
            await didAddHeaders(entries, replacingChainAbove: result.forkHeight)
        }

        if let failure = result.failure {
            if Self.isBannable(failure) {
                await penalizeIfInvalid(failure, from: peer)
                await retryWithNextPeer(avoiding: peer)
            } else {
                // The cause may be on this side — a wrong clock, a full
                // disk — and then every peer's headers fail alike. Asking
                // the next peer at once would loop at network speed, so
                // the periodic check picks one instead.
                logger.warning("Headers from \(peer.host) were not accepted: \(String(describing: failure))")
                abandonSyncPeer(peer)
            }
            return
        }

        guard isFollowing(peer) else { return }

        // A full message means the peer has more, whatever height peers
        // announced when they connected.
        let peerHasMore = entries.count >= HeadersMessage.maximumEntries
        if result.added > 0, peerHasMore || chainHeight < _targetHeight {
            syncState = .syncing
            await requestHeaders(from: peer)
        } else if chainHeight >= _targetHeight {
            markSynchronized(at: chainHeight)
        } else {
            // Headers we already had, and still short of the target: the
            // peer is not helping us advance.
            abandonSyncPeer(peer)
        }
    }

    /// Brings transaction state and the delegate up to date after `entries`
    /// extended the chain or — when `forkHeight` is set — replaced the part
    /// of it above that height.
    private func didAddHeaders(_ entries: [HeadersMessage.Entry], replacingChainAbove forkHeight: Int32?) async {
        // Before anything is confirmed: a transaction leaves its old block
        // here and may enter its new one in the very next step.
        if let forkHeight {
            await handleReorganization(above: forkHeight)
        }
        await refreshPendingMerkleBlocks()
        await requestFilteredBlocksIfNeeded()

        for entry in entries {
            if let stored = await headerChain.getHeader(hash: entry.header.hash) {
                delegateEvents.yield(.header(entry.header, height: stored.height))
            }
        }

        let chainHeight = await headerChain.height
        delegateEvents.yield(.progress(Self.computeProgress(height: chainHeight, target: _targetHeight), height: chainHeight))
    }

    /// Reports completion when the chain catches up and again each time it
    /// has grown since — delegates record the synced height from it — but
    /// not when a peer merely confirms there is nothing new.
    private func markSynchronized(at height: Int32) {
        let isNews = syncState != .synchronized || lastSynchronizedHeight != height
        syncState = .synchronized
        lastSynchronizedHeight = height
        if isNews {
            delegateEvents.yield(.completed)
        }
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
        // or after every earlier peer was lost — or if the chain looks
        // complete and this peer says it is not. The peer being followed
        // may be the one that is behind.
        var shouldFollow = syncPeer == nil
        if !shouldFollow, syncState == .synchronized, let announcedHeight = peerStartHeights[peer.id] {
            shouldFollow = await announcedHeight > headerChain.height
        }
        if isActive, shouldFollow, headerRequest == nil {
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
            await followAnnouncement(of: blockInv, from: peer)
        }
    }

    /// Asks `peer` for headers when it announces a block this chain lacks.
    ///
    /// Only the peer being followed used to be asked. If that one stopped
    /// announcing blocks — stalled, or simply behind — the chain stayed at
    /// its tip for as long as it remained connected, whatever every other
    /// peer announced.
    private func followAnnouncement(of blocks: [InventoryVector], from peer: Peer) async {
        // Mid-sync, the peer being followed is already delivering the chain.
        guard isActive, headerRequest == nil,
              syncPeer == nil || syncPeer == peer || syncState == .synchronized else {
            return
        }

        // The newest block comes last.
        for block in blocks.suffix(Self.announcedBlocksChecked).reversed() {
            if await headerChain.getHeader(hash: block.hash) == nil {
                await requestHeaders(from: peer)
                return
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

        // Every peer that announces a block sends its merkle block, so the
        // same one arrives several times. Matches already confirmed in it
        // are settled; waiting for them again would keep the block pending
        // forever.
        let matchedSet = Set(matches.matchedHashes).filter { verifiedTransactions[$0]?.blockHash != blockHash }

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
        // Whatever arrives here is kept, hashed, and handed to the wallet.
        guard let decoded = Self.decodeRelayedTransaction(txMessage.rawData) else {
            logger.warning("Banning \(peer.host) for a malformed transaction")
            await peerManager.banPeer(peer, reason: .invalidTransaction)
            return
        }

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
            guard Self.transaction(decoded, withTxid: txid, matches: filter) else {
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

    /// Decodes a transaction a peer sent. Returns nil unless the bytes are
    /// exactly one transaction as Dogecoin serializes it: nothing missing,
    /// nothing trailing, no witness data, and no larger than a block.
    nonisolated static func decodeRelayedTransaction(_ raw: Data) -> RawTransaction? {
        guard raw.count <= maximumTransactionSize,
              let transaction = RawTransaction(data: raw),
              // The txid is the hash of these bytes only if they are the
              // plain serialization.
              transaction.strippedData == raw else {
            return nil
        }
        return transaction
    }

    /// Whether `raw` is a well-formed transaction that matches `filter`.
    nonisolated static func transactionMatchesBloomFilter(_ raw: Data, filter: BloomFilter) -> Bool {
        guard let transaction = decodeRelayedTransaction(raw) else { return false }
        return self.transaction(transaction, withTxid: MerkleTree.doubleSHA256(raw), matches: filter)
    }

    /// Whether `transaction` matches `filter`, tested as BIP 37 has a node
    /// test it: the txid, every data push in every output script, every
    /// outpoint spent, and every data push in every input script.
    ///
    /// Whole output scripts are tested as well. No node does that, but a
    /// caller that put scripts in its filter expects them to match here.
    /// - Parameter txid: The transaction id in internal byte order
    nonisolated static func transaction(_ transaction: RawTransaction, withTxid txid: Data, matches filter: BloomFilter) -> Bool {
        if filter.contains(txid) { return true }

        for output in transaction.outputs {
            if filter.contains(output.script) || anyDataPush(in: output.script, satisfies: filter.contains) {
                return true
            }
        }

        for input in transaction.inputs {
            var outpoint = input.previousTxid
            withUnsafeBytes(of: input.previousIndex.littleEndian) { outpoint.append(contentsOf: $0) }
            if filter.contains(outpoint) || anyDataPush(in: input.script, satisfies: filter.contains) {
                return true
            }
        }

        return false
    }

    /// Whether any data push in `script` satisfies `predicate`. Recognizes
    /// direct pushes (opcodes 0x01...0x4b) and `OP_PUSHDATA1/2/4`; other
    /// opcodes are skipped, and a malformed push ends the walk.
    nonisolated private static func anyDataPush(in script: Data, satisfies predicate: (Data) -> Bool) -> Bool {
        var index = script.startIndex
        while index < script.endIndex {
            let opcode = script[index]
            index += 1

            let length: Int
            switch opcode {
            case 0x01...0x4b:
                length = Int(opcode)
            case 0x4c:
                guard index < script.endIndex else { return false }
                length = Int(script[index])
                index += 1
            case 0x4d:
                guard script.endIndex - index >= 2 else { return false }
                length = Int(script[index]) | (Int(script[index + 1]) << 8)
                index += 2
            case 0x4e:
                guard script.endIndex - index >= 4 else { return false }
                length = Int(script[index])
                    | (Int(script[index + 1]) << 8)
                    | (Int(script[index + 2]) << 16)
                    | (Int(script[index + 3]) << 24)
                index += 4
            default:
                continue
            }

            guard script.endIndex - index >= length else { return false }
            if length > 0, predicate(script[index..<(index + length)]) {
                return true
            }
            index += length
        }
        return false
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

        for blockHash in Array(pendingMerkleBlocks.keys) {
            let needsHeight = pendingMerkleBlocks[blockHash]?.height == nil
            let isOnBestChain = await headerChain.isHeaderInBestChain(blockHash)
            let height = needsHeight ? await headerChain.getHeader(hash: blockHash)?.height : nil

            // Read only now: the entry may have changed during the lookups,
            // and writing an older copy back would undo that.
            guard var pending = pendingMerkleBlocks[blockHash] else { continue }
            pending.isOnBestChain = isOnBestChain
            if pending.height == nil {
                pending.height = height
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

    /// The best chain above `forkHeight` was replaced.
    ///
    /// Transactions confirmed in the blocks that lost go back to waiting:
    /// the block that replaced theirs usually holds them too, and they can
    /// only be confirmed in it while their bytes are still at hand. The
    /// scan returns to the fork, because peers announce just the new tip —
    /// the blocks beneath it on the new branch would never be fetched.
    private func handleReorganization(above forkHeight: Int32) async {
        var events: [(TxMessage, SPVTransactionState)] = []

        for (txid, verified) in verifiedTransactions.filter({ $0.value.height > forkHeight }) {
            guard await !headerChain.isHeaderInBestChain(verified.blockHash),
                  verifiedTransactions[txid]?.blockHash == verified.blockHash else {
                continue
            }

            verifiedTransactions.removeValue(forKey: txid)
            pendingTransactions[txid] = verified.transaction
            events.append((
                verified.transaction,
                .reorged(previousBlockHash: verified.blockHash, previousHeight: verified.height)
            ))
        }

        for event in events {
            delegateEvents.yield(.transaction(event.0, event.1))
        }

        guard let nextHeight = nextFilteredHeight, nextHeight > forkHeight + 1 else { return }

        logger.info("Chain reorganized above height \(forkHeight); rescanning from there")
        filteredBlocksInFlight = filteredBlocksInFlight.filter { $0.value <= forkHeight }
        if filteredBlocksInFlight.isEmpty {
            filteredWindowPeer = nil
            filteredBlockRequestTime = nil
        }
        nextFilteredHeight = forkHeight + 1
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
