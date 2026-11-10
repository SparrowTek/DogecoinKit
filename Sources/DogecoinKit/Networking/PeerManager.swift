import Foundation
#if canImport(Android)
import Android
#endif
#if canImport(os)
import os.log
#endif

/// Delegate for peer manager events
public protocol PeerManagerDelegate: AnyObject, Sendable {
    /// Called when a peer becomes ready
    func peerManager(_ manager: PeerManager, peerDidBecomeReady peer: Peer) async

    /// Called when a peer disconnects
    func peerManager(_ manager: PeerManager, peerDidDisconnect peer: Peer) async

    /// Called when a message is received from any peer
    func peerManager(_ manager: PeerManager, peer: Peer, didReceiveMessage message: ProtocolMessage) async

    /// Called when the number of connected peers changes
    func peerManager(_ manager: PeerManager, connectedPeerCountChanged count: Int) async
}

/// Manages connections to multiple peers
public actor PeerManager {
    /// The network to connect to
    public nonisolated let network: DogecoinNetwork

    /// Delegate for events
    public weak var delegate: (any PeerManagerDelegate)?

    /// Set the delegate (for cross-actor assignment)
    public func setDelegate(_ delegate: (any PeerManagerDelegate)?) {
        self.delegate = delegate
    }

    /// Minimum number of peer connections to maintain
    public var minPeerConnections: Int = 3

    /// Maximum number of peer connections
    public var maxPeerConnections: Int = 8

    /// All known peers
    private var peers: [Peer] = []

    /// Addresses discovered from DNS seeds and peers
    private var discoveredAddresses: [String: UInt16] = [:]

    private struct PeerHistory: Sendable {
        var score: Int = 0
        var consecutiveFailures: Int = 0
        var backoffUntil: Date?
    }

    private var peerHistory: [String: PeerHistory] = [:]

    /// Banned peer addresses with ban expiration time
    private var bannedPeers: [String: Date] = [:]

    /// Ban duration in seconds (default: 24 hours)
    public var banDuration: TimeInterval = 86400

    /// Misbehavior score that triggers a ban
    public var misbehaviorBanThreshold: Int = 100

    /// Base backoff delay after failures
    public var baseBackoff: TimeInterval = 30

    /// Maximum backoff delay
    public var maxBackoff: TimeInterval = 3600

    /// Sets connection limits — actor properties cannot be assigned from
    /// outside the actor, so this is the way to change them.
    public func configure(minPeerConnections: Int? = nil, maxPeerConnections: Int? = nil) {
        if let minPeerConnections {
            self.minPeerConnections = max(0, minPeerConnections)
        }
        if let maxPeerConnections {
            self.maxPeerConnections = max(1, maxPeerConnections)
        }
    }

    /// UserDefaults key for persisted banned peers
    private static let bannedPeersKey = "DogecoinKit.bannedPeers"

    /// Logger
    private let logger = Logger(subsystem: "DogecoinKit", category: "PeerManager")

    /// Timer task for maintenance
    private var maintenanceTask: Task<Void, Never>?

    /// DNS seed discovery, cancelled by `stop()`
    private var discoveryTask: Task<Void, Never>?

    /// Between `start()` and `stop()`; only then are new peers dialed on our own
    private var isRunning = false

    /// Track ready/disconnected peer IDs locally to avoid N-await per peer
    private var readyPeerIDs: Set<UUID> = []
    private var disconnectedPeerIDs: Set<UUID> = []

    /// Sliding-window budget for `addr` messages. Caps how many entries a
    /// single peer can inject into the discovery table per minute, guarding
    /// against a hostile peer flooding random addresses.
    private struct AddrBudget: Sendable {
        static let windowInterval: TimeInterval = 60
        static let entriesPerWindow: Int = 1000

        var windowStart: Date
        var entriesThisWindow: Int

        static let initial = AddrBudget(windowStart: Date(), entriesThisWindow: 0)
    }
    private var addrBudgetByPeer: [UUID: AddrBudget] = [:]

    /// A transaction on offer to peers
    private struct Announcement {
        let transaction: TxMessage
        /// Counts the times the transaction was announced, so the end of an
        /// earlier announcement's window leaves a later one alone
        var generation = 0
        var wasFetched = false
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }

    /// Transactions announced to peers, by txid in internal byte order
    private var announcements: [Data: Announcement] = [:]

    /// How long a broadcast waits for a peer to ask for the transaction
    private let broadcastTimeout: Duration

    /// How long an announced transaction stays on offer
    private let announcementLifetime: Duration = .seconds(60)

    private let makeStream: ByteStreamFactory
    private let dnsSeeds: [String]
    /// Dialed when no DNS seed yields a working peer
    private let fallbackNodes: [(host: String, port: UInt16)]
    /// Where bans persist across launches; nil keeps them in memory only
    private let banStore: UserDefaults?

    /// Number of connected peers
    public var connectedPeerCount: Int {
        peers.filter { readyPeerIDs.contains($0.id) }.count
    }

    /// All connected peers
    public var connectedPeers: [Peer] {
        peers.filter { readyPeerIDs.contains($0.id) }
    }

    /// Reasons for banning a peer
    public enum BanReason: String, Sendable {
        case invalidHeaders = "Sent invalid block headers"
        case invalidTransaction = "Sent invalid transaction"
        case invalidMessage = "Sent malformed protocol message"
        case dosAttack = "Suspected denial-of-service attack"
        case timeout = "Connection timeout or unresponsive"
        case protocolViolation = "Protocol violation"
        case manual = "Manually banned"
    }

    /// Create a peer manager
    public init(network: DogecoinNetwork = .mainnet) {
        self.init(
            network: network,
            streamFactory: defaultByteStreamFactory,
            dnsSeeds: NetworkConstants.seeds(for: network),
            fallbackNodes: network == .mainnet ? NetworkConstants.mainnetFallbackNodes : []
        )
    }

    init(
        network: DogecoinNetwork,
        streamFactory: @escaping ByteStreamFactory,
        dnsSeeds: [String],
        fallbackNodes: [(host: String, port: UInt16)],
        banStore: UserDefaults? = .standard,
        broadcastTimeout: Duration = .seconds(15)
    ) {
        self.network = network
        self.makeStream = streamFactory
        self.dnsSeeds = dnsSeeds
        self.fallbackNodes = fallbackNodes
        self.banStore = banStore
        self.broadcastTimeout = broadcastTimeout

        // Inline banned peer loading (can't call actor-isolated methods from init)
        if let data = banStore?.data(forKey: Self.bannedPeersKey),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            let now = Date()
            self.bannedPeers = decoded.filter { $0.value > now }
        }
    }

    /// Start the peer manager
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        logger.info("Starting peer manager for \(self.network == .mainnet ? "mainnet" : "testnet")")
        discoverPeers()
        startMaintenanceTask()
    }

    /// Stop the peer manager
    public func stop() async {
        logger.info("Stopping peer manager")
        isRunning = false
        maintenanceTask?.cancel()
        maintenanceTask = nil
        discoveryTask?.cancel()
        discoveryTask = nil

        let allPeers = peers
        for peer in allPeers {
            await peer.disconnect()
        }

        peers.removeAll()
        readyPeerIDs.removeAll()
        disconnectedPeerIDs.removeAll()
    }

    /// Add a peer by address
    public func addPeer(host: String, port: UInt16? = nil) async {
        let peer = Peer(host: host, port: port, network: network, streamFactory: makeStream)
        await addPeer(peer)
    }

    /// Add a peer instance
    public func addPeer(_ peer: Peer) async {
        // Don't connect to banned peers
        if isHostBanned(peer.host) {
            logger.debug("Not connecting to banned peer \(peer.host)")
            return
        }

        guard !isHostBackedOff(peer.host) else {
            logger.debug("Backoff active for peer \(peer.host)")
            return
        }

        guard !peers.contains(where: { $0.host == peer.host && $0.port == peer.port }) else {
            return
        }
        peers.append(peer)

        await peer.setDelegate(self)
        await peer.connect()
    }

    /// Remove a peer
    public func removePeer(_ peer: Peer) async {
        peers.removeAll { $0 == peer }
        addrBudgetByPeer.removeValue(forKey: peer.id)
        await peer.disconnect()
        // Disconnecting reports `.disconnected`, which tells the delegate;
        // this covers a peer that was already down.
        await peerWentDown(peer)
    }

    /// Records that `peer` is gone and, if it had been ready, tells the
    /// delegate — exactly once, however the peer was lost.
    private func peerWentDown(_ peer: Peer) async {
        disconnectedPeerIDs.insert(peer.id)
        guard readyPeerIDs.remove(peer.id) != nil else { return }
        let count = connectedPeerCount
        await delegate?.peerManager(self, peerDidDisconnect: peer)
        await delegate?.peerManager(self, connectedPeerCountChanged: count)
    }

    // MARK: - Peer Banning

    /// Ban a peer for misbehavior
    public func banPeer(_ peer: Peer, reason: BanReason, duration: TimeInterval? = nil) async {
        let host = peer.host
        let banUntil = Date().addingTimeInterval(duration ?? banDuration)

        bannedPeers[host] = banUntil

        logger.warning("Banned peer \(host): \(reason.rawValue) until \(banUntil)")

        await removePeer(peer)
        saveBannedPeers()
    }

    /// Ban a peer by host address
    public func banHost(_ host: String, reason: BanReason, duration: TimeInterval? = nil) async {
        let banUntil = Date().addingTimeInterval(duration ?? banDuration)

        bannedPeers[host] = banUntil

        let peersToRemove = peers.filter { $0.host == host }
        for peer in peersToRemove {
            await removePeer(peer)
        }

        logger.warning("Banned host \(host): \(reason.rawValue) until \(banUntil)")
        saveBannedPeers()
    }

    /// Unban a peer
    public func unbanHost(_ host: String) {
        bannedPeers.removeValue(forKey: host)
        logger.info("Unbanned host \(host)")
        saveBannedPeers()
    }

    /// Check if a host is banned
    public func isHostBanned(_ host: String) -> Bool {
        guard let banExpiry = bannedPeers[host] else {
            return false
        }

        if banExpiry < Date() {
            bannedPeers.removeValue(forKey: host)
            return false
        }

        return true
    }

    /// Get all currently banned hosts
    public var bannedHosts: [String] {
        cleanExpiredBans()
        return Array(bannedPeers.keys)
    }

    /// Clear all bans
    public func clearAllBans() {
        bannedPeers.removeAll()
        logger.info("Cleared all peer bans")
        saveBannedPeers()
    }

    // MARK: - Ban Persistence

    private func saveBannedPeers() {
        let toSave = bannedPeers
        if let data = try? JSONEncoder().encode(toSave) {
            banStore?.set(data, forKey: Self.bannedPeersKey)
        }
    }

    @discardableResult
    private func cleanExpiredBans() -> Bool {
        let now = Date()
        let before = bannedPeers.count
        bannedPeers = bannedPeers.filter { $0.value > now }
        return bannedPeers.count != before
    }

    /// Broadcast a message to all connected peers
    public func broadcast(_ message: ProtocolMessage) async {
        for peer in connectedPeers {
            await peer.send(message)
        }
    }

    // MARK: - Transaction Broadcasting

    /// Broadcast a transaction to the network
    public func broadcastTransaction(_ rawHex: String) async throws -> String {
        guard let txMessage = TxMessage(rawHex: rawHex) else {
            throw DogecoinError.internalError("Invalid transaction hex")
        }

        return try await broadcastTransaction(txMessage)
    }

    /// Announces a transaction to every connected peer and waits until one
    /// of them has asked for it.
    ///
    /// An announcement only tells peers the transaction exists; it has left
    /// this device once a peer fetches it. Returning before that reported
    /// transactions as sent that no peer ever received. A peer that fetches
    /// a transaction may still decline to relay it.
    ///
    /// Cancelling the calling task does not withdraw the announcement: the
    /// call still ends, one way or the other, once a peer asks or the wait
    /// runs out.
    /// - Returns: The transaction id, in display byte order
    /// - Throws: `DogecoinError.noPeersAvailable` with no peer connected,
    ///   or `DogecoinError.broadcastFailed` when no peer asks for the
    ///   transaction in time — it is then no longer on offer
    public func broadcastTransaction(_ txMessage: TxMessage) async throws -> String {
        let readyPeers = connectedPeers
        guard !readyPeers.isEmpty else {
            throw DogecoinError.noPeersAvailable
        }

        let txid = txMessage.txidInternal
        let txidHex = txMessage.txidHex

        // Announcing a transaction again gives it a whole window of its own.
        var announcement = announcements[txid] ?? Announcement(transaction: txMessage)
        announcement.generation += 1
        let generation = announcement.generation
        announcements[txid] = announcement

        logger.info("Broadcasting transaction: \(txidHex)")

        let inv = InventoryVector(type: .transaction, hash: txid)

        for peer in readyPeers {
            await peer.sendInv(inventory: [inv])
        }

        Task { [weak self, announcementLifetime] in
            try? await Task.sleep(for: announcementLifetime)
            await self?.endAnnouncement(of: txid, generation: generation)
        }

        try await waitUntilFetched(txid)
        return txidHex
    }

    /// Returns once a peer has fetched the announced transaction.
    private func waitUntilFetched(_ txid: Data) async throws {
        guard let announcement = announcements[txid] else {
            throw DogecoinError.broadcastFailed("No peer asked for the transaction")
        }
        // A peer may have asked while the others were still being told.
        guard !announcement.wasFetched else { return }

        let waiter = UUID()
        let timeout = Task { [weak self, broadcastTimeout] in
            try? await Task.sleep(for: broadcastTimeout)
            guard !Task.isCancelled else { return }
            await self?.stopWaiting(waiter, for: txid)
        }
        defer { timeout.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            announcements[txid]?.waiters[waiter] = continuation
        }
    }

    /// The wait for a peer ran out. With nobody else waiting either, the
    /// transaction is taken off offer: one reported as failed must not go
    /// out afterwards.
    private func stopWaiting(_ waiter: UUID, for txid: Data) {
        guard var announcement = announcements[txid],
              let continuation = announcement.waiters.removeValue(forKey: waiter) else {
            return
        }
        announcements[txid] = announcement.waiters.isEmpty ? nil : announcement

        logger.error("No peer asked for transaction \(announcement.transaction.txidHex)")
        continuation.resume(throwing: DogecoinError.broadcastFailed("No peer asked for the transaction"))
    }

    private func endAnnouncement(of txid: Data, generation: Int) {
        guard let announcement = announcements[txid],
              announcement.generation == generation,
              announcement.waiters.isEmpty else {
            return
        }
        announcements[txid] = nil
    }

    /// Handle a getdata request from a peer
    internal func handleGetData(_ inventory: [InventoryVector], from peer: Peer) async {
        for item in inventory where item.type == .transaction {
            guard let transaction = announcements[item.hash]?.transaction else { continue }

            logger.info("Sending transaction \(transaction.txidHex) to peer \(peer.host)")
            guard await peer.sendTransaction(transaction) else { continue }
            markFetched(item.hash)
        }
    }

    private func markFetched(_ txid: Data) {
        guard var announcement = announcements[txid] else { return }

        let waiters = Array(announcement.waiters.values)
        announcement.wasFetched = true
        announcement.waiters = [:]
        announcements[txid] = announcement

        for waiter in waiters {
            waiter.resume()
        }
    }

    // MARK: - Private Methods

    private func discoverPeers() {
        let seeds = dnsSeeds
        let fallbackNodes = self.fallbackNodes
        let port = NetworkConstants.port(for: network)
        discoveryTask = Task { [weak self] in
            guard let self else { return }

            self.logger.info("Discovering peers from \(seeds.count) DNS seeds")

            // Resolve DNS seeds concurrently, connecting as each seed resolves
            // rather than waiting for all of them.
            await withTaskGroup(of: [String].self) { group in
                for seed in seeds {
                    group.addTask {
                        await Self.resolve(seed, timeout: .seconds(10))
                    }
                }
                for await addresses in group where !addresses.isEmpty {
                    for host in addresses {
                        await self.addDiscoveredAddress(host: host, port: port)
                    }
                    await self.connectToDiscoveredPeers()
                }
            }

            // If DNS resolution failed, use hardcoded fallback nodes
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }

            if await self.connectedPeerCount == 0, !fallbackNodes.isEmpty {
                self.logger.info("DNS seeds failed, trying fallback nodes")
                for node in fallbackNodes {
                    await self.addDiscoveredAddress(host: node.host, port: node.port)
                }
                await self.connectToDiscoveredPeers()
            }
        }
    }

    /// Resolves a DNS seed to numeric addresses.
    ///
    /// `getaddrinfo` blocks and cannot be cancelled, so it runs on its own
    /// thread — never a cooperative pool thread — and a lookup that outlives
    /// `timeout` is abandoned (its result discarded) instead of stalling
    /// discovery.
    nonisolated private static func resolve(_ hostname: String, timeout: Duration) async -> [String] {
        let addresses = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            let once = ResumeOnce(continuation)
            Thread.detachNewThread {
                once.resume(returning: numericAddresses(for: hostname))
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(throwing: CancellationError())
            }
        }
        return addresses ?? []
    }

    /// Blocking `getaddrinfo` lookup, deduplicated, in numeric form.
    nonisolated private static func numericAddresses(for hostname: String) -> [String] {
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, nil, &results) == 0, let first = results else {
            return []
        }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            // The buffer length is a `socklen_t` on Darwin and a `size_t` on Android.
            let status = getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, numericCast(host.count), nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }

            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !addresses.contains(address) {
                addresses.append(address)
            }
        }
        return addresses
    }

    private func handleAddrMessage(_ message: AddrMessage, from peer: Peer) {
        guard !message.entries.isEmpty else { return }

        let now = Date()
        var budget = addrBudgetByPeer[peer.id] ?? .initial
        if now.timeIntervalSince(budget.windowStart) >= AddrBudget.windowInterval {
            budget = AddrBudget(windowStart: now, entriesThisWindow: 0)
        }
        let remaining = max(0, AddrBudget.entriesPerWindow - budget.entriesThisWindow)
        if remaining == 0 {
            logger.info("Rate-limiting addr entries from \(peer.host) (\(AddrBudget.entriesPerWindow)/min budget exhausted)")
            addrBudgetByPeer[peer.id] = budget
            return
        }

        var added = 0
        var considered = 0
        var seenInBatch = Set<String>()
        for entry in message.entries where considered < remaining {
            considered += 1
            guard entry.address.isRoutable,
                  let host = entry.address.addressString,
                  entry.address.port > 0 else {
                continue
            }

            // Dedupe within this single addr batch so a peer spamming the
            // same host repeatedly burns budget only once per unique host.
            guard seenInBatch.insert(host).inserted else { continue }

            addDiscoveredAddress(host: host, port: entry.address.port)
            added += 1
        }

        budget.entriesThisWindow += considered
        addrBudgetByPeer[peer.id] = budget

        if added > 0 {
            logger.info("Added \(added) addresses from \(peer.host) (\(considered)/\(AddrBudget.entriesPerWindow) budget this window)")
            if connectedPeerCount < minPeerConnections {
                connectToDiscoveredPeers()
            }
        }
    }

    private func connectToDiscoveredPeers() {
        guard isRunning else { return }

        // Count only peers that are still actively connecting or connected,
        // not ones that have already disconnected and are awaiting cleanup.
        let activePeers = peers.filter { !disconnectedPeerIDs.contains($0.id) }
        let needed = maxPeerConnections - activePeers.count
        guard needed > 0 else { return }

        // Skip hosts we are already using or must not use yet, and shuffle so
        // repeated rounds try different addresses instead of the same few.
        let activeHosts = Set(activePeers.map(\.host))
        let candidates = discoveredAddresses
            .filter { host, _ in !activeHosts.contains(host) && !isHostBanned(host) && !isHostBackedOff(host) }
            .shuffled()
            .prefix(needed)

        for (address, port) in candidates {
            Task { [weak self] in
                await self?.addPeer(host: address, port: port)
            }
        }
    }

    private func startMaintenanceTask() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.performMaintenance()
            }
        }
    }

    private func performMaintenance() async {
        // Send pings to connected peers
        for peer in connectedPeers {
            await peer.sendPing()
        }

        // Try to connect more peers if needed
        if connectedPeerCount < minPeerConnections {
            connectToDiscoveredPeers()
        }

        // Remove disconnected peers
        peers.removeAll { disconnectedPeerIDs.contains($0.id) }
        disconnectedPeerIDs.removeAll()
    }

    private func addDiscoveredAddress(host: String, port: UInt16) {
        guard !isHostBanned(host), !isHostBackedOff(host) else { return }
        discoveredAddresses[host] = port
    }

    private func isHostBackedOff(_ host: String) -> Bool {
        guard let history = peerHistory[host], let backoff = history.backoffUntil else {
            return false
        }

        if backoff < Date() {
            var updated = history
            updated.backoffUntil = nil
            peerHistory[host] = updated
            return false
        }

        return true
    }

    private func recordMisbehavior(for peer: Peer, score: Int, reason: BanReason) async {
        let host = peer.host

        var history = peerHistory[host, default: PeerHistory()]
        history.score += score
        peerHistory[host] = history
        let totalScore = history.score

        if totalScore >= misbehaviorBanThreshold {
            await banPeer(peer, reason: reason)
        }
    }

    private func recordConnectionFailure(for peer: Peer, reason: BanReason) {
        let host = peer.host
        let now = Date()

        var history = peerHistory[host, default: PeerHistory()]
        history.consecutiveFailures += 1
        let delay = min(maxBackoff, baseBackoff * pow(2.0, Double(max(0, history.consecutiveFailures - 1))))
        history.backoffUntil = now.addingTimeInterval(delay)
        peerHistory[host] = history

        logger.warning("Backoff for \(host) set to \(Int(delay))s (\(reason.rawValue))")
    }

    private func recordSuccessfulConnection(for peer: Peer) {
        var history = peerHistory[peer.host, default: PeerHistory()]
        history.consecutiveFailures = 0
        history.backoffUntil = nil
        peerHistory[peer.host] = history
    }
}

