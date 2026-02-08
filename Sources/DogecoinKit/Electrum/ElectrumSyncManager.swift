import Foundation

public final class ElectrumSyncManager: @unchecked Sendable {

    // MARK: - Public Properties

    public let network: DogecoinNetwork
    public weak var delegate: BlockchainSyncDelegate?

    public var state: ElectrumSyncState { lock.withLock { _state } }
    public var currentHeight: Int32 { lock.withLock { _currentHeight } }
    public var progress: Double { lock.withLock { _progress } }
    public var connectedServer: ElectrumServer? { lock.withLock { _connectedServer } }

    // MARK: - Private State (protected by lock)

    private let lock = NSLock()
    private var _state: ElectrumSyncState = .disconnected
    private var _currentHeight: Int32 = 0
    private var _progress: Double = 0
    private var _connectedServer: ElectrumServer?
    private var _client: ElectrumClient?
    private var _addressSubscriptions: Set<String> = []
    private var _isRunning = false

    // MARK: - Immutable

    private let serverList: [ElectrumServer]

    /// Per-server connection timeout in seconds
    private let connectionTimeout: TimeInterval = 10

    // MARK: - Initialization

    public init(network: DogecoinNetwork) {
        self.network = network
        self.serverList = ElectrumServerList.servers(for: network).shuffled()
    }

    init(network: DogecoinNetwork, serverList: [ElectrumServer]) {
        self.network = network
        self.serverList = serverList
    }

    // MARK: - Public Methods

    public func start() async throws {
        let shouldStart = lock.withLock {
            guard !_isRunning else { return false }
            _isRunning = true
            return true
        }

        guard shouldStart else {
            print("[ElectrumSyncManager] Already running, skipping start")
            return
        }

        do {
            try await startSync()
        } catch {
            lock.withLock { _isRunning = false }
            throw error
        }
    }

    public func stop() {
        let existingClient: ElectrumClient? = lock.withLock {
            let client = _client
            _client = nil
            _connectedServer = nil
            _state = .disconnected
            _addressSubscriptions.removeAll()
            _isRunning = false
            return client
        }

        Task {
            await existingClient?.disconnect()
        }
    }

    public func refreshBalance(for addresses: [String]) async throws -> Int64 {
        let client = try connectedClient()

        print("[ElectrumSyncManager] Refreshing balance for \(addresses.count) addresses (parallel)...")

        // Pre-compute script hashes
        let scriptHashes = try addresses.map { address in
            (address: address, scriptHash: try ElectrumScriptHash(address: address, network: network))
        }

        // Fetch balances in parallel
        let results = try await withThrowingTaskGroup(of: (address: String, balance: ElectrumBalance).self) { group in
            for item in scriptHashes {
                group.addTask {
                    let balance = try await client.getBalance(scriptHash: item.scriptHash.scriptHash)
                    return (address: item.address, balance: balance)
                }
            }

            var balances: [(address: String, balance: ElectrumBalance)] = []
            for try await result in group {
                balances.append(result)
            }
            return balances
        }

        var totalBalance: Int64 = 0
        var addressesWithBalance = 0

        for result in results {
            let balanceSum = result.balance.confirmed + result.balance.unconfirmed
            if balanceSum > 0 {
                addressesWithBalance += 1
                print("[ElectrumSyncManager] Found balance at \(result.address): \(balanceSum) koinu")
            }
            totalBalance += balanceSum
        }

        print("[ElectrumSyncManager] Addresses with balance: \(addressesWithBalance)")
        print("[ElectrumSyncManager] Total balance: \(totalBalance) koinu (\(Double(totalBalance) / 100_000_000.0) DOGE)")
        return totalBalance
    }

