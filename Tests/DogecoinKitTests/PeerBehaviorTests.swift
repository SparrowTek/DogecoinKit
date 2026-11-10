import Foundation
import Testing
@testable import DogecoinKit

// MARK: - Scripted P2P node

/// Bytes queued for the peer to read.
private actor WireInbox {
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

/// A message as a node puts it on the wire.
private struct WireMessage: Sendable {
    let command: String
    let payload: Data
}

/// How the scripted node behaves.
private struct NodeScript: Sendable {
    enum Handshake: Sendable {
        case versionThenVerack
        case verackThenVersion
        case verackOnly
    }

    var answersVersion = true
    var handshake = Handshake.versionThenVerack
    var echoesOurNonce = false
    var sendsGarbageVersion = false
    var answersPing = true
    var magic = NetworkConstants.mainnetMagic
    var startHeight: Int32 = 6_400_000
    /// Sent back for every `getheaders`; nil leaves them unanswered
    var headersReply: Data?
    /// Whether the node fetches the transactions announced to it
    var fetchesAnnouncedTransactions = false
    /// What the node sends when asked for a filtered block, by block hash
    var filteredBlocks: [Data: [WireMessage]] = [:]
}

/// A `ByteStream` that plays a Dogecoin node.
private final class ScriptedNode: ByteStream, @unchecked Sendable {
    let inbox = WireInbox()
    let host: String
    private let script: NodeScript
    private let lock = NSLock()
    private var received: [ProtocolMessage] = []

    init(script: NodeScript, host: String = "node.test") {
        self.script = script
        self.host = host
    }

    var commandsReceived: [String] {
        lock.withLock { received.map(\.command) }
    }

    func payloads(of command: String) -> [Data] {
        lock.withLock { received.filter { $0.command == command }.map(\.payload) }
    }

    func open() async throws {}

    func write(_ data: Data) async throws {
        var buffer = data
        while case .message(let message, let remaining) = ProtocolMessage.parseDetailed(from: buffer) {
            buffer = remaining
            lock.withLock { received.append(message) }
            await respond(to: message)
        }
    }

    func read() async throws -> Data? {
        await inbox.next()
    }

    func close() {
        Task { await inbox.close() }
    }

    func send(_ command: String, _ payload: Data = Data()) async {
        await inbox.push(ProtocolMessage(magic: script.magic, command: command, payload: payload).serialize())
    }

    private func respond(to message: ProtocolMessage) async {
        switch message.command {
        case ProtocolMessage.Command.version:
            guard script.answersVersion else { return }
            if script.sendsGarbageVersion {
                await send("version", Data([1, 2, 3]))
                return
            }
            let ours = VersionMessage.parse(from: message.payload)
            let nonce = script.echoesOurNonce ? (ours?.nonce ?? 0) : 42
            let version = VersionMessage(nonce: nonce, userAgent: "/ScriptedNode:1.0/", startHeight: script.startHeight)
            switch script.handshake {
            case .versionThenVerack:
                await send("version", version.serialize())
                await send("verack")
            case .verackThenVersion:
                await send("verack")
                await send("version", version.serialize())
            case .verackOnly:
                await send("verack")
            }
        case ProtocolMessage.Command.ping:
            guard script.answersPing, let ping = PingMessage.parse(from: message.payload) else { return }
            await send("pong", PongMessage(nonce: ping.nonce).serialize())
        case ProtocolMessage.Command.getheaders:
            guard let headersReply = script.headersReply else { return }
            await send("headers", headersReply)
        case ProtocolMessage.Command.inv:
            guard script.fetchesAnnouncedTransactions,
                  let transactions = InvMessage.parse(from: message.payload)?.inventory.filter({ $0.type == .transaction }),
                  !transactions.isEmpty else { return }
            await send("getdata", GetDataMessage(inventory: transactions).serialize())
        case ProtocolMessage.Command.getdata:
            let requested = GetDataMessage.parse(from: message.payload)?.inventory ?? []
            for item in requested where item.type == .filteredBlock {
                for reply in script.filteredBlocks[item.hash] ?? [] {
                    await send(reply.command, reply.payload)
                }
            }
        default:
            break
        }
    }
}

private final class NodeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: [ScriptedNode] = []
    private let script: NodeScript
    private let scripts: [String: NodeScript]

    /// - Parameters:
    ///   - script: How every node behaves, unless `scripts` says otherwise
    ///   - scripts: How particular nodes behave, by host
    init(script: NodeScript = NodeScript(), scripts: [String: NodeScript] = [:]) {
        self.script = script
        self.scripts = scripts
    }

    var factory: ByteStreamFactory {
        { [self] host, _, _ in
            let node = ScriptedNode(script: scripts[host] ?? script, host: host)
            lock.withLock { nodes.append(node) }
            return node
        }
    }

    func node(for host: String) -> ScriptedNode? {
        lock.withLock { nodes.last { $0.host == host } }
    }

    var all: [ScriptedNode] {
        lock.withLock { nodes }
    }
}

