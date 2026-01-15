import Foundation
import os.log

/// Delegate for peer manager events
public protocol PeerManagerDelegate: AnyObject, Sendable {
    /// Called when a peer becomes ready
    func peerManager(_ manager: PeerManager, peerDidBecomeReady peer: Peer)

    /// Called when a peer disconnects
    func peerManager(_ manager: PeerManager, peerDidDisconnect peer: Peer)

    /// Called when a message is received from any peer
    func peerManager(_ manager: PeerManager, peer: Peer, didReceiveMessage message: ProtocolMessage)

    /// Called when the number of connected peers changes
    func peerManager(_ manager: PeerManager, connectedPeerCountChanged count: Int)
}

/// Manages connections to multiple peers
public final class PeerManager: @unchecked Sendable {
    /// The network to connect to
    public let network: DogecoinNetwork

    /// Delegate for events
    public weak var delegate: PeerManagerDelegate?

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

    /// Lock for thread safety
    private let lock = NSLock()

    /// UserDefaults key for persisted banned peers
    private static let bannedPeersKey = "DogecoinKit.bannedPeers"

    /// Queue for operations
    private let queue = DispatchQueue(label: "com.dogecoinkit.peermanager", qos: .utility)

    /// Logger
    private let logger = Logger(subsystem: "DogecoinKit", category: "PeerManager")

    /// Timer for maintenance tasks
    private var maintenanceTimer: Timer?

