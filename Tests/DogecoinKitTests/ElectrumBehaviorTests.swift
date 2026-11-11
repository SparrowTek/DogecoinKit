import Foundation
import Testing
@testable import DogecoinKit

// MARK: - Scripted Electrum server

/// Answers JSON-RPC requests the way a scripted server would.
private typealias Responder = @Sendable (_ method: String, _ id: Int, _ params: [Any]) -> [String]

/// An in-memory `ByteStream` backed by a `Responder`.
private final class ScriptedStream: ByteStream, @unchecked Sendable {
    let inbox = ChunkInbox()
    private let responder: Responder
    private let openDelay: Duration
    private let refusesToOpen: Bool
    private let lock = NSLock()
    private var sentMethods: [String] = []

    init(responder: @escaping Responder, openDelay: Duration = .zero, refusesToOpen: Bool = false) {
        self.responder = responder
        self.openDelay = openDelay
        self.refusesToOpen = refusesToOpen
    }

    var methods: [String] {
        lock.withLock { sentMethods }
    }

    func open() async throws {
        if openDelay > .zero {
            try await Task.sleep(for: openDelay)
        }
        if refusesToOpen {
            throw ByteStreamError.closed
        }
    }

    func write(_ data: Data) async throws {
        for line in data.split(separator: 0x0a) {
            guard let request = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let method = request["method"] as? String,
                  let id = request["id"] as? Int else { continue }
            lock.withLock { sentMethods.append(method) }
            // Replies are queued before write() returns — the instant-reply
            // race the client must survive.
            for reply in responder(method, id, request["params"] as? [Any] ?? []) {
                await inbox.push(Data(reply.utf8))
            }
        }
    }

    func read() async throws -> Data? {
        await inbox.next()
    }

    func close() {
        Task { await inbox.close() }
    }

    /// Pushes raw bytes as if the server sent them unprompted.
    func send(_ text: String) async {
        await inbox.push(Data(text.utf8))
    }
}

private func reply(_ id: Int, _ result: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"# + "\n"
}

