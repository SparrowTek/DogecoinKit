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

    /// Called when the sync cannot go on: the header database could not be
    /// opened or read. The manager's state is `.error` and it has stopped;
    /// `start()` tries again.
    ///
    /// Trouble with one peer — bad data, silence — is dealt with by dropping
    /// that peer and is not reported here.
    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) async

    /// Called when a transaction changes state (unconfirmed, confirmed, or reorged)
    func spvSync(_ manager: SPVSyncManager, didUpdateTransaction transaction: TxMessage, state: SPVTransactionState) async

    /// Called as the scan for the wallet's transactions advances: every
    /// block up to and including `height` has been fetched, checked against
    /// its header, and searched, and every transaction found in them has
    /// been reported before this call.
    ///
    /// A later scan can start just above this height. Store the latest
    /// value, not the highest: after a reorganization the scan — and this
    /// height — goes back to the fork.
    func spvSync(_ manager: SPVSyncManager, didScanThrough height: Int32, targetHeight: Int32) async
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

    /// How long the sync waits for things
    struct Timing: Sendable {
        /// For the answer to a `getheaders`
        var headerRequest: Duration = .seconds(60)
        /// For a filtered block, and the transactions it names, from the
        /// moment it was asked for
        var filteredBlock: Duration = .seconds(120)
        /// Between checks for anything overdue
        var check: Duration = .seconds(5)
        /// An answer to `getheaders` slower than this counts against the
        /// peer giving it
        var slowHeaderReply: Duration = .seconds(20)
        /// For a second peer, before one peer's word that the chain is
        /// complete is taken
        var loneCompletion: Duration = .seconds(10)
        /// Between offers of a sent transaction that has yet to confirm
        var reannouncement: Duration = .seconds(600)
        /// Before a sent transaction that never confirmed stops being offered
        var ownTransactionLifetime: Duration = .seconds(48 * 3600)
    }

    private let timing: Timing

    // MARK: - Delegate Events

    private enum DelegateEvent: Sendable {
        case progress(Double, height: Int32)
        case completed
        case failure(any Error)
        case transaction(TxMessage, SPVTransactionState)
        case scanned(through: Int32, targetHeight: Int32)
    }

    /// Delivers delegate callbacks strictly in order — a transaction's
    /// `.confirmed` must never overtake its `.unconfirmed`, and a scan height
    /// must never overtake the transactions found below it.
    private lazy var delegateEvents = SerialEventQueue<DelegateEvent> { [weak self] event in
        guard let self, let delegate = await self.delegate else { return }
        switch event {
        case .progress(let progress, let height):
            await delegate.spvSync(self, progressUpdated: progress, height: height)
        case .completed:
            await delegate.spvSyncDidComplete(self)
        case .failure(let error):
            await delegate.spvSync(self, didEncounterError: error)
        case .transaction(let transaction, let state):
            await delegate.spvSync(self, didUpdateTransaction: transaction, state: state)
        case .scanned(let height, let targetHeight):
            await delegate.spvSync(self, didScanThrough: height, targetHeight: targetHeight)
        }
    }

    // MARK: - Sync State

    /// A `getheaders` awaiting its answer. At most one is outstanding, and
    /// only the answer from the peer it went to steers the sync.
    private struct HeaderRequest: Equatable {
        let peer: Peer
        let sentAt: ContinuousClock.Instant
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
    /// Slow answers in a row from the peer being followed
    private var slowHeaderReplies = 0
    /// Since when the chain has looked complete on one peer's word alone
    private var completionPendingSince: ContinuousClock.Instant?

    // MARK: - Transaction State

    private struct VerifiedTransaction: Sendable {
        let transaction: TxMessage
        let blockHash: Data
        let height: Int32
    }

    /// A transaction this wallet sent, offered to peers until it confirms
    private struct OwnTransaction: Sendable {
        let transaction: TxMessage
        let since: ContinuousClock.Instant
        var lastOffered: ContinuousClock.Instant
    }

    private var bloomFilter: BloomFilter?

    /// Exactly what the wallet watches: what the filter was built from, and
    /// the outputs found paying it since. A bloom filter also matches things
    /// that were never put in it; this decides what is really the wallet's.
    private var watchedElements: Set<Data> = []

    /// The wallet's transactions not yet in a block
    private let pendingTransactions = LRUCache<Data, TxMessage>(capacity: 1024)

    /// The wallet's transactions confirmed in recent blocks, kept so a
    /// reorganization can take them out again
    private var verifiedTransactions: [Data: VerifiedTransaction] = [:]

    /// Transactions asked for after a peer announced them, and when
    private let requestedTransactions = LRUCache<Data, ContinuousClock.Instant>(capacity: 4096)

    /// Transactions looked at and found not to be the wallet's — the bloom
    /// filter's false positives
    private let irrelevantTransactions = LRUCache<Data, Bool>(capacity: 4096)

    private var ownTransactions: [Data: OwnTransaction] = [:]

    // MARK: - Scan State

    /// A filtered block the scan has asked for
    private struct FilteredBlockRequest: Sendable {
        let height: Int32
        let requestedAt: ContinuousClock.Instant
        /// The transactions its merkle proof names that have yet to arrive;
        /// `nil` until the merkle block itself has
        var awaitedTransactions: Set<Data>?
    }

    /// The next height the scan will ask for
    private var nextFilteredHeight: Int32?

    /// The filtered blocks asked for and not yet complete, by block hash.
    /// A block is complete once its merkle block and every transaction that
    /// names have arrived. When they are lost the scan rewinds to the lowest
    /// of them, so nothing is skipped.
    private var filteredBlocksInFlight: [Data: FilteredBlockRequest] = [:]

    /// Which block in flight is waiting for a transaction, by txid
    private var awaitedTransactionBlocks: [Data: Data] = [:]

    /// The peer serving the filtered blocks in flight
    private var filteredWindowPeer: Peer?

    /// Peers that said they do not have blocks the scan asked for
    private var peersUnableToServeBlocks: Set<UUID> = []

    /// Peers that hold the current filter and have nothing left to send
    /// that an earlier one produced. Only these are asked for filtered
    /// blocks.
    private var peersWithFilter: Set<UUID> = []

    /// Peers sent a new filter over an old one, and the ping that follows
    /// it. A node answers in order, so its pong marks the point after which
    /// every merkle block was made with the new filter. Without that mark
    /// a block asked for again could be answered by what the old filter
    /// found in it — and what only the new one matches would be missed.
    private var filterBarriers: [UUID: UInt64] = [:]

    /// Counts filters, so a slow send of an old one is not mistaken for
    /// the current one
    private var filterGeneration = 0

    /// Set while a filtered-block request is assembled across awaits, so
    /// overlapping calls cannot request the same range twice — and what
    /// they wanted, so it is not forgotten either
    private var isRequestingFilteredBlocks = false
    private var wantsFilteredBlocks = false

    /// The scan height last reported
    private var reportedScanHeight: Int32?

    /// Current sync state
    public var state: SPVSyncState { syncState }

    /// Filtered blocks asked for and not yet complete
    var filteredBlocksInFlightCount: Int { filteredBlocksInFlight.count }

    /// How far the chain is expected to reach: the median of the heights
    /// connected peers announced, or the chain's own height once it is past
    /// that
    public var targetHeight: Int32 { _targetHeight }

    /// Current synced height, or -1 before the header database is open
    public var currentHeight: Int32 {
        get async { await headerChain.height }
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

    // MARK: - Limits

    /// Most filtered blocks in flight, and the count at which more are
    /// asked for. Refilling one block at a time would send a request for
    /// every block that arrives.
    private static let maximumFilteredBlocksInFlight = 128
    private static let filteredBlockLowWaterMark = 64

    /// How many of an announcement's blocks are looked up, newest first. A
    /// real one names a block or two; the bound keeps a peer from buying
    /// thousands of database reads with a single message.
    private static let announcedBlocksChecked = 8

    /// How many of an announcement's transactions are asked for
    private static let announcedTransactionsFetched = 1000

    /// How long a transaction that was asked for is not asked for again
    private static let transactionRequestLifetime: Duration = .seconds(60)

    /// The size of the largest block, which no transaction can exceed
    private static let maximumTransactionSize = 1_000_000

    /// More matches than this in one block is not a wallet's history but a
    /// peer making one up
    private static let maximumMatchesPerBlock = 2000

    /// How far below the tip confirmed transactions are remembered. A
    /// reorganization deeper than this — two days of blocks — is not
    /// followed transaction by transaction.
    private static let reorganizationHorizon: Int32 = 2880

    /// Slow answers in a row before the sync moves to another peer
    private static let slowHeaderRepliesTolerated = 3

    /// Peers that must agree before the chain is called complete at once
    private static let peersForCompletion = 2

    /// Sent transactions offered at one time
    private static let maximumOwnTransactions = 100

    /// `NODE_NETWORK`: the peer has the whole chain. `NODE_BLOOM`: it
    /// serves bloom-filtered blocks — and bans a client that sends it a
    /// filter if it does not.
    private static let nodeNetwork: UInt64 = 1
    private static let nodeBloom: UInt64 = 4

    private var requiredServices: UInt64 {
        bloomFilter == nil ? Self.nodeNetwork : Self.nodeNetwork | Self.nodeBloom
    }

    // MARK: - Timeouts

    /// Task for periodic timeout checks
    private var timeoutTask: Task<Void, Never>?

    private func startTimeoutTask() {
        timeoutTask?.cancel()
        let interval = timing.check
        timeoutTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                // Ends with the manager, even one dropped without `stop()`.
                guard !Task.isCancelled, let self else { return }
                await self.checkTimeouts()
            }
        }
    }

    private func stopTimeoutTask() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    /// Runs every few seconds: expires unanswered requests, settles a
    /// completion that was waiting for a second peer, offers unconfirmed
    /// transactions again, and restarts a header sync left without a peer.
    private func checkTimeouts() async {
        guard isActive else { return }
        let now = ContinuousClock.now

        if let request = headerRequest, now - request.sentAt > timing.headerRequest {
            logger.warning("Header request to \(request.peer.host) timed out")
            await handleHeaderRequestTimeout(request)
        }

        if filteredBlocksInFlight.values.contains(where: { now - $0.requestedAt > timing.filteredBlock }) {
            logger.warning("A filtered block request timed out")
            await handleFilteredBlockTimeout()
        }

        if let since = completionPendingSince, now - since >= timing.loneCompletion {
            await settlePendingCompletion(waited: true)
        }

        await offerOwnTransactions(dueAt: now)

        // Every peer was lost, or none had anything new: start over with
        // whoever is connected now.
        if isActive, syncPeer == nil, headerRequest == nil {
            let peers = await peerManager.connectedPeers
            let others = peers.filter { $0 != lastAbandonedPeer }
            if isActive, syncPeer == nil, headerRequest == nil, let peer = others.randomElement() ?? peers.randomElement() {
                await requestHeaders(from: peer)
            }
        }
    }

    private func handleHeaderRequestTimeout(_ request: HeaderRequest) async {
        guard headerRequest == request else { return }
        headerRequest = nil
        abandonSyncPeer(request.peer)

        logger.info("Disconnecting unresponsive peer: \(request.peer.host)")
        await peerManager.removeUnresponsivePeer(request.peer)
        await retryWithNextPeer(avoiding: request.peer)
    }

    /// A block that was asked for never came, or the transactions it named
    /// did not. Its peer is dropped — and left alone for a while — so that
    /// the same blocks are not asked of it again, and the scan goes to
    /// another.
    private func handleFilteredBlockTimeout() async {
        if let peer = filteredWindowPeer {
            logger.info("Disconnecting \(peer.host): it did not deliver the filtered blocks it was asked for")
            // Losing the peer abandons its blocks and asks another for them.
            await peerManager.removeUnresponsivePeer(peer)
            guard filteredWindowPeer == peer else { return }
        }

        // The peer was gone already.
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
        slowHeaderReplies = 0
    }

    // MARK: - Lifecycle

    /// Create an SPV sync manager
    ///
    /// The header database is opened by ``start()``. Until then
    /// ``currentHeight`` is -1; use ``create(network:storageDirectory:bundledCacheDirectory:)``
    /// to have it open — and its height known — from the outset.
    public init(network: DogecoinNetwork = .mainnet, storageDirectory: URL? = nil, bundledCacheDirectory: URL? = nil) {
        self.init(
            network: network,
            peerManager: PeerManager(network: network),
            headerChain: HeaderChain(network: network, storageDirectory: storageDirectory, bundledCacheDirectory: bundledCacheDirectory)
        )
    }

    init(network: DogecoinNetwork, peerManager: PeerManager, headerChain: HeaderChain, timing: Timing = Timing()) {
        self.network = network
        self.peerManager = peerManager
        self.headerChain = headerChain
        self.timing = timing
    }

    /// Create an SPV sync manager asynchronously, offloading the heavy
    /// `HeaderChain` initialization to a background thread.
    /// - Throws: If the header database cannot be opened
    public static func create(
        network: DogecoinNetwork = .mainnet,
        storageDirectory: URL? = nil,
        bundledCacheDirectory: URL? = nil
    ) async throws -> SPVSyncManager {
        let manager = SPVSyncManager(
            network: network,
            storageDirectory: storageDirectory,
            bundledCacheDirectory: bundledCacheDirectory
        )
        try await manager.headerChain.setup()
        return manager
    }

    /// Start synchronization
    ///
    /// If the header database cannot be opened the state becomes `.error`
    /// and the delegate is told; calling this again tries again.
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

        // Without its database the chain can neither read nor store a
        // header: every request would time out, peer after peer, with the
        // state stuck on "syncing". Say so instead.
        do {
            try await headerChain.setup()
        } catch {
            // stop() ran while we were setting up.
            guard self.session == session else { return }
            logger.error("Cannot start: \(error.localizedDescription)")
            isActive = false
            syncState = .error(error)
            delegateEvents.yield(.failure(error))
            return
        }

        await peerManager.setDelegate(self)
        await peerManager.requireServices(requiredServices)

        guard self.session == session else { return }

        _targetHeight = max(_targetHeight, await headerChain.height)
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

        peerStartHeights.removeAll()
        peersUnableToServeBlocks.removeAll()
        peersWithFilter.removeAll()
        filterBarriers.removeAll()
        requestedTransactions.clear()
        lastSynchronizedHeight = nil
        completionPendingSince = nil
        slowHeaderReplies = 0
        syncState = .idle
    }

    /// The header database failed: nothing more can be read or stored, so
    /// the sync ends here rather than time out against peer after peer.
    private func fail(_ error: any Error) async {
        guard isActive else { return }
        logger.error("Sync cannot continue: \(error.localizedDescription)")

        session += 1
        isActive = false
        stopTimeoutTask()
        syncPeer = nil
        headerRequest = nil
        completionPendingSince = nil
        abandonFilteredBlocksInFlight(reason: "sync failed")
        syncState = .error(error)
        delegateEvents.yield(.failure(error))

        await peerManager.stop()
        peerStartHeights.removeAll()
    }

    // MARK: - Transaction Broadcasting

    /// Broadcast a signed transaction to the network
    ///
    /// Once a peer has taken the transaction it keeps being offered — to
    /// peers that connect later, and to all of them every few minutes —
    /// until it is seen in a block, so one that the first peers dropped
    /// still gets out.
    /// - Returns: The transaction id, in display byte order
    /// - Throws: `DogecoinError.noPeersAvailable` with no peer connected,
    ///   or `DogecoinError.broadcastFailed` when no peer asks for the
    ///   transaction in time or every peer that took it rejected it
    public func broadcastTransaction(_ rawHex: String) async throws -> String {
        let txid = try await peerManager.broadcastTransaction(rawHex)
        try? await announceUntilConfirmed(rawHex)
        return txid
    }

    /// Offers a transaction this wallet sent earlier — in an earlier
    /// session, say — to peers again, and keeps offering it until it is
    /// seen in a block.
    ///
    /// Unlike ``broadcastTransaction(_:)`` this does not wait for a peer to
    /// take it: peers that already have the transaction never ask for it
    /// again.
    /// - Throws: `DogecoinError.internalError` if `rawHex` is not a
    ///   transaction
    public func announceUntilConfirmed(_ rawHex: String) async throws {
        guard let transaction = TxMessage(rawHex: rawHex),
              Self.decodeRelayedTransaction(transaction.rawData) != nil else {
            throw DogecoinError.internalError("Invalid transaction hex")
        }

        let txid = transaction.txidInternal
        guard verifiedTransactions[txid] == nil else { return }

        if ownTransactions[txid] == nil, ownTransactions.count >= Self.maximumOwnTransactions,
           let oldest = ownTransactions.min(by: { $0.value.since < $1.value.since })?.key {
            await forgetOwnTransaction(oldest)
        }

        let now = ContinuousClock.now
        ownTransactions[txid] = OwnTransaction(
            transaction: transaction,
            since: ownTransactions[txid]?.since ?? now,
            lastOffered: now
        )
        // Held, so the block that includes it confirms it even from a peer
        // that does not send it again.
        pendingTransactions.set(txid, transaction)
        await peerManager.offer(transaction)
    }

    private func offerOwnTransactions(dueAt now: ContinuousClock.Instant) async {
        for (txid, own) in ownTransactions {
            if now - own.since > timing.ownTransactionLifetime {
                logger.info("Transaction \(own.transaction.txidHex) did not confirm; no longer offering it")
                await forgetOwnTransaction(txid)
            } else if now - own.lastOffered >= timing.reannouncement {
                ownTransactions[txid]?.lastOffered = now
                await peerManager.offer(own.transaction)
            }
        }
    }

    private func forgetOwnTransaction(_ txid: Data) async {
        guard ownTransactions.removeValue(forKey: txid) != nil else { return }
        await peerManager.withdraw(transactionID: txid)
    }

    // MARK: - Bloom Filter Configuration

    /// Configure the bloom filter for SPV transaction matching
    ///
    /// Also starts the scan for the wallet's transactions over at
    /// `startHeight`.
    /// - Parameters:
    ///   - elements: What to watch: public key hashes, and the outpoints of
    ///     the wallet's unspent outputs
    ///   - falsePositiveRate: How often the filter may match something that
    ///     was not asked for. Lower rates tell peers more precisely what
    ///     the wallet watches; higher ones cost more traffic.
    ///   - tweak: The filter's seed. A random one, unless a test needs the
    ///     same filter twice.
    ///   - flags: BIP 37's update flags. The default, 1, has peers add every
    ///     output that matches to their copy of the filter, so that a later
    ///     transaction spending it matches too — even one in the same
    ///     batch of blocks, before the wallet could have asked.
    ///   - startHeight: The first block to scan
    public func configureBloomFilter(
        elements: [Data],
        falsePositiveRate: Double = 0.001,
        tweak: UInt32 = UInt32.random(in: 0...UInt32.max),
        flags: UInt8 = 1,
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

        let replacesAFilter = bloomFilter != nil
        bloomFilter = filter
        filterGeneration += 1
        let generation = filterGeneration
        watchedElements = Set(elements)
        // What was nobody's under the old filter may be the wallet's now.
        irrelevantTransactions.clear()
        nextFilteredHeight = max(Int32(0), startHeight)
        reportedScanHeight = nil
        resetFilteredBlocksInFlight()
        // Nobody has this filter yet, so nobody is asked for blocks yet.
        peersWithFilter.removeAll()
        filterBarriers.removeAll()

        // Only peers that serve filtered blocks are of use from here on.
        await peerManager.requireServices(requiredServices)

        for peer in await peerManager.connectedPeers {
            guard filterGeneration == generation else { return }
            await peer.sendFilterLoad(filter)
            guard filterGeneration == generation else { return }

            if replacesAFilter {
                // Answers made with the old filter may still be on their way.
                let barrier = PingMessage()
                filterBarriers[peer.id] = barrier.nonce
                await peer.send(ProtocolMessage(network: network, command: ProtocolMessage.Command.ping, payload: barrier.serialize()))
            } else {
                peersWithFilter.insert(peer.id)
            }
        }

        await requestFilteredBlocksIfNeeded()
    }

    /// Add an element to the active bloom filter
    public func addBloomFilterElement(_ element: Data) async {
        guard bloomFilter != nil else { return }
        bloomFilter?.insert(element)
        watchedElements.insert(element)
        irrelevantTransactions.clear()

        // Peers still waiting for the filter get this element with it.
        for peer in await peerManager.connectedPeers where peersWithFilter.contains(peer.id) || filterBarriers[peer.id] != nil {
            await peer.sendFilterAdd(element: element)
        }
    }

    /// A peer has answered the ping that followed a new filter: everything
    /// it sends from here on was made with that filter.
    private func handlePong(_ pong: PongMessage, from peer: Peer) async {
        guard filterBarriers[peer.id] == pong.nonce else { return }
        filterBarriers[peer.id] = nil
        peersWithFilter.insert(peer.id)
        await requestFilteredBlocksIfNeeded()
    }

    // MARK: - Filtered Block Scan

    /// Asks for more filtered blocks when few enough are in flight. Calls
    /// that arrive while one is at work are not lost: it goes round again.
    private func requestFilteredBlocksIfNeeded() async {
        guard !isRequestingFilteredBlocks else {
            wantsFilteredBlocks = true
            return
        }

        isRequestingFilteredBlocks = true
        defer { isRequestingFilteredBlocks = false }

        repeat {
            wantsFilteredBlocks = false
            do {
                try await requestFilteredBlocks()
            } catch {
                await fail(error)
                return
            }
        } while wantsFilteredBlocks
    }

    private func requestFilteredBlocks() async throws {
        guard isActive,
              let nextHeight = nextFilteredHeight,
              bloomFilter != nil,
              filteredBlocksInFlight.count <= Self.filteredBlockLowWaterMark else {
            return
        }

        let chainHeight = await headerChain.height
        guard nextHeight <= chainHeight else {
            // Caught up. Blocks still in flight report as they complete.
            if filteredBlocksInFlight.isEmpty {
                reportScanProgress()
            }
            return
        }

        // Blocks in flight stay with the peer serving them.
        let windowPeer = filteredWindowPeer
        guard let peer = await filteredBlockPeer(keeping: windowPeer) else { return }

        var requested: [(hash: Data, height: Int32)] = []
        var height = nextHeight
        while height <= chainHeight,
              filteredBlocksInFlight.count + requested.count < Self.maximumFilteredBlocksInFlight {
            guard let stored = try await headerChain.getHeader(height: height) else {
                // The chain was replaced below its old height meanwhile.
                break
            }
            requested.append((stored.header.hash, height))
            height += 1
        }

        // A timeout, disconnect, or filter change while the range was read
        // has moved the scan; this request would be stale. Whatever moved
        // it has asked for another round.
        guard !requested.isEmpty,
              isActive,
              nextFilteredHeight == nextHeight,
              filteredWindowPeer == windowPeer else {
            return
        }

        let now = ContinuousClock.now
        nextFilteredHeight = height
        for block in requested {
            filteredBlocksInFlight[block.hash] = FilteredBlockRequest(height: block.height, requestedAt: now)
        }
        filteredWindowPeer = peer

        await peer.sendGetData(inventory: requested.map { InventoryVector(type: .filteredBlock, hash: $0.hash) })
    }

    /// The peer to ask for filtered blocks: the one already serving some,
    /// or else the peer being followed, or any other — of those that hold
    /// the filter and have not said they lack the blocks.
    private func filteredBlockPeer(keeping windowPeer: Peer?) async -> Peer? {
        if let windowPeer {
            return windowPeer
        }
        let candidates = await peerManager.connectedPeers.filter {
            peersWithFilter.contains($0.id) && !peersUnableToServeBlocks.contains($0.id)
        }
        if let syncPeer, candidates.contains(syncPeer) {
            return syncPeer
        }
        return candidates.randomElement()
    }

    /// Forgets the filtered blocks in flight after their peer is lost and
    /// rewinds the scan to the lowest of them, so the next peer re-requests
    /// every block that never arrived — or arrived without the transactions
    /// it named.
    private func abandonFilteredBlocksInFlight(reason: String) {
        guard let lowest = filteredBlocksInFlight.values.map(\.height).min() else {
            filteredWindowPeer = nil
            return
        }
        nextFilteredHeight = nextFilteredHeight.map { min($0, lowest) }
        logger.info("Abandoning \(self.filteredBlocksInFlight.count) filtered blocks in flight (\(reason)); rewinding to height \(self.nextFilteredHeight ?? -1)")
        resetFilteredBlocksInFlight()
    }

    private func resetFilteredBlocksInFlight() {
        filteredBlocksInFlight.removeAll()
        awaitedTransactionBlocks.removeAll()
        filteredWindowPeer = nil
    }

    /// A block in flight has its merkle block and all its transactions.
    private func completeFilteredBlock(_ blockHash: Data) {
        guard filteredBlocksInFlight.removeValue(forKey: blockHash) != nil else { return }
        if filteredBlocksInFlight.isEmpty {
            filteredWindowPeer = nil
        }
        reportScanProgress()
    }

    /// Tells the delegate how far the scan has got without a gap: just
    /// below the lowest block still in flight, or the next one to ask for.
    private func reportScanProgress() {
        guard bloomFilter != nil, let nextHeight = nextFilteredHeight else { return }

        let scanned = (filteredBlocksInFlight.values.map(\.height).min() ?? nextHeight) - 1
        guard scanned != reportedScanHeight else { return }
        reportedScanHeight = scanned
        // Only the latest height matters to a delegate that has fallen
        // behind — as long as it still comes after every transaction found
        // before it, which taking the place of the last event waiting keeps
        // true.
        delegateEvents.yield(.scanned(through: scanned, targetHeight: _targetHeight)) { waiting in
            if case .scanned = waiting { true } else { false }
        }
    }

    // MARK: - Header Sync

    /// Sends `getheaders` to `peer` and follows it from now on. At most one
    /// request is outstanding at a time.
    private func requestHeaders(from peer: Peer) async {
        guard isActive, headerRequest == nil else { return }

        if syncPeer != peer {
            slowHeaderReplies = 0
        }
        let request = HeaderRequest(peer: peer, sentAt: .now)
        syncPeer = peer
        headerRequest = request

        let locator: [Data]
        do {
            locator = try await headerChain.getBlockLocator()
        } catch {
            await fail(error)
            return
        }

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
                await didAddHeaders(result, from: peer)
            }
            return
        }

        headerRequest = nil
        let replyWasSlow = ContinuousClock.now - request.sentAt > timing.slowHeaderReply

        guard !entries.isEmpty else {
            logger.info("No more headers from \(peer.host)")

            let chainHeight = await headerChain.height
            guard isFollowing(peer) else { return }

            if chainHeight >= _targetHeight {
                await considerSynchronized(at: chainHeight)
            } else {
                logger.info("Still below target height (\(chainHeight) < \(self._targetHeight)), trying another peer")
                abandonSyncPeer(peer)
            }
            return
        }

        logger.info("Received \(entries.count) headers from \(peer.host)")

        let result = await headerChain.addHeaders(entries)
        guard await didAddHeaders(result, from: peer) else {
            if let failure = result.failure, Self.isBannable(failure) {
                await retryWithNextPeer(avoiding: peer)
            } else {
                // The cause may be on this side — a wrong clock, a full
                // disk — and then every peer's headers fail alike. Asking
                // the next peer at once would loop at network speed, so
                // the periodic check picks one instead.
                abandonSyncPeer(peer)
            }
            return
        }

        guard isFollowing(peer) else { return }
        let chainHeight = await headerChain.height

        if entries.count >= HeadersMessage.maximumEntries {
            // A full message means the peer has more, whatever height peers
            // announced when they connected. But a peer that takes its time
            // over every one of them could hold the sync back for days.
            slowHeaderReplies = replyWasSlow ? slowHeaderReplies + 1 : 0
            if slowHeaderReplies >= Self.slowHeaderRepliesTolerated, await peerManager.connectedPeerCount > 1 {
                logger.info("\(peer.host) answers too slowly; continuing with another peer")
                abandonSyncPeer(peer)
            } else {
                syncState = .syncing
                await requestHeaders(from: peer)
            }
        } else if chainHeight >= _targetHeight {
            await considerSynchronized(at: chainHeight)
        } else {
            // A message that is not full is all the peer has, and it falls
            // short. Asking it again would only get a header at a time out
            // of a peer that lags — or that means to keep us waiting.
            logger.info("\(peer.host) has no more headers and the chain is still below its target")
            abandonSyncPeer(peer)
        }
    }

    /// Follows up on a batch of headers: what it added, and what it proved
    /// about its sender.
    /// - Returns: Whether the whole batch was accepted
    @discardableResult
    private func didAddHeaders(_ result: HeaderChain.BatchResult, from peer: Peer) async -> Bool {
        if result.added > 0 {
            await chainDidGrow(replacingChainAbove: result.forkHeight)
        }

        guard let failure = result.failure else { return true }

        if case .databaseError(let error) = failure {
            await fail(error)
        } else if Self.isBannable(failure) {
            logger.warning("Banning \(peer.host) for invalid headers: \(String(describing: failure))")
            await peerManager.banPeer(peer, reason: .invalidHeaders)
        } else {
            logger.warning("Headers from \(peer.host) were not accepted: \(String(describing: failure))")
        }
        return false
    }

    /// Brings transaction state and the delegate up to date after headers
    /// extended the chain or — when `forkHeight` is set — replaced the part
    /// of it above that height.
    private func chainDidGrow(replacingChainAbove forkHeight: Int32?) async {
        // Before anything is confirmed: a transaction leaves its old block
        // here and may enter its new one in the very next step.
        if let forkHeight {
            await handleReorganization(above: forkHeight)
        }

        let chainHeight = await headerChain.height
        updateTargetHeight(chainHeight: chainHeight)
        forgetTransactionsBelowHorizon(chainHeight: chainHeight)

        await requestFilteredBlocksIfNeeded()
        delegateEvents.yield(.progress(Self.computeProgress(height: chainHeight, target: _targetHeight), height: chainHeight)) { waiting in
            if case .progress = waiting { true } else { false }
        }
    }

    /// The chain has caught up with the peer being followed. With another
    /// peer connected to contradict it, that is reported at once; on one
    /// peer's word alone, only after others have had a moment to connect —
    /// the one peer may be the one that lags.
    private func considerSynchronized(at height: Int32) async {
        if syncState == .synchronized {
            markSynchronized(at: height)
        } else if await peerManager.connectedPeerCount >= Self.peersForCompletion {
            guard isActive, headerRequest == nil else { return }
            markSynchronized(at: height)
        } else if completionPendingSince == nil {
            completionPendingSince = .now
        }
    }

    /// Reports a completion that was waiting for a second opinion, if the
    /// chain still looks complete and nothing is being asked.
    /// - Parameter waited: Whether the wait for another peer is over
    private func settlePendingCompletion(waited: Bool) async {
        guard completionPendingSince != nil, isActive, headerRequest == nil else { return }

        let chainHeight = await headerChain.height
        let peerCount = await peerManager.connectedPeerCount
        guard completionPendingSince != nil, isActive, headerRequest == nil,
              chainHeight >= _targetHeight,
              waited || peerCount >= Self.peersForCompletion else {
            return
        }
        markSynchronized(at: chainHeight)
    }

    /// Reports completion when the chain catches up and again each time it
    /// has grown since — delegates record the synced height from it — but
    /// not when a peer merely confirms there is nothing new.
    private func markSynchronized(at height: Int32) {
        let isNews = syncState != .synchronized || lastSynchronizedHeight != height
        syncState = .synchronized
        lastSynchronizedHeight = height
        completionPendingSince = nil
        if isNews {
            delegateEvents.yield(.completed)
        }
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

    /// The median of connected peers' announced heights — one peer claiming
    /// an absurd height cannot keep the sync from ever finishing — and never
    /// less than the height the chain itself has reached with blocks peers
    /// announced since.
    private func updateTargetHeight(chainHeight: Int32) {
        let heights = peerStartHeights.values.sorted()
        let median = heights.isEmpty ? 0 : heights[(heights.count - 1) / 2]
        _targetHeight = max(median, chainHeight, 0)
    }
}

