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

    /// Addresses discovered from DNS seeds
    private var discoveredAddresses: [String] = []

    /// Banned peer addresses with ban expiration time
    private var bannedPeers: [String: Date] = [:]

    /// Ban duration in seconds (default: 24 hours)
    public var banDuration: TimeInterval = 86400

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

        lock.lock()
        guard !peers.contains(peer) else {
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

        let txid = txMessage.txid
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
                lock.lock()
                if !discoveredAddresses.contains(address) {
                    discoveredAddresses.append(address)
                }
                lock.unlock()
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

    private func connectToDiscoveredPeers() {
        lock.lock()
        let currentPeerCount = peers.count
        let addressesToTry = discoveredAddresses
        lock.unlock()

        let needed = maxPeerConnections - currentPeerCount
        guard needed > 0 else { return }

        for address in addressesToTry.prefix(needed) {
            addPeer(host: address)
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
}

// MARK: - PeerDelegate

extension PeerManager: PeerDelegate {
    public func peer(_ peer: Peer, didChangeState state: Peer.State) {
        logger.debug("Peer \(peer.host) state: \(String(describing: state))")

        switch state {
        case .ready:
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

        // Forward to delegate for other handling
        delegate?.peerManager(self, peer: peer, didReceiveMessage: message)
    }

    public func peer(_ peer: Peer, didFailWithError error: Error) {
        logger.error("Peer \(peer.host) error: \(error.localizedDescription)")
        removePeer(peer)
    }
}
