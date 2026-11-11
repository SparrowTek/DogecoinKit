import Foundation
#if canImport(os)
import os.log
#endif

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
///
/// Delegate callbacks arrive in exactly the order things happened on the
/// wire, and the connection reads no further until the delegate has handled
/// each message — a slow consumer throttles the peer through TCP instead of
/// buffering without bound.
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

    private let makeStream: ByteStreamFactory

    /// The live connection. Events from any other stream are stale.
    private var stream: (any ByteStream)?
    private var writer: OrderedStreamWriter?
    private var connectionTask: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var pingTimeoutTask: Task<Void, Never>?
    private var pendingPingNonce: UInt64?
    private var didReceiveVerack = false
    private var didRequestAddresses = false
    private var receiveBuffer = Data()

    // MARK: - Configuration

    /// Connection timeout in seconds
    public var connectionTimeout: TimeInterval = 30

    /// Handshake timeout in seconds
    public var handshakeTimeout: TimeInterval = 60

    /// Ping timeout in seconds (disconnect if no pong received)
    public var pingTimeout: TimeInterval = 120

    /// Sets the timeouts — actor properties cannot be assigned from outside
    /// the actor, so this is the way to change them. Applies to the next
    /// connection attempt, handshake, or ping.
    public func configureTimeouts(connection: TimeInterval? = nil, handshake: TimeInterval? = nil, ping: TimeInterval? = nil) {
        if let connection { connectionTimeout = connection }
        if let handshake { handshakeTimeout = handshake }
        if let ping { pingTimeout = ping }
    }

    /// Logger
    private let logger = Logger(subsystem: "DogecoinKit", category: "Peer")

    /// Create a peer connection
    public init(host: String, port: UInt16? = nil, network: DogecoinNetwork = .mainnet) {
        self.init(host: host, port: port, network: network, streamFactory: defaultByteStreamFactory)
    }

    init(host: String, port: UInt16?, network: DogecoinNetwork, streamFactory: @escaping ByteStreamFactory) {
        self.id = UUID()
        self.host = host
        self.port = port ?? NetworkConstants.port(for: network)
        self.network = network
        self.nonce = UInt64.random(in: 0...UInt64.max)
        self.makeStream = streamFactory
    }

    deinit {
        connectionTask?.cancel()
        handshakeTimeoutTask?.cancel()
        pingTimeoutTask?.cancel()
        stream?.close()
    }

    // MARK: - State Updates

    private func updateState(_ newState: State) async {
        guard state != newState else { return }
        state = newState
        await delegate?.peer(self, didChangeState: newState)
    }

    // MARK: - Public API

    /// Connect to the peer
    public func connect() async {
        guard state == .disconnected else {
            logger.warning("Cannot connect: peer is in state \(String(describing: self.state))")
            return
        }

        let stream = makeStream(host, port, false)
        self.stream = stream
        writer = OrderedStreamWriter(stream: stream) { [weak self] error in
            await self?.connectionEnded(stream, error: error)
        }
        receiveBuffer = Data()
        pendingPingNonce = nil
        peerVersion = nil
        didReceiveVerack = false

        logger.info("Connecting to \(self.host):\(self.port)")
        await updateState(.connecting)

        let timeout = Duration.seconds(connectionTimeout)
        connectionTask = Task { [weak self] in
            do {
                try await stream.open(timeout: timeout)
            } catch {
                await self?.connectionEnded(stream, error: error)
                return
            }

            guard await self?.connectionOpened(stream) == true else { return }

            do {
                while let chunk = try await stream.read() {
                    guard let self else { return }
                    await self.received(chunk, from: stream)
                }
                await self?.connectionEnded(stream, error: nil)
            } catch {
                await self?.connectionEnded(stream, error: error)
            }
        }
    }

    /// Disconnect from the peer
    public func disconnect() async {
        guard state != .disconnected && state != .disconnecting else { return }

        logger.info("Disconnecting from \(self.host):\(self.port)")
        await updateState(.disconnecting)
        closeStream()
        await updateState(.disconnected)
    }

    /// Send a protocol message
    /// - Returns: Whether the message was handed to a live connection
    @discardableResult
    public func send(_ message: ProtocolMessage) -> Bool {
        guard let writer, state == .ready || state == .handshaking else {
            logger.warning("Cannot send message: not connected")
            return false
        }

        let data = message.serialize()
        logger.debug("Sending \(message.command) message (\(data.count) bytes)")
        writer.write(data)
        return true
    }

    /// Send a ping message
    ///
    /// While a ping is unanswered no new one is sent, so the timeout keeps
    /// running: a peer that never answers is dropped after ``pingTimeout``.
    public func sendPing() {
        guard pendingPingNonce == nil else { return }

        let ping = PingMessage()
        pendingPingNonce = ping.nonce
        lastPingTime = Date()

        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.ping, payload: ping.serialize())
        send(message)

        startPingTimeout()
    }

    // MARK: - Timeout Management

    private func startHandshakeTimeout() {
        handshakeTimeoutTask?.cancel()
        let timeout = handshakeTimeout
        handshakeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.handshakeTimedOut()
        }
    }

    private func handshakeTimedOut() async {
        guard state == .handshaking || state == .connected else { return }
        logger.warning("Handshake timeout for \(self.host)")
        await handleTimeout(.handshake)
    }

    private func startPingTimeout() {
        pingTimeoutTask?.cancel()
        let timeout = pingTimeout
        pingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.pingTimedOut()
        }
    }

    private func pingTimedOut() async {
        guard pendingPingNonce != nil, state == .ready else { return }
        logger.warning("Ping timeout for \(self.host)")
        await handleTimeout(.ping)
    }

    private func cancelAllTimeouts() {
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

    private func handleTimeout(_ type: TimeoutType) async {
        logger.error("Peer \(self.host): \(type.rawValue)")
        await delegate?.peer(self, didFailWithError: PeerError.timeout(type))
        await disconnect()
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
    ///
    /// Announces `relay = false` (BIP 37): no transaction announcements until
    /// a bloom filter is loaded, rather than the whole mempool.
    public func sendVersion(startHeight: Int32 = 0) {
        let version = VersionMessage(
            nonce: nonce,
            startHeight: startHeight,
            relay: false
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
    /// - Returns: Whether the transaction was handed to a live connection
    @discardableResult
    public func sendTransaction(_ txMessage: TxMessage) -> Bool {
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.tx, payload: txMessage.serialize())
        return send(message)
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

    /// Request peer addresses
    public func sendGetAddr() {
        let message = ProtocolMessage(network: network, command: ProtocolMessage.Command.getaddr, payload: Data())
        send(message)
    }

    // MARK: - Connection Events

    /// - Returns: `false` if this stream has been replaced or closed meanwhile.
    private func connectionOpened(_ source: any ByteStream) async -> Bool {
        guard source === stream else { return false }

        logger.info("Connection ready to \(self.host):\(self.port)")
        await updateState(.connected)
        guard source === stream else { return false }

        await updateState(.handshaking)
        startHandshakeTimeout()
        sendVersion(startHeight: 0)
        return source === stream
    }

    private func connectionEnded(_ source: any ByteStream, error: Error?) async {
        guard source === stream else { return }

        if let error {
            logger.error("Connection to \(self.host) failed: \(error.localizedDescription)")
        } else {
            logger.info("Connection closed by peer")
        }

        let wasEstablished = state == .ready || state == .handshaking || state == .connected
        closeStream()
        if let error, !wasEstablished, !(error is CancellationError) {
            let reported: Error = (error as? ByteStreamError) == .timedOut ? PeerError.timeout(.connection) : error
            await delegate?.peer(self, didFailWithError: reported)
        }
        await updateState(.disconnected)
    }

    private func closeStream() {
        cancelAllTimeouts()
        connectionTask?.cancel()
        connectionTask = nil
        stream?.close()
        stream = nil
        writer = nil
        receiveBuffer = Data()
        pendingPingNonce = nil
    }

    private func received(_ chunk: Data, from source: any ByteStream) async {
        guard source === stream else { return }
        receiveBuffer.append(chunk)

        let expectedMagic = NetworkConstants.magic(for: network)

        // One read often carries many messages. Step through them in place
        // and drop them from the buffer together at the end, instead of
        // copying the rest of the buffer once per message.
        var handled = 0

        // A handler may close this connection, which empties the buffer:
        // from then on neither it nor `handled` means anything here.
        while source === stream {
            switch ProtocolMessage.frame(in: receiveBuffer, at: handled) {
            case .message(let message, let length):
                handled += length

                guard message.magic == expectedMagic else {
                    await handleProtocolError(.invalidMagic(expected: expectedMagic, got: message.magic))
                    return
                }

                await handleMessage(message)

            case .incomplete:
                receiveBuffer.removeFirst(handled)
                return

            case .invalid(let error):
                await handleProtocolError(.invalidMessage(error))
                return
            }
        }
    }

    private func handleProtocolError(_ error: PeerError) async {
        logger.error("Protocol error from \(self.host): \(error.localizedDescription)")
        await delegate?.peer(self, didFailWithError: error)
        await disconnect()
    }

    private func handleMessage(_ message: ProtocolMessage) async {
        logger.debug("Received \(message.command) message")

        switch message.command {
        case ProtocolMessage.Command.version:
            await handleVersionMessage(message.payload)

        case ProtocolMessage.Command.verack:
            await handleVerackMessage()

        case ProtocolMessage.Command.ping:
            handlePingMessage(message.payload)

        case ProtocolMessage.Command.pong:
            await handlePongMessage(message)

        default:
            await delegate?.peer(self, didReceiveMessage: message)
        }
    }

    private func handleVersionMessage(_ payload: Data) async {
        guard peerVersion == nil else { return }

        guard let version = VersionMessage.parse(from: payload) else {
            logger.error("Failed to parse version message")
            await handleProtocolError(.connectionFailed)
            return
        }

        // Our own nonce coming back means we dialed ourselves.
        guard version.nonce != nonce else {
            logger.warning("Connected to self via \(self.host); disconnecting")
            await disconnect()
            return
        }

        peerVersion = version
        logger.info("Peer version: \(version.userAgent), height: \(version.startHeight)")

        sendVerack()
        await completeHandshakeIfDone()
    }

    private func handleVerackMessage() async {
        guard state == .handshaking else { return }
        didReceiveVerack = true
        await completeHandshakeIfDone()
    }

    /// The handshake is over once the peer has both introduced itself and
    /// acknowledged us, in whichever order. Becoming ready on `verack`
    /// alone left a peer in use with no known version or height.
    private func completeHandshakeIfDone() async {
        guard state == .handshaking, didReceiveVerack, peerVersion != nil else { return }

        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        logger.info("Handshake complete with \(self.host):\(self.port)")
        await updateState(.ready)

        if !didRequestAddresses, state == .ready {
            sendGetAddr()
            didRequestAddresses = true
        }
    }

    private func handlePingMessage(_ payload: Data) {
        guard let ping = PingMessage.parse(from: payload) else { return }
        sendPong(nonce: ping.nonce)
    }

    private func handlePongMessage(_ message: ProtocolMessage) async {
        guard let pong = PongMessage.parse(from: message.payload) else { return }

        // Not the answer to this peer's own keepalive: someone else sent a
        // ping through `send(_:)` to learn when the peer had got that far
        // through its messages. Pass the answer on.
        guard let pendingNonce = pendingPingNonce, pong.nonce == pendingNonce else {
            await delegate?.peer(self, didReceiveMessage: message)
            return
        }

        pingTimeoutTask?.cancel()
        pingTimeoutTask = nil
        pendingPingNonce = nil

        if let lastPing = lastPingTime {
            let rtt = Date().timeIntervalSince(lastPing)
            roundTripTime = rtt
            logger.debug("RTT: \(rtt)s")
        }
    }
}

// MARK: - Equatable

extension Peer: Equatable {
    public static func == (lhs: Peer, rhs: Peer) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - CustomStringConvertible

extension Peer: CustomStringConvertible {
    nonisolated public var description: String {
        "Peer(\(host):\(port))"
    }
}
