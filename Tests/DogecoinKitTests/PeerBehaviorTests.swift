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

/// How the scripted node behaves.
private struct NodeScript: Sendable {
    var answersVersion = true
    var echoesOurNonce = false
    var sendsGarbageVersion = false
    var answersPing = true
    var magic = NetworkConstants.mainnetMagic
    var startHeight: Int32 = 6_400_000
    /// Sent back for every `getheaders`; nil leaves them unanswered
    var headersReply: Data?
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
            await send("version", version.serialize())
            await send("verack")
        case ProtocolMessage.Command.ping:
            guard script.answersPing, let ping = PingMessage.parse(from: message.payload) else { return }
            await send("pong", PongMessage(nonce: ping.nonce).serialize())
        case ProtocolMessage.Command.getheaders:
            guard let headersReply = script.headersReply else { return }
            await send("headers", headersReply)
        default:
            break
        }
    }
}

private final class NodeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: [ScriptedNode] = []
    private let script: NodeScript

    init(script: NodeScript = NodeScript()) {
        self.script = script
    }

    var factory: ByteStreamFactory {
        { [self] host, _, _ in
            let node = ScriptedNode(script: script, host: host)
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

        // Re-pinging must not keep restarting the timeout.
        for _ in 0..<5 {
            await peer.sendPing()
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(await eventually { await peer.state == .disconnected })
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
private func makePeerManager(_ recorder: NodeRecorder) -> PeerManager {
    PeerManager(
        network: .mainnet,
        streamFactory: recorder.factory,
        dnsSeeds: [],
        fallbackNodes: [],
        banStore: nil
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
}

// MARK: - SPV sync

@Suite("SPV Sync Peer Handling")
struct SPVSyncPeerHandlingTests {

    init() async {
        await Dogecoin.initialize()
    }

    /// An empty `headers` message: "nothing after your tip".
    private static let noHeaders = Data([0x00])

    private func makeSync(_ recorder: NodeRecorder) async throws -> (SPVSyncManager, PeerManager) {
        let peerManager = makePeerManager(recorder)
        let chain = try await RealChainFixtures.headerChainAtTip()
        let sync = SPVSyncManager(network: .mainnet, peerManager: peerManager, headerChain: chain)
        await sync.start()
        return (sync, peerManager)
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
}