// MARK: - PeerManagerDelegate

extension SPVSyncManager: PeerManagerDelegate {
    public func peerManager(_ manager: PeerManager, peerDidBecomeReady peer: Peer) async {
        logger.info("Peer ready: \(peer.host)")
        guard isActive else { return }

        if let version = await peer.peerVersion {
            peerStartHeights[peer.id] = version.startHeight
        }
        let chainHeight = await headerChain.height
        guard isActive else { return }
        updateTargetHeight(chainHeight: chainHeight)

        // The filter first: nothing asked of this peer afterwards may be
        // answered without it. A peer new to the connection has nothing an
        // older filter produced still to send.
        // (Unless a filter set just now has reached it already.)
        if let filter = bloomFilter, !peersWithFilter.contains(peer.id), filterBarriers[peer.id] == nil {
            let generation = filterGeneration
            await peer.sendFilterLoad(filter)
            if filterGeneration == generation, isActive {
                peersWithFilter.insert(peer.id)
            }
        }

        // Follow this peer if the sync has nobody to follow — at the start,
        // or after every earlier peer was lost — or if it says its chain is
        // longer than ours. The peer being followed may be the one that is
        // behind.
        let announcedHeight = peerStartHeights[peer.id] ?? 0
        if isActive, headerRequest == nil, syncPeer == nil || announcedHeight > chainHeight {
            if syncState == .connecting {
                syncState = .syncing
            }
            await requestHeaders(from: peer)
        } else {
            // A second peer that has nothing to add settles a completion
            // that was waiting for one.
            await settlePendingCompletion(waited: false)
        }

        await requestFilteredBlocksIfNeeded()
    }