/// Records everything a peer reports, in order.
private final class PeerEventLog: PeerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Peer.State] = []
    private var commands: [String] = []
    private var payloads: [Data] = []
    private var errors: [String] = []

    var stateHistory: [Peer.State] { lock.withLock { states } }
    var messageCommands: [String] { lock.withLock { commands } }
    var messagePayloads: [Data] { lock.withLock { payloads } }
    var errorDescriptions: [String] { lock.withLock { errors } }

    func peer(_ peer: Peer, didChangeState state: Peer.State) async {
        lock.withLock { states.append(state) }
    }

    func peer(_ peer: Peer, didReceiveMessage message: ProtocolMessage) async {
        lock.withLock {
            commands.append(message.command)
            payloads.append(message.payload)
        }
    }

    func peer(_ peer: Peer, didFailWithError error: Error) async {
        lock.withLock { errors.append(String(describing: error)) }
    }
}

private func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// MARK: - Tests

@Suite("Peer Behavior")
struct PeerBehaviorTests {

    private func makePeer(_ recorder: NodeRecorder, log: PeerEventLog) async -> Peer {
        let peer = Peer(host: "node.test", port: 22556, network: .mainnet, streamFactory: recorder.factory)
        await peer.setDelegate(log)
        return peer
    }

    @Test("The handshake completes and requests addresses afterwards")
    func handshake() async throws {
        let recorder = NodeRecorder()
        let log = PeerEventLog()
        let peer = await makePeer(recorder, log: log)

        await peer.connect()
        #expect(await eventually { await peer.state == .ready })
        #expect(log.stateHistory == [.connecting, .connected, .handshaking, .ready])
        #expect(await peer.peerVersion?.startHeight == 6_400_000)

        let node = try #require(recorder.all.first)
        #expect(await eventually { node.commandsReceived == ["version", "verack", "getaddr"] })
    }

    @Test("The version sent claims no services and asks for no transaction relay")
    func versionSent() async throws {
        let recorder = NodeRecorder()
        let peer = await makePeer(recorder, log: PeerEventLog())

        await peer.connect()
        #expect(await eventually { await peer.state == .ready })

        let payload = try #require(recorder.all.first?.payloads(of: "version").first)
        let version = try #require(VersionMessage.parse(from: payload))
        #expect(version.services == 0)
        #expect(!version.relay)
    }

    @Test("A verack that arrives before the version still completes the handshake")
    func verackBeforeVersion() async throws {
        var script = NodeScript()
        script.handshake = .verackThenVersion
        let recorder = NodeRecorder(script: script)
        let log = PeerEventLog()
        let peer = await makePeer(recorder, log: log)

        await peer.connect()
        #expect(await eventually { await peer.state == .ready })
        #expect(await peer.peerVersion?.startHeight == 6_400_000)
        #expect(log.stateHistory == [.connecting, .connected, .handshaking, .ready])
    }

    @Test("A peer that acknowledges us without sending its version never becomes ready")
    func verackWithoutVersion() async throws {
        var script = NodeScript()
        script.handshake = .verackOnly
        let recorder = NodeRecorder(script: script)
        let log = PeerEventLog()
        let peer = await makePeer(recorder, log: log)
        await peer.configureTimeouts(handshake: 0.3)

        await peer.connect()
        #expect(await eventually { await peer.state == .disconnected })
        #expect(!log.stateHistory.contains(.ready))
        #expect(log.errorDescriptions.contains { $0.contains("handshake") })
    }

    @Test("Messages reach the delegate in exactly wire order")
    func messagesStayOrdered() async throws {
        let recorder = NodeRecorder()
        let log = PeerEventLog()
        let peer = await makePeer(recorder, log: log)
        await peer.connect()
        #expect(await eventually { await peer.state == .ready })

        // 200 distinct messages, many packed into single reads
        let node = try #require(recorder.all.first)
        var batch = Data()
        for index in 0..<200 {
            batch.append(ProtocolMessage(network: .mainnet, command: "inv", payload: InvMessage(inventory: [
                InventoryVector(type: .transaction, hash: Data(repeating: UInt8(index % 256), count: 31) + Data([UInt8(index / 256)]))
            ]).serialize()).serialize())
            if index % 37 == 0 {
                await node.inbox.push(batch)
                batch = Data()
            }
        }
        await node.inbox.push(batch)

        #expect(await eventually { log.messagePayloads.count == 200 })
        let order = log.messagePayloads.compactMap { InvMessage.parse(from: $0)?.inventory.first?.hash.first }
        #expect(order == (0..<200).map { UInt8($0 % 256) })
    }