/// A well-behaved server: answers the handshake and common queries.
private let standardResponder: Responder = { method, id, _ in
    switch method {
    case "server.version":
        [reply(id, #"["MockElectrum 1.0","1.4"]"#)]
    case "blockchain.headers.subscribe":
        [reply(id, #"{"height":5000000,"hex":"00"}"#)]
    case "blockchain.scripthash.subscribe":
        [reply(id, "null")]
    case "blockchain.scripthash.get_balance":
        [reply(id, #"{"confirmed":100,"unconfirmed":-40}"#)]
    case "blockchain.scripthash.get_history":
        [reply(id, "[]")]
    case "server.ping":
        [reply(id, "null")]
    default:
        [reply(id, "null")]
    }
}

/// Records every stream the client opens.
private final class StreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [ScriptedStream] = []
    private var openedHosts: [String] = []
    private let responderForStream: @Sendable (Int) -> Responder
    private let openDelay: @Sendable (Int) -> Duration
    private let refusedConnections: Set<Int>

    init(responder: @escaping Responder = standardResponder) {
        self.responderForStream = { _ in responder }
        self.openDelay = { _ in .zero }
        self.refusedConnections = []
    }

    /// Scripts each connection separately, by the order it was opened in.
    /// - Parameter refusing: The connections that fail to open
    init(
        openDelay: @escaping @Sendable (Int) -> Duration = { _ in .zero },
        refusing refusedConnections: Set<Int> = [],
        responderForStream: @escaping @Sendable (Int) -> Responder
    ) {
        self.responderForStream = responderForStream
        self.openDelay = openDelay
        self.refusedConnections = refusedConnections
    }

    var factory: ByteStreamFactory {
        { [self] host, _, _ in
            lock.withLock {
                let index = opened.count
                let stream = ScriptedStream(
                    responder: responderForStream(index),
                    openDelay: openDelay(index),
                    refusesToOpen: refusedConnections.contains(index)
                )
                opened.append(stream)
                openedHosts.append(host)
                return stream
            }
        }
    }

    var streams: [ScriptedStream] {
        lock.withLock { opened }
    }

    /// The host of each connection, in the order they were opened.
    var hosts: [String] {
        lock.withLock { openedHosts }
    }
}

private let testServer = ElectrumServer(host: "electrum.test", port: 50002, useSSL: true, network: .mainnet)
private let secondTestServer = ElectrumServer(host: "electrum2.test", port: 50002, useSSL: true, network: .mainnet)

// MARK: - Tests

@Suite("Electrum Client Behavior", .timeLimit(.minutes(1)))
struct ElectrumBehaviorTests {

    @Test("A reply that arrives before the request finishes sending is still delivered")
    func instantReplyIsMatched() async throws {
        let recorder = StreamRecorder()
        let client = ElectrumClient(server: testServer, streamFactory: recorder.factory)

        try await client.connect()
        try await client.serverPing()
        #expect(await client.isConnected)
    }

    @Test("Replies split across reads, or packed into one read, are all parsed")
    func lineFramingAcrossChunks() async throws {
        let responder: Responder = { method, id, _ in
            switch method {
            case "server.version":
                // One reply delivered in three pieces
                let whole = reply(id, #"["MockElectrum 1.0","1.4"]"#)
                let bytes = Array(whole.utf8)
                return [String(decoding: bytes[0..<7], as: UTF8.self),
                        String(decoding: bytes[7..<20], as: UTF8.self),
                        String(decoding: bytes[20...], as: UTF8.self)]
            case "blockchain.scripthash.get_balance":
                // A notification and the reply packed into one read
                return [#"{"jsonrpc":"2.0","method":"blockchain.scripthash.subscribe","params":["ab","cd"]}"# + "\n" + reply(id, #"{"confirmed":7,"unconfirmed":0}"#)]
            default:
                return [reply(id, "null")]
            }
        }
        let client = ElectrumClient(server: testServer, streamFactory: StreamRecorder(responder: responder).factory)

        try await client.connect()
        let balance = try await client.getBalance(scriptHash: String(repeating: "ab", count: 32))
        #expect(balance.confirmed == 7)
    }

    @Test("Lines are found wherever the reads happen to split them")
    func lineFramingAtAwkwardBoundaries() async throws {
        let notification = #"{"jsonrpc":"2.0","method":"blockchain.scripthash.subscribe","params":["feed","beef"]}"#
        let responder: Responder = { method, id, _ in
            guard method == "blockchain.scripthash.get_balance" else {
                return standardResponder(method, id, [])
            }
            // A line ending mid-read with the next line already begun, then
            // a line whose newline arrives in a read of its own.
            let balance = #"{"jsonrpc":"2.0","id":\#(id),"result":{"confirmed":7,"unconfirmed":0}}"#
            return [
                String(notification.prefix(30)),
                String(notification.dropFirst(30)) + "\n" + String(balance.prefix(25)),
                String(balance.dropFirst(25)),
                "\n",
            ]
        }
        let client = ElectrumClient(server: testServer, streamFactory: StreamRecorder(responder: responder).factory)
        try await client.connect()

        let received = StatusBox()
        _ = try await client.subscribeScriptHash("feed") { received.set($0) }

        let balance = try await client.getBalance(scriptHash: String(repeating: "ab", count: 32))
        #expect(balance.confirmed == 7)
        #expect(await eventually { received.value == "beef" })

        // Nothing is left over to corrupt the next reply.
        try await client.serverPing()
    }

    @Test("Servers that echo the request id as a string are understood")
    func stringIDs() async throws {
        let responder: Responder = { method, id, _ in
            method == "server.version"
                ? [#"{"jsonrpc":"2.0","id":"\#(id)","result":["Mock","1.4"]}"# + "\n"]
                : [reply(id, "null")]
        }
        let client = ElectrumClient(server: testServer, streamFactory: StreamRecorder(responder: responder).factory)
        try await client.connect()
        #expect(await client.isConnected)
    }

    @Test("Overflowing balances saturate instead of crashing")
    func hostileBalanceDoesNotTrap() async throws {
        let responder: Responder = { method, id, _ in
            method == "blockchain.scripthash.get_balance"
                ? [reply(id, #"{"confirmed":9223372036854775807,"unconfirmed":9223372036854775807}"#)]
                : standardResponder(method, id, [])
        }
        let client = ElectrumClient(server: testServer, streamFactory: StreamRecorder(responder: responder).factory)
        try await client.connect()

        let balance = try await client.getBalance(scriptHash: String(repeating: "ab", count: 32))
        #expect(balance.total == .max)
    }

    @Test("Negative or out-of-range UTXO values are rejected, not passed on")
    func hostileUTXOIsRejected() async throws {
        let responder: Responder = { method, id, _ in
            method == "blockchain.scripthash.listunspent"
                ? [reply(id, #"[{"tx_hash":"\#(String(repeating: "ab", count: 32))","tx_pos":0,"height":1,"value":-5}]"#)]
                : standardResponder(method, id, [])
        }
        let client = ElectrumClient(server: testServer, streamFactory: StreamRecorder(responder: responder).factory)
        try await client.connect()

        await #expect(throws: (any Error).self) {
            _ = try await client.listUnspent(scriptHash: String(repeating: "ab", count: 32))
        }
    }

    @Test("Header heights beyond Int32 are rejected, not truncated")
    func hostileHeaderHeightIsRejected() async throws {
        let responder: Responder = { method, id, _ in
            method == "blockchain.headers.subscribe"
                ? [reply(id, #"{"height":9999999999,"hex":"00"}"#)]
                : standardResponder(method, id, [])
        }
        let client = ElectrumClient(server: testServer, streamFactory: StreamRecorder(responder: responder).factory)
        try await client.connect()

        await #expect(throws: (any Error).self) {
            _ = try await client.subscribeHeaders()
        }
    }

    @Test("A dropped connection fails waiting requests immediately")
    func dropFailsPendingRequests() async throws {
        let responder: Responder = { method, id, _ in
            // Never answers balance queries
            method == "blockchain.scripthash.get_balance" ? [] : standardResponder(method, id, [])
        }
        let recorder = StreamRecorder(responder: responder)
        let client = ElectrumClient(server: testServer, streamFactory: recorder.factory)
        try await client.connect()

        let request = Task {
            try await client.getBalance(scriptHash: String(repeating: "ab", count: 32))
        }
        #expect(await eventually { recorder.streams.first?.methods.contains("blockchain.scripthash.get_balance") == true })

        await recorder.streams.first?.inbox.close()

        await #expect(throws: ElectrumError.serverDisconnected) {
            _ = try await request.value
        }
        #expect(await !client.isConnected)
    }

    @Test("A line that never ends is cut off instead of buffered forever")
    func unboundedLineIsCut() async throws {
        let recorder = StreamRecorder()
        let client = ElectrumClient(server: testServer, streamFactory: recorder.factory)
        try await client.connect()

        let chunk = String(repeating: "x", count: 1024 * 1024)
        for _ in 0..<9 {
            await recorder.streams.first?.send(chunk)
        }
        #expect(await eventually { await !client.isConnected })
    }

    @Test("Concurrent connect calls share one connection")
    func concurrentConnectsShareAttempt() async throws {
        let recorder = StreamRecorder()
        let client = ElectrumClient(server: testServer, streamFactory: recorder.factory)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try await client.connect() }
            }
            try await group.waitForAll()
        }

        #expect(recorder.streams.count == 1)
        #expect(await client.isConnected)
    }

    @Test("Reconnecting ignores the old connection's late shutdown")
    func staleStreamIsIgnored() async throws {
        let recorder = StreamRecorder()
        let client = ElectrumClient(server: testServer, streamFactory: recorder.factory)

        try await client.connect()
        await client.disconnect()
        try await client.connect()

        // The first stream finishing now must not tear down the second.
        await recorder.streams.first?.inbox.close()
        try await Task.sleep(for: .milliseconds(50))

        #expect(await client.isConnected)
        try await client.serverPing()
    }

    @Test("Address subscription notifications reach their handler")
    func scriptHashNotificationsAreRouted() async throws {
        let recorder = StreamRecorder()
        let client = ElectrumClient(server: testServer, streamFactory: recorder.factory)
        try await client.connect()

        let received = StatusBox()
        _ = try await client.subscribeScriptHash("feed") { status in
            received.set(status)
        }
        await recorder.streams.first?.send(#"{"jsonrpc":"2.0","method":"blockchain.scripthash.subscribe","params":["feed","beef"]}"# + "\n")

        #expect(await eventually { received.value == "beef" })
    }

    @Test("A request left unanswered drops the connection so its owner reconnects")
    func unansweredRequestDropsConnection() async throws {
        let responder: Responder = { method, id, _ in
            method == "blockchain.scripthash.get_balance" ? [] : standardResponder(method, id, [])
        }
        let client = ElectrumClient(server: testServer, streamFactory: StreamRecorder(responder: responder).factory, requestTimeout: .milliseconds(200))
        try await client.connect()

        let dropped = StatusBox()
        await client.setDisconnectHandler { dropped.set("dropped") }

        await #expect(throws: ElectrumError.connectionTimeout) {
            _ = try await client.getBalance(scriptHash: String(repeating: "ab", count: 32))
        }
        #expect(await !client.isConnected)
        #expect(await eventually { dropped.value == "dropped" })
    }

    @Test("An idle connection is pinged, so the server does not drop it")
    func idleConnectionIsPinged() async throws {
        let recorder = StreamRecorder()
        let client = ElectrumClient(server: testServer, streamFactory: recorder.factory, keepaliveInterval: .milliseconds(50))
        try await client.connect()

        #expect(await eventually { recorder.streams.first?.methods.contains("server.ping") == true })
        #expect(await client.isConnected)

        // And goes on being pinged for as long as it stays idle.
        #expect(await eventually { (recorder.streams.first?.methods.filter { $0 == "server.ping" }.count ?? 0) >= 3 })
        await client.disconnect()
    }

    @Test("A connection in use is not pinged")
    func busyConnectionIsNotPinged() async throws {
        let recorder = StreamRecorder()
        let client = ElectrumClient(server: testServer, streamFactory: recorder.factory, keepaliveInterval: .milliseconds(400))
        try await client.connect()

        // Requests arrive more often than the keepalive interval, for
        // longer than the interval.
        for _ in 0..<12 {
            _ = try await client.getBalance(scriptHash: String(repeating: "ab", count: 32))
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(recorder.streams.first?.methods.contains("server.ping") == false)
        await client.disconnect()
    }

    @Test("An unanswered keepalive drops the connection so its owner reconnects")
    func unansweredKeepaliveDropsConnection() async throws {
        let responder: Responder = { method, id, _ in
            method == "server.ping" ? [] : standardResponder(method, id, [])
        }
        let client = ElectrumClient(
            server: testServer,
            streamFactory: StreamRecorder(responder: responder).factory,
            requestTimeout: .milliseconds(200),
            keepaliveInterval: .milliseconds(50)
        )
        try await client.connect()

        let dropped = StatusBox()
        await client.setDisconnectHandler { dropped.set("dropped") }

        #expect(await eventually { dropped.value == "dropped" })
        #expect(await !client.isConnected)
    }

    @Test("A disconnected client stops pinging")
    func disconnectStopsKeepalive() async throws {
        let recorder = StreamRecorder()
        let client = ElectrumClient(server: testServer, streamFactory: recorder.factory, keepaliveInterval: .milliseconds(50))
        try await client.connect()
        await client.disconnect()

        let pings = recorder.streams.first?.methods.filter { $0 == "server.ping" }.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.streams.first?.methods.filter { $0 == "server.ping" }.count == pings)
    }
}

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: String?

    var value: String? { lock.withLock { status } }

    func set(_ status: String) {
        lock.withLock { self.status = status }
    }
}

// MARK: - Sync manager

private final class RecordingDelegate: ElectrumSyncDelegate, @unchecked Sendable {
    enum Event: Equatable {
        case connected
        case height(Int32)
        case activity(String)
    }

    private let lock = NSLock()
    private var recorded: [Event] = []

    var events: [Event] { lock.withLock { recorded } }
    var connectedCount: Int { events.count { $0 == .connected } }
    var heights: [Int32] { events.compactMap { if case .height(let height) = $0 { height } else { nil } } }
    var activity: [String] { events.compactMap { if case .activity(let address) = $0 { address } else { nil } } }

    func electrumSyncDidConnect(_ manager: ElectrumSyncManager) async {
        lock.withLock { recorded.append(.connected) }
    }

    func electrumSync(_ manager: ElectrumSyncManager, didReachHeight height: Int32) async {
        lock.withLock { recorded.append(.height(height)) }
    }

    func electrumSync(_ manager: ElectrumSyncManager, didObserveActivityAt address: String) async {
        lock.withLock { recorded.append(.activity(address)) }
    }
}

/// A delegate whose first call does not return until it is released, which
/// holds back every call queued behind it.
private final class StallingDelegate: ElectrumSyncDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int32] = []
    private var connections = 0
    private let (gate, release) = AsyncStream.makeStream(of: Void.self)

    var heights: [Int32] { lock.withLock { recorded } }
    var connectedCount: Int { lock.withLock { connections } }

    func resume() {
        release.finish()
    }

    func electrumSyncDidConnect(_ manager: ElectrumSyncManager) async {
        lock.withLock { connections += 1 }
    }

    func electrumSync(_ manager: ElectrumSyncManager, didReachHeight height: Int32) async {
        let isFirst = lock.withLock {
            recorded.append(height)
            return recorded.count == 1
        }
        if isFirst {
            for await _ in gate {}
        }
    }

    func electrumSync(_ manager: ElectrumSyncManager, didObserveActivityAt address: String) async {}
}

/// Requests a scripted server is sitting on.
private final class HeldRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [Int] = []
    private var isHolding = true

    var ids: [Int] { lock.withLock { held } }

    /// - Returns: Whether the request is now held, and so goes unanswered
    func hold(_ id: Int) -> Bool {
        lock.withLock {
            guard isHolding else { return false }
            held.append(id)
            return true
        }
    }

    /// Stops holding requests.
    /// - Returns: The ones held so far
    func release() -> [Int] {
        lock.withLock {
            isHolding = false
            return held
        }
    }
}

private func headerNotification(height: Int32) -> String {
    #"{"jsonrpc":"2.0","method":"blockchain.headers.subscribe","params":[{"height":\#(height),"hex":"00"}]}"# + "\n"
}

private func errorReply(_ id: Int, code: Int = -32600, _ message: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":\#(code),"message":"\#(message)"}}"# + "\n"
}

/// A server that answers every request as `standardResponder` does, except
/// that it gives `status` — by connection — for an address's history.
private func statusResponder(_ status: @escaping @Sendable (_ connection: Int) -> String?) -> @Sendable (Int) -> Responder {
    { connection in
        { method, id, _ in
            guard method == "blockchain.scripthash.subscribe" else { return standardResponder(method, id, []) }
            return [reply(id, status(connection).map { #""\#($0)""# } ?? "null")]
        }
    }
}

/// A server that says which chain it indexes.
private func chainResponder(genesisHash: String) -> Responder {
    { method, id, _ in
        method == "server.features"
            ? [reply(id, #"{"genesis_hash":"\#(genesisHash)","hosts":{}}"#)]
            : standardResponder(method, id, [])
    }
}

@Suite("Electrum Sync Manager Behavior", .timeLimit(.minutes(1)))
struct ElectrumSyncManagerBehaviorTests {

    private let address = "DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5"

    @Test("A dropped server is replaced and address subscriptions are restored")
    func reconnectsAndResubscribes() async throws {
        let recorder = StreamRecorder()
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        let delegate = RecordingDelegate()
        await manager.setDelegate(delegate)

        try await manager.start()
        try await manager.subscribeToAddresses(["DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5"])
        #expect(await eventually { delegate.connectedCount == 1 })

        // Server drops the connection
        await recorder.streams.first?.inbox.close()

        #expect(await eventually { recorder.streams.count == 2 })
        #expect(await eventually { recorder.streams.last?.methods.contains("blockchain.scripthash.subscribe") == true })
        #expect(await eventually { delegate.connectedCount == 2 })
        #expect(await manager.state.isConnected)
        // Nothing changed at the address while the manager was away.
        #expect(delegate.activity.isEmpty)

        #expect(try await manager.fetchTransactionHistory(for: ["DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5"]).isEmpty)
        await manager.stop()
    }

    @Test("Requests made while disconnected reconnect first")
    func requestTriggersReconnect() async throws {
        let recorder = StreamRecorder()
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)

        try await manager.start()
        await recorder.streams.first?.inbox.close()

        #expect(try await manager.fetchTransactionHistory(for: ["DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5"]).isEmpty)
        await manager.stop()
    }

    @Test("Stopped managers do not reconnect")
    func stoppedManagerStaysDown() async throws {
        let recorder = StreamRecorder()
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)

        try await manager.start()
        await manager.stop()
        try await Task.sleep(for: .milliseconds(100))

        #expect(recorder.streams.count == 1)
        await #expect(throws: ElectrumError.serverDisconnected) {
            _ = try await manager.fetchTransactionHistory(for: ["DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5"])
        }
    }

    @Test("Starting with no servers fails right away")
    func noServers() async throws {
        let manager = ElectrumSyncManager(network: .testnet, serverList: [], streamFactory: StreamRecorder().factory)

        await #expect(throws: ElectrumError.noServersAvailable) {
            try await manager.start()
        }
        #expect(await !manager.state.isConnected)
    }

    @Test("A server that drops the connection is not the first one tried again")
    func droppedServerIsTriedLast() async throws {
        let recorder = StreamRecorder()
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer, secondTestServer], streamFactory: recorder.factory)
        try await manager.start()
        #expect(recorder.hosts == [testServer.host])

        await recorder.streams.last?.inbox.close()
        #expect(await eventually { recorder.hosts.count == 2 })
        #expect(await eventually { await manager.state.isConnected })
        #expect(recorder.hosts == [testServer.host, secondTestServer.host])
        #expect(await manager.connectedServer == secondTestServer)

        // The list wraps around.
        await recorder.streams.last?.inbox.close()
        #expect(await eventually { recorder.hosts.count == 3 })
        #expect(await eventually { await manager.state.isConnected })
        #expect(recorder.hosts == [testServer.host, secondTestServer.host, testServer.host])
        await manager.stop()
    }

    @Test("A request the server never answers is retried on the next server")
    func unansweredRequestMovesToNextServer() async throws {
        let recorder = StreamRecorder { index in
            { method, id, _ in
                // The first connection accepts everything but never answers
                // a history query.
                index == 0 && method == "blockchain.scripthash.get_history" ? [] : standardResponder(method, id, [])
            }
        }
        let manager = ElectrumSyncManager(
            network: .mainnet,
            serverList: [testServer, secondTestServer],
            streamFactory: recorder.factory,
            requestTimeout: .milliseconds(200)
        )
        try await manager.start()

        #expect(try await manager.fetchTransactionHistory(for: ["DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5"]).isEmpty)
        #expect(recorder.hosts == [testServer.host, secondTestServer.host])
        await manager.stop()
    }

    // MARK: Activity

    @Test("A server's notice of activity at an address is passed on")
    func addressNotification() async throws {
        let recorder = StreamRecorder()
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        let delegate = RecordingDelegate()
        await manager.setDelegate(delegate)
        try await manager.start()
        try await manager.subscribeToAddresses([address])
        #expect(delegate.activity.isEmpty)

        let scriptHash = try ElectrumScriptHash(address: address, network: .mainnet).scriptHash
        await recorder.streams.first?.send(
            #"{"jsonrpc":"2.0","method":"blockchain.scripthash.subscribe","params":["\#(scriptHash)","c0ffee"]}"# + "\n"
        )

        #expect(await eventually { delegate.activity == [address] })
        await manager.stop()
    }

    @Test("An address whose history changed while the manager was reconnecting is reported")
    func activityAcrossReconnect() async throws {
        let recorder = StreamRecorder(responderForStream: statusResponder { $0 == 0 ? "aa" : "bb" })
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        let delegate = RecordingDelegate()
        await manager.setDelegate(delegate)
        try await manager.start()
        try await manager.subscribeToAddresses([address])
        #expect(await eventually { delegate.connectedCount == 1 })
        // The first status is where the address starts, not a change.
        #expect(delegate.activity.isEmpty)

        await recorder.streams.first?.inbox.close()

        #expect(await eventually { delegate.connectedCount == 2 })
        // Reported ahead of the connection, whose refresh then covers it.
        #expect(delegate.events.suffix(3) == [.activity(address), .height(5_000_000), .connected])
        await manager.stop()
    }

    @Test("An address that lost its history while the manager was reconnecting is reported")
    func droppedHistoryAcrossReconnect() async throws {
        let recorder = StreamRecorder(responderForStream: statusResponder { $0 == 0 ? "aa" : nil })
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        let delegate = RecordingDelegate()
        await manager.setDelegate(delegate)
        try await manager.start()
        try await manager.subscribeToAddresses([address])

        await recorder.streams.first?.inbox.close()

        #expect(await eventually { delegate.connectedCount == 2 })
        #expect(delegate.activity == [address])
        await manager.stop()
    }

    @Test("Activity the server already announced is not reported again on reconnecting")
    func announcedActivityIsRemembered() async throws {
        // The second connection reports the status the first one announced.
        let recorder = StreamRecorder(responderForStream: statusResponder { $0 == 0 ? nil : "c0ffee" })
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        let delegate = RecordingDelegate()
        await manager.setDelegate(delegate)
        try await manager.start()
        try await manager.subscribeToAddresses([address])

        let scriptHash = try ElectrumScriptHash(address: address, network: .mainnet).scriptHash
        await recorder.streams.first?.send(
            #"{"jsonrpc":"2.0","method":"blockchain.scripthash.subscribe","params":["\#(scriptHash)","c0ffee"]}"# + "\n"
        )
        #expect(await eventually { delegate.activity == [address] })

        await recorder.streams.first?.inbox.close()

        #expect(await eventually { delegate.connectedCount == 2 })
        #expect(delegate.activity == [address])
        await manager.stop()
    }

    // MARK: Ordering

    @Test("Blocks are reported in the order the server announced them")
    func heightsStayInOrder() async throws {
        let recorder = StreamRecorder()
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        let delegate = RecordingDelegate()
        await manager.setDelegate(delegate)
        try await manager.start()

        let announced = (1...300).map { Int32(5_000_000 + $0) }
        await recorder.streams.first?.send(announced.map(headerNotification).joined())

        #expect(await eventually { delegate.heights.count == announced.count + 1 })
        #expect(delegate.heights == [5_000_000] + announced)
        #expect(await manager.currentHeight == 5_000_300)
        await manager.stop()
    }

    @Test("Nothing seen before stop() is reported after it")
    func stopSilencesTheDelegate() async throws {
        let recorder = StreamRecorder()
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        let delegate = StallingDelegate()
        await manager.setDelegate(delegate)
        try await manager.start()
        // The delegate is now stuck in its first call, with the connection
        // and the next block waiting their turn behind it.
        #expect(await eventually { delegate.heights == [5_000_000] })
        await recorder.streams.first?.send(headerNotification(height: 5_000_001))
        #expect(await eventually { await manager.currentHeight == 5_000_001 })

        await manager.stop()
        delegate.resume()
        try await Task.sleep(for: .milliseconds(100))

        #expect(delegate.heights == [5_000_000])
        #expect(delegate.connectedCount == 0)
    }

    // MARK: Load

    @Test("No more than eight requests wait on the server at a time")
    func requestsAreCapped() async throws {
        let held = HeldRequests()
        let recorder = StreamRecorder(responder: { method, id, _ in
            method == "blockchain.scripthash.get_history" && held.hold(id) ? [] : standardResponder(method, id, [])
        })
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()
        let stream = try #require(recorder.streams.first)
        let addresses = try (1...20).map { try Address.fromPubkeyHash(Data(repeating: UInt8($0), count: 20).hexString) }

        let fetch = Task { try await manager.fetchTransactionHistory(for: addresses) }
        #expect(await eventually { held.ids.count == 8 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(held.ids.count == 8)

        // An answer makes room for one more, and only one.
        await stream.send(reply(try #require(held.ids.first), "[]"))
        #expect(await eventually { held.ids.count == 9 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(held.ids.count == 9)

        for id in held.release().dropFirst() {
            await stream.send(reply(id, "[]"))
        }
        #expect(try await fetch.value.isEmpty)
        #expect(stream.methods.count { $0 == "blockchain.scripthash.get_history" } == addresses.count)
        await manager.stop()
    }

    // MARK: Starting

    @Test("A start that fails throws, tells the delegate nothing, and can be tried again")
    func failedStart() async throws {
        let recorder = StreamRecorder(refusing: [0]) { _ in standardResponder }
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        let delegate = RecordingDelegate()
        await manager.setDelegate(delegate)

        await #expect(throws: ElectrumError.connectionFailed("The connection was closed")) {
            try await manager.start()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(delegate.events.isEmpty)
        #expect(await !manager.state.isConnected)
        // Not running: nothing retries in the background.
        #expect(recorder.streams.count == 1)

        try await manager.start()
        #expect(await manager.state.isConnected)
        #expect(await eventually { delegate.events == [.height(5_000_000), .connected] })
        await manager.stop()
    }

    // MARK: The right chain

    @Test("A server that indexes another chain is passed over")
    func wrongChainIsRefused() async throws {
        let litecoin = "12a765e31ffd4059bada1e25190f6e98c99d9714d334efa41a195a7e7e04bfe2"
        let recorder = StreamRecorder { connection in
            chainResponder(genesisHash: connection == 0 ? litecoin : NetworkConstants.mainnetGenesisHash)
        }
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer, secondTestServer], streamFactory: recorder.factory)

        try await manager.start()

        #expect(await manager.connectedServer == secondTestServer)
        // Refused before anything was asked of it.
        #expect(recorder.streams.first?.methods.contains("blockchain.headers.subscribe") == false)
        await manager.stop()
    }

    @Test("With only another chain's server to use, starting fails", arguments: [DogecoinNetwork.mainnet, .testnet])
    func onlyWrongChain(network: DogecoinNetwork) async throws {
        // Each network's server, offered to a wallet on the other.
        let other: DogecoinNetwork = network == .mainnet ? .testnet : .mainnet
        let recorder = StreamRecorder(responder: chainResponder(genesisHash: NetworkConstants.genesisHash(for: other)))
        let manager = ElectrumSyncManager(network: network, serverList: [testServer], streamFactory: recorder.factory)

        await #expect(throws: ElectrumError.invalidResponse("The server is on another chain")) {
            try await manager.start()
        }
        #expect(await !manager.state.isConnected)
    }

    @Test("A server that names this chain is used, however it writes the hash")
    func rightChainIsAccepted() async throws {
        let recorder = StreamRecorder(responder: chainResponder(genesisHash: NetworkConstants.mainnetGenesisHash.uppercased()))
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)

        try await manager.start()

        #expect(await manager.state.isConnected)
        await manager.stop()
    }

    @Test("A server that will not say which chain it indexes is taken at its word")
    func unansweredChainQueryIsTolerated() async throws {
        let recorder = StreamRecorder(responder: { method, id, _ in
            method == "server.features" ? [errorReply(id, code: -32601, "unknown method")] : standardResponder(method, id, [])
        })
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)

        try await manager.start()

        #expect(await manager.state.isConnected)
        await manager.stop()
    }
}