    public func peerManager(_ manager: PeerManager, peerDidDisconnect peer: Peer) async {
        logger.info("Peer disconnected: \(peer.host)")

        peerStartHeights.removeValue(forKey: peer.id)
        peersUnableToServeBlocks.remove(peer.id)
        peersWithFilter.remove(peer.id)
        filterBarriers[peer.id] = nil

        guard isActive else { return }
        updateTargetHeight(chainHeight: await headerChain.height)

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
        guard isActive else { return }

        do {
            switch message.command {
            case ProtocolMessage.Command.headers:
                if let headersMsg = HeadersMessage.parse(from: message.payload) {
                    await handleHeaders(headersMsg.entries, from: peer)
                } else {
                    await peerManager.banPeer(peer, reason: .invalidMessage)
                }

            case ProtocolMessage.Command.inv:
                if let invMsg = InvMessage.parse(from: message.payload) {
                    try await handleInventory(invMsg.inventory, from: peer)
                }

            case ProtocolMessage.Command.merkleblock:
                if let merkleBlock = MerkleBlockMessage.parse(from: message.payload) {
                    try await handleMerkleBlock(merkleBlock, from: peer)
                } else {
                    await peerManager.banPeer(peer, reason: .invalidMessage)
                }

            case ProtocolMessage.Command.tx:
                if let txMessage = TxMessage.parse(from: message.payload) {
                    await handleTransaction(txMessage, from: peer)
                } else {
                    await peerManager.banPeer(peer, reason: .invalidTransaction)
                }

            case ProtocolMessage.Command.notfound:
                if let notFound = NotFoundMessage.parse(from: message.payload) {
                    await handleNotFound(notFound.inventory, from: peer)
                }

            case ProtocolMessage.Command.pong:
                if let pong = PongMessage.parse(from: message.payload) {
                    await handlePong(pong, from: peer)
                }

            default:
                break
            }
        } catch {
            // Only reading the header database throws here.
            await fail(error)
        }
    }