    @Test("An unparseable version message ends the connection at once")
    func garbageVersionDisconnects() async throws {
        var script = NodeScript()
        script.sendsGarbageVersion = true
        let recorder = NodeRecorder(script: script)
        let log = PeerEventLog()
        let peer = await makePeer(recorder, log: log)

        await peer.connect()
        #expect(await eventually { await peer.state == .disconnected })
        #expect(!log.errorDescriptions.isEmpty)
    }

    @Test("Dialing ourselves is detected and dropped")
    func selfConnectionDropped() async throws {
        var script = NodeScript()
        script.echoesOurNonce = true
        let recorder = NodeRecorder(script: script)
        let log = PeerEventLog()
        let peer = await makePeer(recorder, log: log)

        await peer.connect()
        #expect(await eventually { await peer.state == .disconnected })
        #expect(!log.stateHistory.contains(.ready))
    }

    @Test("Messages with another network's magic end the connection")
    func wrongMagicDisconnects() async throws {
        var script = NodeScript()
        script.magic = NetworkConstants.testnetMagic
        let recorder = NodeRecorder(script: script)
        let log = PeerEventLog()
        let peer = await makePeer(recorder, log: log)

        await peer.connect()
        #expect(await eventually { await peer.state == .disconnected })
        #expect(log.errorDescriptions.contains { $0.contains("invalidMagic") })
    }

    @Test("A peer that never answers pings is dropped, even when pinged repeatedly")
    func unansweredPingTimesOut() async throws {
        var script = NodeScript()
        script.answersPing = false
        let recorder = NodeRecorder(script: script)
        let log = PeerEventLog()
        let peer = await makePeer(recorder, log: log)
        await peer.configureTimeouts(ping: 0.3)

        await peer.connect()
        #expect(await eventually { await peer.state == .ready })

        // Re-pinging must not keep restarting the timeout: pinged several
        // times per timeout, for several timeouts, the peer is still dropped.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline, await peer.state != .disconnected {
            await peer.sendPing()
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(await peer.state == .disconnected)
        #expect(log.errorDescriptions.contains { $0.contains("ping") })
    }

    @Test("Answered pings keep the peer connected and measure round-trip time")
    func answeredPingMeasuresRTT() async throws {
        let recorder = NodeRecorder()
        let log = PeerEventLog()
        let peer = await makePeer(recorder, log: log)
        await peer.configureTimeouts(ping: 0.3)

        await peer.connect()
        #expect(await eventually { await peer.state == .ready })

        await peer.sendPing()
        #expect(await eventually { await peer.roundTripTime != nil })
        try await Task.sleep(for: .milliseconds(500))
        #expect(await peer.state == .ready)
    }

    @Test("A reconnect is not torn down by the old connection closing late")
    func staleConnectionIgnored() async throws {
        let recorder = NodeRecorder()
        let log = PeerEventLog()
        let peer = await makePeer(recorder, log: log)

        await peer.connect()
        #expect(await eventually { await peer.state == .ready })
        await peer.disconnect()

        await peer.connect()
        #expect(await eventually { await peer.state == .ready })

        await recorder.all.first?.inbox.close()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await peer.state == .ready)
    }

    @Test("The remote closing the connection is reported as a disconnect")
    func remoteCloseDisconnects() async throws {
        let recorder = NodeRecorder()
        let log = PeerEventLog()
        let peer = await makePeer(recorder, log: log)

        await peer.connect()
        #expect(await eventually { await peer.state == .ready })

        await recorder.all.first?.inbox.close()
        #expect(await eventually { await peer.state == .disconnected })
    }
}

// MARK: - Peer manager

/// Records what a peer manager reports.
private final class ManagerEventLog: PeerManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var ready = 0
    private var disconnected = 0
    private var counts: [Int] = []

    var readyCount: Int { lock.withLock { ready } }
    var disconnectCount: Int { lock.withLock { disconnected } }
    var lastCount: Int? { lock.withLock { counts.last } }

    func peerManager(_ manager: PeerManager, peerDidBecomeReady peer: Peer) async {
        lock.withLock { ready += 1 }
    }

    func peerManager(_ manager: PeerManager, peerDidDisconnect peer: Peer) async {
        lock.withLock { disconnected += 1 }
    }

    func peerManager(_ manager: PeerManager, peer: Peer, didReceiveMessage message: ProtocolMessage) async {}

    func peerManager(_ manager: PeerManager, connectedPeerCountChanged count: Int) async {
        lock.withLock { counts.append(count) }
    }
}

/// A peer manager that dials only scripted nodes and keeps its bans to itself.
private func makePeerManager(
    _ recorder: NodeRecorder,
    network: DogecoinNetwork = .mainnet,
    broadcastTimeout: Duration = .seconds(15)
) -> PeerManager {
    PeerManager(
        network: network,
        streamFactory: recorder.factory,
        dnsSeeds: [],
        fallbackNodes: [],
        banStore: nil,
        broadcastTimeout: broadcastTimeout
    )
}

@Suite("Peer Manager Behavior")
struct PeerManagerBehaviorTests {

