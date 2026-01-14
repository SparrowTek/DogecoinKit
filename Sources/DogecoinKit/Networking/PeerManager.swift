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

    /// Lock for thread safety
    private let lock = NSLock()

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

    /// Create a peer manager
    public init(network: DogecoinNetwork = .mainnet) {
        self.network = network
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

    /// Broadcast a message to all connected peers
    public func broadcast(_ message: ProtocolMessage) {
        for peer in connectedPeers {
            peer.send(message)
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
        delegate?.peerManager(self, peer: peer, didReceiveMessage: message)
    }

    public func peer(_ peer: Peer, didFailWithError error: Error) {
        logger.error("Peer \(peer.host) error: \(error.localizedDescription)")
        removePeer(peer)
    }
}