    public func peerManager(_ manager: PeerManager, connectedPeerCountChanged count: Int) async {
        logger.info("Connected peers: \(count)")
    }

    // MARK: Announcements

    private func handleInventory(_ inventory: [InventoryVector], from peer: Peer) async throws {
        // Without a bloom filter nothing can match the wallet; fetching
        // announced transactions would only waste bandwidth.
        if bloomFilter != nil {
            // Each transaction is asked for once, of the first peer that
            // announces it — unless that request is old enough to have
            // been lost.
            let now = ContinuousClock.now
            var wanted: [InventoryVector] = []
            for item in inventory.lazy.filter({ $0.type == .transaction }).prefix(Self.announcedTransactionsFetched) {
                let txid = item.hash
                if let requested = requestedTransactions.get(txid), now - requested < Self.transactionRequestLifetime {
                    continue
                }
                guard verifiedTransactions[txid] == nil,
                      !pendingTransactions.contains(txid),
                      !irrelevantTransactions.contains(txid) else {
                    continue
                }
                requestedTransactions.set(txid, now)
                wanted.append(item)
            }
            if !wanted.isEmpty {
                await peer.sendGetData(inventory: wanted)
            }
        }

        // An announced block is not fetched here. Its header is — and once
        // the chain has it, the scan asks for the block, once, of one peer.
        let blocks = inventory.filter { $0.type == .block }
        if !blocks.isEmpty {
            logger.debug("Received inventory with \(blocks.count) blocks")
            try await followAnnouncement(of: blocks, from: peer)
        }
    }