    /// Number of connected peers
    public var connectedPeerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return peers.filter { $0.state == .ready }.count
    }

    /// All connected peers
    public var connectedPeers: [Peer] {
        lock.lock()
        defer { lock.unlock() }
        return peers.filter { $0.state == .ready }
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
        loadBannedPeers()
    }

    /// Start the peer manager
    public func start() {
        logger.info("Starting peer manager for \(self.network == .mainnet ? "mainnet" : "testnet")")
        discoverPeers()
        startMaintenanceTimer()
    }

    /// Stop the peer manager
    public func stop() {
        logger.info("Stopping peer manager")
        stopMaintenanceTimer()

        lock.lock()
        let allPeers = peers
        lock.unlock()

        for peer in allPeers {
            peer.disconnect()
        }

        lock.lock()
        peers.removeAll()
        lock.unlock()
    }

    /// Add a peer by address
    public func addPeer(host: String, port: UInt16? = nil) {
        let peer = Peer(host: host, port: port, network: network)
        addPeer(peer)
    }

    /// Add a peer instance
    public func addPeer(_ peer: Peer) {
        // Don't connect to banned peers
        if isHostBanned(peer.host) {
            logger.debug("Not connecting to banned peer \(peer.host)")
            return
        }

        guard !isHostBackedOff(peer.host) else {
            logger.debug("Backoff active for peer \(peer.host)")
            return
        }

        lock.lock()
        guard !peers.contains(where: { $0.host == peer.host && $0.port == peer.port }) else {
            lock.unlock()
            return
        }
        peers.append(peer)
        lock.unlock()

        peer.delegate = self
        peer.connect()
    }

    /// Remove a peer
    public func removePeer(_ peer: Peer) {
        lock.lock()
        peers.removeAll { $0 == peer }
        lock.unlock()

        peer.disconnect()
    }

    // MARK: - Peer Banning

    /// Ban a peer for misbehavior
    /// - Parameters:
    ///   - peer: The peer to ban
    ///   - reason: Why the peer is being banned
    ///   - duration: Ban duration (nil uses default)
    public func banPeer(_ peer: Peer, reason: BanReason, duration: TimeInterval? = nil) {
        let host = peer.host
        let banUntil = Date().addingTimeInterval(duration ?? banDuration)

        lock.lock()
        bannedPeers[host] = banUntil
        lock.unlock()

        logger.warning("Banned peer \(host): \(reason.rawValue) until \(banUntil)")

        // Disconnect the peer
        removePeer(peer)

        // Persist banned peers
        saveBannedPeers()
    }

    /// Ban a peer by host address
    /// - Parameters:
    ///   - host: The host address to ban
    ///   - reason: Why the peer is being banned
    ///   - duration: Ban duration (nil uses default)
    public func banHost(_ host: String, reason: BanReason, duration: TimeInterval? = nil) {
        let banUntil = Date().addingTimeInterval(duration ?? banDuration)

        lock.lock()
        bannedPeers[host] = banUntil

        // Disconnect any existing connection to this host
        let peersToRemove = peers.filter { $0.host == host }
        lock.unlock()

        for peer in peersToRemove {
            removePeer(peer)
        }

        logger.warning("Banned host \(host): \(reason.rawValue) until \(banUntil)")
        saveBannedPeers()
    }

    /// Unban a peer
    /// - Parameter host: The host address to unban
    public func unbanHost(_ host: String) {
        lock.lock()
        bannedPeers.removeValue(forKey: host)
        lock.unlock()

        logger.info("Unbanned host \(host)")
        saveBannedPeers()
    }

    /// Check if a host is banned
    /// - Parameter host: The host to check
    /// - Returns: true if the host is currently banned
    public func isHostBanned(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let banExpiry = bannedPeers[host] else {
            return false
        }

        // Check if ban has expired
        if banExpiry < Date() {
            bannedPeers.removeValue(forKey: host)
            return false
        }

        return true
    }

    /// Get all currently banned hosts
    public var bannedHosts: [String] {
        cleanExpiredBans()

        lock.lock()
        defer { lock.unlock() }
        return Array(bannedPeers.keys)
    }

    /// Clear all bans
    public func clearAllBans() {
        lock.lock()
        bannedPeers.removeAll()
        lock.unlock()

        logger.info("Cleared all peer bans")
        saveBannedPeers()
    }

    // MARK: - Ban Persistence

    private func loadBannedPeers() {
        guard let data = UserDefaults.standard.data(forKey: Self.bannedPeersKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return
        }

        lock.lock()
        bannedPeers = decoded
        lock.unlock()

        cleanExpiredBans()
        logger.info("Loaded \(self.bannedPeers.count) banned peers from storage")
    }

    private func saveBannedPeers() {
        lock.lock()
        let toSave = bannedPeers
        lock.unlock()

        if let data = try? JSONEncoder().encode(toSave) {
            UserDefaults.standard.set(data, forKey: Self.bannedPeersKey)
        }
    }

    private func cleanExpiredBans() {
        let now = Date()

        lock.lock()
        bannedPeers = bannedPeers.filter { $0.value > now }
        lock.unlock()
    }

    /// Broadcast a message to all connected peers
    public func broadcast(_ message: ProtocolMessage) {
        for peer in connectedPeers {
            peer.send(message)
        }
    }

    // MARK: - Transaction Broadcasting

    /// Pending transactions waiting to be requested by peers
    private var pendingTransactions: [Data: TxMessage] = [:]

    /// Lock for pending transactions
    private let txLock = NSLock()

    /// Broadcast a transaction to the network
    /// - Parameter rawHex: The raw transaction hex
    /// - Returns: The transaction ID (txid) as a hex string
    /// - Throws: DogecoinError if broadcast fails
    public func broadcastTransaction(_ rawHex: String) throws -> String {
        guard let txMessage = TxMessage(rawHex: rawHex) else {
            throw DogecoinError.internalError("Invalid transaction hex")
        }

        return try broadcastTransaction(txMessage)
    }

    /// Broadcast a transaction to the network
    /// - Parameter txMessage: The transaction message
    /// - Returns: The transaction ID (txid) as a hex string
    /// - Throws: DogecoinError if broadcast fails
    public func broadcastTransaction(_ txMessage: TxMessage) throws -> String {
        let peers = connectedPeers
        guard !peers.isEmpty else {
            throw DogecoinError.noPeersAvailable
        }

        let txid = txMessage.txidInternal
        let txidHex = txMessage.txidHex

        // Store transaction for when peers request it
        txLock.lock()
        pendingTransactions[txid] = txMessage
        txLock.unlock()

        logger.info("Broadcasting transaction: \(txidHex)")

        // Create inventory vector for this transaction
        let inv = InventoryVector(type: .transaction, hash: txid)

        // Announce to all connected peers
        for peer in peers {
            peer.sendInv(inventory: [inv])
        }

        // Schedule cleanup of pending transaction after 60 seconds
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.txLock.lock()
            self?.pendingTransactions.removeValue(forKey: txid)
            self?.txLock.unlock()
        }

        return txidHex
    }

    /// Handle a getdata request from a peer
    /// - Parameters:
    ///   - inventory: The requested inventory items
    ///   - peer: The requesting peer
    internal func handleGetData(_ inventory: [InventoryVector], from peer: Peer) {
        for item in inventory {
            switch item.type {
            case .transaction:
                txLock.lock()
                let tx = pendingTransactions[item.hash]
                txLock.unlock()

                if let tx = tx {
                    logger.info("Sending transaction \(tx.txidHex) to peer \(peer.host)")
                    peer.sendTransaction(tx)
                }
            default:
                break
            }
        }
    }

    // MARK: - Private Methods

    private func discoverPeers() {
        queue.async { [weak self] in
            guard let self = self else { return }

            let seeds = NetworkConstants.seeds(for: self.network)
            self.logger.info("Discovering peers from \(seeds.count) DNS seeds")

            for seed in seeds {
                self.resolveHost(seed)
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

    private func handleGetAddr(from peer: Peer) {
        lock.lock()
        let candidates = Array(discoveredAddresses.prefix(100))
        lock.unlock()

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
        peer.send(message)
    }

    private func resolveHost(_ hostname: String) {
        let host = CFHostCreateWithName(nil, hostname as CFString).takeRetainedValue()
        CFHostStartInfoResolution(host, .addresses, nil)

        var success: DarwinBoolean = false
        guard let addresses = CFHostGetAddressing(host, &success)?.takeUnretainedValue() as? [Data], success.boolValue else {
            logger.warning("Failed to resolve \(hostname)")
            return
        }

        for addressData in addresses {
            if let address = parseIPv4Address(addressData) {
                addDiscoveredAddress(host: address, port: NetworkConstants.port(for: network))
            } else if let address = parseIPv6Address(addressData) {
                addDiscoveredAddress(host: address, port: NetworkConstants.port(for: network))
            }
        }

        logger.info("Discovered \(addresses.count) addresses from \(hostname)")
        connectToDiscoveredPeers()
    }

    private func parseIPv4Address(_ data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }

        return data.withUnsafeBytes { bytes -> String? in
            guard let baseAddress = bytes.baseAddress else { return nil }
            let sockaddr = baseAddress.assumingMemoryBound(to: sockaddr_in.self).pointee

            guard sockaddr.sin_family == AF_INET else { return nil }

            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = sockaddr.sin_addr
            inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))

            return String(cString: buffer)
        }
    }

    private func parseIPv6Address(_ data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr_in6>.size else { return nil }

        return data.withUnsafeBytes { bytes -> String? in
            guard let baseAddress = bytes.baseAddress else { return nil }
            let sockaddr = baseAddress.assumingMemoryBound(to: sockaddr_in6.self).pointee

            guard sockaddr.sin6_family == AF_INET6 else { return nil }

            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var addr = sockaddr.sin6_addr
            inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN))

            return String(cString: buffer)
        }
    }

    private func connectToDiscoveredPeers() {
        lock.lock()
        let currentPeerCount = peers.count
        let addressesToTry = discoveredAddresses
        lock.unlock()

        let needed = maxPeerConnections - currentPeerCount
        guard needed > 0 else { return }

        let candidates = addressesToTry.prefix(needed)
        for (address, port) in candidates {
            addPeer(host: address, port: port)
        }
    }

    private func startMaintenanceTimer() {
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.performMaintenance()
        }
    }

    private func stopMaintenanceTimer() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
    }

    private func performMaintenance() {
        // Send pings to connected peers
        for peer in connectedPeers {
            peer.sendPing()
        }

        // Try to connect more peers if needed
        if connectedPeerCount < minPeerConnections {
            connectToDiscoveredPeers()
        }

        // Remove disconnected peers
        lock.lock()
        peers.removeAll { $0.state == .disconnected }
        lock.unlock()
    }

    private func addDiscoveredAddress(host: String, port: UInt16) {
        guard !isHostBanned(host), !isHostBackedOff(host) else { return }

        lock.lock()
        discoveredAddresses[host] = port
        lock.unlock()
    }

    private func isHostBackedOff(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

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

    private func recordMisbehavior(for peer: Peer, score: Int, reason: BanReason) {
        let host = peer.host

        lock.lock()
        var history = peerHistory[host, default: PeerHistory()]
        history.score += score
        peerHistory[host] = history
        let totalScore = history.score
        lock.unlock()

        if totalScore >= misbehaviorBanThreshold {
            banPeer(peer, reason: reason)
        }
    }

    private func recordConnectionFailure(for peer: Peer, reason: BanReason) {
        let host = peer.host
        let now = Date()

        lock.lock()
        var history = peerHistory[host, default: PeerHistory()]
        history.consecutiveFailures += 1
        let delay = min(maxBackoff, baseBackoff * pow(2.0, Double(max(0, history.consecutiveFailures - 1))))
        history.backoffUntil = now.addingTimeInterval(delay)
        peerHistory[host] = history
        lock.unlock()

        logger.warning("Backoff for \(host) set to \(Int(delay))s (\(reason.rawValue))")
    }

    private func recordSuccessfulConnection(for peer: Peer) {
        lock.lock()
        var history = peerHistory[peer.host, default: PeerHistory()]
        history.consecutiveFailures = 0
        history.backoffUntil = nil
        peerHistory[peer.host] = history
        lock.unlock()
    }
}