    @Test("Removing a ready peer reports the disconnect")
    func removalIsReported() async throws {
        let manager = makePeerManager(NodeRecorder())
        let events = ManagerEventLog()
        await manager.setDelegate(events)

        await manager.addPeer(host: "a.test")
        #expect(await eventually { events.readyCount == 1 })

        let peer = try #require(await manager.connectedPeers.first)
        await manager.removePeer(peer)

        #expect(events.disconnectCount == 1)
        #expect(events.lastCount == 0)
        #expect(await manager.connectedPeerCount == 0)
    }

    @Test("Banning a ready peer reports the disconnect")
    func banIsReported() async throws {
        let host = "ban.test"
        let manager = makePeerManager(NodeRecorder())
        let events = ManagerEventLog()
        await manager.setDelegate(events)

        await manager.addPeer(host: host)
        #expect(await eventually { events.readyCount == 1 })

        let peer = try #require(await manager.connectedPeers.first)
        await manager.banPeer(peer, reason: .invalidHeaders)

        #expect(events.disconnectCount == 1)
        #expect(await manager.isHostBanned(host))
    }

    @Test("A peer the remote drops is reported exactly once")
    func remoteDropIsReportedOnce() async throws {
        let recorder = NodeRecorder()
        let manager = makePeerManager(recorder)
        let events = ManagerEventLog()
        await manager.setDelegate(events)

        await manager.addPeer(host: "a.test")
        #expect(await eventually { events.readyCount == 1 })

        await recorder.node(for: "a.test")?.inbox.close()
        #expect(await eventually { events.disconnectCount == 1 })

        if let peer = await manager.connectedPeers.first {
            await manager.removePeer(peer)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.disconnectCount == 1)
    }

    @Test("A peer asking for addresses gets no answer")
    func addressRequestsAreNotAnswered() async throws {
        let recorder = NodeRecorder()
        let manager = makePeerManager(recorder)
        await manager.addPeer(host: "a.test")
        #expect(await eventually { await manager.connectedPeerCount == 1 })
        let node = try #require(recorder.node(for: "a.test"))

        // Something the manager could pass on, were it to answer.
        let entry = AddrMessage.Entry(timestamp: UInt32(Date().timeIntervalSince1970), address: .ipv4("8.8.8.8", port: 22556, services: 1))
        await node.send("addr", AddrMessage(entries: [entry]).serialize())
        await node.send("getaddr")

        try await Task.sleep(for: .milliseconds(150))
        #expect(!node.commandsReceived.contains("addr"))
        #expect(await manager.connectedPeerCount == 1)
    }

    // MARK: Broadcasting

    private let transaction = TxMessage(rawData: ReorgFixtures.transaction)

    @Test("A broadcast returns once a peer has fetched the transaction")
    func broadcastWaitsForFetch() async throws {
        var script = NodeScript()
        script.fetchesAnnouncedTransactions = true
        let recorder = NodeRecorder(script: script)
        let manager = makePeerManager(recorder)
        await manager.addPeer(host: "a.test")
        #expect(await eventually { await manager.connectedPeerCount == 1 })

        let txid = try await manager.broadcastTransaction(transaction)

        #expect(txid == transaction.txidHex)
        let node = try #require(recorder.node(for: "a.test"))
        #expect(await eventually { node.payloads(of: "tx") == [transaction.rawData] })
    }

    @Test("One peer fetching the transaction is enough")
    func broadcastNeedsOnlyOneFetch() async throws {
        var fetching = NodeScript()
        fetching.fetchesAnnouncedTransactions = true
        let recorder = NodeRecorder(scripts: ["b.test": fetching])
        let manager = makePeerManager(recorder)
        await manager.addPeer(host: "a.test")
        await manager.addPeer(host: "b.test")
        #expect(await eventually { await manager.connectedPeerCount == 2 })

        _ = try await manager.broadcastTransaction(transaction)

        #expect(recorder.node(for: "a.test")?.commandsReceived.contains("inv") == true)
        #expect(recorder.node(for: "a.test")?.payloads(of: "tx").isEmpty == true)
    }

    @Test("A broadcast no peer asks for fails, and the transaction is withdrawn")
    func broadcastFailsWhenNobodyFetches() async throws {
        let recorder = NodeRecorder()
        let manager = makePeerManager(recorder, broadcastTimeout: .milliseconds(200))
        await manager.addPeer(host: "a.test")
        #expect(await eventually { await manager.connectedPeerCount == 1 })

        let error = await #expect(throws: DogecoinError.self) {
            try await manager.broadcastTransaction(transaction)
        }
        #expect(error == .broadcastFailed("No peer asked for the transaction"))