    /// Asks `peer` for headers when it announces a block this chain lacks.
    ///
    /// Only the peer being followed used to be asked. If that one stopped
    /// announcing blocks — stalled, or simply behind — the chain stayed at
    /// its tip for as long as it remained connected, whatever every other
    /// peer announced.
    private func followAnnouncement(of blocks: [InventoryVector], from peer: Peer) async throws {
        // Mid-sync, the peer being followed is already delivering the chain.
        guard isActive, headerRequest == nil,
              syncPeer == nil || syncPeer == peer || syncState == .synchronized else {
            return
        }

        // The newest block comes last.
        for block in blocks.suffix(Self.announcedBlocksChecked).reversed() {
            if try await headerChain.getHeader(hash: block.hash) == nil {
                await requestHeaders(from: peer)
                return
            }
        }
    }

    /// A peer does not have something it was asked for.
    private func handleNotFound(_ inventory: [InventoryVector], from peer: Peer) async {
        var lacksBlocks = false
        for item in inventory {
            switch item.type {
            case .transaction:
                requestedTransactions.remove(item.hash)
            case .filteredBlock, .block:
                lacksBlocks = lacksBlocks || (peer == filteredWindowPeer && filteredBlocksInFlight[item.hash] != nil)
            case .error:
                break
            }
        }

        guard lacksBlocks else { return }

        // It serves headers but not the blocks under them. Leave it
        // connected, and ask someone else from here on.
        logger.info("\(peer.host) does not have the filtered blocks it was asked for")
        peersUnableToServeBlocks.insert(peer.id)
        abandonFilteredBlocksInFlight(reason: "\(peer.host) lacks the blocks")
        await requestFilteredBlocksIfNeeded()
    }

