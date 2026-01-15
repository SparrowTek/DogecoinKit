import Foundation
import Network
import os.log

/// Delegate for peer events
public protocol PeerDelegate: AnyObject, Sendable {
    /// Called when the peer connection state changes
    func peer(_ peer: Peer, didChangeState state: Peer.State)

    /// Called when a message is received from the peer
    func peer(_ peer: Peer, didReceiveMessage message: ProtocolMessage)

    /// Called when the peer connection fails
    func peer(_ peer: Peer, didFailWithError error: Error)
}

/// A connection to a Dogecoin peer
public final class Peer: @unchecked Sendable {
    /// Connection state
    public enum State: Sendable {
        case disconnected
        case connecting
        case connected
        case handshaking
        case ready
        case disconnecting
    }

    /// Peer identifier
    public let id: UUID

    /// Host address
    public let host: String

    /// Port number
    public let port: UInt16

    /// Network type
    public let network: DogecoinNetwork

    /// Delegate for events
    public weak var delegate: PeerDelegate?

    /// Current state
    public private(set) var state: State = .disconnected {
        didSet {
            if oldValue != state {
                delegate?.peer(self, didChangeState: state)
            }
        }
    }

    /// Version message received from peer
    public private(set) var peerVersion: VersionMessage?

    /// Our nonce for this connection
    public let nonce: UInt64

    /// Last ping time
    public private(set) var lastPingTime: Date?

    /// Last ping nonce
    private var pendingPingNonce: UInt64?

    /// Round-trip time in seconds
    public private(set) var roundTripTime: TimeInterval?

    /// Track if we've requested peer addresses
    private var didRequestAddresses = false

    // MARK: - Timeout Configuration

    /// Connection timeout in seconds
    public var connectionTimeout: TimeInterval = 30

    /// Handshake timeout in seconds
    public var handshakeTimeout: TimeInterval = 60

    /// Ping timeout in seconds (disconnect if no pong received)
    public var pingTimeout: TimeInterval = 120

    /// Timer for connection timeout
    private var connectionTimeoutTimer: DispatchSourceTimer?

    /// Timer for handshake timeout
    private var handshakeTimeoutTimer: DispatchSourceTimer?

    /// Timer for ping timeout
    private var pingTimeoutTimer: DispatchSourceTimer?

    /// The network connection
    private var connection: NWConnection?

    /// Buffer for incoming data
    private var receiveBuffer = Data()

    /// Queue for network operations
    private let queue = DispatchQueue(label: "com.dogecoinkit.peer", qos: .utility)

    /// Logger
    private let logger = Logger(subsystem: "DogecoinKit", category: "Peer")

    /// Create a peer connection
    public init(host: String, port: UInt16? = nil, network: DogecoinNetwork = .mainnet) {
        self.id = UUID()
        self.host = host
        self.port = port ?? NetworkConstants.port(for: network)
        self.network = network
        self.nonce = UInt64.random(in: 0...UInt64.max)
    }

    /// Connect to the peer
    public func connect() {
        guard state == .disconnected else {
            logger.warning("Cannot connect: peer is in state \(String(describing: self.state))")
            return
        }

        state = .connecting
        logger.info("Connecting to \(self.host):\(self.port)")

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )

        let parameters = NWParameters.tcp
        parameters.prohibitExpensivePaths = false
        parameters.prohibitConstrainedPaths = false