// MARK: - PeerDelegate

extension PeerManager: PeerDelegate {
    public func peer(_ peer: Peer, didChangeState state: Peer.State) {
        logger.debug("Peer \(peer.host) state: \(String(describing: state))")

        switch state {
        case .ready:
            recordSuccessfulConnection(for: peer)
            delegate?.peerManager(self, peerDidBecomeReady: peer)
            delegate?.peerManager(self, connectedPeerCountChanged: connectedPeerCount)

        case .disconnected:
            delegate?.peerManager(self, peerDidDisconnect: peer)
            delegate?.peerManager(self, connectedPeerCountChanged: connectedPeerCount)

        default:
            break
        }
    }

    public func peer(_ peer: Peer, didReceiveMessage message: ProtocolMessage) {
        // Handle getdata messages internally for transaction broadcasting
        if message.command == ProtocolMessage.Command.getdata {
            if let getData = GetDataMessage.parse(from: message.payload) {
                handleGetData(getData.inventory, from: peer)
            }
        }

        if message.command == ProtocolMessage.Command.addr {
            guard let addrMessage = AddrMessage.parse(from: message.payload) else {
                recordMisbehavior(for: peer, score: 25, reason: .invalidMessage)
                return
            }
            handleAddrMessage(addrMessage, from: peer)
        }

        if message.command == ProtocolMessage.Command.getaddr {
            handleGetAddr(from: peer)
        }

        // Forward to delegate for other handling
        delegate?.peerManager(self, peer: peer, didReceiveMessage: message)
    }

    public func peer(_ peer: Peer, didFailWithError error: Error) {
        logger.error("Peer \(peer.host) error: \(error.localizedDescription)")
        if let peerError = error as? Peer.PeerError {
            switch peerError {
            case .invalidMagic:
                recordMisbehavior(for: peer, score: 100, reason: .protocolViolation)
            case .invalidMessage(let reason):
                let score: Int
                switch reason {
                case .invalidChecksum, .invalidPayloadLength, .invalidCommandPadding:
                    score = 50
                case .invalidCommand:
                    score = 25
                }
                recordMisbehavior(for: peer, score: score, reason: .invalidMessage)
            case .timeout:
                recordConnectionFailure(for: peer, reason: .timeout)
            case .connectionFailed:
                recordConnectionFailure(for: peer, reason: .timeout)
            }
        } else {
            recordConnectionFailure(for: peer, reason: .timeout)
        }
        removePeer(peer)
    }
}
