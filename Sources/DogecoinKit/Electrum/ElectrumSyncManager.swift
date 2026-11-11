import Foundation
#if canImport(os)
import os.log
#endif

/// Delegate for Electrum sync events
///
/// Calls arrive one at a time, in the order things happened. None begins
/// after ``ElectrumSyncManager/stop()`` has returned.
public protocol ElectrumSyncDelegate: AnyObject, Sendable {
    /// The manager is connected — for the first time, or again after a
    /// drop, in which case every address it was watching is being watched
    /// again. Whatever may have changed while it was not connected should
    /// be fetched now.
    func electrumSyncDidConnect(_ manager: ElectrumSyncManager) async

    /// The chain's tip is at `height`: reported on connecting, and for
    /// every block after.
    func electrumSync(_ manager: ElectrumSyncManager, didReachHeight height: Int32) async

    /// Something changed at `address` — a transaction arrived, confirmed,
    /// or was dropped. Its balance, outputs, and history should be fetched
    /// again.
    ///
    /// Also reported for an address whose history turns out to have changed
    /// while the manager was reconnecting.
    func electrumSync(_ manager: ElectrumSyncManager, didObserveActivityAt address: String) async
}

public extension ElectrumSyncDelegate {
    func electrumSync(_ manager: ElectrumSyncManager, didReachHeight height: Int32) async {}
}