    public func fetchTransactionHistory(for addresses: [String]) async throws -> [ElectrumHistoryItem] {
        let client = try connectedClient()

        print("[ElectrumSyncManager] Fetching transaction history for \(addresses.count) addresses (parallel)")

        // Pre-compute script hashes
        let scriptHashes = try addresses.map { address in
            try ElectrumScriptHash(address: address, network: network)
        }

        // Fetch history in parallel
        let results = try await withThrowingTaskGroup(of: [ElectrumHistoryItem].self) { group in
            for scriptHash in scriptHashes {
                group.addTask {
                    try await client.getHistory(scriptHash: scriptHash.scriptHash)
                }
            }

            var allItems: [[ElectrumHistoryItem]] = []
            for try await items in group {
                allItems.append(items)
            }
            return allItems
        }

        // Deduplicate by txid
        var seenTxids: Set<String> = []
        var allHistory: [ElectrumHistoryItem] = []

        for items in results {
            for item in items {
                if !seenTxids.contains(item.txHash) {
                    seenTxids.insert(item.txHash)
                    allHistory.append(item)
                }
            }
        }

        print("[ElectrumSyncManager] Total transactions found: \(allHistory.count)")

        // Sort by height (newest first), unconfirmed (height <= 0) at top
        return allHistory.sorted { lhs, rhs in
            if lhs.height <= 0 && rhs.height > 0 { return true }
            if lhs.height > 0 && rhs.height <= 0 { return false }
            return lhs.height > rhs.height
        }
    }

    public func fetchUTXOs(for addresses: [String]) async throws -> [(address: String, utxo: ElectrumUTXO)] {
        let client = try connectedClient()

        print("[ElectrumSyncManager] Fetching UTXOs for \(addresses.count) addresses (parallel)")

        // Pre-compute script hashes
        let scriptHashes = try addresses.map { address in
            (address: address, scriptHash: try ElectrumScriptHash(address: address, network: network))
        }

        // Fetch UTXOs in parallel
        let results = try await withThrowingTaskGroup(of: (address: String, utxos: [ElectrumUTXO]).self) { group in
            for item in scriptHashes {
                group.addTask {
                    let utxos = try await client.listUnspent(scriptHash: item.scriptHash.scriptHash)
                    return (address: item.address, utxos: utxos)
                }
            }

            var allResults: [(address: String, utxos: [ElectrumUTXO])] = []
            for try await result in group {
                allResults.append(result)
            }
            return allResults
        }

        var allUTXOs: [(address: String, utxo: ElectrumUTXO)] = []

        for result in results {
            for utxo in result.utxos {
                print("[ElectrumSyncManager] UTXO found: \(result.address) - \(utxo.value) koinu (\(Double(utxo.value) / 100_000_000.0) DOGE), height=\(utxo.height)")
                allUTXOs.append((address: result.address, utxo: utxo))
            }
        }

        print("[ElectrumSyncManager] Total UTXOs found: \(allUTXOs.count)")
        return allUTXOs
    }

    public func getTransaction(txid: String) async throws -> String {
        let client = try connectedClient()
        return try await client.getTransaction(txHash: txid)
    }

    public func broadcastTransaction(_ rawHex: String) async throws -> String {
        let client = try connectedClient()
        return try await client.broadcastTransaction(rawHex: rawHex)
    }

    public func subscribeToAddresses(_ addresses: [String]) async throws {
        let (client, existingSubscriptions) = try lock.withLock {
            guard let client = _client else {
                throw ElectrumError.serverDisconnected
            }
            return (client, _addressSubscriptions)
        }

        // Filter to only addresses not already subscribed
        let newAddresses = addresses.filter { !existingSubscriptions.contains($0) }
        guard !newAddresses.isEmpty else { return }

        print("[ElectrumSyncManager] Subscribing to \(newAddresses.count) addresses (parallel)")

        // Pre-compute script hashes
        let scriptHashes = try newAddresses.map { address in
            (address: address, scriptHash: try ElectrumScriptHash(address: address, network: network))
        }

        // Subscribe in parallel
        try await withThrowingTaskGroup(of: String.self) { group in
            for item in scriptHashes {
                group.addTask { [weak self] in
                    _ = try await client.subscribeScriptHash(item.scriptHash.scriptHash) { [weak self] _ in
                        guard let self else { return }
                        // Notify delegate of address activity
                        Task {
                            if let history = try? await self.fetchTransactionHistory(for: [item.address]),
                               let latest = history.first {
                                self.delegate?.syncManager(self, didUpdateTransaction: latest.txHash, confirmations: latest.height > 0 ? 1 : 0)
                            }
                        }
                    }
                    return item.address
                }
            }

            // Collect subscribed addresses
            for try await address in group {
                lock.withLock { _ = _addressSubscriptions.insert(address) }
            }
        }

        print("[ElectrumSyncManager] Subscribed to \(newAddresses.count) addresses")
    }