// MARK: - Sync manager resilience

/// A transaction paying `value` to `address` as its only output.
private func fundingTransaction(paying address: String, value: UInt64) throws -> (hex: String, txid: String) {
    let script = try #require(Address.scriptPubKey(for: address))
    var data = Data([1, 0, 0, 0, 1])                      // version, one input
    data.append(Data(repeating: 0x11, count: 32))         // previous txid
    data.append(contentsOf: [0, 0, 0, 0, 0])              // index, empty script
    data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 1])  // sequence, one output
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    data.append(UInt8(script.count))
    data.append(script)
    data.append(contentsOf: [0, 0, 0, 0])                 // lock time
    return (data.hexString, Data(MerkleTree.doubleSHA256(data).reversed()).hexString)
}

/// A server holding `transactions`, all of them unspent at output 0.
/// - Parameter failingRequest: The `blockchain.transaction.get` request,
///   counted from 1, to answer with an error
private func walletResponder(
    transactions: [(hex: String, txid: String)],
    values: [UInt64],
    failingRequest: Int? = nil
) -> Responder {
    let hexByTxid = Dictionary(uniqueKeysWithValues: transactions.map { ($0.txid, $0.hex) })
    let unspent = zip(transactions, values)
        .map { #"{"tx_hash":"\#($0.txid)","tx_pos":0,"height":100,"value":\#($1)}"# }
        .joined(separator: ",")
    let requests = Counter()

    return { method, id, params in
        switch method {
        case "blockchain.scripthash.listunspent":
            return [reply(id, "[\(unspent)]")]
        case "blockchain.transaction.get":
            guard requests.increment() != failingRequest,
                  let txid = params.first as? String, let hex = hexByTxid[txid] else {
                return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32600,"message":"busy"}}"# + "\n"]
            }
            return [reply(id, #""\#(hex)""#)]
        default:
            return standardResponder(method, id, [])
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// - Returns: The count after incrementing
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// A server whose UTXO list and transactions can disagree.
private func utxoResponder(txid: String, reportedValue: UInt64, transactionHex: String) -> Responder {
    { method, id, _ in
        switch method {
        case "blockchain.scripthash.listunspent":
            [reply(id, #"[{"tx_hash":"\#(txid)","tx_pos":0,"height":100,"value":\#(reportedValue)}]"#)]
        case "blockchain.transaction.get":
            [reply(id, #""\#(transactionHex)""#)]
        default:
            standardResponder(method, id, [])
        }
    }
}

@Suite("Electrum Sync Manager Resilience", .timeLimit(.minutes(1)))
struct ElectrumSyncManagerResilienceTests {

    private let address = "DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5"

    @Test("Stopping and restarting while the first start is still connecting leaves the manager running")
    func restartDuringConnect() async throws {
        let recorder = StreamRecorder(openDelay: { $0 == 0 ? .milliseconds(500) : .zero }) { _ in standardResponder }
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)

        let first = Task { try await manager.start() }
        try await Task.sleep(for: .milliseconds(100))
        await manager.stop()
        try await manager.start()
        _ = await first.result

        #expect(await manager.state.isConnected)
        #expect(try await manager.fetchTransactionHistory(for: [address]).isEmpty)
        await manager.stop()
    }

    @Test("A reconnect that fails to restore subscriptions is retried, and later drops still reconnect")
    func failedResubscriptionIsRetried() async throws {
        let recorder = StreamRecorder { index in
            { method, id, _ in
                // The first reconnection refuses subscriptions.
                if index == 1, method == "blockchain.scripthash.subscribe" {
                    return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32600,"message":"busy"}}"# + "\n"]
                }
                return standardResponder(method, id, [])
            }
        }
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()
        try await manager.subscribeToAddresses([address])

        await recorder.streams.first?.inbox.close()
        #expect(await eventually(timeout: .seconds(10)) {
            recorder.streams.count >= 3 && (recorder.streams.last?.methods.contains("blockchain.scripthash.subscribe") ?? false)
        })
        #expect(await eventually { await manager.state.isConnected })

        let connections = recorder.streams.count
        await recorder.streams.last?.inbox.close()
        #expect(await eventually(timeout: .seconds(10)) { recorder.streams.count > connections })
        #expect(await eventually { await manager.state.isConnected })
        await manager.stop()
    }

    @Test("UTXOs whose funding transactions match are returned")
    func verifiedUTXOs() async throws {
        let funding = try fundingTransaction(paying: address, value: 123_456_789)
        let recorder = StreamRecorder(responder: utxoResponder(txid: funding.txid, reportedValue: 123_456_789, transactionHex: funding.hex))
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        let utxos = try await manager.fetchUTXOs(for: [address])
        #expect(utxos.map(\.utxo.value) == [123_456_789])

        // Checked transactions are remembered, not fetched again.
        _ = try await manager.fetchUTXOs(for: [address])
        #expect(recorder.streams.first?.methods.filter { $0 == "blockchain.transaction.get" }.count == 1)
        await manager.stop()
    }

    @Test("A server that understates a UTXO's value is caught")
    func understatedValue() async throws {
        let funding = try fundingTransaction(paying: address, value: 1_000_000_000_000)
        let recorder = StreamRecorder(responder: utxoResponder(txid: funding.txid, reportedValue: 100_000_000, transactionHex: funding.hex))
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        await #expect(throws: ElectrumError.invalidResponse("Server misreported output \(funding.txid):0")) {
            _ = try await manager.fetchUTXOs(for: [address])
        }
        await manager.stop()
    }

    @Test("A funding transaction that does not hash to its txid is caught")
    func forgedFundingTransaction() async throws {
        let real = try fundingTransaction(paying: address, value: 100_000_000)
        let forged = try fundingTransaction(paying: address, value: 999_000_000)
        let recorder = StreamRecorder(responder: utxoResponder(txid: real.txid, reportedValue: 999_000_000, transactionHex: forged.hex))
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        await #expect(throws: ElectrumError.invalidResponse("Transaction does not match txid \(real.txid)")) {
            _ = try await manager.fetchUTXOs(for: [address])
        }
        await #expect(throws: ElectrumError.invalidResponse("Transaction does not match txid \(real.txid)")) {
            _ = try await manager.getTransaction(txid: real.txid)
        }
        await manager.stop()
    }

    @Test("A UTXO whose output pays someone else is caught")
    func outputPaysSomeoneElse() async throws {
        let funding = try fundingTransaction(paying: "A9rmPAxPNGTojaWevb571EYNmCiRLpXzcM", value: 100_000_000)
        let recorder = StreamRecorder(responder: utxoResponder(txid: funding.txid, reportedValue: 100_000_000, transactionHex: funding.hex))
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        await #expect(throws: ElectrumError.invalidResponse("Server misreported output \(funding.txid):0")) {
            _ = try await manager.fetchUTXOs(for: [address])
        }
        await manager.stop()
    }

    @Test("After a failed fetch, verification carries on instead of starting over")
    func verificationResumes() async throws {
        // One more transaction than is fetched at a time, so the request
        // that fails is only sent once another has been verified.
        let values = (1...9).map { UInt64($0) * 100_000_000 }
        let transactions = try values.map { try fundingTransaction(paying: address, value: $0) }
        let recorder = StreamRecorder(responder: walletResponder(transactions: transactions, values: values, failingRequest: 9))
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        await #expect(throws: ElectrumError.requestFailed(code: -32600, message: "busy")) {
            _ = try await manager.fetchUTXOs(for: [address])
        }

        let utxos = try await manager.fetchUTXOs(for: [address])
        #expect(Set(utxos.map(\.utxo.value)) == Set(values.map { Int64($0) }))

        // Starting over would fetch all nine again: eighteen requests.
        let fetches = recorder.streams.first?.methods.filter { $0 == "blockchain.transaction.get" }.count ?? 0
        #expect(fetches < 18)
        await manager.stop()
    }

    @Test("A wallet with more outputs than are remembered still verifies")
    func moreOutputsThanTheCacheHolds() async throws {
        let values = (1...8_200).map { UInt64($0) + 100_000_000 }
        let transactions = try values.map { try fundingTransaction(paying: address, value: $0) }
        let recorder = StreamRecorder(responder: walletResponder(transactions: transactions, values: values))
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        let utxos = try await manager.fetchUTXOs(for: [address])
        #expect(utxos.count == values.count)
        await manager.stop()
    }

    @Test("Broadcasting returns the transaction's own id, whatever the server calls it")
    func broadcastReturnsComputedTxid() async throws {
        let funding = try fundingTransaction(paying: address, value: 100_000_000)
        let responder: Responder = { method, id, _ in
            method == "blockchain.transaction.broadcast"
                ? [reply(id, #""\#(String(repeating: "ff", count: 32))""#)]
                : standardResponder(method, id, [])
        }
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: StreamRecorder(responder: responder).factory)
        try await manager.start()

        #expect(try await manager.broadcastTransaction(funding.hex) == funding.txid)
        await manager.stop()
    }

    @Test("A rejected broadcast is reported, not retried")
    func rejectedBroadcast() async throws {
        let funding = try fundingTransaction(paying: address, value: 100_000_000)
        let responder: Responder = { method, id, _ in
            method == "blockchain.transaction.broadcast"
                ? [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":1,"message":"min relay fee not met"}}"# + "\n"]
                : standardResponder(method, id, [])
        }
        let recorder = StreamRecorder(responder: responder)
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        await #expect(throws: ElectrumError.requestFailed(code: 1, message: "min relay fee not met")) {
            _ = try await manager.broadcastTransaction(funding.hex)
        }
        #expect(recorder.streams.first?.methods.filter { $0 == "blockchain.transaction.broadcast" }.count == 1)
        await manager.stop()
    }

    @Test("A drop right after reconnecting is not left to an older retry's backoff")
    func freshDropGetsFreshRetry() async throws {
        // The retry after the first drop is refused, which puts the retry
        // loop to sleep for a second.
        let recorder = StreamRecorder(refusing: [1]) { _ in standardResponder }
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()
        await recorder.streams.first?.inbox.close()
        #expect(await eventually { recorder.streams.count == 2 })

        // A request does not wait for it, and reconnects.
        #expect(await eventually { (try? await manager.fetchTransactionHistory(for: [address])) != nil })

        // That connection is lost in turn, with the old retry still asleep.
        let connections = recorder.streams.count
        await recorder.streams.last?.inbox.close()
        #expect(await eventually(timeout: .milliseconds(700)) { recorder.streams.count > connections })
        #expect(await eventually { await manager.state.isConnected })
        await manager.stop()
    }

    // MARK: Totals

    @Test("Outputs that add up to more than can exist are refused")
    func impossibleTotal() async throws {
        // Each is no larger than an output may be; together they are.
        let values = [DogecoinAmount.maxMoney.koinu, DogecoinAmount.maxMoney.koinu - 1]
        let transactions = try values.map { try fundingTransaction(paying: address, value: $0) }
        let recorder = StreamRecorder(responder: walletResponder(transactions: transactions, values: values))
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        await #expect(throws: ElectrumError.invalidResponse("The server reported outputs worth more than can exist")) {
            _ = try await manager.fetchUTXOs(for: [address])
        }
        await manager.stop()
    }

    @Test("Outputs that add up to exactly all the money there is are accepted")
    func largestPossibleTotal() async throws {
        let values = [DogecoinAmount.maxMoney.koinu - 1, 1]
        let transactions = try values.map { try fundingTransaction(paying: address, value: $0) }
        let recorder = StreamRecorder(responder: walletResponder(transactions: transactions, values: values))
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        let utxos = try await manager.fetchUTXOs(for: [address])

        #expect(utxos.reduce(0) { $0 + UInt64($1.utxo.value) } == DogecoinAmount.maxMoney.koinu)
        await manager.stop()
    }

    // MARK: Broadcasts that go unanswered

    @Test("A broadcast cut off by a lost connection is reported as unsettled, and not sent again")
    func broadcastCutOff() async throws {
        let funding = try fundingTransaction(paying: address, value: 100_000_000)
        let recorder = StreamRecorder(responder: { method, id, _ in
            method == "blockchain.transaction.broadcast" ? [] : standardResponder(method, id, [])
        })
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        let broadcast = Task { try await manager.broadcastTransaction(funding.hex) }
        #expect(await eventually { recorder.streams.first?.methods.contains("blockchain.transaction.broadcast") == true })
        await recorder.streams.first?.inbox.close()

        await #expect(throws: ElectrumError.broadcastOutcomeUnknown(txid: funding.txid)) {
            _ = try await broadcast.value
        }
        // The manager reconnects, and leaves the transaction alone.
        #expect(await eventually { await manager.state.isConnected && recorder.streams.count == 2 })
        #expect(recorder.streams.flatMap(\.methods).count { $0 == "blockchain.transaction.broadcast" } == 1)
        await manager.stop()
    }

    @Test("A broadcast the server never answers is reported as unsettled")
    func broadcastUnanswered() async throws {
        let funding = try fundingTransaction(paying: address, value: 100_000_000)
        let recorder = StreamRecorder(responder: { method, id, _ in
            method == "blockchain.transaction.broadcast" ? [] : standardResponder(method, id, [])
        })
        let manager = ElectrumSyncManager(
            network: .mainnet,
            serverList: [testServer],
            streamFactory: recorder.factory,
            requestTimeout: .milliseconds(200)
        )
        try await manager.start()

        await #expect(throws: ElectrumError.broadcastOutcomeUnknown(txid: funding.txid)) {
            _ = try await manager.broadcastTransaction(funding.hex)
        }
        #expect(recorder.streams.flatMap(\.methods).count { $0 == "blockchain.transaction.broadcast" } == 1)
        await manager.stop()
    }

    @Test("Something that is not a transaction is never sent")
    func malformedBroadcast() async throws {
        let recorder = StreamRecorder()
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        await #expect(throws: ElectrumError.invalidResponse("Not a transaction")) {
            _ = try await manager.broadcastTransaction("00ff")
        }
        #expect(recorder.streams.first?.methods.contains("blockchain.transaction.broadcast") == false)
        await manager.stop()
    }

    @Test("A transaction the server has is known")
    func knownTransaction() async throws {
        let funding = try fundingTransaction(paying: address, value: 100_000_000)
        let recorder = StreamRecorder(responder: utxoResponder(txid: funding.txid, reportedValue: 100_000_000, transactionHex: funding.hex))
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        #expect(try await manager.isTransactionKnown(txid: funding.txid))
        await manager.stop()
    }

    @Test("A transaction the server has never heard of is not known")
    func unknownTransaction() async throws {
        let funding = try fundingTransaction(paying: address, value: 100_000_000)
        let recorder = StreamRecorder(responder: { method, id, _ in
            method == "blockchain.transaction.get"
                ? [errorReply(id, code: 2, "No such mempool or blockchain transaction")]
                : standardResponder(method, id, [])
        })
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        #expect(try await !manager.isTransactionKnown(txid: funding.txid))
        await manager.stop()
    }

    @Test("A server too busy to answer has not said the transaction is unknown")
    func busyServerSettlesNothing() async throws {
        let funding = try fundingTransaction(paying: address, value: 100_000_000)
        let recorder = StreamRecorder(responder: { method, id, _ in
            method == "blockchain.transaction.get"
                ? [errorReply(id, code: -101, "excessive resource usage")]
                : standardResponder(method, id, [])
        })
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        await #expect(throws: ElectrumError.requestFailed(code: -101, message: "excessive resource usage")) {
            _ = try await manager.isTransactionKnown(txid: funding.txid)
        }
        await manager.stop()
    }

    @Test("A node without a transaction index says \"unknown\" in other words, and is understood")
    func unknownTransactionWithoutIndex() async throws {
        let funding = try fundingTransaction(paying: address, value: 100_000_000)
        let recorder = StreamRecorder(responder: { method, id, _ in
            method == "blockchain.transaction.get"
                ? [errorReply(id, code: 2, "daemon error: DaemonError({'code': -5, 'message': 'No such mempool transaction. Use -txindex to enable blockchain transaction queries. Use gettransaction for wallet transactions.'})")]
                : standardResponder(method, id, [])
        })
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        #expect(try await !manager.isTransactionKnown(txid: funding.txid))
        await manager.stop()
    }

    @Test("Whether a transaction is known is not guessed when the server cannot be asked")
    func transactionKnownNeedsAnAnswer() async throws {
        let funding = try fundingTransaction(paying: address, value: 100_000_000)
        let other = try fundingTransaction(paying: address, value: 200_000_000)
        // A server that answers with some other transaction settles nothing.
        let recorder = StreamRecorder(responder: utxoResponder(txid: funding.txid, reportedValue: 100_000_000, transactionHex: other.hex))
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        await #expect(throws: ElectrumError.invalidResponse("Transaction does not match txid \(funding.txid)")) {
            _ = try await manager.isTransactionKnown(txid: funding.txid)
        }

        await manager.stop()
        await #expect(throws: ElectrumError.serverDisconnected) {
            _ = try await manager.isTransactionKnown(txid: funding.txid)
        }
    }

    // MARK: Block times

    @Test("A block's time comes from its header, and is asked for once")
    func blockTime() async throws {
        let header = BlockHeader(
            version: 0x0062_0104,
            prevBlock: Data(repeating: 0x22, count: 32),
            merkleRoot: Data(repeating: 0x33, count: 32),
            timestamp: 1_700_000_000,
            bits: 0x1a01_cd2d,
            nonce: 0
        )
        // A merge-mined block's header arrives with its proof attached.
        let headerHex = (header.serializeCore() + Data(repeating: 0xAB, count: 120)).hexString
        let recorder = StreamRecorder(responder: { method, id, _ in
            method == "blockchain.block.header" ? [reply(id, #""\#(headerHex)""#)] : standardResponder(method, id, [])
        })
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        #expect(try await manager.blockTime(atHeight: 4_900_000) == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try await manager.blockTime(atHeight: 4_900_000) == Date(timeIntervalSince1970: 1_700_000_000))

        #expect(recorder.streams.first?.methods.count { $0 == "blockchain.block.header" } == 1)
        await manager.stop()
    }

    @Test("A reply too short to be a header gives no block time")
    func blockTimeNeedsAHeader() async throws {
        let recorder = StreamRecorder(responder: { method, id, _ in
            method == "blockchain.block.header" ? [reply(id, #""00ff""#)] : standardResponder(method, id, [])
        })
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        try await manager.start()

        await #expect(throws: ElectrumError.invalidResponse("Not a block header")) {
            _ = try await manager.blockTime(atHeight: 4_900_000)
        }
        await manager.stop()
    }
}
