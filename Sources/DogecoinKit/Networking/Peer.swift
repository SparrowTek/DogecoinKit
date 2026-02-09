import Foundation
import Network
import os.log

/// Delegate for peer events
public protocol PeerDelegate: AnyObject, Sendable {
    /// Called when the peer connection state changes
    func peer(_ peer: Peer, didChangeState state: Peer.State) async

    /// Called when a message is received from the peer
    func peer(_ peer: Peer, didReceiveMessage message: ProtocolMessage) async

    /// Called when the peer connection fails
    func peer(_ peer: Peer, didFailWithError error: Error) async
}

/// A connection to a Dogecoin peer
public actor Peer {
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
    public nonisolated let id: UUID

    /// Host address
    public nonisolated let host: String

    /// Port number
    public nonisolated let port: UInt16

    /// Network type
    public nonisolated let network: DogecoinNetwork

    /// Delegate for events
    public weak var delegate: (any PeerDelegate)?

    /// Set the delegate (for cross-actor assignment)
    public func setDelegate(_ delegate: (any PeerDelegate)?) {
        self.delegate = delegate
    }

    /// Our nonce for this connection
    public nonisolated let nonce: UInt64

    // MARK: - State

    /// Current connection state
    public private(set) var state: State = .disconnected

    /// Version message received from peer
    public private(set) var peerVersion: VersionMessage?

    /// Last ping time
    public private(set) var lastPingTime: Date?

    /// Round-trip time in seconds
    public private(set) var roundTripTime: TimeInterval?

    // MARK: - Private State

    private var pendingPingNonce: UInt64?
    private var didRequestAddresses = false
    private var connectionTimeoutTask: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var pingTimeoutTask: Task<Void, Never>?
    private var connection: NWConnection?
    private var receiveBuffer = Data()

    // MARK: - Configuration

    /// Connection timeout in seconds
    public var connectionTimeout: TimeInterval = 30

    /// Handshake timeout in seconds
    public var handshakeTimeout: TimeInterval = 60

    /// Ping timeout in seconds (disconnect if no pong received)
    public var pingTimeout: TimeInterval = 120

    /// Shared network queue for NWConnection callbacks
    private static let networkQueue = DispatchQueue(label: "com.dogecoinkit.peer.network", qos: .utility)

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

    deinit {
        connectionTimeoutTask?.cancel()
        handshakeTimeoutTask?.cancel()
        pingTimeoutTask?.cancel()
        connection?.cancel()
    }

    // MARK: - State Updates

    private func updateState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        let delegate = self.delegate
        Task { [weak self] in
            guard let self else { return }
            await delegate?.peer(self, didChangeState: newState)
        }
    }

    // MARK: - Public API

    /// Connect to the peer
    public func connect() {
        guard state == .disconnected else {
            logger.warning("Cannot connect: peer is in state \(String(describing: self.state))")
            return
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            logger.error("Invalid port: \(self.port)")
            return
        }

        updateState(.connecting)
        logger.info("Connecting to \(self.host):\(self.port)")

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort
        )

        let parameters = NWParameters.tcp
        parameters.prohibitExpensivePaths = false
        parameters.prohibitConstrainedPaths = false

        let conn = NWConnection(to: endpoint, using: parameters)
        connection = conn

        conn.stateUpdateHandler = { [weak self] nwState in
            Task { [weak self] in
                await self?.handleConnectionState(nwState)
            }
        }

        startReceiving()
        conn.start(queue: Self.networkQueue)
        startConnectionTimeout()
    }

    /// Disconnect from the peer
    public func disconnect() {
        guard state != .disconnected && state != .disconnecting else { return }

        updateState(.disconnecting)
        logger.info("Disconnecting from \(self.host):\(self.port)")

        cancelAllTimeouts()
        connection?.cancel()
        connection = nil
        updateState(.disconnected)
    }

    /// Send a protocol message
    public func send(_ message: ProtocolMessage) {
        guard let connection, state == .ready || state == .handshaking else {
            logger.warning("Cannot send message: not connected")
            return
        }

        let data = message.serialize()
        logger.debug("Sending \(message.command) message (\(data.count) bytes)")

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                Task { [weak self] in
                    self?.logger.error("Send error: \(error.localizedDescription)")
                }
            }
        })
    }

    /// Send a ping message
    public func sendPing() {
        let ping = PingMessage()
        pendingPingNonce = ping.nonce
        lastPingTime = Date()

        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.ping, payload: ping.serialize())
        send(message)

        startPingTimeout()
    }

    // MARK: - Timeout Management

    private func startConnectionTimeout() {
        connectionTimeoutTask?.cancel()
        let timeout = connectionTimeout
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let currentState = await self.state
            if currentState == .connecting || currentState == .connected {
                self.logger.warning("Connection timeout for \(self.host)")
                await self.handleTimeout(.connection)
            }
        }
    }

    private func startHandshakeTimeout() {
        handshakeTimeoutTask?.cancel()
        let timeout = handshakeTimeout
        handshakeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let currentState = await self.state
            if currentState == .handshaking {
                self.logger.warning("Handshake timeout for \(self.host)")
                await self.handleTimeout(.handshake)
            }
        }
    }

    private func startPingTimeout() {
        pingTimeoutTask?.cancel()
        let timeout = pingTimeout
        pingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if await self.pendingPingNonce != nil {
                self.logger.warning("Ping timeout for \(self.host)")
                await self.handleTimeout(.ping)
            }
        }
    }

    private func cancelAllTimeouts() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        pingTimeoutTask?.cancel()
        pingTimeoutTask = nil
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
        let delegate = self.delegate
        Task { [weak self] in
            guard let self else { return }
            await delegate?.peer(self, didFailWithError: error)
        }
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

    /// Request peer addresses
    public func sendGetAddr() {
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.getaddr, payload: Data())
        send(message)
    }

    // MARK: - Private Methods

    private func handleConnectionState(_ connectionState: NWConnection.State) {
        switch connectionState {
        case .ready:
            logger.info("Connection ready to \(self.host):\(self.port)")
            updateState(.connected)
            beginHandshake()

        case .failed(let error):
            logger.error("Connection failed: \(error.localizedDescription)")
            updateState(.disconnected)
            connection = nil
            let delegate = self.delegate
            Task { [weak self] in
                guard let self else { return }
                await delegate?.peer(self, didFailWithError: error)
            }

        case .cancelled:
            logger.info("Connection cancelled")
            updateState(.disconnected)
            connection = nil

        case .waiting(let error):
            logger.warning("Connection waiting: \(error.localizedDescription)")

        default:
            break
        }
    }

    private func beginHandshake() {
        updateState(.handshaking)
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        startHandshakeTimeout()
        sendVersion(startHeight: 0)
    }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { [weak self] in
                guard let self else { return }
                await self.handleReceived(content: content, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleReceived(content: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            logger.error("Receive error: \(error.localizedDescription)")
            disconnect()
            return
        }

        if let data = content {
            receiveBuffer.append(data)
            processReceiveBuffer()
        }

        if isComplete {
            logger.info("Connection closed by peer")
            disconnect()
        } else {
            startReceiving()
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
        let delegate = self.delegate
        Task { [weak self] in
            guard let self else { return }
            await delegate?.peer(self, didFailWithError: error)
        }
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
            let delegate = self.delegate
            Task { [weak self] in
                guard let self else { return }
                await delegate?.peer(self, didReceiveMessage: message)
            }

        default:
            let delegate = self.delegate
            Task { [weak self] in
                guard let self else { return }
                await delegate?.peer(self, didReceiveMessage: message)
            }
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
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        logger.info("Handshake complete with \(self.host):\(self.port)")
        updateState(.ready)

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

        if let pendingNonce = pendingPingNonce, pong.nonce == pendingNonce {
            if let lastPing = lastPingTime {
                pingTimeoutTask?.cancel()
                pingTimeoutTask = nil
                let rtt = Date().timeIntervalSince(lastPing)
                roundTripTime = rtt
                logger.debug("RTT: \(rtt)s")
            }
        }

        pendingPingNonce = nil
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
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - CustomStringConvertible

extension Peer: CustomStringConvertible {
    nonisolated public var description: String {
        "Peer(\(host):\(port))"
    }
}
