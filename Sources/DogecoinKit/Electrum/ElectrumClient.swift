import Foundation
#if canImport(os)
import os.log
#endif

public actor ElectrumClient {

    // MARK: - Properties

    private let server: ElectrumServer
    private let makeStream: ByteStreamFactory

    /// The live connection. Callbacks from any other stream are stale and ignored.
    private var stream: (any ByteStream)?
    private var writer: OrderedStreamWriter?
    private var connectTask: Task<Void, Error>?

    private var requestId: Int = 0
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
    private var requestTimeouts: [Int: Task<Void, Never>] = [:]
    private var lineBuffer = Data()

    private var subscriptionHandlers: [String: @Sendable (String) -> Void] = [:]
    private var headersHandler: (@Sendable (ElectrumHeader) -> Void)?
    private var disconnectHandler: (@Sendable () -> Void)?

    /// Whether the version handshake has completed on a live connection
    public private(set) var isConnected = false

    private let connectionTimeout: Duration = .seconds(30)
    private let requestTimeout: Duration

    /// Upper bound for a single newline-delimited JSON-RPC line. A server (or
    /// MITM on the wire) that streams data without ever sending a newline
    /// would otherwise grow the buffer without limit until the app is killed
    /// for memory. Large-wallet history responses fit comfortably.
    private let maxReceiveBufferBytes = 8 * 1024 * 1024

    private let logger = Logger(subsystem: "DogecoinKit", category: "electrum")

    // MARK: - Initialization

    public init(server: ElectrumServer) {
        self.init(server: server, streamFactory: defaultByteStreamFactory)
    }

    init(server: ElectrumServer, streamFactory: @escaping ByteStreamFactory, requestTimeout: Duration = .seconds(60)) {
        self.server = server
        self.makeStream = streamFactory
        self.requestTimeout = requestTimeout
    }

    // MARK: - Connection Management

    /// Connects and performs the version handshake.
    ///
    /// Concurrent callers share one attempt; cancelling a caller abandons it.
    public func connect() async throws {
        if isConnected {
            logger.debug("Already connected to \(self.server.host, privacy: .public), skipping")
            return
        }

        let attempt: Task<Void, Error>
        if let connectTask {
            attempt = connectTask
        } else {
            attempt = Task { try await self.establishConnection() }
            connectTask = attempt
        }

        // A disconnect() and a fresh connect() may have replaced the attempt
        // while this caller waited; only the attempt's own callers clear it.
        defer {
            if connectTask == attempt {
                connectTask = nil
            }
        }

        try await withTaskCancellationHandler {
            try await attempt.value
        } onCancel: {
            attempt.cancel()
        }
    }

    public func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        teardown(failingWith: ElectrumError.serverDisconnected)
        headersHandler = nil
        subscriptionHandlers.removeAll()
    }

    /// Called once whenever an established connection drops unexpectedly —
    /// not after `disconnect()`.
    public func setDisconnectHandler(_ handler: (@Sendable () -> Void)?) {
        disconnectHandler = handler
    }

    private func establishConnection() async throws {
        guard let port = UInt16(exactly: server.port) else {
            throw ElectrumError.connectionFailed("Invalid port \(server.port)")
        }

        logger.info("Connecting to \(self.server.host, privacy: .public):\(port) (SSL: \(self.server.useSSL))")

        let stream = makeStream(server.host, port, server.useSSL)
        teardown(failingWith: ElectrumError.serverDisconnected)
        self.stream = stream
        writer = OrderedStreamWriter(stream: stream) { [weak self] _ in
            await self?.connectionEnded(stream)
        }

        do {
            try await stream.open(timeout: connectionTimeout)
        } catch {
            if self.stream === stream {
                teardown(failingWith: ElectrumError.serverDisconnected)
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            if error is CancellationError {
                // disconnect() closed the stream mid-handshake
                throw ElectrumError.serverDisconnected
            }
            logger.error("Connection to \(self.server.host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if let streamError = error as? ByteStreamError, streamError == .timedOut {
                throw ElectrumError.connectionTimeout
            }
            throw ElectrumError.connectionFailed(error.localizedDescription)
        }

        guard self.stream === stream else {
            throw ElectrumError.serverDisconnected
        }
        startReceiving(on: stream)

        do {
            logger.debug("Connection established, performing version handshake")
            let version = try await serverVersion()
            guard self.stream === stream else {
                throw ElectrumError.serverDisconnected
            }
            logger.info("Connected to \(self.server.host, privacy: .public) — server version \(version.joined(separator: " "), privacy: .public)")
            isConnected = true
        } catch {
            logger.error("Version handshake with \(self.server.host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if self.stream === stream {
                teardown(failingWith: ElectrumError.serverDisconnected)
            }
            throw error
        }
    }

    /// Closes the current stream and fails everything waiting on it.
    private func teardown(failingWith error: Error) {
        stream?.close()
        stream = nil
        writer = nil
        isConnected = false
        lineBuffer = Data()

        for task in requestTimeouts.values {
            task.cancel()
        }
        requestTimeouts.removeAll()

        let waiting = pendingRequests
        pendingRequests.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Send/Receive

    private func sendRequest<T: Decodable & Sendable>(_ method: ElectrumMethod, params: [ElectrumParam] = []) async throws -> T {
        guard let writer else {
            logger.error("sendRequest(\(method.rawValue, privacy: .public)) failed: not connected")
            throw ElectrumError.serverDisconnected
        }

        requestId += 1
        let id = requestId

        // Newline-delimited JSON-RPC
        let payload = try JSONEncoder().encode(ElectrumRequest(id: id, method: method.rawValue, params: params)) + Data([0x0a])

        let responseData = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                // Register before the request leaves, so even an instant reply
                // finds someone waiting for it.
                pendingRequests[id] = continuation
                requestTimeouts[id] = Task { [weak self, requestTimeout] in
                    try? await Task.sleep(for: requestTimeout)
                    guard !Task.isCancelled else { return }
                    await self?.requestTimedOut(id)
                }
                // A failed write ends the connection, failing this request too.
                writer.write(payload)
            }
        } onCancel: {
            Task { await self.failRequest(id, with: CancellationError()) }
        }

        let response = try JSONDecoder().decode(ElectrumResponse<T>.self, from: responseData)

        if let error = response.error {
            logger.error("Request #\(id, privacy: .public) (\(method.rawValue, privacy: .public)) error: \(error.code, privacy: .public) — \(error.message, privacy: .public)")
            throw ElectrumError.requestFailed(code: error.code, message: error.message)
        }

        if let result = response.result {
            return result
        }

        if T.self is ExpressibleByNilLiteral.Type {
            let none: Any? = nil
            if let value = none as? T {
                return value
            }
        }

        // Some Electrum methods return null (e.g., server.ping)
        if T.self == ElectrumNull.self, let result = ElectrumNull() as? T {
            return result
        }

        throw ElectrumError.invalidResponse("No result in response")
    }

    private func failRequest(_ id: Int, with error: Error) {
        requestTimeouts.removeValue(forKey: id)?.cancel()
        pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// Servers answer in well under a second; a request left unanswered this
    /// long means the connection is dead even if TCP has not noticed. Drop it
    /// so the owner reconnects instead of timing out request after request.
    private func requestTimedOut(_ id: Int) {
        guard pendingRequests[id] != nil else { return }
        logger.error("Request #\(id, privacy: .public) to \(self.server.host, privacy: .public) timed out — dropping the connection")
        failRequest(id, with: ElectrumError.connectionTimeout)
        if let stream {
            connectionEnded(stream)
        }
    }

    private func startReceiving(on stream: any ByteStream) {
        Task { [weak self] in
            do {
                while let chunk = try await stream.read() {
                    guard let self else { return }
                    await self.handle(chunk, from: stream)
                }
                await self?.connectionEnded(stream)
            } catch {
                await self?.connectionEnded(stream)
            }
        }
    }

    private func handle(_ chunk: Data, from source: any ByteStream) {
        guard source === stream else { return }

        lineBuffer.append(chunk)
        var consumed = lineBuffer.startIndex
        while let newline = lineBuffer[consumed...].firstIndex(of: 0x0a) {
            let line = Data(lineBuffer[consumed..<newline])
            consumed = lineBuffer.index(after: newline)
            handleMessage(line)
            // A handler may have torn the connection down.
            guard source === stream else { return }
        }
        // Copy the unconsumed tail so consumed bytes are actually released.
        lineBuffer = Data(lineBuffer[consumed...])

        // A line that exceeds the cap without a newline is a protocol
        // violation (or an attack) — drop the connection instead of
        // buffering until out-of-memory.
        if lineBuffer.count > maxReceiveBufferBytes {
            logger.error("\(self.server.host, privacy: .public) exceeded \(self.maxReceiveBufferBytes) byte line limit — disconnecting")
            connectionEnded(source)
        }
    }

    /// The live stream closed or failed: fail every in-flight request now
    /// rather than leaving callers to stall on the request timeout.
    private func connectionEnded(_ source: any ByteStream) {
        guard source === stream else { return }
        let wasConnected = isConnected
        teardown(failingWith: ElectrumError.serverDisconnected)
        if wasConnected {
            logger.info("Connection to \(self.server.host, privacy: .public) lost")
            disconnectHandler?()
        }
    }

    private func handleMessage(_ data: Data) {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(ElectrumEnvelope.self, from: data) else { return }

        if let id = envelope.id, let continuation = pendingRequests.removeValue(forKey: id) {
            requestTimeouts.removeValue(forKey: id)?.cancel()
            continuation.resume(returning: data)
            return
        }

        switch envelope.method {
        case ElectrumMethod.blockchainHeadersSubscribe.rawValue:
            if let header = (try? decoder.decode(ElectrumHeaderNotification.self, from: data))?.params.first {
                headersHandler?(header)
            }
        case ElectrumMethod.blockchainScripthashSubscribe.rawValue:
            if let params = (try? decoder.decode(ElectrumScriptHashNotification.self, from: data))?.params,
               params.count >= 2,
               let scriptHash = params[0] {
                subscriptionHandlers[scriptHash]?(params[1] ?? "")
            }
        default:
            break
        }
    }

    // MARK: - Server Methods

    public func serverVersion() async throws -> [String] {
        try await sendRequest(.serverVersion, params: [
            .string("Avocadoge"),
            .string("1.4")
        ])
    }

    public func serverPing() async throws {
        let _: ElectrumNull = try await sendRequest(.serverPing)
    }

    // MARK: - Blockchain Methods

    public func subscribeHeaders(handler: (@Sendable (ElectrumHeader) -> Void)? = nil) async throws -> ElectrumHeader {
        headersHandler = handler
        return try await sendRequest(.blockchainHeadersSubscribe)
    }

    public func getBlockHeader(height: Int) async throws -> String {
        try await sendRequest(.blockchainBlockHeader, params: [.int(height)])
    }

    public func estimateFee(blocks: Int = 6) async throws -> Double {
        try await sendRequest(.blockchainEstimateFee, params: [.int(blocks)])
    }

    // MARK: - Address Methods

    public func getBalance(scriptHash: String) async throws -> ElectrumBalance {
        try await sendRequest(.blockchainScripthashGetBalance, params: [.string(scriptHash)])
    }

    public func getHistory(scriptHash: String) async throws -> [ElectrumHistoryItem] {
        try await sendRequest(.blockchainScripthashGetHistory, params: [.string(scriptHash)])
    }

    public func listUnspent(scriptHash: String) async throws -> [ElectrumUTXO] {
        try await sendRequest(.blockchainScripthashListUnspent, params: [.string(scriptHash)])
    }

    public func subscribeScriptHash(_ scriptHash: String, handler: @escaping @Sendable (String) -> Void) async throws -> String? {
        subscriptionHandlers[scriptHash] = handler
        do {
            return try await sendRequest(.blockchainScripthashSubscribe, params: [.string(scriptHash)])
        } catch {
            subscriptionHandlers.removeValue(forKey: scriptHash)
            throw error
        }
    }

    public func unsubscribeScriptHash(_ scriptHash: String) async throws -> Bool {
        subscriptionHandlers.removeValue(forKey: scriptHash)
        return try await sendRequest(.blockchainScripthashUnsubscribe, params: [.string(scriptHash)])
    }

    // MARK: - Transaction Methods

    /// Returns raw transaction hex by default (verbose=false)
    public func getTransaction(txHash: String, verbose: Bool = false) async throws -> String {
        try await sendRequest(.blockchainTransactionGet, params: [
            .string(txHash),
            .bool(verbose)
        ])
    }

    public func broadcastTransaction(rawHex: String) async throws -> String {
        try await sendRequest(.blockchainTransactionBroadcast, params: [.string(rawHex)])
    }
}

// MARK: - Wire Envelopes

/// Just enough of a JSON-RPC message to route it: a response carries the id
/// of the request it answers, a notification carries a method name.
private struct ElectrumEnvelope: Decodable {
    let id: Int?
    let method: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case method
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // We always send numeric ids; tolerate servers that echo them as strings.
        if let numeric = try? container.decodeIfPresent(Int.self, forKey: .id) {
            id = numeric
        } else {
            id = (try? container.decodeIfPresent(String.self, forKey: .id)).flatMap { Int($0) }
        }
        method = try? container.decodeIfPresent(String.self, forKey: .method)
    }
}

private struct ElectrumHeaderNotification: Decodable {
    let params: [ElectrumHeader]
}

/// `[scripthash, status]` — the status is `null` for an address with no history.
private struct ElectrumScriptHashNotification: Decodable {
    let params: [String?]
}
