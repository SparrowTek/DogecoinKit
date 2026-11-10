import Foundation
#if canImport(os)
import os.log
#endif

public actor ElectrumSyncManager {

    // MARK: - Public Properties

    public nonisolated let network: DogecoinNetwork
    public weak var delegate: (any BlockchainSyncDelegate)?

    /// Set the delegate
    public func setDelegate(_ delegate: (any BlockchainSyncDelegate)?) {
        self.delegate = delegate
    }

    public private(set) var state: ElectrumSyncState = .disconnected
    public private(set) var currentHeight: Int32 = 0
    public private(set) var progress: Double = 0
    public private(set) var connectedServer: ElectrumServer?

    // MARK: - Private State

    private var client: ElectrumClient?
    private var addressSubscriptions: Set<String> = []
    private var isRunning = false

    /// Bumped by `start()` and `stop()`. Connection work begun in an earlier
    /// session never installs its client or reports failure.
    private var session = 0

    /// One reconnect attempt shared by every caller that finds the
    /// connection gone.
    private var reconnectAttempt: Task<Void, Error>?

    /// Keeps retrying with backoff after the connection drops, so address
    /// notifications resume without the app having to ask.
    private var reconnectLoop: Task<Void, Never>?

    /// Identifies the current reconnect loop, so a superseded one can never
    /// clear its successor.
    private var reconnectLoopGeneration = 0

    /// Funding-transaction outputs already checked against their txids.
    /// Transactions never change, so these stay valid; the capacity covers
    /// wallets with thousands of UTXOs, whose first check servers throttle.
    private let verifiedOutputs = LRUCache<String, [RawTransaction.Output]>(capacity: 8192)

    private enum DelegateEvent: Sendable {
        case progress(Double, height: Int32)
        case completed
        case failed(any Error)
        case transaction(txid: String, confirmations: Int)
    }

    private lazy var delegateEvents = SerialEventQueue<DelegateEvent> { [weak self] event in
        guard let self, let delegate = await self.delegate else { return }
        switch event {
        case .progress(let progress, let height):
            await delegate.syncManager(self, progressUpdated: progress, height: height)
        case .completed:
            await delegate.syncManagerDidComplete(self)
        case .failed(let error):
            await delegate.syncManager(self, didEncounterError: error)
        case .transaction(let txid, let confirmations):
            await delegate.syncManager(self, didUpdateTransaction: txid, confirmations: confirmations)
        }
    }

    // MARK: - Immutable

    private let serverList: [ElectrumServer]
    private let streamFactory: ByteStreamFactory

    /// Per-server connection timeout
    private let connectionTimeout: Duration = .seconds(10)

    /// Longest pause between reconnect attempts
    private let maximumReconnectDelay: Duration = .seconds(60)

    /// Funding transactions fetched at once when verifying UTXOs
    private static let maximumConcurrentTransactionFetches = 8

    private let logger = Logger(subsystem: "DogecoinKit", category: "electrum")

    // MARK: - Initialization

    public init(network: DogecoinNetwork) {
        self.init(network: network, serverList: ElectrumServerList.servers(for: network).shuffled())
    }

    init(network: DogecoinNetwork, serverList: [ElectrumServer], streamFactory: @escaping ByteStreamFactory = defaultByteStreamFactory) {
        self.network = network
        self.serverList = serverList
        self.streamFactory = streamFactory
    }

    // MARK: - Public Methods

    public func start() async throws {
        guard !isRunning else {
            logger.debug("Already running, skipping start")
            return
        }

        session += 1
        let session = self.session
        isRunning = true
        logger.info("Starting sync for \(String(describing: self.network), privacy: .public) — \(self.serverList.count, privacy: .public) candidate servers")

        do {
            try await reconnect()
        } catch {
            // A stop() — and perhaps a new start() — while this one was
            // connecting owns the state now.
            guard session == self.session else { throw error }
            isRunning = false
            state = .error(error.localizedDescription)
            delegateEvents.yield(.failed(error))
            throw error
        }
    }

    public func stop() {
        session += 1
        isRunning = false
        reconnectLoop?.cancel()
        reconnectLoop = nil
        reconnectAttempt?.cancel()
        reconnectAttempt = nil

        let existingClient = client
        client = nil
        connectedServer = nil
        state = .disconnected
        addressSubscriptions.removeAll()

        Task {
            await existingClient?.disconnect()
        }
    }

    public func refreshBalance(for addresses: [String]) async throws -> Int64 {
        logger.debug("Refreshing balance for \(addresses.count, privacy: .public) addresses")

        // Pre-compute script hashes
        let scriptHashes = try addresses.map { address in
            (address: address, scriptHash: try ElectrumScriptHash(address: address, network: network))
        }

        // Fetch balances in parallel
        let results = try await withClient { client in
            try await withThrowingTaskGroup(of: (address: String, balance: ElectrumBalance).self) { group in
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
        }

        var totalBalance: Int64 = 0
        var addressesWithBalance = 0

        for result in results {
            let balanceSum = result.balance.total
            if balanceSum > 0 {
                addressesWithBalance += 1
                // Address hash (privacy: .private) keeps user addresses out of
                // unredacted device logs — only visible when the log client is
                // signed with the appropriate entitlement.
                logger.debug("Balance at \(result.address, privacy: .private): \(balanceSum, privacy: .public) koinu")
            }
            // Server-supplied values: saturate rather than trap on overflow.
            let (sum, overflow) = totalBalance.addingReportingOverflow(balanceSum)
            totalBalance = overflow ? (balanceSum < 0 ? .min : .max) : sum
        }

        logger.info("Balance refresh complete — \(addressesWithBalance, privacy: .public)/\(addresses.count, privacy: .public) addresses funded, total \(totalBalance, privacy: .public) koinu")
        return totalBalance
    }

    public func fetchTransactionHistory(for addresses: [String]) async throws -> [ElectrumHistoryItem] {
        logger.debug("Fetching transaction history for \(addresses.count, privacy: .public) addresses")

        // Pre-compute script hashes
        let scriptHashes = try addresses.map { address in
            try ElectrumScriptHash(address: address, network: network)
        }

        // Fetch history in parallel
        let results = try await withClient { client in
            try await withThrowingTaskGroup(of: [ElectrumHistoryItem].self) { group in
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
        }

        // Deduplicate by txid
        var seenTxids: Set<String> = []
        var allHistory: [ElectrumHistoryItem] = []

        for items in results {
            for item in items where seenTxids.insert(item.txHash).inserted {
                allHistory.append(item)
            }
        }

        logger.info("Transaction history: \(allHistory.count, privacy: .public) unique txids across \(addresses.count, privacy: .public) addresses")

        // Sort by height (newest first), unconfirmed (height <= 0) at top
        return allHistory.sorted { lhs, rhs in
            if lhs.height <= 0 && rhs.height > 0 { return true }
            if lhs.height > 0 && rhs.height <= 0 { return false }
            return lhs.height > rhs.height
        }
    }

    public func fetchUTXOs(for addresses: [String]) async throws -> [(address: String, utxo: ElectrumUTXO)] {
        logger.debug("Fetching UTXOs for \(addresses.count, privacy: .public) addresses")

        // Pre-compute script hashes
        let scriptHashes = try addresses.map { address in
            (address: address, scriptHash: try ElectrumScriptHash(address: address, network: network))
        }

        // Fetch UTXOs in parallel
        let results = try await withClient { client in
            try await withThrowingTaskGroup(of: (address: String, utxos: [ElectrumUTXO]).self) { group in
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
        }

        var allUTXOs: [(address: String, utxo: ElectrumUTXO)] = []

        for result in results {
            for utxo in result.utxos {
                logger.debug("UTXO at \(result.address, privacy: .private) — \(utxo.value, privacy: .public) koinu, height=\(utxo.height, privacy: .public)")
                allUTXOs.append((address: result.address, utxo: utxo))
            }
        }

        try await verifyAgainstFundingTransactions(allUTXOs)

        logger.info("UTXO fetch complete — \(allUTXOs.count, privacy: .public) outputs across \(addresses.count, privacy: .public) addresses")
        return allUTXOs
    }

    /// Fetches a raw transaction, checking that it hashes to `txid`.
    /// - Throws: `ElectrumError.invalidResponse` if the server sends a
    ///   different transaction
    public func getTransaction(txid: String) async throws -> String {
        let rawHex = try await withClient { client in
            try await client.getTransaction(txHash: txid)
        }

        guard let expected = Data(hexString: txid),
              let raw = Data(hexString: rawHex),
              MerkleTree.doubleSHA256(raw) == Data(expected.reversed()) else {
            throw ElectrumError.invalidResponse("Transaction does not match txid \(txid)")
        }
        return rawHex
    }

    /// Broadcasts once and never retries: if the connection drops before the
    /// reply, the transaction may or may not have reached the server, and the
    /// caller is better placed to decide what to do about that.
    public func broadcastTransaction(_ rawHex: String) async throws -> String {
        let client = try await connectedClient()
        return try await client.broadcastTransaction(rawHex: rawHex)
    }

    public func subscribeToAddresses(_ addresses: [String]) async throws {
        try await withClient { client in
            // Filter to only addresses not already subscribed
            let newAddresses = Array(Set(addresses).subtracting(await self.addressSubscriptions))
            guard !newAddresses.isEmpty else { return }

            self.logger.debug("Subscribing to \(newAddresses.count, privacy: .public) new addresses")
            try await self.subscribe(newAddresses, on: client)
            self.logger.info("Subscribed to \(newAddresses.count, privacy: .public) addresses")
        }
    }

    public func estimateFee(blocks: Int = 6) async throws -> Double {
        try await withClient { client in
            try await client.estimateFee(blocks: blocks)
        }
    }

    // MARK: - Connection

    /// Runs `operation` against the live client. If the connection drops
    /// underneath it, reconnects once and runs it again — every operation
    /// routed through here is a read or an idempotent subscription.
    private func withClient<T: Sendable>(_ operation: @Sendable (ElectrumClient) async throws -> T) async throws -> T {
        let client = try await connectedClient()
        do {
            return try await operation(client)
        } catch ElectrumError.serverDisconnected where isRunning {
            logger.info("Connection dropped mid-request; reconnecting and retrying once")
            return try await operation(try await connectedClient())
        }
    }

    /// The live client, reconnecting first if the connection has dropped.
    private func connectedClient() async throws -> ElectrumClient {
        if let client, await client.isConnected {
            return client
        }
        guard isRunning else {
            throw ElectrumError.serverDisconnected
        }

        do {
            try await reconnect()
        } catch {
            // Keep trying in the background, so notifications resume on
            // their own.
            if isRunning {
                startReconnectLoop()
            }
            throw error
        }

        guard let client else {
            throw ElectrumError.serverDisconnected
        }
        return client
    }

    /// Connects, or joins the attempt already under way. The attempt runs as
    /// its own task: a caller that goes away mid-connect (a SwiftUI `.task`
    /// or `.refreshable` being cancelled) must not abort the manager's
    /// connection.
    private func reconnect() async throws {
        let attempt: Task<Void, Error>
        if let reconnectAttempt {
            attempt = reconnectAttempt
        } else {
            let session = self.session
            attempt = Task { try await self.connectAndRestoreSubscriptions(session: session) }
            reconnectAttempt = attempt
        }

        // A stop() and a new start() may have replaced the attempt while
        // this caller waited; only the attempt's own callers clear it.
        defer {
            if reconnectAttempt == attempt {
                reconnectAttempt = nil
            }
        }

        try await attempt.value
    }

    private func connectAndRestoreSubscriptions(session: Int) async throws {
        let client = try await connectToFirstAvailableServer(session: session)

        // The new server knows nothing about our address subscriptions. A
        // connection missing some of them would silently drop activity, so
        // it counts as a failed attempt.
        if !addressSubscriptions.isEmpty {
            do {
                try await subscribe(Array(addressSubscriptions), on: client)
            } catch {
                if self.client === client {
                    self.client = nil
                    connectedServer = nil
                    state = .connecting
                }
                await client.disconnect()
                throw error
            }
        }

        guard session == self.session else {
            throw CancellationError()
        }

        // Lets the app catch up on anything it missed while disconnected.
        delegateEvents.yield(.progress(progress, height: currentHeight))
        delegateEvents.yield(.completed)
    }

    private func clientDidDisconnect(_ disconnected: ElectrumClient) {
        guard isRunning, client === disconnected else { return }

        logger.info("Lost connection to \(self.connectedServer?.host ?? "server", privacy: .public); reconnecting")
        client = nil
        connectedServer = nil
        state = .connecting
        startReconnectLoop()
    }

    private func startReconnectLoop() {
        guard reconnectLoop == nil else { return }

        reconnectLoopGeneration += 1
        let generation = reconnectLoopGeneration
        let maximumDelay = maximumReconnectDelay
        reconnectLoop = Task { [weak self] in
            var delay: Duration = .seconds(1)
            while await self?.reconnectOnce(generation: generation) == true {
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, maximumDelay)
            }
        }
    }

    /// One pass of the reconnect loop.
    /// - Returns: Whether to pause and go again. When the loop is done —
    ///   connected or stopped — it clears itself in this same turn, so the
    ///   next drop always starts a fresh loop.
    private func reconnectOnce(generation: Int) async -> Bool {
        guard generation == reconnectLoopGeneration, !Task.isCancelled else { return false }

        if isRunning, client == nil {
            do {
                try await reconnect()
            } catch {
                logger.error("Reconnect failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        guard generation == reconnectLoopGeneration, !Task.isCancelled else { return false }
        guard isRunning, client == nil else {
            reconnectLoop = nil
            return false
        }
        return true
    }

    private func connectWithTimeout(_ client: ElectrumClient) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await client.connect()
            }
            group.addTask { [connectionTimeout] in
                try await Task.sleep(for: connectionTimeout)
                throw ElectrumError.connectionTimeout
            }
            // First task to complete wins; cancel the other.
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    /// Connects to the first server that answers and installs it — unless
    /// `session` has ended meanwhile.
    private func connectToFirstAvailableServer(session: Int) async throws -> ElectrumClient {
        guard !serverList.isEmpty else {
            throw ElectrumError.noServersAvailable
        }

        state = .connecting

        // Try servers until one connects
        var lastError: Error?
        for (index, server) in serverList.enumerated() {
            try Task.checkCancellation()
            logger.debug("Trying server \(index + 1, privacy: .public)/\(self.serverList.count, privacy: .public): \(server.host, privacy: .public):\(server.port, privacy: .public)")

            let candidate = ElectrumClient(server: server, streamFactory: streamFactory)
            do {
                try await connectWithTimeout(candidate)

                logger.info("Connected to \(server.host, privacy: .public), subscribing to headers")
                let header = try await candidate.subscribeHeaders { [weak self] header in
                    Task { await self?.handleHeaderUpdate(height: Int32(clamping: header.height)) }
                }

                await candidate.setDisconnectHandler { [weak self, weak candidate] in
                    guard let candidate else { return }
                    Task { await self?.clientDidDisconnect(candidate) }
                }
                let isLive = await candidate.isConnected

                // Nothing below suspends, so stop() cannot slip in between
                // this check and the client being installed.
                guard session == self.session else {
                    await candidate.disconnect()
                    throw CancellationError()
                }
                guard isLive else {
                    throw ElectrumError.serverDisconnected
                }

                client = candidate
                connectedServer = server
                currentHeight = Int32(clamping: header.height)
                progress = 1.0
                state = .connected

                logger.info("Sync ready at \(server.host, privacy: .public) — current block height \(self.currentHeight, privacy: .public)")
                return candidate
            } catch is CancellationError {
                await candidate.disconnect()
                throw CancellationError()
            } catch {
                logger.error("Server \(server.host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                await candidate.disconnect()
                lastError = error
            }
        }

        logger.error("All \(self.serverList.count, privacy: .public) Electrum servers failed")
        throw lastError ?? ElectrumError.noServersAvailable
    }

    private func subscribe(_ addresses: [String], on client: ElectrumClient) async throws {
        let scriptHashes = try addresses.map { address in
            (address: address, scriptHash: try ElectrumScriptHash(address: address, network: network))
        }

        try await withThrowingTaskGroup(of: String.self) { group in
            for item in scriptHashes {
                // Weak all the way down: the handler lives as long as the client.
                group.addTask { [weak self] in
                    _ = try await client.subscribeScriptHash(item.scriptHash.scriptHash) { [weak self] _ in
                        Task { await self?.addressActivity(item.address) }
                    }
                    return item.address
                }
            }

            // Collect subscribed addresses
            for try await address in group {
                addressSubscriptions.insert(address)
            }
        }
    }

    // MARK: - UTXO Verification

    /// Checks every UTXO against the transaction that created it: that
    /// transaction must hash to the claimed txid, and the output must exist,
    /// pay the address, and carry exactly the reported value.
    ///
    /// Legacy signatures do not commit to the amounts being spent, so a
    /// server that understated an output's value could otherwise make the
    /// wallet sign away the difference as fee.
    /// - Throws: `ElectrumError.invalidResponse` for the first UTXO the
    ///   server misreported
    private func verifyAgainstFundingTransactions(_ utxos: [(address: String, utxo: ElectrumUTXO)]) async throws {
        let outputsByTxid = try await fundingOutputs(of: Set(utxos.map { $0.utxo.txHash.lowercased() }))

        for (address, utxo) in utxos {
            guard let outputs = outputsByTxid[utxo.txHash.lowercased()],
                  outputs.indices.contains(utxo.txPos),
                  outputs[utxo.txPos].script == Address.scriptPubKey(for: address),
                  outputs[utxo.txPos].value == UInt64(exactly: utxo.value) else {
                logger.error("Server misreported UTXO \(utxo.outpoint, privacy: .public)")
                throw ElectrumError.invalidResponse("Server misreported output \(utxo.outpoint)")
            }
        }
    }

    /// The outputs of each transaction, from the cache or fetched a few at a
    /// time — a wallet with hundreds of small outputs must not flood the
    /// server — and checked against the txid.
    private func fundingOutputs(of txids: Set<String>) async throws -> [String: [RawTransaction.Output]] {
        var outputsByTxid: [String: [RawTransaction.Output]] = [:]
        for txid in txids {
            outputsByTxid[txid] = verifiedOutputs.get(txid)
        }
        let missing = txids.filter { outputsByTxid[$0] == nil }
        guard !missing.isEmpty else { return outputsByTxid }

        let fetched = try await withClient { client in
            try await withThrowingTaskGroup(of: (txid: String, outputs: [RawTransaction.Output]).self) { group in
                var remaining = missing.makeIterator()
                for _ in 0..<Self.maximumConcurrentTransactionFetches {
                    guard let txid = remaining.next() else { break }
                    group.addTask { (txid, try await Self.verifiedOutputs(of: txid, from: client)) }
                }

                var results: [(txid: String, outputs: [RawTransaction.Output])] = []
                while let result = try await group.next() {
                    results.append(result)
                    if let txid = remaining.next() {
                        group.addTask { (txid, try await Self.verifiedOutputs(of: txid, from: client)) }
                    }
                }
                return results
            }
        }

        for (txid, outputs) in fetched {
            verifiedOutputs.set(txid, outputs)
            outputsByTxid[txid] = outputs
        }
        return outputsByTxid
    }

    /// Fetches a transaction and returns its outputs, once it hashes to `txid`.
    private static func verifiedOutputs(of txid: String, from client: ElectrumClient) async throws -> [RawTransaction.Output] {
        let rawHex = try await client.getTransaction(txHash: txid)
        guard let expected = Data(hexString: txid),
              let transaction = RawTransaction(hex: rawHex),
              transaction.txid == Data(expected.reversed()) else {
            throw ElectrumError.invalidResponse("Transaction does not match txid \(txid)")
        }
        return transaction.outputs
    }

    /// Notify delegate of address activity
    private func addressActivity(_ address: String) async {
        guard let history = try? await fetchTransactionHistory(for: [address]),
              let latest = history.first else {
            return
        }
        delegateEvents.yield(.transaction(txid: latest.txHash, confirmations: latest.height > 0 ? 1 : 0))
    }

    private func handleHeaderUpdate(height: Int32) {
        currentHeight = height
        progress = 1.0
        delegateEvents.yield(.progress(progress, height: height))
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