public actor ElectrumSyncManager {

    // MARK: - Public Properties

    public nonisolated let network: DogecoinNetwork
    public weak var delegate: (any ElectrumSyncDelegate)?

    /// Set the delegate
    public func setDelegate(_ delegate: (any ElectrumSyncDelegate)?) {
        self.delegate = delegate
    }

    public private(set) var state: ElectrumSyncState = .disconnected
    public private(set) var currentHeight: Int32 = 0
    public private(set) var connectedServer: ElectrumServer?

    // MARK: - Private State

    private var client: ElectrumClient?
    private var addressSubscriptions: Set<String> = []
    private var isRunning = false

    /// The last status the server gave for each subscribed address: a
    /// digest of its history, empty for an address without one. An address
    /// whose status differs after a reconnect saw activity in between.
    private var addressStatuses: [String: String] = [:]

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

    /// Outputs already checked against their funding transaction's txid.
    /// Transactions never change, so these stay valid; the capacity covers
    /// wallets with thousands of UTXOs, whose first check servers throttle.
    private let verifiedOutputs = LRUCache<Outpoint, RawTransaction.Output>(capacity: 8192)

    /// When blocks were mined, by height
    private let blockTimes = LRUCache<Int, Date>(capacity: 1024)

    /// Where the next connection attempt starts in `serverList`. It moves
    /// past a server whose connection was lost or that would not take the
    /// subscriptions back, so one that accepts connections but does not
    /// work is not retried forever while the others go unused.
    private var nextServerIndex = 0

    private enum DelegateEvent: Sendable {
        case connected
        case height(Int32)
        case activity(address: String)
    }

    private lazy var delegateEvents = SerialEventQueue<(event: DelegateEvent, session: Int)> { [weak self] item in
        guard let self, let delegate = await self.delegate(during: item.session) else { return }
        switch item.event {
        case .connected:
            await delegate.electrumSyncDidConnect(self)
        case .height(let height):
            await delegate.electrumSync(self, didReachHeight: height)
        case .activity(let address):
            await delegate.electrumSync(self, didObserveActivityAt: address)
        }
    }

    /// Queues `event` for the delegate.
    private func report(_ event: DelegateEvent) {
        delegateEvents.yield((event, session))
    }

    /// The delegate, for as long as `session` lasts. What was seen before a
    /// `stop()` is not reported once it has returned.
    private func delegate(during session: Int) -> (any ElectrumSyncDelegate)? {
        session == self.session ? delegate : nil
    }

    // MARK: - Server Notifications

    /// What a server pushes, and the connection it came over
    private enum Notification: Sendable {
        case header(height: Int32, source: ObjectIdentifier)
        case addressStatus(address: String, status: String, source: ObjectIdentifier)
        case disconnected(source: ObjectIdentifier)
    }

    /// Carries notifications from the client to this actor in the order
    /// they arrived. A task for each would let a later block's height be
    /// overtaken by an earlier one's.
    private nonisolated let notifications: AsyncStream<Notification>.Continuation

    /// The connection whose notifications count, while it is being set up
    /// and before it is installed
    private var connectingSource: ObjectIdentifier?

    // MARK: - Immutable

    private let serverList: [ElectrumServer]
    private let streamFactory: ByteStreamFactory
    private let requestTimeout: Duration

    /// Per-server connection timeout
    private let connectionTimeout: Duration = .seconds(10)

    /// Longest pause between reconnect attempts
    private let maximumReconnectDelay: Duration = .seconds(60)

    /// Most requests one call keeps outstanding at a time. A wallet has
    /// dozens of addresses and may have thousands of outputs; asked for all
    /// at once, the last request would spend its whole timeout waiting its
    /// turn at the server.
    private static let maximumConcurrentRequests = 8

    private let logger = Logger(subsystem: "DogecoinKit", category: "electrum")

    // MARK: - Initialization

    public init(network: DogecoinNetwork) {
        self.init(network: network, serverList: ElectrumServerList.servers(for: network).shuffled())
    }

    /// Creates a sync manager that uses your own servers instead of the
    /// built-in list. They are tried in the order given.
    public init(network: DogecoinNetwork, servers: [ElectrumServer]) {
        self.init(network: network, serverList: servers)
    }

    init(
        network: DogecoinNetwork,
        serverList: [ElectrumServer],
        streamFactory: @escaping ByteStreamFactory = defaultByteStreamFactory,
        requestTimeout: Duration = ElectrumClient.defaultRequestTimeout
    ) {
        self.network = network
        self.serverList = serverList
        self.streamFactory = streamFactory
        self.requestTimeout = requestTimeout

        let (stream, continuation) = AsyncStream.makeStream(of: Notification.self)
        self.notifications = continuation
        Task { [weak self] in
            for await notification in stream {
                await self?.handle(notification)
            }
        }
    }

    deinit {
        notifications.finish()
    }

    // MARK: - Public Methods

    /// Connects to the first server that works.
    /// - Throws: Whatever kept the last server tried from working. The
    ///   manager is then not running; `start()` may be called again.
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
        connectingSource = nil
        connectedServer = nil
        state = .disconnected
        addressSubscriptions.removeAll()
        addressStatuses.removeAll()

        Task {
            await existingClient?.disconnect()
        }
    }

    public func fetchTransactionHistory(for addresses: [String]) async throws -> [ElectrumHistoryItem] {
        logger.debug("Fetching transaction history for \(addresses.count, privacy: .public) addresses")

        let scriptHashes = try addresses.map { address in
            try ElectrumScriptHash(address: address, network: network).scriptHash
        }

        let results = try await withClient { client in
            try await Self.concurrently(scriptHashes) { scriptHash in
                try await client.getHistory(scriptHash: scriptHash)
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

    /// The unspent outputs of `addresses`, each checked against the
    /// transaction that created it.
    ///
    /// The check proves that an output is what its transaction says. It
    /// cannot prove the transaction is in the chain: that is taken on the
    /// server's word, as everything in this mode is.
    /// - Throws: `ElectrumError.invalidResponse` for an output the server
    ///   misreported, or a set of them worth more than can exist
    public func fetchUTXOs(for addresses: [String]) async throws -> [(address: String, utxo: ElectrumUTXO)] {
        logger.debug("Fetching UTXOs for \(addresses.count, privacy: .public) addresses")

        let scriptHashes = try addresses.map { address in
            (address: address, scriptHash: try ElectrumScriptHash(address: address, network: network).scriptHash)
        }

        let results = try await withClient { client in
            try await Self.concurrently(scriptHashes) { item in
                (address: item.address, utxos: try await client.listUnspent(scriptHash: item.scriptHash))
            }
        }

        var allUTXOs: [(address: String, utxo: ElectrumUTXO)] = []
        var total: UInt64 = 0

        for result in results {
            for utxo in result.utxos {
                logger.debug("UTXO at \(result.address, privacy: .private) — \(utxo.value, privacy: .public) koinu, height=\(utxo.height, privacy: .public)")
                allUTXOs.append((address: result.address, utxo: utxo))

                // Each value is within range; their sum has to be as well,
                // or it would overflow what the wallet adds up.
                let (sum, overflow) = total.addingReportingOverflow(UInt64(clamping: utxo.value))
                guard !overflow, sum <= DogecoinAmount.maxMoney.koinu else {
                    throw ElectrumError.invalidResponse("The server reported outputs worth more than can exist")
                }
                total = sum
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

    /// Whether the server knows a transaction, in a block or waiting for one.
    ///
    /// This settles an ``ElectrumError/broadcastOutcomeUnknown(txid:)``. A
    /// transaction can take a few seconds to reach a server other than the
    /// one it was sent to, so "no" right after a broadcast is not yet final.
    /// - Returns: `false` only when the server says it has no such
    ///   transaction
    /// - Throws: If the server cannot be asked, or answers with anything
    ///   else — being busy, say. That it failed to answer is not an answer.
    public func isTransactionKnown(txid: String) async throws -> Bool {
        do {
            _ = try await getTransaction(txid: txid)
            return true
        } catch ElectrumError.requestFailed(_, let message) where Self.saysNoSuchTransaction(message) {
            return false
        }
    }

    /// Whether an error message is the node's "no such transaction".
    ///
    /// Electrum servers hand on what the Dogecoin node behind them said,
    /// each in a wrapping of its own, so the node's wording is all there is
    /// to go by: "No such mempool or blockchain transaction", or "No such
    /// mempool transaction" from a node without a transaction index.
    private static func saysNoSuchTransaction(_ message: String) -> Bool {
        message.range(of: "No such mempool", options: .caseInsensitive) != nil
    }

    /// When the block at `height` was mined, by its own header.
    public func blockTime(atHeight height: Int) async throws -> Date {
        if let known = blockTimes.get(height) {
            return known
        }

        let headerHex = try await withClient { client in
            try await client.getBlockHeader(height: height)
        }
        // A merge-mined block's proof may follow its 80 bytes.
        guard let header = Data(hexString: headerHex).flatMap({ BlockHeader.parse(from: $0.prefix(BlockHeader.size)) }) else {
            throw ElectrumError.invalidResponse("Not a block header")
        }

        let time = Date(timeIntervalSince1970: TimeInterval(header.timestamp))
        blockTimes.set(height, time)
        return time
    }

    /// Broadcasts once and never retries.
    ///
    /// Cancelling the calling task does not abandon a broadcast under way.
    /// By then the transaction is with the server, and giving up could only
    /// hide whether it was accepted.
    /// - Returns: The transaction's id, computed from the transaction
    ///   itself. A server decides whether to accept a transaction, not
    ///   what it is called.
    /// - Throws: `ElectrumError.requestFailed` when the server refuses the
    ///   transaction, and ``ElectrumError/broadcastOutcomeUnknown(txid:)``
    ///   when the connection is lost before it answers — the transaction
    ///   may then have been accepted. Any other error means it was never
    ///   sent.
    public func broadcastTransaction(_ rawHex: String) async throws -> String {
        guard let transaction = RawTransaction(hex: rawHex) else {
            throw ElectrumError.invalidResponse("Not a transaction")
        }
        let txid = Data(transaction.txid.reversed()).hexString

        let client = try await connectedClient()
        let reported: String
        do {
            reported = try await Task {
                try await client.broadcastTransaction(rawHex: rawHex)
            }.value
        } catch let error as ElectrumError where error.endedConnection {
            logger.error("Connection lost while broadcasting \(txid, privacy: .public)")
            throw ElectrumError.broadcastOutcomeUnknown(txid: txid)
        }

        if reported.lowercased() != txid {
            logger.error("Server reported txid \(reported, privacy: .public) for transaction \(txid, privacy: .public)")
        }
        return txid
    }

    /// Watches `addresses`. The delegate hears of activity at each from
    /// then on — also of what happened while the manager was reconnecting.
    ///
    /// Subscribe before fetching an address's state: what changes between
    /// the two is then reported, where the other way round it would be
    /// missed.
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

    // MARK: - Connection

    /// Runs `operation` against the live client. If the connection drops
    /// underneath it — or the server stops answering, which drops it too —
    /// reconnects once and runs it again. Every operation routed through
    /// here is a read or an idempotent subscription.
    private func withClient<T: Sendable>(_ operation: @Sendable (ElectrumClient) async throws -> T) async throws -> T {
        let client = try await connectedClient()
        do {
            return try await operation(client)
        } catch let error as ElectrumError where isRunning && error.endedConnection {
            logger.info("Connection lost mid-request; reconnecting and retrying once")
            // The client's own notice of the drop may not have arrived yet.
            clientDidDisconnect(ObjectIdentifier(client))
            return try await operation(try await connectedClient())
        }
    }

    /// Runs `operation` for every item, a few at a time.
    /// - Returns: The results, in no particular order
    private static func concurrently<Item: Sendable, Output: Sendable>(
        _ items: [Item],
        _ operation: @escaping @Sendable (Item) async throws -> Output
    ) async throws -> [Output] {
        try await withThrowingTaskGroup(of: Output.self) { group in
            var remaining = items.makeIterator()
            for _ in 0..<maximumConcurrentRequests {
                guard let item = remaining.next() else { break }
                group.addTask { try await operation(item) }
            }

            var outputs: [Output] = []
            outputs.reserveCapacity(items.count)
            while let output = try await group.next() {
                outputs.append(output)
                if let item = remaining.next() {
                    group.addTask { try await operation(item) }
                }
            }
            return outputs
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
                    tryNextServerFirst()
                }
                await client.disconnect()
                throw error
            }
        }

        guard session == self.session else {
            throw CancellationError()
        }

        // Only now is the drop repaired. Ending the loop any earlier would
        // leave a connection that refused the subscriptions with nothing
        // to try the next server.
        endReconnectLoop()

        // Lets the app catch up on anything it missed while disconnected.
        report(.height(currentHeight))
        report(.connected)
    }

    private func clientDidDisconnect(_ source: ObjectIdentifier) {
        guard isRunning, let client, ObjectIdentifier(client) == source else { return }

        logger.info("Lost connection to \(self.connectedServer?.host ?? "server", privacy: .public); reconnecting")
        self.client = nil
        connectedServer = nil
        state = .connecting
        tryNextServerFirst()
        startReconnectLoop()
    }

    /// Makes the next attempt begin with the server after the one that was
    /// just in use.
    private func tryNextServerFirst() {
        guard !serverList.isEmpty else { return }
        nextServerIndex = (nextServerIndex + 1) % serverList.count
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

    /// Ends the reconnect loop, if one is running. A loop is only good for
    /// the drop it was started for: kept past a successful connection, it
    /// would meet the next drop asleep, deep in its backoff.
    private func endReconnectLoop() {
        reconnectLoop?.cancel()
        reconnectLoop = nil
        reconnectLoopGeneration += 1
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

        // Try servers until one connects, starting where the last attempt
        // left off
        var lastError: Error?
        let firstIndex = nextServerIndex
        for offset in serverList.indices {
            try Task.checkCancellation()
            let index = (firstIndex + offset) % serverList.count
            let server = serverList[index]
            logger.debug("Trying server \(offset + 1, privacy: .public)/\(self.serverList.count, privacy: .public): \(server.host, privacy: .public):\(server.port, privacy: .public)")

            let candidate = ElectrumClient(server: server, streamFactory: streamFactory, requestTimeout: requestTimeout)
            let source = ObjectIdentifier(candidate)
            do {
                try await connectWithTimeout(candidate)
                try await verifyChain(of: candidate)

                logger.info("Connected to \(server.host, privacy: .public), subscribing to headers")
                connectingSource = source
                let header = try await candidate.subscribeHeaders { [notifications] header in
                    notifications.yield(.header(height: Int32(clamping: header.height), source: source))
                }

                await candidate.setDisconnectHandler { [notifications] in
                    notifications.yield(.disconnected(source: source))
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
                connectingSource = nil
                connectedServer = server
                nextServerIndex = index
                // A block announced while this was being set up is already
                // counted.
                currentHeight = max(currentHeight, Int32(clamping: header.height))
                state = .connected

                logger.info("Sync ready at \(server.host, privacy: .public) — current block height \(self.currentHeight, privacy: .public)")
                return candidate
            } catch is CancellationError {
                clearConnecting(source)
                await candidate.disconnect()
                throw CancellationError()
            } catch {
                logger.error("Server \(server.host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                clearConnecting(source)
                await candidate.disconnect()
                lastError = error
            }
        }

        logger.error("All \(self.serverList.count, privacy: .public) Electrum servers failed")
        throw lastError ?? ElectrumError.noServersAvailable
    }

    private func clearConnecting(_ source: ObjectIdentifier) {
        if connectingSource == source {
            connectingSource = nil
        }
    }

    /// Refuses a server that says it indexes another chain — a Litecoin or
    /// Bitcoin server reached by mistake answers every query, with nothing.
    ///
    /// A server that does not say is taken at its word: the query is one
    /// servers may leave out.
    private func verifyChain(of client: ElectrumClient) async throws {
        let features: ElectrumServerFeatures
        do {
            features = try await client.serverFeatures()
        } catch let error as ElectrumError where error.endedConnection {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return
        }

        guard features.genesisHash.lowercased() == NetworkConstants.genesisHash(for: network) else {
            throw ElectrumError.invalidResponse("The server is on another chain")
        }
    }

    /// Subscribes `addresses` on `client` and records what state each is
    /// in. An address already known in another state has seen activity
    /// since: that is reported.
    private func subscribe(_ addresses: [String], on client: ElectrumClient) async throws {
        let scriptHashes = try addresses.map { address in
            (address: address, scriptHash: try ElectrumScriptHash(address: address, network: network).scriptHash)
        }
        let source = ObjectIdentifier(client)

        let statuses = try await Self.concurrently(scriptHashes) { [notifications] item in
            // The handler lives as long as the client.
            let status = try await client.subscribeScriptHash(item.scriptHash) { [notifications] status in
                notifications.yield(.addressStatus(address: item.address, status: status, source: source))
            }
            return (address: item.address, status: status ?? "")
        }

        for (address, status) in statuses {
            addressSubscriptions.insert(address)
            if let known = addressStatuses[address], known != status {
                report(.activity(address: address))
            }
            addressStatuses[address] = status
        }
    }

    // MARK: - Notifications

    private func handle(_ notification: Notification) {
        switch notification {
        case .header(let height, let source):
            guard isRunning, isLive(source) || connectingSource == source else { return }
            currentHeight = height
            // Reported once the connection it came over is the one in use.
            if isLive(source) {
                report(.height(height))
            }

        case .addressStatus(let address, let status, let source):
            guard isRunning, isLive(source) else { return }
            addressStatuses[address] = status
            report(.activity(address: address))

        case .disconnected(let source):
            clientDidDisconnect(source)
        }
    }

    private func isLive(_ source: ObjectIdentifier) -> Bool {
        client.map(ObjectIdentifier.init) == source
    }

    // MARK: - UTXO Verification

    /// Where an output sits on the chain
    private struct Outpoint: Hashable, Sendable {
        /// Lowercase display-order hex
        let txid: String
        let index: Int

        init(txid: String, index: Int) {
            self.txid = txid
            self.index = index
        }

        init(_ utxo: ElectrumUTXO) {
            self.init(txid: utxo.txHash.lowercased(), index: utxo.txPos)
        }
    }

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
        // Collected here as well as cached: a wallet with more outputs than
        // the cache holds must still verify.
        var outputs: [Outpoint: RawTransaction.Output] = [:]
        var missing: [String: Set<Int>] = [:]
        for (_, utxo) in utxos {
            let outpoint = Outpoint(utxo)
            if let output = verifiedOutputs.get(outpoint) {
                outputs[outpoint] = output
            } else {
                missing[outpoint.txid, default: []].insert(outpoint.index)
            }
        }

        if !missing.isEmpty {
            outputs.merge(try await fetchVerifiedOutputs(missing)) { _, fetched in fetched }
        }

        for (address, utxo) in utxos {
            guard let output = outputs[Outpoint(utxo)],
                  output.script == Address.scriptPubKey(for: address),
                  output.value == UInt64(exactly: utxo.value) else {
                logger.error("Server misreported UTXO \(utxo.outpoint, privacy: .public)")
                throw ElectrumError.invalidResponse("Server misreported output \(utxo.outpoint)")
            }
        }
    }

    /// Fetches transactions a few at a time — a wallet with hundreds of
    /// small outputs must not flood the server — checks each against its
    /// txid, and returns the outputs asked for.
    ///
    /// Each transaction's outputs are cached as soon as it verifies. When
    /// one fetch among thousands fails, the retry — or the next refresh —
    /// carries on from there instead of starting over.
    /// - Parameter indexesByTxid: The output indexes needed, by txid
    private func fetchVerifiedOutputs(_ indexesByTxid: [String: Set<Int>]) async throws -> [Outpoint: RawTransaction.Output] {
        try await withClient { client in
            // This runs again after a reconnect, and then picks up whatever
            // the first run got through.
            let cached = await self.cachedOutputs(of: indexesByTxid)
            var outputs = cached.outputs

            try await withThrowingTaskGroup(of: (txid: String, outputs: [RawTransaction.Output]).self) { group in
                var remaining = cached.missingTxids.makeIterator()
                for _ in 0..<Self.maximumConcurrentRequests {
                    guard let txid = remaining.next() else { break }
                    group.addTask { (txid, try await Self.verifiedOutputs(of: txid, from: client)) }
                }

                while let (txid, fetched) = try await group.next() {
                    let kept = await self.remember(fetched, of: txid, at: indexesByTxid[txid] ?? [])
                    outputs.merge(kept) { _, new in new }
                    if let txid = remaining.next() {
                        group.addTask { (txid, try await Self.verifiedOutputs(of: txid, from: client)) }
                    }
                }
            }
            return outputs
        }
    }

    /// The outputs among `indexesByTxid` that are already cached, and the
    /// transactions to fetch for the rest.
    private func cachedOutputs(
        of indexesByTxid: [String: Set<Int>]
    ) -> (outputs: [Outpoint: RawTransaction.Output], missingTxids: [String]) {
        var outputs: [Outpoint: RawTransaction.Output] = [:]
        var missingTxids: [String] = []
        for (txid, indexes) in indexesByTxid {
            var isMissingAny = false
            for index in indexes {
                let outpoint = Outpoint(txid: txid, index: index)
                if let output = verifiedOutputs.get(outpoint) {
                    outputs[outpoint] = output
                } else {
                    isMissingAny = true
                }
            }
            if isMissingAny {
                missingTxids.append(txid)
            }
        }
        return (outputs, missingTxids)
    }

    /// Caches the outputs of `txid` at `indexes` and returns them by outpoint.
    private func remember(
        _ outputs: [RawTransaction.Output],
        of txid: String,
        at indexes: Set<Int>
    ) -> [Outpoint: RawTransaction.Output] {
        var kept: [Outpoint: RawTransaction.Output] = [:]
        for index in indexes where outputs.indices.contains(index) {
            let outpoint = Outpoint(txid: txid, index: index)
            verifiedOutputs.set(outpoint, outputs[index])
            kept[outpoint] = outputs[index]
        }
        return kept
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
}

// MARK: - Sync State

public enum ElectrumSyncState: Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)

    public var isConnected: Bool {
        if case .connected = self { true } else { false }
    }
}
