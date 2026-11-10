import Foundation
import Testing
@testable import DogecoinKit

// MARK: - Scripted Electrum server

/// Chunks queued for the client to read, plus end-of-stream.
private actor Inbox {
    private var chunks: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var closed = false

    func push(_ chunk: Data) {
        guard !closed else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: chunk)
        } else {
            chunks.append(chunk)
        }
    }

    func close() {
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func next() async -> Data? {
        if !chunks.isEmpty {
            return chunks.removeFirst()
        }
        if closed {
            return nil
        }
        return await withCheckedContinuation { waiter = $0 }
    }
}

/// Answers JSON-RPC requests the way a scripted server would.
private typealias Responder = @Sendable (_ method: String, _ id: Int, _ params: [Any]) -> [String]

/// An in-memory `ByteStream` backed by a `Responder`.
private final class ScriptedStream: ByteStream, @unchecked Sendable {
    let inbox = Inbox()
    private let responder: Responder
    private let openDelay: Duration
    private let lock = NSLock()
    private var sentMethods: [String] = []

    init(responder: @escaping Responder, openDelay: Duration = .zero) {
        self.responder = responder
        self.openDelay = openDelay
    }

    var methods: [String] {
        lock.withLock { sentMethods }
    }

    func open() async throws {
        if openDelay > .zero {
            try await Task.sleep(for: openDelay)
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
    private let responderForStream: @Sendable (Int) -> Responder
    private let openDelay: @Sendable (Int) -> Duration

    init(responder: @escaping Responder = standardResponder) {
        self.responderForStream = { _ in responder }
        self.openDelay = { _ in .zero }
    }

    /// Scripts each connection separately, by the order it was opened in.
    init(openDelay: @escaping @Sendable (Int) -> Duration = { _ in .zero }, responderForStream: @escaping @Sendable (Int) -> Responder) {
        self.responderForStream = responderForStream
        self.openDelay = openDelay
    }

    var factory: ByteStreamFactory {
        { [self] _, _, _ in
            lock.withLock {
                let index = opened.count
                let stream = ScriptedStream(responder: responderForStream(index), openDelay: openDelay(index))
                opened.append(stream)
                return stream
            }
        }
    }

    var streams: [ScriptedStream] {
        lock.withLock { opened }
    }
}

private let testServer = ElectrumServer(host: "electrum.test", port: 50002, useSSL: true, network: .mainnet)

private func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// MARK: - Tests

@Suite("Electrum Client Behavior")
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
        #expect(await waitUntil { recorder.streams.first?.methods.contains("blockchain.scripthash.get_balance") == true })

        await recorder.streams.first?.inbox.close()

        await #expect(throws: ElectrumError.self) {
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
        #expect(await waitUntil { await !client.isConnected })
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

        #expect(await waitUntil { received.value == "beef" })
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

        await #expect(throws: ElectrumError.self) {
            _ = try await client.getBalance(scriptHash: String(repeating: "ab", count: 32))
        }
        #expect(await !client.isConnected)
        #expect(await waitUntil { dropped.value == "dropped" })
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

private final class RecordingDelegate: BlockchainSyncDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var completions = 0
    private var errors = 0

    var completedCount: Int { lock.withLock { completions } }
    var errorCount: Int { lock.withLock { errors } }

    func syncManagerDidComplete(_ manager: any BlockchainSyncManager) async {
        lock.withLock { completions += 1 }
    }

    func syncManager(_ manager: any BlockchainSyncManager, didEncounterError error: Error) async {
        lock.withLock { errors += 1 }
    }
}

@Suite("Electrum Sync Manager Behavior")
struct ElectrumSyncManagerBehaviorTests {

    @Test("A dropped server is replaced and address subscriptions are restored")
    func reconnectsAndResubscribes() async throws {
        let recorder = StreamRecorder()
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)
        let delegate = RecordingDelegate()
        await manager.setDelegate(delegate)

        try await manager.start()
        try await manager.subscribeToAddresses(["DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5"])
        #expect(await waitUntil { delegate.completedCount == 1 })

        // Server drops the connection
        await recorder.streams.first?.inbox.close()

        #expect(await waitUntil { recorder.streams.count == 2 })
        #expect(await waitUntil { recorder.streams.last?.methods.contains("blockchain.scripthash.subscribe") == true })
        #expect(await waitUntil { delegate.completedCount == 2 })
        #expect(delegate.errorCount == 0)
        #expect(await manager.state.isConnected)

        let balance = try await manager.refreshBalance(for: ["DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5"])
        #expect(balance == 60)
        await manager.stop()
    }

    @Test("Requests made while disconnected reconnect first")
    func requestTriggersReconnect() async throws {
        let recorder = StreamRecorder()
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [testServer], streamFactory: recorder.factory)

        try await manager.start()
        await recorder.streams.first?.inbox.close()

        let balance = try await manager.refreshBalance(for: ["DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5"])
        #expect(balance == 60)
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
        await #expect(throws: ElectrumError.self) {
            _ = try await manager.refreshBalance(for: ["DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5"])
        }
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

@Suite("Electrum Sync Manager Resilience")
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
        let balance = try await manager.refreshBalance(for: [address])
        #expect(balance == 60)
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
        #expect(await waitUntil(timeout: .seconds(10)) {
            recorder.streams.count >= 3 && (recorder.streams.last?.methods.contains("blockchain.scripthash.subscribe") ?? false)
        })
        #expect(await waitUntil { await manager.state.isConnected })

        let connections = recorder.streams.count
        await recorder.streams.last?.inbox.close()
        #expect(await waitUntil(timeout: .seconds(10)) { recorder.streams.count > connections })
        #expect(await waitUntil { await manager.state.isConnected })
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

        await #expect(throws: ElectrumError.self) {
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

        await #expect(throws: ElectrumError.self) {
            _ = try await manager.fetchUTXOs(for: [address])
        }
        await #expect(throws: ElectrumError.self) {
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

        await #expect(throws: ElectrumError.self) {
            _ = try await manager.fetchUTXOs(for: [address])
        }
        await manager.stop()
    }
}