    // MARK: Merkle Blocks

    private func handleMerkleBlock(_ merkleBlock: MerkleBlockMessage, from peer: Peer) async throws {
        let blockHash = merkleBlock.header.hash

        // Only a block the scan asked this peer for, and only once. Asked
        // for by hash, its header is the one the chain holds.
        guard peer == filteredWindowPeer,
              let request = filteredBlocksInFlight[blockHash],
              request.awaitedTransactions == nil else {
            return
        }

        let matches: MerkleBlockMatches
        do {
            matches = try merkleBlock.extractMatches()
        } catch {
            logger.warning("Banning \(peer.host) for a malformed merkle proof")
            await peerManager.banPeer(peer, reason: .invalidTransaction)
            return
        }

        guard matches.merkleRoot == merkleBlock.header.merkleRoot else {
            logger.warning("Banning \(peer.host) for a merkle proof that does not match its block")
            await peerManager.banPeer(peer, reason: .invalidTransaction)
            return
        }

        guard matches.matchedHashes.count <= Self.maximumMatchesPerBlock else {
            logger.warning("Banning \(peer.host) for a merkle block with \(matches.matchedHashes.count) matches")
            await peerManager.banPeer(peer, reason: .protocolViolation)
            return
        }

        let isOnBestChain = try await headerChain.isHeaderInBestChain(blockHash)

        // The scan may have moved on during the lookup.
        guard peer == filteredWindowPeer,
              var request = filteredBlocksInFlight[blockHash],
              request.awaitedTransactions == nil else {
            return
        }

        guard isOnBestChain else {
            // Replaced while in flight. The reorganization that replaced it
            // sends the scan back to the fork.
            filteredBlocksInFlight[blockHash] = nil
            if filteredBlocksInFlight.isEmpty {
                filteredWindowPeer = nil
            }
            return
        }

        var awaited: Set<Data> = []
        var confirmed: [TxMessage] = []
        for txid in matches.matchedHashes where verifiedTransactions[txid] == nil {
            if let held = pendingTransactions.get(txid) {
                confirmed.append(held)
            } else if !irrelevantTransactions.contains(txid) {
                awaited.insert(txid)
                awaitedTransactionBlocks[txid] = blockHash
            }
        }

        request.awaitedTransactions = awaited
        filteredBlocksInFlight[blockHash] = request

        for transaction in confirmed {
            await confirm(transaction, inBlock: blockHash, height: request.height)
        }

        if awaited.isEmpty {
            completeFilteredBlock(blockHash)
            await requestFilteredBlocksIfNeeded()
        }
    }

