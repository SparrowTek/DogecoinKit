import Foundation
import os.log

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

    /// UserDefaults key for persisted banned peers
    private static let bannedPeersKey = "DogecoinKit.bannedPeers"

    /// Logger
    private let logger = Logger(subsystem: "DogecoinKit", category: "PeerManager")

    /// Timer task for maintenance
    private var maintenanceTask: Task<Void, Never>?

    /// Track ready/disconnected peer IDs locally to avoid N-await per peer
    private var readyPeerIDs: Set<UUID> = []
    private var disconnectedPeerIDs: Set<UUID> = []

    /// Pending transactions waiting to be requested by peers
    private var pendingTransactions: [Data: TxMessage] = [:]

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
        self.network = network

        // Inline banned peer loading (can't call actor-isolated methods from init)
        if let data = UserDefaults.standard.data(forKey: Self.bannedPeersKey),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            let now = Date()
            self.bannedPeers = decoded.filter { $0.value > now }
        }
    }

    /// Start the peer manager
    public func start() {
        logger.info("Starting peer manager for \(self.network == .mainnet ? "mainnet" : "testnet")")
        discoverPeers()
        startMaintenanceTask()
    }

    /// Stop the peer manager
    public func stop() async {
        logger.info("Stopping peer manager")
        maintenanceTask?.cancel()
        maintenanceTask = nil

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
        let peer = Peer(host: host, port: port, network: network)
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
        readyPeerIDs.remove(peer.id)
        disconnectedPeerIDs.insert(peer.id)
        await peer.disconnect()
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

    private func loadBannedPeers() {
        guard let data = UserDefaults.standard.data(forKey: Self.bannedPeersKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return
        }

        bannedPeers = decoded
        cleanExpiredBans()
        logger.info("Loaded \(self.bannedPeers.count) banned peers from storage")
    }

    private func saveBannedPeers() {
        let toSave = bannedPeers
        if let data = try? JSONEncoder().encode(toSave) {
            UserDefaults.standard.set(data, forKey: Self.bannedPeersKey)
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

    /// Broadcast a transaction to the network
    public func broadcastTransaction(_ txMessage: TxMessage) async throws -> String {
        let readyPeers = connectedPeers
        guard !readyPeers.isEmpty else {
            throw DogecoinError.noPeersAvailable
        }

        let txid = txMessage.txidInternal
        let txidHex = txMessage.txidHex

        pendingTransactions[txid] = txMessage

        logger.info("Broadcasting transaction: \(txidHex)")

        let inv = InventoryVector(type: .transaction, hash: txid)

        for peer in readyPeers {
            await peer.sendInv(inventory: [inv])
        }

        // Schedule cleanup of pending transaction after 60 seconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await self?.removePendingTransaction(txid)
        }

        return txidHex
    }

    private func removePendingTransaction(_ txid: Data) {
        pendingTransactions.removeValue(forKey: txid)
    }

    /// Handle a getdata request from a peer
    internal func handleGetData(_ inventory: [InventoryVector], from peer: Peer) async {
        for item in inventory {
            switch item.type {
            case .transaction:
                if let tx = pendingTransactions[item.hash] {
                    logger.info("Sending transaction \(tx.txidHex) to peer \(peer.host)")
                    await peer.sendTransaction(tx)
                }
            default:
                break
            }
        }
    }

    // MARK: - Private Methods

    private func discoverPeers() {
        let network = self.network
        Task { [weak self] in
            guard let self else { return }

            let seeds = NetworkConstants.seeds(for: network)
            self.logger.info("Discovering peers from \(seeds.count) DNS seeds")

            // Resolve DNS seeds concurrently off the actor to avoid blocking it
            let resolvedAddresses = await withTaskGroup(of: [(String, UInt16)].self) { group in
                let port = NetworkConstants.port(for: network)
                for seed in seeds {
                    group.addTask {
                        Self.resolveHostOffActor(seed, port: port)
                    }
                }
                var all: [(String, UInt16)] = []
                for await batch in group {
                    all.append(contentsOf: batch)
                }
                return all
            }

            for (host, port) in resolvedAddresses {
                await self.addDiscoveredAddress(host: host, port: port)
            }
            await self.connectToDiscoveredPeers()

            // If DNS resolution failed, use hardcoded fallback nodes
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }

            if await self.connectedPeerCount == 0 && network == .mainnet {
                self.logger.info("DNS seeds failed, trying fallback nodes")
                for node in NetworkConstants.mainnetFallbackNodes {
                    await self.addDiscoveredAddress(host: node.host, port: node.port)
                }
                await self.connectToDiscoveredPeers()
            }
        }
    }

    private func handleAddrMessage(_ message: AddrMessage, from peer: Peer) {
        guard !message.entries.isEmpty else { return }

        var added = 0
        for entry in message.entries {
            guard entry.address.isRoutable,
                  let host = entry.address.addressString,
                  entry.address.port > 0 else {
                continue
            }

            addDiscoveredAddress(host: host, port: entry.address.port)
            added += 1
        }

        if added > 0 {
            logger.info("Added \(added) addresses from \(peer.host)")
            if connectedPeerCount < minPeerConnections {
                connectToDiscoveredPeers()
            }
        }
    }

    private func handleGetAddr(from peer: Peer) async {
        let candidates = Array(discoveredAddresses.prefix(100))

        guard !candidates.isEmpty else { return }

        let now = UInt32(Date().timeIntervalSince1970)
        let entries: [AddrMessage.Entry] = candidates.compactMap { host, port in
            guard let address = NetworkAddress.from(host: host, port: port) else { return nil }
            guard address.isRoutable else { return nil }
            return AddrMessage.Entry(timestamp: now, address: address)
        }

        let addrMessage = AddrMessage(entries: entries)
        let payload = addrMessage.serialize()
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.addr, payload: payload)
        await peer.send(message)
    }

    /// Resolve a DNS seed off-actor so the blocking CFHost call doesn't starve the actor.
    nonisolated private static func resolveHostOffActor(_ hostname: String, port: UInt16) -> [(String, UInt16)] {
        let host = CFHostCreateWithName(nil, hostname as CFString).takeRetainedValue()
        CFHostStartInfoResolution(host, .addresses, nil)

        var success: DarwinBoolean = false
        guard let addresses = CFHostGetAddressing(host, &success)?.takeUnretainedValue() as? [Data], success.boolValue else {
            return []
        }

        var results: [(String, UInt16)] = []
        for addressData in addresses {
            if let address = parseIPv4Address(addressData) {
                results.append((address, port))
            } else if let address = parseIPv6Address(addressData) {
                results.append((address, port))
            }
        }
        return results
    }

    nonisolated private static func parseIPv4Address(_ data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }

        return data.withUnsafeBytes { bytes -> String? in
            guard let baseAddress = bytes.baseAddress else { return nil }
            let sockaddr = baseAddress.assumingMemoryBound(to: sockaddr_in.self).pointee

            guard sockaddr.sin_family == AF_INET else { return nil }

            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = sockaddr.sin_addr
            inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))

            let bytes = Data(buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    nonisolated private static func parseIPv6Address(_ data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr_in6>.size else { return nil }

        return data.withUnsafeBytes { bytes -> String? in
            guard let baseAddress = bytes.baseAddress else { return nil }
            let sockaddr = baseAddress.assumingMemoryBound(to: sockaddr_in6.self).pointee

            guard sockaddr.sin6_family == AF_INET6 else { return nil }

            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var addr = sockaddr.sin6_addr
            inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN))

            let bytes = Data(buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private func connectToDiscoveredPeers() {
        // Count only peers that are still actively connecting or connected,
        // not ones that have already disconnected and are awaiting cleanup.
        let activePeerCount = peers.filter { !disconnectedPeerIDs.contains($0.id) }.count
        let addressesToTry = discoveredAddresses

        let needed = maxPeerConnections - activePeerCount
        guard needed > 0 else { return }

        let candidates = addressesToTry.prefix(needed)
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
            let delegate = self.delegate
            let count = connectedPeerCount
            Task { [weak self] in
                guard let self else { return }
                await delegate?.peerManager(self, peerDidBecomeReady: peer)
                await delegate?.peerManager(self, connectedPeerCountChanged: count)
            }

        case .disconnected:
            readyPeerIDs.remove(peer.id)
            disconnectedPeerIDs.insert(peer.id)
            let delegate = self.delegate
            let count = connectedPeerCount
            Task { [weak self] in
                guard let self else { return }
                await delegate?.peerManager(self, peerDidDisconnect: peer)
                await delegate?.peerManager(self, connectedPeerCountChanged: count)
            }

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

        if message.command == ProtocolMessage.Command.getaddr {
            await handleGetAddr(from: peer)
        }

        // Forward to delegate for other handling
        let delegate = self.delegate
        Task { [weak self] in
            guard let self else { return }
            await delegate?.peerManager(self, peer: peer, didReceiveMessage: message)
        }
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