    public func estimateFee(blocks: Int = 6) async throws -> Double {
        let client = try connectedClient()
        return try await client.estimateFee(blocks: blocks)
    }

    // MARK: - Private Methods

    private func connectWithTimeout(_ client: ElectrumClient) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await client.connect()
            }
            group.addTask { [connectionTimeout] in
                try await Task.sleep(for: .seconds(connectionTimeout))
                throw ElectrumError.connectionTimeout
            }
            // First task to complete wins; cancel the other.
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func connectedClient() throws -> ElectrumClient {
        try lock.withLock {
            guard let client = _client else {
                throw ElectrumError.serverDisconnected
            }
            return client
        }
    }

    private func startSync() async throws {
        guard !serverList.isEmpty else {
            let error = ElectrumError.noServersAvailable
            lock.withLock { _state = .error(error.localizedDescription) }
            delegate?.syncManager(self, didEncounterError: error)
            throw error
        }

        print("[ElectrumSyncManager] Starting sync for \(network) network")
        print("[ElectrumSyncManager] Server list: \(serverList.map { "\($0.host):\($0.port)" })")
        lock.withLock { _state = .connecting }

        // Try servers until one connects
        var lastError: Error?
        for (index, server) in serverList.enumerated() {
            print("[ElectrumSyncManager] Trying server \(index + 1)/\(serverList.count): \(server.host):\(server.port)")
            let candidateClient = ElectrumClient(server: server)
            do {
                try await connectWithTimeout(candidateClient)

                lock.withLock {
                    _client = candidateClient
                    _connectedServer = server
                }

                print("[ElectrumSyncManager] Connected! Subscribing to headers...")
                // Subscribe to block headers (updates on new blocks)
                let header = try await candidateClient.subscribeHeaders { [weak self] header in
                    guard let self else { return }
                    let (height, prog) = self.lock.withLock {
                        self._currentHeight = Int32(header.height)
                        self._progress = 1.0
                        return (self._currentHeight, self._progress)
                    }
                    self.delegate?.syncManager(self, progressUpdated: prog, height: height)
                }

                let (height, prog) = lock.withLock {
                    _currentHeight = Int32(header.height)
                    _progress = 1.0
                    _state = .connected
                    return (_currentHeight, _progress)
                }

                print("[ElectrumSyncManager] Current block height: \(height)")
                delegate?.syncManager(self, progressUpdated: prog, height: height)
                delegate?.syncManagerDidComplete(self)
                return

            } catch {
                print("[ElectrumSyncManager] Server \(server.host) failed: \(error)")
                await candidateClient.disconnect()
                lastError = error
                continue
            }
        }

        print("[ElectrumSyncManager] All servers failed!")
        let message = lastError?.localizedDescription ?? ElectrumError.noServersAvailable.localizedDescription
        lock.withLock { _state = .error(message) }
        delegate?.syncManager(self, didEncounterError: lastError ?? ElectrumError.noServersAvailable)
        throw lastError ?? ElectrumError.noServersAvailable
    }
}

// MARK: - Sync State

public enum ElectrumSyncState: Sendable {
    case disconnected
    case connecting
    case connected
    case syncing
    case error(String)

    public var isConnected: Bool {
        switch self {
        case .connected, .syncing:
            return true
        default:
            return false
        }
    }
}

// MARK: - BlockchainSyncManager Conformance

extension ElectrumSyncManager: BlockchainSyncManager {
    public var syncState: SyncState {
        switch state {
        case .disconnected:
            return .idle
        case .connecting, .syncing:
            return .syncing
        case .connected:
            return .completed
        case .error:
            return .failed
        }
    }
}
