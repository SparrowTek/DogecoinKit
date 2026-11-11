import Foundation
import Testing
@testable import DogecoinKit

// MARK: - Scripted P2P node

/// A message as a node puts it on the wire.
struct WireMessage: Sendable {
    let command: String
    let payload: Data
}

/// How the scripted node behaves.
struct NodeScript: Sendable {
    enum Handshake: Sendable {
        case versionThenVerack
        case verackThenVersion
        case verackOnly
    }

    var answersVersion = true
    var handshake = Handshake.versionThenVerack
    /// Closes the connection on receiving our version, without a word
    var hangsUpDuringHandshake = false
    /// Does so only for this many connections to the host, then behaves
    var hangUpsBeforeAnswering = 0
    var echoesOurNonce = false
    var sendsGarbageVersion = false
    var answersPing = true
    var magic = NetworkConstants.mainnetMagic
    /// The services the node advertises: a full node that serves bloom
    /// filters, as mainnet nodes are
    var services: UInt64 = 5
    var startHeight: Int32 = 6_400_000
    /// Sent back for every `getheaders`; nil leaves them unanswered
    var headersReply: Data?
    /// Sent back for the first, second, … `getheaders` instead; the last
    /// one is repeated
    var headersReplies: [Data] = []
    /// How long the node takes over each answer to `getheaders`
    var headersReplyDelay: Duration?
    /// Whether the node fetches the transactions announced to it
    var fetchesAnnouncedTransactions = false
    /// The node's answer to a transaction it fetched: a reason to reject it with
    var rejectsTransactionsWith: String?
    /// What the node sends when asked for a filtered block, by block hash
    var filteredBlocks: [Data: [WireMessage]] = [:]
    /// Whether the node answers `notfound` for filtered blocks it has no script for
    var deniesUnknownFilteredBlocks = false
    /// The transactions the node hands over when asked, by txid (internal order)
    var transactions: [Data: Data] = [:]
    /// Whether the node says so when it is asked for a transaction it lacks
    var deniesUnknownTransactions = true
}

/// A `ByteStream` that plays a Dogecoin node.
final class ScriptedNode: ByteStream, @unchecked Sendable {
    let inbox = ChunkInbox()
    let host: String
    let port: UInt16
    /// How many connections to this host came before this one
    let connectionIndex: Int
    private let script: NodeScript
    private let lock = NSLock()
    private var received: [ProtocolMessage] = []
    private var headerRequestsAnswered = 0

    init(script: NodeScript, host: String = "node.test", port: UInt16 = 0, connectionIndex: Int = 0) {
        self.script = script
        self.host = host
        self.port = port
        self.connectionIndex = connectionIndex
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
            if script.hangsUpDuringHandshake || connectionIndex < script.hangUpsBeforeAnswering {
                await inbox.close()
                return
            }
            guard script.answersVersion else { return }
            if script.sendsGarbageVersion {
                await send("version", Data([1, 2, 3]))
                return
            }
            let ours = VersionMessage.parse(from: message.payload)
            let nonce = script.echoesOurNonce ? (ours?.nonce ?? 0) : 42
            let version = VersionMessage(services: script.services, nonce: nonce, userAgent: "/ScriptedNode:1.0/", startHeight: script.startHeight)
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
            let answered = lock.withLock {
                defer { headerRequestsAnswered += 1 }
                return headerRequestsAnswered
            }
            let scripted = script.headersReplies.isEmpty
                ? script.headersReply
                : script.headersReplies[min(answered, script.headersReplies.count - 1)]
            guard let reply = scripted else { return }
            if let delay = script.headersReplyDelay {
                try? await Task.sleep(for: delay)
            }
            await send("headers", reply)
        case ProtocolMessage.Command.inv:
            guard script.fetchesAnnouncedTransactions,
                  let transactions = InvMessage.parse(from: message.payload)?.inventory.filter({ $0.type == .transaction }),
                  !transactions.isEmpty else { return }
            await send("getdata", GetDataMessage(inventory: transactions).serialize())
        case ProtocolMessage.Command.tx:
            guard let reason = script.rejectsTransactionsWith else { return }
            await send("reject", Self.rejection(of: MerkleTree.doubleSHA256(message.payload), reason: reason))
        case ProtocolMessage.Command.getdata:
            let requested = GetDataMessage.parse(from: message.payload)?.inventory ?? []
            var missing: [InventoryVector] = []
            for item in requested {
                switch item.type {
                case .filteredBlock:
                    if let replies = script.filteredBlocks[item.hash] {
                        for reply in replies {
                            await send(reply.command, reply.payload)
                        }
                    } else if script.deniesUnknownFilteredBlocks {
                        missing.append(item)
                    }
                case .transaction:
                    if let transaction = script.transactions[item.hash] {
                        await send("tx", transaction)
                    } else if script.deniesUnknownTransactions {
                        missing.append(item)
                    }
                default:
                    break
                }
            }
            if !missing.isEmpty {
                await send("notfound", NotFoundMessage(inventory: missing).serialize())
            }
        default:
            break
        }
    }

    /// A `reject` for a transaction, as a node sends one.
    static func rejection(of txid: Data, reason: String, code: UInt8 = 0x40) -> Data {
        var payload = VarInt(2).serialize() + Data("tx".utf8)
        payload.append(code)
        payload.append(VarInt(UInt64(reason.utf8.count)).serialize())
        payload.append(Data(reason.utf8))
        payload.append(txid)
        return payload
    }
}