        connection = NWConnection(to: endpoint, using: parameters)
        connection?.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state)
        }

        startReceiving()
        connection?.start(queue: queue)

        // Start connection timeout timer
        startConnectionTimeoutTimer()
    }

    // MARK: - Timeout Management

    private func startConnectionTimeoutTimer() {
        cancelConnectionTimeoutTimer()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + connectionTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.state == .connecting || self.state == .connected {
                self.logger.warning("Connection timeout for \(self.host)")
                self.handleTimeout(.connection)
            }
        }
        timer.resume()
        connectionTimeoutTimer = timer
    }

    private func cancelConnectionTimeoutTimer() {
        connectionTimeoutTimer?.cancel()
        connectionTimeoutTimer = nil
    }

    private func startHandshakeTimeoutTimer() {
        cancelHandshakeTimeoutTimer()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + handshakeTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.state == .handshaking {
                self.logger.warning("Handshake timeout for \(self.host)")
                self.handleTimeout(.handshake)
            }
        }
        timer.resume()
        handshakeTimeoutTimer = timer
    }

    private func cancelHandshakeTimeoutTimer() {
        handshakeTimeoutTimer?.cancel()
        handshakeTimeoutTimer = nil
    }

    private func startPingTimeoutTimer() {
        cancelPingTimeoutTimer()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pingTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.pendingPingNonce != nil {
                self.logger.warning("Ping timeout for \(self.host)")
                self.handleTimeout(.ping)
            }
        }
        timer.resume()
        pingTimeoutTimer = timer
    }

    private func cancelPingTimeoutTimer() {
        pingTimeoutTimer?.cancel()
        pingTimeoutTimer = nil
    }

    private func cancelAllTimeoutTimers() {
        cancelConnectionTimeoutTimer()
        cancelHandshakeTimeoutTimer()
        cancelPingTimeoutTimer()
    }

    /// Timeout types
    public enum TimeoutType: String, Sendable {
        case connection = "Connection timeout"
        case handshake = "Handshake timeout"
        case ping = "Ping timeout"
    }

    private func handleTimeout(_ type: TimeoutType) {
        let error = PeerError.timeout(type)
        logger.error("Peer \(self.host): \(type.rawValue)")
        delegate?.peer(self, didFailWithError: error)
        disconnect()
    }

    /// Peer errors
    public enum PeerError: Error, LocalizedError {
        case timeout(TimeoutType)
        case invalidMessage(ProtocolMessage.ParseError)
        case invalidMagic(expected: UInt32, got: UInt32)
        case connectionFailed

        public var errorDescription: String? {
            switch self {
            case .timeout(let type):
                return type.rawValue
            case .invalidMessage(let reason):
                return "Invalid message received: \(reason)"
            case .invalidMagic(let expected, let got):
                return "Invalid network magic (expected \(expected), got \(got))"
            case .connectionFailed:
                return "Connection failed"
            }
        }
    }

    /// Disconnect from the peer
    public func disconnect() {
        guard state != .disconnected && state != .disconnecting else { return }

        state = .disconnecting
        logger.info("Disconnecting from \(self.host):\(self.port)")

        // Cancel all timeout timers
        cancelAllTimeoutTimers()

        connection?.cancel()
        connection = nil
        state = .disconnected
    }

    /// Send a protocol message
    public func send(_ message: ProtocolMessage) {
        guard let connection = connection, state == .ready || state == .handshaking else {
            logger.warning("Cannot send message: not connected")
            return
        }

        let data = message.serialize()
        logger.debug("Sending \(message.command) message (\(data.count) bytes)")

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("Send error: \(error.localizedDescription)")
            }
        })
    }

    /// Send a version message
    public func sendVersion(startHeight: Int32 = 0) {
        let version = VersionMessage(
            nonce: nonce,
            startHeight: startHeight
        )
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.version, payload: version.serialize())
        send(message)
    }

    /// Send a verack message
    public func sendVerack() {
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.verack, payload: Data())
        send(message)
    }

    /// Send a ping message
    public func sendPing() {
        let ping = PingMessage()
        pendingPingNonce = ping.nonce
        lastPingTime = Date()

        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.ping, payload: ping.serialize())
        send(message)

        // Start ping timeout timer
        startPingTimeoutTimer()
    }

    /// Send a pong message in response to a ping
    public func sendPong(nonce: UInt64) {
        let pong = PongMessage(nonce: nonce)
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.pong, payload: pong.serialize())
        send(message)
    }

    /// Send a getheaders message
    public func sendGetHeaders(locatorHashes: [Data], hashStop: Data = Data(count: 32)) {
        let getHeaders = GetHeadersMessage(locatorHashes: locatorHashes, hashStop: hashStop)
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.getheaders, payload: getHeaders.serialize())
        send(message)
    }

    /// Send a getdata message
    public func sendGetData(inventory: [InventoryVector]) {
        let getData = GetDataMessage(inventory: inventory)
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.getdata, payload: getData.serialize())
        send(message)
    }

    /// Send a transaction message
    public func sendTransaction(_ txMessage: TxMessage) {
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.tx, payload: txMessage.serialize())
        send(message)
    }

    /// Send an inv message announcing a transaction
    public func sendInv(inventory: [InventoryVector]) {
        let inv = InvMessage(inventory: inventory)
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.inv, payload: inv.serialize())
        send(message)
    }

    /// Send a filterload message to configure bloom filtering
    public func sendFilterLoad(_ filter: BloomFilter) {
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.filterload, payload: filter.loadMessage().serialize())
        send(message)
    }

    /// Send a filteradd message to add an element to the bloom filter
    public func sendFilterAdd(element: Data) {
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.filteradd, payload: FilterAddMessage(element: element).serialize())
        send(message)
    }

    /// Send a filterclear message to disable bloom filtering
    public func sendFilterClear() {
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.filterclear, payload: FilterClearMessage().serialize())
        send(message)
    }

    // MARK: - Private Methods

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("Connection ready to \(self.host):\(self.port)")
            self.state = .connected
            beginHandshake()

        case .failed(let error):
            logger.error("Connection failed: \(error.localizedDescription)")
            self.state = .disconnected
            connection = nil
            delegate?.peer(self, didFailWithError: error)

        case .cancelled:
            logger.info("Connection cancelled")
            self.state = .disconnected
            connection = nil

        case .waiting(let error):
            logger.warning("Connection waiting: \(error.localizedDescription)")

        default:
            break
        }
    }

    private func beginHandshake() {
        state = .handshaking
        cancelConnectionTimeoutTimer()
        startHandshakeTimeoutTimer()
        sendVersion(startHeight: 0)
    }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.error("Receive error: \(error.localizedDescription)")
                self.disconnect()
                return
            }

            if let data = content {
                self.receiveBuffer.append(data)
                self.processReceiveBuffer()
            }

            if isComplete {
                self.logger.info("Connection closed by peer")
                self.disconnect()
            } else {
                self.startReceiving()
            }
        }
    }

    private func processReceiveBuffer() {
        let expectedMagic = NetworkConstants.magic(for: network)

        while true {
            switch ProtocolMessage.parseDetailed(from: receiveBuffer) {
            case .message(let message, let remaining):
                receiveBuffer = remaining

                guard message.magic == expectedMagic else {
                    handleProtocolError(.invalidMagic(expected: expectedMagic, got: message.magic))
                    return
                }

                handleMessage(message)

            case .incomplete:
                return

            case .invalid(let error):
                handleProtocolError(.invalidMessage(error))
                return
            }
        }
    }

    private func handleProtocolError(_ error: PeerError) {
        logger.error("Protocol error from \(self.host): \(error.localizedDescription)")
        delegate?.peer(self, didFailWithError: error)
        disconnect()
    }

    private func handleMessage(_ message: ProtocolMessage) {
        logger.debug("Received \(message.command) message")

        switch message.command {
        case ProtocolMessage.Command.version:
            handleVersionMessage(message.payload)

        case ProtocolMessage.Command.verack:
            handleVerackMessage()

        case ProtocolMessage.Command.ping:
            handlePingMessage(message.payload)

        case ProtocolMessage.Command.pong:
            handlePongMessage(message.payload)

        case ProtocolMessage.Command.addr,
             ProtocolMessage.Command.getaddr:
            delegate?.peer(self, didReceiveMessage: message)

        default:
            // Forward other messages to delegate
            delegate?.peer(self, didReceiveMessage: message)
        }
    }

    private func handleVersionMessage(_ payload: Data) {
        guard let version = VersionMessage.parse(from: payload) else {
            logger.error("Failed to parse version message")
            return
        }

        peerVersion = version
        logger.info("Peer version: \(version.userAgent), height: \(version.startHeight)")

        sendVerack()
    }

    private func handleVerackMessage() {
        cancelHandshakeTimeoutTimer()
        logger.info("Handshake complete with \(self.host):\(self.port)")
        state = .ready

        if !didRequestAddresses {
            sendGetAddr()
            didRequestAddresses = true
        }
    }

    private func handlePingMessage(_ payload: Data) {
        guard let ping = PingMessage.parse(from: payload) else { return }
        sendPong(nonce: ping.nonce)
    }

    private func handlePongMessage(_ payload: Data) {
        guard let pong = PongMessage.parse(from: payload) else { return }

        if let pendingNonce = pendingPingNonce, let lastPing = lastPingTime, pong.nonce == pendingNonce {
            cancelPingTimeoutTimer()
            roundTripTime = Date().timeIntervalSince(lastPing)
            logger.debug("RTT: \(self.roundTripTime ?? 0)s")
        }

        pendingPingNonce = nil
    }

    /// Request peer addresses
    public func sendGetAddr() {
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.getaddr, payload: Data())
        send(message)
    }
}

// MARK: - Equatable

extension Peer: Equatable {
    public static func == (lhs: Peer, rhs: Peer) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Hashable

extension Peer: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - CustomStringConvertible

extension Peer: CustomStringConvertible {
    public var description: String {
        "Peer(\(host):\(port), state: \(state))"
    }
}