    /// Records a transaction as confirmed and reports it.
    private func confirm(_ transaction: TxMessage, inBlock blockHash: Data, height: Int32) async {
        let txid = transaction.txidInternal
        verifiedTransactions[txid] = VerifiedTransaction(transaction: transaction, blockHash: blockHash, height: height)
        pendingTransactions.remove(txid)
        await forgetOwnTransaction(txid)
        delegateEvents.yield(.transaction(transaction, .confirmed(blockHash: blockHash, height: height)))
    }

    // MARK: Transactions

    private func handleTransaction(_ txMessage: TxMessage, from peer: Peer) async {
        // Whatever arrives here is hashed, and may be kept and handed to
        // the wallet.
        guard let decoded = Self.decodeRelayedTransaction(txMessage.rawData) else {
            logger.warning("Banning \(peer.host) for a malformed transaction")
            await peerManager.banPeer(peer, reason: .invalidTransaction)
            return
        }

        let txid = txMessage.txidInternal
        let wasRequested = requestedTransactions.remove(txid) != nil
        let owingBlock = awaitedTransactionBlocks.removeValue(forKey: txid)

        // A node sends a transaction when asked for it, or after the merkle
        // block that names it. Anything else was not asked for and proves
        // nothing: taking it would let any peer fill the wallet's memory —
        // or its history — with whatever it liked.
        guard wasRequested || owingBlock != nil else {
            logger.debug("Dropping a transaction \(peer.host) sent unasked")
            return
        }

        // The bloom filter lets through what it was never given. Only what
        // the wallet really watches is the wallet's.
        let isRelevant = verifiedTransactions[txid] == nil && watch(decoded, txid: txid)
        if !isRelevant, verifiedTransactions[txid] == nil {
            irrelevantTransactions.set(txid, true)
        }

        if let blockHash = owingBlock, var request = filteredBlocksInFlight[blockHash] {
            request.awaitedTransactions?.remove(txid)
            filteredBlocksInFlight[blockHash] = request

            if isRelevant {
                await confirm(txMessage, inBlock: blockHash, height: request.height)
            }
            if request.awaitedTransactions?.isEmpty == true {
                completeFilteredBlock(blockHash)
                await requestFilteredBlocksIfNeeded()
            }
        } else if isRelevant, !pendingTransactions.contains(txid) {
            pendingTransactions.set(txid, txMessage)
            delegateEvents.yield(.transaction(txMessage, .unconfirmed))
        }
    }