final class NodeRecorder: @unchecked Sendable {
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
        { [self] host, port, _ in
            lock.withLock {
                let earlier = nodes.count { $0.host == host }
                let node = ScriptedNode(script: scripts[host] ?? script, host: host, port: port, connectionIndex: earlier)
                nodes.append(node)
                return node
            }
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
final class PeerEventLog: PeerDelegate, @unchecked Sendable {
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


// MARK: - Peer manager

/// Records what a peer manager reports.
final class ManagerEventLog: PeerManagerDelegate, @unchecked Sendable {
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

/// A peer manager that dials only scripted nodes and — unless it is given
/// somewhere to write them — keeps its bans to itself.
func makePeerManager(
    _ recorder: NodeRecorder,
    network: DogecoinNetwork = .mainnet,
    broadcastTimeout: Duration = .seconds(15),
    rejectionWindow: Duration = .milliseconds(100),
    fallbackNodes: [(host: String, port: UInt16)] = [],
    banStore: UserDefaults? = nil
) -> PeerManager {
    // `UserDefaults` may be used from any thread; its declaration does not
    // say so.
    nonisolated(unsafe) let banStore = banStore
    return PeerManager(
        network: network,
        streamFactory: recorder.factory,
        dnsSeeds: [],
        fallbackNodes: fallbackNodes,
        banStore: banStore,
        broadcastTimeout: broadcastTimeout,
        rejectionWindow: rejectionWindow,
        pacing: PeerManager.Pacing(
            maintenance: .milliseconds(50),
            peerlessMaintenance: .milliseconds(50),
            fallbackDelay: .milliseconds(20)
        )
    )
}

// MARK: - SPV sync

/// Records what an SPV sync reports.
final class SyncEventLog: SPVSyncDelegate, @unchecked Sendable {
    enum TransactionEvent: Equatable {
        case unconfirmed
        case confirmed(blockHash: Data, height: Int32)
        case reorged(previousBlockHash: Data, previousHeight: Int32)
    }

    /// Everything reported, in the order it was
    enum Event: Equatable {
        case completed
        case transaction(TransactionEvent)
        case scanned(through: Int32)
        case failed
    }

    private let lock = NSLock()
    private var completions = 0
    private var transactions: [TransactionEvent] = []
    private var events: [Event] = []

    var completionCount: Int { lock.withLock { completions } }
    var transactionEvents: [TransactionEvent] { lock.withLock { transactions } }
    var allEvents: [Event] { lock.withLock { events } }
    var scanHeights: [Int32] {
        allEvents.compactMap { if case .scanned(let height) = $0 { height } else { nil } }
    }
    var failureCount: Int { allEvents.count { $0 == .failed } }

    /// What was reported apart from completions, with each run of scan
    /// heights reduced to its last. A delegate is told how far the scan has
    /// got — not of every step on the way, when steps come faster than it
    /// takes them.
    var milestones: [Event] {
        var milestones: [Event] = []
        for event in allEvents where event != .completed {
            if case .scanned = event, case .scanned = milestones.last {
                milestones.removeLast()
            }
            milestones.append(event)
        }
        return milestones
    }

    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) async {}

    func spvSyncDidComplete(_ manager: SPVSyncManager) async {
        lock.withLock {
            completions += 1
            events.append(.completed)
        }
    }

    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) async {
        lock.withLock { events.append(.failed) }
    }

    func spvSync(_ manager: SPVSyncManager, didScanThrough height: Int32, targetHeight: Int32) async {
        lock.withLock { events.append(.scanned(through: height)) }
    }

    func spvSync(_ manager: SPVSyncManager, didUpdateTransaction transaction: TxMessage, state: SPVTransactionState) async {
        let event: TransactionEvent = switch state {
        case .unconfirmed:
            .unconfirmed
        case .confirmed(let blockHash, let height):
            .confirmed(blockHash: blockHash, height: height)
        case .reorged(let previousBlockHash, let previousHeight):
            .reorged(previousBlockHash: previousBlockHash, previousHeight: previousHeight)
        }
        lock.withLock {
            transactions.append(event)
            events.append(.transaction(event))
        }
    }
}

/// Sync timing for tests: checks every few milliseconds, and — unless a
/// test is about it — no waiting for a second peer before one peer's word
/// that the chain is complete is taken.
func testTiming(
    headerRequest: Duration = .seconds(60),
    filteredBlock: Duration = .seconds(120),
    check: Duration = .milliseconds(20),
    loneCompletion: Duration = .zero,
    slowHeaderReply: Duration = .seconds(20),
    reannouncement: Duration = .seconds(600)
) -> SPVSyncManager.Timing {
    SPVSyncManager.Timing(
        headerRequest: headerRequest,
        filteredBlock: filteredBlock,
        check: check,
        slowHeaderReply: slowHeaderReply,
        loneCompletion: loneCompletion,
        reannouncement: reannouncement
    )
}

/// What the SPV sync tests start from.
enum SyncFixture {
    /// An empty `headers` message: "nothing after your tip".
    static let noHeaders = Data([0x00])

    /// The height of the mainnet fixture chain's tip, and of the last of
    /// the three real headers that follow it.
    static let tipHeight: Int32 = 6_341_590
    static let extendedHeight: Int32 = 6_341_593

    /// A mainnet sync whose chain holds the fixture's real headers.
    static func mainnet(
        _ recorder: NodeRecorder,
        delegate: SyncEventLog? = nil,
        timing: SPVSyncManager.Timing = testTiming()
    ) async throws -> (SPVSyncManager, PeerManager) {
        let peerManager = makePeerManager(recorder)
        let chain = try await RealChainFixtures.headerChainAtTip()
        let sync = SPVSyncManager(network: .mainnet, peerManager: peerManager, headerChain: chain, timing: timing)
        await sync.setDelegate(delegate)
        await sync.start()
        return (sync, peerManager)
    }

    /// A testnet sync that starts from the genesis block alone.
    static func testnet(
        _ recorder: NodeRecorder,
        delegate: SyncEventLog? = nil,
        timing: SPVSyncManager.Timing = testTiming()
    ) async -> (SPVSyncManager, PeerManager) {
        let peerManager = makePeerManager(recorder, network: .testnet)
        let chain = HeaderChain(network: .testnet, storageDirectory: TestDirectories.unique())
        let sync = SPVSyncManager(network: .testnet, peerManager: peerManager, headerChain: chain, timing: timing)
        await sync.setDelegate(delegate)
        await sync.start()
        return (sync, peerManager)
    }

    /// An `inv` announcing one block.
    static func blockAnnouncement(_ hash: Data) -> Data {
        InvMessage(inventory: [InventoryVector(type: .block, hash: hash)]).serialize()
    }

    /// An `inv` announcing one transaction.
    static func transactionAnnouncement(_ txid: Data) -> Data {
        InvMessage(inventory: [InventoryVector(type: .transaction, hash: txid)]).serialize()
    }
}

extension ScriptedNode {
    /// The hashes of the filtered blocks this node was asked for, in order.
    var filteredBlocksRequested: [Data] {
        payloads(of: "getdata")
            .compactMap { GetDataMessage.parse(from: $0)?.inventory }
            .flatMap { $0 }
            .filter { $0.type == .filteredBlock }
            .map(\.hash)
    }

    /// The transactions this node was asked for, in order.
    var transactionsRequested: [Data] {
        payloads(of: "getdata")
            .compactMap { GetDataMessage.parse(from: $0)?.inventory }
            .flatMap { $0 }
            .filter { $0.type == .transaction }
            .map(\.hash)
    }
}

// MARK: - Made-up chains

/// A chain made up for a test and written straight into a header database,
/// so that no block has to be mined. Its headers are whatever the test
/// says they are; only what is *read* from them — hashes, heights, merkle
/// roots — is exercised.
enum FabricatedChain {
    /// Testnet's genesis block
    static let genesisHash = Data((Data(hexString: "bb0a78264637406b6360aad926284d544d7049f45189db5664f3c4d07350559e") ?? Data()).reversed())
    static let genesisTimestamp: UInt32 = 1_391_503_289

    /// The root given to a block nobody cares about: unlike any other's
    static func plainRoot(_ height: Int32) -> Data {
        var root = Data(repeating: 0xC0, count: 28)
        withUnsafeBytes(of: height.littleEndian) { root.append(contentsOf: $0) }
        return root
    }

    /// `count` headers at heights 1 through `count`, each on the one
    /// before and the first on testnet's genesis block.
    /// - Parameters:
    ///   - merkleRoot: The root of the block at a height; for a block that
    ///     holds one transaction, that transaction's id
    ///   - version: 4 for an ordinary block. With `0x100` set the block is
    ///     flagged as merge-mined, which a header chain takes on trust —
    ///     without a proof — below testnet's last checkpoint.
    static func headers(
        count: Int,
        version: Int32 = 4,
        branch: UInt32 = 0,
        merkleRoot: (Int32) -> Data = plainRoot
    ) -> [BlockHeader] {
        var headers: [BlockHeader] = []
        var parent = genesisHash
        for height in 1...Int32(max(1, count)) {
            let header = BlockHeader(
                version: version,
                prevBlock: parent,
                merkleRoot: merkleRoot(height),
                timestamp: genesisTimestamp + UInt32(height),
                bits: 0x1e0ffff0,
                nonce: branch
            )
            headers.append(header)
            parent = header.hash
        }
        return headers
    }

    /// A testnet header chain that holds the genesis block and `headers`
    /// on top of it as its best chain.
    static func headerChain(holding headers: [BlockHeader]) async throws -> HeaderChain {
        let directory = TestDirectories.unique()
        do {
            // Creates the database and its genesis block.
            try await HeaderChain(network: .testnet, storageDirectory: directory).setup()
        }

        let database = try HeaderDatabase(path: directory.appendingPathComponent("headers.sqlite").path)
        let genesis = try #require(try database.getHeader(height: 0)).toStoredHeader()
        let workPerBlock = ProofOfWorkRules.work(forTarget: UInt256(compact: 0x1e0ffff0) ?? .one)

        var work = UInt256(littleEndian: genesis.chainWork)
        var records: [HeaderRecord] = []
        for (offset, header) in headers.enumerated() {
            work = work &+ workPerBlock
            let stored = StoredHeader(header: header, height: Int32(offset + 1), chainWork: work.littleEndianData)
            records.append(HeaderRecord(storedHeader: stored, isInBestChain: true))
        }
        try database.appendToBestChain(records, after: genesis.header.hash)

        let chain = HeaderChain(network: .testnet, storageDirectory: directory)
        try await chain.setup()
        return chain
    }

    /// The merkle block a node sends for a block whose only transaction is
    /// the one its header commits to.
    /// - Parameter matched: Whether that transaction matched the filter
    static func merkleBlock(for header: BlockHeader, matched: Bool) -> WireMessage {
        WireMessage(command: "merkleblock", payload: ReorgFixtures.merkleBlock(for: header, matched: matched))
    }
}

extension SyncFixture {
    /// A testnet sync whose chain already holds `headers`.
    static func fabricated(
        _ headers: [BlockHeader],
        recorder: NodeRecorder,
        delegate: SyncEventLog? = nil,
        timing: SPVSyncManager.Timing = testTiming()
    ) async throws -> (SPVSyncManager, PeerManager) {
        let peerManager = makePeerManager(recorder, network: .testnet)
        let chain = try await FabricatedChain.headerChain(holding: headers)
        let sync = SPVSyncManager(network: .testnet, peerManager: peerManager, headerChain: chain, timing: timing)
        await sync.setDelegate(delegate)
        await sync.start()
        return (sync, peerManager)
    }

    /// A node on testnet that has nothing beyond a chain of `height` blocks.
    static func testnetNode(height: Int32) -> NodeScript {
        var script = NodeScript()
        script.magic = NetworkConstants.testnetMagic
        script.startHeight = height
        script.headersReply = noHeaders
        return script
    }
}
