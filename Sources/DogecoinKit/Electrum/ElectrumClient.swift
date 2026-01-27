import Foundation
import Network
import Security

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

    // MARK: - Initialization

    public init(server: ElectrumServer) {
        self.server = server
    }

    // MARK: - Connection Management

    public func connect() async throws {
        guard !isConnected else {
            print("[ElectrumClient] Already connected, skipping")
            return
        }
        didResumeConnectionContinuation = false

        print("[ElectrumClient] Connecting to \(server.host):\(server.port) (SSL: \(server.useSSL))")

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(server.host),
            port: NWEndpoint.Port(integerLiteral: UInt16(server.port))
        )

        let parameters: NWParameters
        if server.useSSL {
            let tlsOptions = NWProtocolTLS.Options()
            // Disable certificate validation for Electrum servers (they typically use self-signed certs)
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, _, completion in
                    completion(true)
                },
                .main
            )
            parameters = NWParameters(tls: tlsOptions)
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
            print("[ElectrumClient] Connection established, performing version handshake...")
            let version = try await serverVersion()
            print("[ElectrumClient] Server version: \(version)")
            isConnected = true
            print("[ElectrumClient] Successfully connected!")
        } catch {
            print("[ElectrumClient] Version handshake failed: \(error)")
            disconnect()
            throw error
        }
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        didResumeConnectionContinuation = false
        headersHandler = nil
        subscriptionHandlers.removeAll()
        receiveBuffer.removeAll()
        if let continuation = connectionContinuation {
            continuation.resume(throwing: ElectrumError.serverDisconnected)
            connectionContinuation = nil
        }

        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: ElectrumError.serverDisconnected)
        }
        pendingRequests.removeAll()
    }

    private func handleStateUpdate(_ state: NWConnection.State) {
        print("[ElectrumClient] Connection state: \(state)")
        guard !didResumeConnectionContinuation else { return }
        guard let continuation = connectionContinuation else { return }

        switch state {
        case .ready:
            print("[ElectrumClient] Connection ready!")
            didResumeConnectionContinuation = true
            connectionContinuation = nil
            continuation.resume()
        case .failed(let error):
            print("[ElectrumClient] Connection failed: \(error)")
            didResumeConnectionContinuation = true
            connectionContinuation = nil
            continuation.resume(throwing: ElectrumError.connectionFailed(error.localizedDescription))
        case .cancelled:
            print("[ElectrumClient] Connection cancelled")
            didResumeConnectionContinuation = true
            connectionContinuation = nil
            continuation.resume(throwing: ElectrumError.serverDisconnected)
        default:
            break
        }
    }

    private func handleConnectionTimeout() {
        guard !didResumeConnectionContinuation else { return }
        guard let continuation = connectionContinuation else { return }

        didResumeConnectionContinuation = true
        connectionContinuation = nil
        continuation.resume(throwing: ElectrumError.connectionTimeout)
        connection?.cancel()
    }

    // MARK: - Send/Receive

    private func sendRequest<T: Decodable & Sendable>(_ method: ElectrumMethod, params: [ElectrumParam] = []) async throws -> T {
        guard let connection = connection else {
            print("[ElectrumClient] sendRequest failed: not connected")
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
            print("[ElectrumClient] Request #\(currentId) error: \(error.code) - \(error.message)")
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