    /// Whether `transaction` is the wallet's — and if it pays the wallet,
    /// starts watching the outputs that do, as peers given
    /// `BLOOM_UPDATE_ALL` start matching them: a transaction that spends
    /// one is the wallet's as well.
    private func watch(_ transaction: RawTransaction, txid: Data) -> Bool {
        let match = Self.match(transaction, txid: txid, isWatched: watchedElements.contains)
        guard match.isMatch else { return false }

        if let flags = bloomFilter?.flags, flags & 3 == 1 {
            for index in match.matchedOutputs {
                let outpoint = Self.outpoint(txid: txid, index: UInt32(index))
                watchedElements.insert(outpoint)
                // New peers are sent this copy of the filter.
                bloomFilter?.insert(outpoint)
            }
        }
        return true
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
        return match(transaction, txid: MerkleTree.doubleSHA256(raw), isWatched: filter.contains).isMatch
    }

    /// Tests `transaction` as BIP 37 has a node test it: the txid, every
    /// data push in every output script, every outpoint spent, and every
    /// data push in every input script.
    ///
    /// Whole output scripts are tested as well. No node does that, but a
    /// caller that watches scripts expects them to match here.
    /// - Parameters:
    ///   - txid: The transaction id in internal byte order
    ///   - isWatched: Whether an element is one being looked for
    /// - Returns: Whether anything matched, and which outputs did
    nonisolated static func match(
        _ transaction: RawTransaction,
        txid: Data,
        isWatched: (Data) -> Bool
    ) -> (isMatch: Bool, matchedOutputs: [Int]) {
        let matchedOutputs = transaction.outputs.indices.filter { index in
            let script = transaction.outputs[index].script
            return isWatched(script) || anyDataPush(in: script, satisfies: isWatched)
        }

        if !matchedOutputs.isEmpty || isWatched(txid) {
            return (true, matchedOutputs)
        }

        let spendsOrSigns = transaction.inputs.contains { input in
            isWatched(outpoint(txid: input.previousTxid, index: input.previousIndex))
                || anyDataPush(in: input.script, satisfies: isWatched)
        }
        return (spendsOrSigns, [])
    }

    /// An outpoint as it is serialized, and as filters hold it: the txid in
    /// internal byte order, then the output index.
    nonisolated private static func outpoint(txid: Data, index: UInt32) -> Data {
        var outpoint = txid
        withUnsafeBytes(of: index.littleEndian) { outpoint.append(contentsOf: $0) }
        return outpoint
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

    // MARK: Reorganization

    /// The best chain above `forkHeight` was replaced.
    ///
    /// Transactions confirmed in the blocks that lost go back to waiting:
    /// the block that replaced theirs usually holds them too, and they can
    /// only be confirmed in it while their bytes are still at hand. The
    /// scan returns to the fork, because peers announce just the new tip —
    /// the blocks beneath it on the new branch would never be fetched.
    private func handleReorganization(above forkHeight: Int32) async {
        for (txid, verified) in verifiedTransactions.filter({ $0.value.height > forkHeight }) {
            let isStillConfirmed: Bool
            do {
                isStillConfirmed = try await headerChain.isHeaderInBestChain(verified.blockHash)
            } catch {
                await fail(error)
                return
            }
            guard !isStillConfirmed, verifiedTransactions[txid]?.blockHash == verified.blockHash else {
                continue
            }

            verifiedTransactions.removeValue(forKey: txid)
            pendingTransactions.set(txid, verified.transaction)
            delegateEvents.yield(.transaction(
                verified.transaction,
                .reorged(previousBlockHash: verified.blockHash, previousHeight: verified.height)
            ))
        }

        guard let nextHeight = nextFilteredHeight, nextHeight > forkHeight + 1 else { return }

        logger.info("Chain reorganized above height \(forkHeight); rescanning from there")
        let replaced = filteredBlocksInFlight.filter { $0.value.height > forkHeight }.keys
        for blockHash in replaced {
            filteredBlocksInFlight[blockHash] = nil
        }
        awaitedTransactionBlocks = awaitedTransactionBlocks.filter { filteredBlocksInFlight[$0.value] != nil }
        if filteredBlocksInFlight.isEmpty {
            filteredWindowPeer = nil
        }
        nextFilteredHeight = forkHeight + 1
        reportScanProgress()
    }

    /// Stops remembering confirmations too deep to be reorganized away.
    private func forgetTransactionsBelowHorizon(chainHeight: Int32) {
        let horizon = chainHeight - Self.reorganizationHorizon
        guard verifiedTransactions.count > 256, horizon > 0 else { return }
        verifiedTransactions = verifiedTransactions.filter { $0.value.height >= horizon }
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
    func spvSync(_ manager: SPVSyncManager, didScanThrough height: Int32, targetHeight: Int32) async {}
}
