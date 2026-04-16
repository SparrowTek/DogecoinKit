import Foundation
import Network
import os.log

public actor ElectrumClient {

    // MARK: - Properties

    private let server: ElectrumServer
    private var connection: NWConnection?
    private var requestId: Int = 0
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
    private var receiveBuffer = Data()
    private var isConnected = false
    private var subscriptionHandlers: [String: @Sendable (String) -> Void] = [:]
    private var headersHandler: (@Sendable (ElectrumHeader) -> Void)?
    private var didResumeConnectionContinuation = false
    private var connectionContinuation: CheckedContinuation<Void, Error>?

    private let connectionTimeout: TimeInterval = 30
    private let requestTimeout: TimeInterval = 60

    private let logger = Logger(subsystem: "DogecoinKit", category: "electrum")

    // MARK: - Initialization

    public init(server: ElectrumServer) {
        self.server = server
    }

    // MARK: - Connection Management

    public func connect() async throws {
        guard !isConnected else {
            logger.debug("Already connected to \(self.server.host, privacy: .public), skipping")
            return
        }
        didResumeConnectionContinuation = false

        logger.info("Connecting to \(self.server.host, privacy: .public):\(self.server.port) (SSL: \(self.server.useSSL))")

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(server.host),
            port: NWEndpoint.Port(integerLiteral: UInt16(server.port))
        )

        let parameters: NWParameters
        if server.useSSL {
            parameters = NWParameters(tls: Self.makeTLSOptions(serverHost: server.host))
        } else {
            parameters = NWParameters.tcp
        }

        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectionContinuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                Task { [weak self] in
                    await self?.handleStateUpdate(state)
                }
            }
            connection.start(queue: .global())

            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.connectionTimeout * 1_000_000_000))
                await self.handleConnectionTimeout()
            }
        }

        // Start receiving data
        Task {
            await receiveLoop()
        }

        // Perform version handshake
        do {
            logger.debug("Connection established, performing version handshake")
            let version = try await serverVersion()
            logger.info("Connected to \(self.server.host, privacy: .public) — server version \(version.joined(separator: " "), privacy: .public)")
            isConnected = true
        } catch {
            logger.error("Version handshake with \(self.server.host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            disconnect()
            throw error
        }
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        headersHandler = nil
        subscriptionHandlers.removeAll()
        receiveBuffer.removeAll()
        resumeConnectionContinuation(throwing: ElectrumError.serverDisconnected)

        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: ElectrumError.serverDisconnected)
        }
        pendingRequests.removeAll()
    }

    /// Single point of resume for `connectionContinuation`. Guarantees that the
    /// checked continuation is resumed at most once across `connect()`'s three
    /// concurrent completion paths (state updates, timeout task, and
    /// `disconnect()`). Calling after the continuation has already been
    /// resumed is a no-op.
    private func resumeConnectionContinuation(throwing error: Error? = nil) {
        guard !didResumeConnectionContinuation,
              let continuation = connectionContinuation else {
            return
        }
        didResumeConnectionContinuation = true
        connectionContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func handleStateUpdate(_ state: NWConnection.State) {
        logger.debug("\(self.server.host, privacy: .public) connection state: \(String(describing: state), privacy: .public)")

        switch state {
        case .ready:
            resumeConnectionContinuation()
        case .failed(let error):
            logger.error("Connection to \(self.server.host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            resumeConnectionContinuation(throwing: ElectrumError.connectionFailed(error.localizedDescription))
        case .cancelled:
            logger.info("Connection to \(self.server.host, privacy: .public) cancelled")
            resumeConnectionContinuation(throwing: ElectrumError.serverDisconnected)
        default:
            break
        }
    }

    private func handleConnectionTimeout() {
        guard !didResumeConnectionContinuation else { return }
        resumeConnectionContinuation(throwing: ElectrumError.connectionTimeout)
        connection?.cancel()
    }

    // MARK: - TLS

    /// Builds hardened TLS options for Electrum connections.
    ///
    /// Hardening applied:
    /// - Minimum TLS protocol pinned to 1.2 (blocks legacy TLS 1.0/1.1 downgrade).
    /// - Explicit SNI set to the configured server hostname — ensures the
    ///   server presents a certificate for the host we intended to reach and
    ///   prevents accidental matching against an unrelated cert on shared
    ///   hosting.
    ///
    /// Default system trust-chain evaluation remains in place. A future pass
    /// can layer certificate pinning via `sec_protocol_options_set_verify_block`
    /// on top of this; for now the defaults plus min-version + SNI are the
    /// correctness floor we want.
    private static func makeTLSOptions(serverHost: String) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let securityOptions = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
        serverHost.withCString { cString in
            sec_protocol_options_set_tls_server_name(securityOptions, cString)
        }
        return options
    }

    // MARK: - Send/Receive

    private func sendRequest<T: Decodable & Sendable>(_ method: ElectrumMethod, params: [ElectrumParam] = []) async throws -> T {
        guard let connection = connection else {
            logger.error("sendRequest(\(method.rawValue, privacy: .public)) failed: not connected")
            throw ElectrumError.serverDisconnected
        }

        requestId += 1
        let currentId = requestId

        let request = ElectrumRequest(id: currentId, method: method.rawValue, params: params)
        let encoder = JSONEncoder()
        var data = try encoder.encode(request)
        data.append(0x0a) // Newline delimiter

        // Send request
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: ElectrumError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }

        // Wait for response
        let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pendingRequests[currentId] = continuation

            // Set timeout
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.requestTimeout * 1_000_000_000))
                await self.handleRequestTimeout(id: currentId)
            }
        }

        // Parse response
        let decoder = JSONDecoder()
        let response = try decoder.decode(ElectrumResponse<T>.self, from: responseData)

        if let error = response.error {
            logger.error("Request #\(currentId, privacy: .public) (\(method.rawValue, privacy: .public)) error: \(error.code, privacy: .public) — \(error.message, privacy: .public)")
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

    private func handleRequestTimeout(id: Int) {
        if let pending = pendingRequests.removeValue(forKey: id) {
            pending.resume(throwing: ElectrumError.connectionTimeout)
        }
    }

    private func receiveLoop() async {
        guard let connection = connection else { return }

        while true {
            do {
                let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let data = data {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: ElectrumError.serverDisconnected)
                        }
                    }
                }

                receiveBuffer.append(data)
                await processReceiveBuffer()

            } catch {
                isConnected = false
                break
            }
        }
    }

    private func processReceiveBuffer() async {
        while let newlineIndex = receiveBuffer.firstIndex(of: 0x0a) {
            let messageData = receiveBuffer[..<newlineIndex]
            receiveBuffer = receiveBuffer[(newlineIndex + 1)...]

            await handleMessage(Data(messageData))
        }
    }

    private func handleMessage(_ data: Data) async {
        // Try to parse as a response with ID
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? Int,
           let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(returning: data)
            return
        }

        // Try to parse as a subscription notification
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let method = json["method"] as? String,
           let params = json["params"] as? [Any] {

            if method == ElectrumMethod.blockchainHeadersSubscribe.rawValue,
               let headerObject = params.first,
               let headerData = try? JSONSerialization.data(withJSONObject: headerObject),
               let header = try? JSONDecoder().decode(ElectrumHeader.self, from: headerData) {
                headersHandler?(header)
                return
            }

            if params.count >= 2, let scriptHash = params[0] as? String {
                if let handler = subscriptionHandlers[scriptHash] {
                    let status = params[1] as? String ?? ""
                    handler(status)
                }
            }
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
        return try await sendRequest(.blockchainScripthashSubscribe, params: [.string(scriptHash)])
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