// MARK: - PeerDelegate

extension PeerManager: PeerDelegate {
    public func peer(_ peer: Peer, didChangeState state: Peer.State) async {
        logger.debug("Peer \(peer.host) state: \(String(describing: state))")

        switch state {
        case .ready:
            readyPeerIDs.insert(peer.id)
            disconnectedPeerIDs.remove(peer.id)
            recordSuccessfulConnection(for: peer)
            let count = connectedPeerCount
            await delegate?.peerManager(self, peerDidBecomeReady: peer)
            await delegate?.peerManager(self, connectedPeerCountChanged: count)

        case .disconnected:
            await peerWentDown(peer)

        default:
            break
        }
    }

    public func peer(_ peer: Peer, didReceiveMessage message: ProtocolMessage) async {
        // Handle getdata messages internally for transaction broadcasting
        if message.command == ProtocolMessage.Command.getdata {
            if let getData = GetDataMessage.parse(from: message.payload) {
                await handleGetData(getData.inventory, from: peer)
            }
        }

        if message.command == ProtocolMessage.Command.addr {
            guard let addrMessage = AddrMessage.parse(from: message.payload) else {
                await recordMisbehavior(for: peer, score: 25, reason: .invalidMessage)
                return
            }
            handleAddrMessage(addrMessage, from: peer)
        }

        // Forward to delegate for other handling — inline, so messages keep
        // their wire order and a busy consumer slows the peer down.
        await delegate?.peerManager(self, peer: peer, didReceiveMessage: message)
    }

    public func peer(_ peer: Peer, didFailWithError error: Error) async {
        logger.error("Peer \(peer.host) error: \(error.localizedDescription)")
        if let peerError = error as? Peer.PeerError {
            switch peerError {
            case .invalidMagic:
                await recordMisbehavior(for: peer, score: 100, reason: .protocolViolation)
            case .invalidMessage(let reason):
                let score: Int
                switch reason {
                case .invalidChecksum, .invalidPayloadLength, .invalidCommandPadding:
                    score = 50
                case .invalidCommand:
                    score = 25
                }
                await recordMisbehavior(for: peer, score: score, reason: .invalidMessage)
            case .timeout:
                recordConnectionFailure(for: peer, reason: .timeout)
            case .connectionFailed:
                recordConnectionFailure(for: peer, reason: .timeout)
            }
        } else {
            recordConnectionFailure(for: peer, reason: .timeout)
        }
        await removePeer(peer)
    }
}