        // It was announced; asking for it now is too late.
        let node = try #require(recorder.node(for: "a.test"))
        #expect(node.commandsReceived.contains("inv"))
        let request = GetDataMessage(inventory: [InventoryVector(type: .transaction, hash: transaction.txidInternal)])
        await node.send("getdata", request.serialize())
        try await Task.sleep(for: .milliseconds(150))
        #expect(node.payloads(of: "tx").isEmpty)
    }

    @Test("A broadcast that failed can be tried again")
    func broadcastRetry() async throws {
        let recorder = NodeRecorder()
        let manager = makePeerManager(recorder, broadcastTimeout: .milliseconds(300))
        await manager.addPeer(host: "a.test")
        #expect(await eventually { await manager.connectedPeerCount == 1 })
        let node = try #require(recorder.node(for: "a.test"))

        await #expect(throws: DogecoinError.self) {
            try await manager.broadcastTransaction(transaction)
        }

        // The second time, the peer asks.
        let request = GetDataMessage(inventory: [InventoryVector(type: .transaction, hash: transaction.txidInternal)])
        async let txid = manager.broadcastTransaction(transaction)
        #expect(await eventually { node.payloads(of: "inv").count == 2 })
        await node.send("getdata", request.serialize())

        #expect(try await txid == transaction.txidHex)
        #expect(await eventually { node.payloads(of: "tx") == [transaction.rawData] })
    }

    @Test("Broadcasting with no peer connected fails at once")
    func broadcastWithoutPeers() async {
        let manager = makePeerManager(NodeRecorder())

        await #expect(throws: DogecoinError.noPeersAvailable) {
            try await manager.broadcastTransaction(transaction)
        }
    }
}

// MARK: - Wire format

@Suite("Network Magic")
struct NetworkMagicTests {

    @Test("Messages start with their network's magic bytes", arguments: [
        (DogecoinNetwork.mainnet, [UInt8](arrayLiteral: 0xc0, 0xc0, 0xc0, 0xc0)),
        (DogecoinNetwork.testnet, [UInt8](arrayLiteral: 0xfc, 0xc1, 0xb7, 0xdc)),
    ])
    func magicBytes(network: DogecoinNetwork, expected: [UInt8]) {
        let message = ProtocolMessage(network: network, command: "verack", payload: Data())
        #expect([UInt8](message.serialize().prefix(4)) == expected)
    }

    @Test("A message survives the trip through its own network's framing", arguments: [DogecoinNetwork.mainnet, .testnet])
    func roundTrip(network: DogecoinNetwork) throws {
        let message = ProtocolMessage(network: network, command: "ping", payload: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        let parsed = try #require(ProtocolMessage.parse(from: message.serialize()))
        #expect(parsed.message == message)
        #expect(parsed.message.magic == NetworkConstants.magic(for: network))
    }
}

// MARK: - SPV sync

/// Records what an SPV sync reports.
private final class SyncEventLog: SPVSyncDelegate, @unchecked Sendable {
    enum TransactionEvent: Equatable {
        case unconfirmed
        case confirmed(blockHash: Data, height: Int32)
        case reorged(previousBlockHash: Data, previousHeight: Int32)
    }

    private let lock = NSLock()
    private var completions = 0
    private var transactions: [TransactionEvent] = []

    var completionCount: Int { lock.withLock { completions } }
    var transactionEvents: [TransactionEvent] { lock.withLock { transactions } }

    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) async {}

    func spvSyncDidComplete(_ manager: SPVSyncManager) async {
        lock.withLock { completions += 1 }
    }

    func spvSync(_ manager: SPVSyncManager, didReceiveHeader header: BlockHeader, height: Int32) async {}

    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) async {}

    func spvSync(_ manager: SPVSyncManager, didUpdateTransaction transaction: TxMessage, state: SPVTransactionState) async {
        let event: TransactionEvent = switch state {
        case .unconfirmed:
            .unconfirmed
        case .confirmed(let blockHash, let height):
            .confirmed(blockHash: blockHash, height: height)
        case .reorged(let previousBlockHash, let previousHeight):
            .reorged(previousBlockHash: previousBlockHash, previousHeight: previousHeight)
        }
        lock.withLock { transactions.append(event) }
    }
}

@Suite("SPV Sync Peer Handling")
struct SPVSyncPeerHandlingTests {

    init() async {
        await Dogecoin.initialize()
    }

    /// An empty `headers` message: "nothing after your tip".
    private static let noHeaders = Data([0x00])

    /// The height of the fixture chain's tip, and of the last of the three
    /// real headers that follow it.
    private static let tipHeight: Int32 = 6_341_590
    private static let extendedHeight: Int32 = 6_341_593

    private func makeSync(_ recorder: NodeRecorder, delegate: SyncEventLog? = nil) async throws -> (SPVSyncManager, PeerManager) {
        let peerManager = makePeerManager(recorder)
        let chain = try await RealChainFixtures.headerChainAtTip()
        let sync = SPVSyncManager(network: .mainnet, peerManager: peerManager, headerChain: chain)
        await sync.setDelegate(delegate)
        await sync.start()
        return (sync, peerManager)
    }

