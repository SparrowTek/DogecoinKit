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
    public private(set) var minPeerConnections: Int = 3

    /// Maximum number of peer connections
    public private(set) var maxPeerConnections: Int = 8

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

    /// All known peers
    private var peers: [Peer] = []

    // MARK: - Policy

    /// How long a misbehaving peer stays banned
    private static let banDuration: TimeInterval = 86_400

    /// Misbehavior score that triggers a ban
    private static let misbehaviorBanThreshold = 100

    /// Backoff after a first failed connection; doubles with each further one
    private static let baseBackoff: TimeInterval = 30

    /// Longest backoff
    private static let maxBackoff: TimeInterval = 3600

    /// How the manager paces itself
    struct Pacing: Sendable {
        /// Between maintenance rounds
        var maintenance: Duration = .seconds(30)
        /// Between maintenance rounds while no peer is connected at all
        var peerlessMaintenance: Duration = .seconds(5)
        /// After the DNS seeds, before the built-in nodes are tried
        var fallbackDelay: Duration = .seconds(3)
    }

    private let pacing: Pacing

    // MARK: - Known Addresses

    /// Who vouched for an address
    private enum AddressSource: Hashable, Sendable {
        /// A DNS seed or the built-in fallback list
        case seed
        /// A connected peer, by host
        case peer(String)
    }

    private struct KnownAddress: Sendable {
        let port: UInt16
        let source: AddressSource
    }

    /// Hosts that can be dialed. Addresses from seeds are kept apart from
    /// those peers pass on: a peer can tell us about any number of hosts it
    /// controls, and must not be able to crowd out the rest.
    private var knownAddresses: [String: KnownAddress] = [:]

    /// Most addresses kept from what peers pass on, in total and from any
    /// one of them
    private static let maximumGossipedAddresses = 2000
    private static let maximumAddressesPerPeer = 250

    private struct PeerHistory: Sendable {
        var score: Int = 0
        var consecutiveFailures: Int = 0
        var backoffUntil: Date?
    }

    private var peerHistory: [String: PeerHistory] = [:]

    /// Banned peer addresses with ban expiration time
    private var bannedPeers: [String: Date] = [:]

    /// UserDefaults key for persisted banned peers
    private static let bannedPeersKey = "DogecoinKit.bannedPeers"

    /// Logger
    private let logger = Logger(subsystem: "DogecoinKit", category: "PeerManager")

    /// Timer task for maintenance
    private var maintenanceTask: Task<Void, Never>?

    /// DNS seed discovery, cancelled by `stop()`
    private var discoveryTask: Task<Void, Never>?
    private var isDiscovering = false

    /// Between `start()` and `stop()`; only then are new peers dialed on our own
    private var isRunning = false

    /// Track ready/disconnected peer IDs locally to avoid N-await per peer
    private var readyPeerIDs: Set<UUID> = []
    private var disconnectedPeerIDs: Set<UUID> = []

    /// Peers that completed a handshake at some point, whose loss is
    /// therefore no sign that their host cannot be reached
    private var handshakenPeerIDs: Set<UUID> = []

    /// Peers this manager disconnected itself, or has already counted a
    /// failure for
    private var settledPeerIDs: Set<UUID> = []

    /// Service bits every peer must advertise in its `version`
    private var requiredServices: UInt64 = 0

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

    // MARK: - Announcements

    /// A transaction on offer to peers
    private struct Announcement {
        let transaction: TxMessage
        /// On offer until withdrawn, rather than until its window ends
        var isStanding = false
        /// Counts the times the transaction was announced, so the end of an
        /// earlier announcement's window leaves a later one alone
        var generation = 0
        /// The peers that asked for the transaction
        var fetchedBy: Set<UUID> = []
        /// What peers that turned it down said, by peer
        var rejections: [UUID: String] = [:]
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

        var wasFetched: Bool { !fetchedBy.isEmpty }
    }

    /// Transactions announced to peers, by txid in internal byte order
    private var announcements: [Data: Announcement] = [:]

    /// How long a broadcast waits for a peer to ask for the transaction
    private let broadcastTimeout: Duration

    /// How long a broadcast then waits for that peer to turn it down. A
    /// node validates a transaction the moment it arrives, so its `reject`
    /// follows within a round trip.
    private let rejectionWindow: Duration

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
        peers.count { readyPeerIDs.contains($0.id) }
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
        case timeout = "Connection timeout or unresponsive"
        case protocolViolation = "Protocol violation"
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
        broadcastTimeout: Duration = .seconds(15),
        rejectionWindow: Duration = .milliseconds(1500),
        pacing: Pacing = Pacing()
    ) {
        self.network = network
        self.makeStream = streamFactory
        self.dnsSeeds = dnsSeeds
        self.fallbackNodes = fallbackNodes
        self.banStore = banStore
        self.broadcastTimeout = broadcastTimeout
        self.rejectionWindow = rejectionWindow
        self.pacing = pacing

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
        isDiscovering = false

        let allPeers = peers
        for peer in allPeers {
            settledPeerIDs.insert(peer.id)
            await peer.disconnect()
        }

        peers.removeAll()
        readyPeerIDs.removeAll()
        disconnectedPeerIDs.removeAll()
        handshakenPeerIDs.removeAll()
        settledPeerIDs.removeAll()
        addrBudgetByPeer.removeAll()
    }

    /// Add a peer by address
    public func addPeer(host: String, port: UInt16? = nil) async {
        let peer = Peer(host: host, port: port, network: network, streamFactory: makeStream)

        // Don't connect to banned peers
        if isHostBanned(peer.host) {
            logger.debug("Not connecting to banned peer \(peer.host)")
            return
        }

        guard !isHostBackedOff(peer.host) else {
            logger.debug("Backoff active for peer \(peer.host)")
            return
        }

        // A connection to this host that has ended is no reason not to make
        // another; it only waits here for the next round of maintenance.
        peers.removeAll { $0.host == peer.host && $0.port == peer.port && disconnectedPeerIDs.contains($0.id) }
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
        // Our own doing: its going down says nothing about its host.
        settledPeerIDs.insert(peer.id)
        await peer.disconnect()
        // Disconnecting reports `.disconnected`, which tells the delegate;
        // this covers a peer that was already down.
        await peerWentDown(peer)
    }

    /// Disconnects a peer that stopped answering and leaves its host alone
    /// for a while, so the next peer dialed is not the same one again.
    func removeUnresponsivePeer(_ peer: Peer) async {
        recordConnectionFailure(for: peer, reason: .timeout)
        await removePeer(peer)
    }

    /// Requires every peer to advertise `services`, from now on and of the
    /// peers already connected: those that lack a bit are disconnected, and
    /// their hosts not dialed again for a long while.
    func requireServices(_ services: UInt64) async {
        guard requiredServices | services != requiredServices else { return }
        requiredServices |= services

        for peer in connectedPeers {
            let offered = await peer.peerVersion?.services ?? 0
            if offered & requiredServices != requiredServices {
                await dismissUnsuitable(peer, offering: offered)
            }
        }
    }

    private func dismissUnsuitable(_ peer: Peer, offering services: UInt64) async {
        logger.info("Dropping \(peer.host): it offers services \(services), not the \(self.requiredServices) needed")
        var history = peerHistory[peer.host, default: PeerHistory()]
        history.backoffUntil = Date().addingTimeInterval(Self.maxBackoff)
        peerHistory[peer.host] = history
        await removePeer(peer)
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
        let banUntil = Date().addingTimeInterval(duration ?? Self.banDuration)

        bannedPeers[host] = banUntil
        knownAddresses[host] = nil

        logger.warning("Banned peer \(host): \(reason.rawValue) until \(banUntil)")

        await removePeer(peer)
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

    // MARK: - Ban Persistence

    private func saveBannedPeers() {
        let now = Date()
        bannedPeers = bannedPeers.filter { $0.value > now }
        if let data = try? JSONEncoder().encode(bannedPeers) {
            banStore?.set(data, forKey: Self.bannedPeersKey)
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

    /// Announces a transaction to every connected peer, waits until one of
    /// them has asked for it, and then a moment longer for that peer to say
    /// it will not take it.
    ///
    /// An announcement only tells peers the transaction exists; it has left
    /// this device once a peer fetches it. Returning before that reported
    /// transactions as sent that no peer ever received. A node validates
    /// what it fetched at once and answers `reject` if it refuses it, so
    /// waiting that out tells a send that reached the network from one
    /// every peer threw away.
    ///
    /// Cancelling the calling task does not withdraw the announcement: the
    /// call still ends, one way or the other, once a peer asks or the wait
    /// runs out.
    /// - Returns: The transaction id, in display byte order
    /// - Throws: `DogecoinError.internalError` for bytes that are not a
    ///   transaction, `DogecoinError.noPeersAvailable` with no peer
    ///   connected, or `DogecoinError.broadcastFailed` when no peer asks
    ///   for the transaction in time, or every peer that took it rejected
    ///   it — it is then no longer on offer
    public func broadcastTransaction(_ txMessage: TxMessage) async throws -> String {
        // Anything else would be reported as sent, under the hash of
        // whatever it is, as soon as a peer fetched the bytes.
        guard txMessage.isWellFormed else {
            throw DogecoinError.internalError("Invalid transaction hex")
        }

        let readyPeers = connectedPeers
        guard !readyPeers.isEmpty else {
            throw DogecoinError.noPeersAvailable
        }

        let txid = txMessage.txidInternal
        let txidHex = txMessage.txidHex

        // Announcing a transaction again gives it a whole window of its own.
        var announcement = announcements[txid] ?? Announcement(transaction: txMessage)
        announcement.generation += 1
        announcement.rejections = [:]
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

        // A fetch is not yet acceptance.
        try? await Task.sleep(for: rejectionWindow)
        if let settled = announcements[txid],
           settled.wasFetched,
           settled.fetchedBy.isSubset(of: Set(settled.rejections.keys)) {
            let reason = settled.rejections.values.sorted().first ?? "rejected"
            logger.error("Every peer that took transaction \(txidHex) rejected it: \(reason)")
            if !settled.isStanding {
                announcements[txid] = nil
            }
            throw DogecoinError.broadcastFailed("The network rejected the transaction: \(reason)")
        }

        return txidHex
    }

    /// Keeps a transaction on offer: announces it to every connected peer,
    /// and to each that connects later, until ``withdraw(transactionID:)``.
    /// Offering it again announces it again.
    func offer(_ transaction: TxMessage) async {
        let txid = transaction.txidInternal
        var announcement = announcements[txid] ?? Announcement(transaction: transaction)
        announcement.isStanding = true
        announcements[txid] = announcement

        let inv = InventoryVector(type: .transaction, hash: txid)
        for peer in connectedPeers {
            await peer.sendInv(inventory: [inv])
        }
    }

    /// Takes a transaction off offer.
    /// - Parameter txid: The transaction id in internal byte order
    func withdraw(transactionID txid: Data) {
        guard let announcement = announcements[txid], announcement.waiters.isEmpty else { return }
        announcements[txid] = nil
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
        announcements[txid] = announcement.waiters.isEmpty && !announcement.isStanding ? nil : announcement

        logger.error("No peer asked for transaction \(announcement.transaction.txidHex)")
        continuation.resume(throwing: DogecoinError.broadcastFailed("No peer asked for the transaction"))
    }

    private func endAnnouncement(of txid: Data, generation: Int) {
        guard let announcement = announcements[txid],
              !announcement.isStanding,
              announcement.generation == generation,
              announcement.waiters.isEmpty else {
            return
        }
        announcements[txid] = nil
    }

    /// Handle a getdata request from a peer
    private func handleGetData(_ inventory: [InventoryVector], from peer: Peer) async {
        for item in inventory where item.type == .transaction {
            guard let transaction = announcements[item.hash]?.transaction else { continue }

            logger.info("Sending transaction \(transaction.txidHex) to peer \(peer.host)")
            guard await peer.sendTransaction(transaction) else { continue }
            markFetched(item.hash, by: peer)
        }
    }

    private func markFetched(_ txid: Data, by peer: Peer) {
        guard var announcement = announcements[txid] else { return }

        let waiters = Array(announcement.waiters.values)
        announcement.fetchedBy.insert(peer.id)
        announcement.waiters = [:]
        announcements[txid] = announcement

        for waiter in waiters {
            waiter.resume()
        }
    }

    /// A peer turned something down. For a transaction on offer that is
    /// remembered: a broadcast still settling counts it.
    ///
    /// A node that merely has the transaction already never asks for it,
    /// and so never answers this way. Whatever it says here is about a
    /// transaction it took and would not keep.
    private func handleReject(_ rejection: RejectMessage, from peer: Peer) {
        guard rejection.message == ProtocolMessage.Command.tx,
              let txid = rejection.hash,
              announcements[txid] != nil else {
            return
        }

        logger.warning("\(peer.host) rejected transaction \(Data(txid.reversed()).hexString): \(rejection.reason) (code \(rejection.code))")
        announcements[txid]?.rejections[peer.id] = rejection.reason
    }

    // MARK: - Discovery

    private func discoverPeers() {
        guard !isDiscovering else { return }
        isDiscovering = true

        let seeds = dnsSeeds
        let fallbackNodes = self.fallbackNodes
        let fallbackDelay = pacing.fallbackDelay
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
                        await self.addSeedAddress(host: host, port: port)
                    }
                    await self.connectToKnownAddresses()
                }
            }

            // If DNS resolution failed, use hardcoded fallback nodes
            try? await Task.sleep(for: fallbackDelay)
            guard !Task.isCancelled else { return }

            if await self.connectedPeerCount == 0, !fallbackNodes.isEmpty {
                self.logger.info("DNS seeds failed, trying fallback nodes")
                for node in fallbackNodes {
                    await self.addSeedAddress(host: node.host, port: node.port)
                }
                await self.connectToKnownAddresses()
            }

            await self.discoveryFinished()
        }
    }

    private func discoveryFinished() {
        isDiscovering = false
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
        for entry in message.entries where considered < remaining {
            considered += 1
            guard entry.address.isRoutable,
                  let host = entry.address.addressString,
                  entry.address.port > 0 else {
                continue
            }

            if addGossipedAddress(host: host, port: entry.address.port, from: peer.host) {
                added += 1
            }
        }

        budget.entriesThisWindow += considered
        addrBudgetByPeer[peer.id] = budget

        if added > 0 {
            logger.info("Added \(added) addresses from \(peer.host) (\(considered)/\(AddrBudget.entriesPerWindow) budget this window)")
            if connectedPeerCount < minPeerConnections {
                connectToKnownAddresses()
            }
        }
    }

    private func addSeedAddress(host: String, port: UInt16) {
        guard !isHostBanned(host) else { return }
        knownAddresses[host] = KnownAddress(port: port, source: .seed)
    }

    /// Remembers an address a peer passed on — unless the host is already
    /// known, whoever told us: a later mention never changes its port, or
    /// turns a seed's address into this peer's.
    /// - Returns: Whether the address was new and kept
    private func addGossipedAddress(host: String, port: UInt16, from peerHost: String) -> Bool {
        guard knownAddresses[host] == nil, !isHostBanned(host) else { return false }

        let source = AddressSource.peer(peerHost)
        guard knownAddresses.values.count(where: { $0.source == source }) < Self.maximumAddressesPerPeer else {
            return false
        }

        // Full: something a peer told us makes way, at random.
        let gossiped = knownAddresses.filter { $0.value.source != .seed }
        if gossiped.count >= Self.maximumGossipedAddresses, let evicted = gossiped.keys.randomElement() {
            knownAddresses[evicted] = nil
        }

        knownAddresses[host] = KnownAddress(port: port, source: source)
        return true
    }

    /// The port on record for a host, and how many hosts are on record
    func knownPort(of host: String) -> UInt16? {
        knownAddresses[host]?.port
    }

    var knownAddressCount: Int {
        knownAddresses.count
    }

    /// Hosts that could be dialed now: not connected, banned, or backing off.
    private func dialableAddresses() -> [(host: String, address: KnownAddress)] {
        let activeHosts = Set(peers.filter { !disconnectedPeerIDs.contains($0.id) }.map(\.host))
        return knownAddresses
            .filter { host, _ in !activeHosts.contains(host) && !isHostBanned(host) && !isHostBackedOff(host) }
            .map { (host: $0.key, address: $0.value) }
    }

    private func connectToKnownAddresses() {
        guard isRunning else { return }

        // Count only peers that are still actively connecting or connected,
        // not ones that have already disconnected and are awaiting cleanup.
        let activeCount = peers.count { !disconnectedPeerIDs.contains($0.id) }
        let needed = maxPeerConnections - activeCount
        guard needed > 0 else { return }

        // Addresses from seeds first, each group shuffled so repeated rounds
        // try different hosts: what peers pass on only fills the gaps.
        let dialable = dialableAddresses()
        let candidates = (dialable.filter { $0.address.source == .seed }.shuffled()
            + dialable.filter { $0.address.source != .seed }.shuffled())
            .prefix(needed)

        for candidate in candidates {
            Task { [weak self] in
                await self?.addPeer(host: candidate.host, port: candidate.address.port)
            }
        }
    }

    // MARK: - Maintenance

    private func startMaintenanceTask() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            // Ends with the manager, even one dropped without `stop()`.
            while !Task.isCancelled, let interval = await self?.nextMaintenanceInterval {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.performMaintenance()
            }
        }
    }

    private var nextMaintenanceInterval: Duration {
        connectedPeerCount == 0 ? pacing.peerlessMaintenance : pacing.maintenance
    }

    private func performMaintenance() async {
        // Send pings to connected peers
        for peer in connectedPeers {
            await peer.sendPing()
        }

        // Remove disconnected peers
        let removed = Set(peers.filter { disconnectedPeerIDs.contains($0.id) }.map(\.id))
        peers.removeAll { removed.contains($0.id) }
        disconnectedPeerIDs.removeAll()
        handshakenPeerIDs.subtract(removed)
        settledPeerIDs.subtract(removed)

        guard isRunning, connectedPeerCount < minPeerConnections else { return }

        if connectedPeerCount == 0, dialableAddresses().isEmpty {
            // Nobody connected and nobody left to try. More likely this
            // device was offline than every host down: failures collected
            // then say nothing about the hosts. Forget them, and ask the
            // seeds again.
            if peers.isEmpty {
                for host in Array(peerHistory.keys) {
                    peerHistory[host]?.backoffUntil = nil
                    peerHistory[host]?.consecutiveFailures = 0
                }
            }
            discoverPeers()
        }

        connectToKnownAddresses()
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

        if totalScore >= Self.misbehaviorBanThreshold {
            await banPeer(peer, reason: reason)
        }
    }

    /// Counts a failed connection against a peer's host — once per peer.
    private func recordConnectionFailure(for peer: Peer, reason: BanReason) {
        guard settledPeerIDs.insert(peer.id).inserted else { return }

        let host = peer.host
        var history = peerHistory[host, default: PeerHistory()]
        history.consecutiveFailures += 1
        let delay = min(Self.maxBackoff, Self.baseBackoff * pow(2.0, Double(max(0, history.consecutiveFailures - 1))))
        history.backoffUntil = Date().addingTimeInterval(delay)
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
            handshakenPeerIDs.insert(peer.id)
            recordSuccessfulConnection(for: peer)

            let services = await peer.peerVersion?.services ?? 0
            guard services & requiredServices == requiredServices else {
                await dismissUnsuitable(peer, offering: services)
                return
            }
            // Dismissed or dropped while its version was being read.
            guard peers.contains(peer), !disconnectedPeerIDs.contains(peer.id) else { return }

            readyPeerIDs.insert(peer.id)
            let count = connectedPeerCount
            await delegate?.peerManager(self, peerDidBecomeReady: peer)
            await delegate?.peerManager(self, connectedPeerCountChanged: count)

            // A peer that connects while a transaction is on offer hears of
            // it too.
            let offers = announcements.keys.map { InventoryVector(type: .transaction, hash: $0) }
            if !offers.isEmpty, readyPeerIDs.contains(peer.id) {
                await peer.sendInv(inventory: offers)
            }

        case .disconnected:
            // Closed on us before the handshake was done, without an error
            // of its own: left uncounted, the same host would be dialed
            // again at once, for ever.
            if !handshakenPeerIDs.contains(peer.id) {
                recordConnectionFailure(for: peer, reason: .timeout)
            }
            await peerWentDown(peer)

        default:
            break
        }
    }

    public func peer(_ peer: Peer, didReceiveMessage message: ProtocolMessage) async {
        switch message.command {
        case ProtocolMessage.Command.getdata:
            // Handled here: this is how an announced transaction leaves.
            if let getData = GetDataMessage.parse(from: message.payload) {
                await handleGetData(getData.inventory, from: peer)
            }

        case ProtocolMessage.Command.reject:
            if let rejection = RejectMessage.parse(from: message.payload) {
                handleReject(rejection, from: peer)
            }

        case ProtocolMessage.Command.addr:
            guard let addrMessage = AddrMessage.parse(from: message.payload) else {
                await recordMisbehavior(for: peer, score: 25, reason: .invalidMessage)
                return
            }
            handleAddrMessage(addrMessage, from: peer)

        default:
            break
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