    private func blockAnnouncement(_ hash: Data) -> Data {
        InvMessage(inventory: [InventoryVector(type: .block, hash: hash)]).serialize()
    }

    @Test("Losing the sync peer moves header requests to another peer")
    func syncPeerLossSwitchesPeers() async throws {
        let recorder = NodeRecorder(script: NodeScript(startHeight: 6_341_600))
        let (sync, peerManager) = try await makeSync(recorder)

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { recorder.node(for: "a.test")?.commandsReceived.contains("getheaders") == true })
        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { await peerManager.connectedPeerCount == 2 })
        #expect(recorder.node(for: "b.test")?.commandsReceived.contains("getheaders") == false)

        // Removed the way a ban or timeout removes it.
        let syncPeer = try #require(await peerManager.connectedPeers.first { $0.host == "a.test" })
        await peerManager.removePeer(syncPeer)

        #expect(await eventually { recorder.node(for: "b.test")?.commandsReceived.contains("getheaders") == true })
        await sync.stop()
    }

    @Test("After losing every peer while synchronized, the next peer resumes the sync")
    func resumesAfterLosingAllPeers() async throws {
        let recorder = NodeRecorder(script: NodeScript(startHeight: 6_341_590, headersReply: Self.noHeaders))
        let (sync, peerManager) = try await makeSync(recorder)

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })

        let only = try #require(await peerManager.connectedPeers.first)
        await peerManager.removePeer(only)
        #expect(await peerManager.connectedPeerCount == 0)

        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { recorder.node(for: "b.test")?.commandsReceived.contains("getheaders") == true })
        #expect(await eventually { await sync.state == .synchronized })
        await sync.stop()
    }

    @Test("Announced blocks never make the filtered-block scan skip ahead")
    func announcedBlocksDoNotCompleteScan() async throws {
        let recorder = NodeRecorder(script: NodeScript(startHeight: 6_341_590, headersReply: Self.noHeaders))
        let (sync, peerManager) = try await makeSync(recorder)

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })
        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { await peerManager.connectedPeerCount == 2 })

        await sync.configureBloomFilter(elements: [Data(repeating: 0x42, count: 20)], startHeight: 6_341_585)
        let nodeA = try #require(recorder.node(for: "a.test"))
        #expect(await eventually { !nodeA.payloads(of: "getdata").isEmpty })

        // Merkle blocks for blocks the scan never asked for — as if peers
        // had announced them — must not count against the scan's requests.
        for nonce in UInt32(1)...6 {
            let root = Data(repeating: UInt8(nonce), count: 32)
            let header = BlockHeader(version: 0x0062_0004, prevBlock: Data(count: 32), merkleRoot: root, timestamp: 1, bits: 0x1a00ffff, nonce: nonce)
            let block = MerkleBlockMessage(header: header, totalTransactions: 1, hashes: [root], flags: Data([0x00]))
            await nodeA.send("merkleblock", block.serialize())
        }
        try await Task.sleep(for: .milliseconds(200))

        // Valid merkle blocks are no offense: the peer is still connected.
        let peerA = try #require(await peerManager.connectedPeers.first { $0.host == "a.test" })
        await peerManager.removePeer(peerA)

        // The lost range goes to the other peer in full.
        let expected = RealChainFixtures.storedAncestors().filter { $0.height >= 6_341_585 }.map(\.header.hash)
        #expect(await eventually {
            let requested = recorder.node(for: "b.test")?.payloads(of: "getdata")
                .compactMap { GetDataMessage.parse(from: $0)?.inventory }
                .flatMap { $0 }
                .filter { $0.type == .filteredBlock }
                .map(\.hash) ?? []
            return Set(requested) == Set(expected)
        })
        await sync.stop()
    }

    // MARK: Following the best chain

    @Test("A peer that connects with a longer chain is asked for it, even when the sync looked complete")
    func longerChainFromLaterPeer() async throws {
        let recorder = NodeRecorder(scripts: [
            "a.test": NodeScript(startHeight: Self.tipHeight, headersReply: Self.noHeaders),
            "b.test": NodeScript(startHeight: Self.extendedHeight, headersReply: RealChainFixtures.headersPayload()),
        ])
        let (sync, peerManager) = try await makeSync(recorder)

        // The first peer has nothing new, and the sync settles behind it.
        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })
        #expect(await sync.currentHeight == Self.tipHeight)

        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { await sync.currentHeight == Self.extendedHeight })
        #expect(await eventually { await sync.state == .synchronized })
        await sync.stop()
    }

    @Test("A block announced by a peer other than the one being followed is fetched, once")
    func announcementFromAnotherPeer() async throws {
        let recorder = NodeRecorder(scripts: [
            "a.test": NodeScript(startHeight: Self.tipHeight, headersReply: Self.noHeaders),
            "b.test": NodeScript(startHeight: Self.tipHeight, headersReply: RealChainFixtures.headersPayload()),
        ])
        let events = SyncEventLog()
        let (sync, peerManager) = try await makeSync(recorder, delegate: events)

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })
        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { await peerManager.connectedPeerCount == 2 })
        let nodeA = try #require(recorder.node(for: "a.test"))
        let nodeB = try #require(recorder.node(for: "b.test"))
        #expect(!nodeB.commandsReceived.contains("getheaders"))
        #expect(await eventually { events.completionCount == 1 })

        // The peer being followed stays silent; the other announces a block.
        let newBlock = try #require(RealChainFixtures.parsedEntries().first).header.hash
        await nodeB.send("inv", blockAnnouncement(newBlock))
        #expect(await eventually { await sync.currentHeight == Self.extendedHeight })
        #expect(await eventually { events.completionCount == 2 })

        // Announced again by a slower peer, the block is already known.
        let requestsToA = nodeA.payloads(of: "getheaders").count
        await nodeA.send("inv", blockAnnouncement(newBlock))
        try await Task.sleep(for: .milliseconds(150))
        #expect(nodeA.payloads(of: "getheaders").count == requestsToA)
        await sync.stop()
    }

    @Test("A peer confirming there is nothing new does not report completion again")
    func completionIsReportedOncePerHeight() async throws {
        let recorder = NodeRecorder(script: NodeScript(startHeight: Self.tipHeight, headersReply: Self.noHeaders))
        let events = SyncEventLog()
        let (sync, peerManager) = try await makeSync(recorder, delegate: events)

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { events.completionCount == 1 })
        let node = try #require(recorder.node(for: "a.test"))

        // Announcing a block the chain lacks makes the sync ask again; the
        // peer then has nothing to show for it.
        await node.send("inv", blockAnnouncement(Data(repeating: 0xAB, count: 32)))
        #expect(await eventually { node.payloads(of: "getheaders").count == 2 })
        try await Task.sleep(for: .milliseconds(150))

        #expect(events.completionCount == 1)
        #expect(await sync.state == .synchronized)
        await sync.stop()
    }

    @Test("Headers that fail for a reason that may be local are not re-requested from peer after peer at once")
    func unacceptedHeadersDoNotBounce() async throws {
        // One header whose parent is unknown. It proves nothing against its
        // sender, so nobody is banned for it.
        let orphan = BlockHeader(
            version: 0x0062_0004,
            prevBlock: Data(repeating: 0xEE, count: 32),
            merkleRoot: Data(repeating: 0x01, count: 32),
            timestamp: 1,
            bits: 0x1a00ffff,
            nonce: 0
        )
        let script = NodeScript(startHeight: 6_341_600, headersReply: ReorgFixtures.headersPayload([orphan]))
        let recorder = NodeRecorder(script: script)
        let (sync, peerManager) = try await makeSync(recorder)

        await peerManager.addPeer(host: "a.test")
        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { await peerManager.connectedPeerCount == 2 })
        try await Task.sleep(for: .milliseconds(400))

        // Each peer is asked when it connects. Bouncing between them would
        // have sent hundreds of requests by now.
        let requests = recorder.all.reduce(0) { $0 + $1.payloads(of: "getheaders").count }
        #expect(requests <= 2)
        #expect(await peerManager.connectedPeerCount == 2)
        await sync.stop()
    }

    // MARK: Transactions

    @Test("A transaction a peer sends unasked is reported only if it matches the filter")
    func unsolicitedTransactions() async throws {
        let recorder = NodeRecorder(script: NodeScript(startHeight: Self.tipHeight, headersReply: Self.noHeaders))
        let events = SyncEventLog()
        let (sync, peerManager) = try await makeSync(recorder, delegate: events)
        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })
        let node = try #require(recorder.node(for: "a.test"))

        // A filter for other keys — with a fixed tweak, and large enough
        // that it does not match by accident, as a one-element filter does
        // about one time in three.
        let otherKeys = (1...50).map { Data(repeating: UInt8($0), count: 20) }
        await sync.configureBloomFilter(elements: otherKeys, falsePositiveRate: 0.0001, tweak: 0, startHeight: Self.tipHeight)
        await node.send("tx", ReorgFixtures.transaction)
        try await Task.sleep(for: .milliseconds(150))
        #expect(events.transactionEvents.isEmpty)

        await sync.configureBloomFilter(elements: otherKeys + [ReorgFixtures.paidPubkeyHash], tweak: 0, startHeight: Self.tipHeight)
        await node.send("tx", ReorgFixtures.transaction)
        #expect(await eventually { events.transactionEvents == [.unconfirmed] })
        #expect(await peerManager.connectedPeerCount == 1)
        await sync.stop()
    }

    @Test("A peer that sends a malformed transaction is banned, and nothing is reported")
    func malformedTransactionBansPeer() async throws {
        let recorder = NodeRecorder(script: NodeScript(startHeight: Self.tipHeight, headersReply: Self.noHeaders))
        let events = SyncEventLog()
        let (sync, peerManager) = try await makeSync(recorder, delegate: events)
        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })
        await sync.configureBloomFilter(elements: [ReorgFixtures.paidPubkeyHash], startHeight: Self.tipHeight)

        // A transaction that pays the wallet, with a byte tacked on: every
        // such variation would count as a different payment.
        let node = try #require(recorder.node(for: "a.test"))
        await node.send("tx", ReorgFixtures.transaction + Data([0x00]))

        #expect(await eventually { await peerManager.isHostBanned("a.test") })
        #expect(events.transactionEvents.isEmpty)
        await sync.stop()
    }

    @Test("A transaction whose block is reorganized away is confirmed again in the block that replaced it")
    func reorganizedTransactionIsReconfirmed() async throws {
        let a1 = ReorgFixtures.a1
        let b1 = ReorgFixtures.b1
        let b2 = ReorgFixtures.b2
        let transaction = WireMessage(command: "tx", payload: ReorgFixtures.transaction)

        var script = NodeScript()
        script.magic = NetworkConstants.testnetMagic
        script.startHeight = 1
        script.headersReply = ReorgFixtures.headersPayload([a1])
        script.filteredBlocks = [
            a1.hash: [WireMessage(command: "merkleblock", payload: ReorgFixtures.merkleBlock(for: a1, matched: true)), transaction],
            // The node has sent the transaction once and does not repeat it.
            b1.hash: [WireMessage(command: "merkleblock", payload: ReorgFixtures.merkleBlock(for: b1, matched: true))],
            b2.hash: [WireMessage(command: "merkleblock", payload: ReorgFixtures.merkleBlock(for: b2, matched: false))],
        ]
        let recorder = NodeRecorder(script: script)
        let peerManager = makePeerManager(recorder, network: .testnet)
        let chain = HeaderChain(network: .testnet, storageDirectory: TestDirectories.unique())
        let sync = SPVSyncManager(network: .testnet, peerManager: peerManager, headerChain: chain)
        let events = SyncEventLog()
        await sync.setDelegate(events)
        await sync.start()

        // The wallet's transaction confirms in a1.
        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.currentHeight == 1 })
        await sync.configureBloomFilter(elements: [ReorgFixtures.paidPubkeyHash], startHeight: 1)
        #expect(await eventually { events.transactionEvents == [.confirmed(blockHash: a1.hash, height: 1)] })

        // Then a longer branch replaces a1 with b1, which holds it too.
        let node = try #require(recorder.node(for: "a.test"))
        await node.send("headers", ReorgFixtures.headersPayload([b1, b2]))

        #expect(await eventually { await sync.currentHeight == 2 })
        #expect(await eventually {
            events.transactionEvents == [
                .confirmed(blockHash: a1.hash, height: 1),
                .reorged(previousBlockHash: a1.hash, previousHeight: 1),
                .confirmed(blockHash: b1.hash, height: 1),
            ]
        })
        #expect(await peerManager.connectedPeerCount == 1)
        await sync.stop()
    }

    @Test("The same merkle block arriving again confirms nothing twice and leaves nothing waiting")
    func duplicateMerkleBlock() async throws {
        let a1 = ReorgFixtures.a1
        let merkleBlock = WireMessage(command: "merkleblock", payload: ReorgFixtures.merkleBlock(for: a1, matched: true))
        let transaction = WireMessage(command: "tx", payload: ReorgFixtures.transaction)

        var script = NodeScript()
        script.magic = NetworkConstants.testnetMagic
        script.startHeight = 1
        script.headersReply = ReorgFixtures.headersPayload([a1])
        script.filteredBlocks = [a1.hash: [merkleBlock, transaction]]
        let recorder = NodeRecorder(script: script)
        let peerManager = makePeerManager(recorder, network: .testnet)
        let chain = HeaderChain(network: .testnet, storageDirectory: TestDirectories.unique())
        let sync = SPVSyncManager(network: .testnet, peerManager: peerManager, headerChain: chain)
        let events = SyncEventLog()
        await sync.setDelegate(events)
        await sync.start()

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.currentHeight == 1 })
        await sync.configureBloomFilter(elements: [ReorgFixtures.paidPubkeyHash], startHeight: 1)
        let confirmed = [SyncEventLog.TransactionEvent.confirmed(blockHash: a1.hash, height: 1)]
        #expect(await eventually { events.transactionEvents == confirmed })

        // As when a second peer announces the block and sends it as well.
        let node = try #require(recorder.node(for: "a.test"))
        await node.send(merkleBlock.command, merkleBlock.payload)
        await node.send(transaction.command, transaction.payload)
        try await Task.sleep(for: .milliseconds(150))

        #expect(events.transactionEvents == confirmed)
        #expect(await sync.pendingMerkleBlockCount == 0)
        #expect(await peerManager.connectedPeerCount == 1)
        await sync.stop()
    }
}
