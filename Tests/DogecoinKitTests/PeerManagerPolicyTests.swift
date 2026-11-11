import Foundation
import Testing
@testable import DogecoinKit

/// Which peers a manager keeps, which hosts it dials, and what it makes of
/// a peer's answer to a broadcast.
@Suite("Peer Manager Policy", .timeLimit(.minutes(1)))
struct PeerManagerPolicyTests {

    private let transaction = TxMessage(rawData: ReorgFixtures.transaction)

    private var offer: Data {
        SyncFixture.transactionAnnouncement(transaction.txidInternal)
    }

    private func addrMessage(_ addresses: [(String, UInt16)]) -> Data {
        AddrMessage(entries: addresses.map { host, port in
            AddrMessage.Entry(timestamp: UInt32(Date().timeIntervalSince1970), address: .ipv4(host, port: port, services: 5))
        }).serialize()
    }

    // MARK: - Bans

    /// Somewhere of its own for a test's bans, emptied when `body` is done.
    private func withBanStore(_ body: (UserDefaults) async throws -> Void) async throws {
        let suite = "DogecoinKitTests.bans.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        try await body(store)
    }

    @Test("A ban outlives the manager that made it, and the banned host is not dialed")
    func bansPersist() async throws {
        try await withBanStore { store in
            let first = makePeerManager(NodeRecorder(), banStore: store)
            await first.addPeer(host: "bad.test")
            #expect(await eventually { await first.connectedPeerCount == 1 })
            let peer = try #require(await first.connectedPeers.first)
            await first.banPeer(peer, reason: .invalidHeaders)

            // The next launch.
            let recorder = NodeRecorder()
            let second = makePeerManager(recorder, banStore: store)
            #expect(await second.isHostBanned("bad.test"))
            #expect(await !second.isHostBanned("good.test"))

            await second.addPeer(host: "bad.test")
            await second.addPeer(host: "good.test")
            #expect(await eventually { await second.connectedPeerCount == 1 })
            #expect(recorder.all.map(\.host) == ["good.test"])
        }
    }

    @Test("A ban that has run out is forgotten")
    func bansExpire() async throws {
        try await withBanStore { store in
            let first = makePeerManager(NodeRecorder(), banStore: store)
            await first.addPeer(host: "brief.test")
            #expect(await eventually { await first.connectedPeerCount == 1 })
            let peer = try #require(await first.connectedPeers.first)
            await first.banPeer(peer, reason: .invalidHeaders, duration: 0.2)
            #expect(await first.isHostBanned("brief.test"))

            try await Task.sleep(for: .milliseconds(300))

            #expect(await !first.isHostBanned("brief.test"))
            #expect(await !makePeerManager(NodeRecorder(), banStore: store).isHostBanned("brief.test"))
        }
    }

    // MARK: - Services

    @Test("A peer that does not serve bloom filters is dropped once a filter is set, and is never sent one")
    func peerWithoutBloomIsDropped() async throws {
        var plain = SyncFixture.testnetNode(height: 6)
        plain.services = 1
        let recorder = NodeRecorder(scripts: ["a.test": plain, "b.test": SyncFixture.testnetNode(height: 6)])
        let (sync, peerManager) = try await SyncFixture.fabricated(FabricatedChain.headers(count: 6), recorder: recorder)

        // For headers alone, a full node of any kind will do.
        await peerManager.addPeer(host: "a.test")
        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { await peerManager.connectedPeerCount == 2 })

        await sync.configureBloomFilter(elements: [ReorgFixtures.paidPubkeyHash], startHeight: 7)

        // A node without bloom support bans whoever sends it a filter.
        #expect(await peerManager.connectedPeers.map(\.host) == ["b.test"])
        #expect(recorder.node(for: "a.test")?.payloads(of: "filterload").isEmpty == true)
        #expect(await eventually { recorder.node(for: "b.test")?.payloads(of: "filterload").isEmpty == false })

        // Nor is its host dialed again for now.
        await peerManager.addPeer(host: "a.test")
        #expect(recorder.all.count { $0.host == "a.test" } == 1)
        await sync.stop()
    }

    @Test("A peer that does not have the chain is never used", arguments: [UInt64(0), 4, 1024])
    func peerWithoutTheChainIsNeverUsed(services: UInt64) async throws {
        var pruned = SyncFixture.testnetNode(height: 6)
        pruned.services = services
        let recorder = NodeRecorder(script: pruned)
        let (sync, peerManager) = try await SyncFixture.fabricated(FabricatedChain.headers(count: 6), recorder: recorder)

        await peerManager.addPeer(host: "a.test")
        let node = try #require(await eventually { recorder.node(for: "a.test") != nil } ? recorder.node(for: "a.test") : nil)
        #expect(await eventually { node.commandsReceived.contains("verack") })
        try await Task.sleep(for: .milliseconds(150))

        #expect(await peerManager.connectedPeerCount == 0)
        #expect(!node.commandsReceived.contains("getheaders"))
        await sync.stop()
    }

    // MARK: - Dialing

    @Test("A host that hangs up during the handshake is left alone for a while")
    func handshakeHangUpBacksOff() async throws {
        var script = NodeScript()
        script.hangsUpDuringHandshake = true
        let recorder = NodeRecorder(script: script)
        let manager = makePeerManager(recorder)

        await manager.addPeer(host: "a.test")
        #expect(await eventually { recorder.node(for: "a.test")?.commandsReceived == ["version"] })
        try await Task.sleep(for: .milliseconds(100))

        // It closed without an error. Uncounted, the same host would be
        // dialed again at once, for ever.
        await manager.addPeer(host: "a.test")
        await manager.addPeer(host: "a.test")
        #expect(recorder.all.count == 1)
    }

    @Test("A host whose peer was dropped after a good handshake may be dialed again at once")
    func droppedReadyPeerMayBeRedialed() async throws {
        let recorder = NodeRecorder()
        let manager = makePeerManager(recorder)

        await manager.addPeer(host: "a.test")
        #expect(await eventually { await manager.connectedPeerCount == 1 })
        await recorder.node(for: "a.test")?.inbox.close()
        #expect(await eventually { await manager.connectedPeerCount == 0 })

        await manager.addPeer(host: "a.test")
        #expect(await eventually { await manager.connectedPeerCount == 1 })
        #expect(recorder.all.count == 2)
    }

    @Test("With no peer and no host left to try, the manager starts over instead of waiting out its backoffs")
    func peerlessManagerStartsOver() async throws {
        // The only known host turns the first connection away — as every
        // host does while the device is offline.
        var script = NodeScript()
        script.hangUpsBeforeAnswering = 1
        let recorder = NodeRecorder(script: script)
        let manager = makePeerManager(recorder, fallbackNodes: [(host: "a.test", port: 22556)])

        await manager.start()

        // The failure put the host on a 30-second backoff. With nobody
        // connected that says more about this device than about the host.
        #expect(await eventually { await manager.connectedPeerCount == 1 })
        #expect(recorder.all.count { $0.host == "a.test" } == 2)
        await manager.stop()
    }

    // MARK: - Addresses

    @Test("What a peer says about a host the manager already knows changes nothing")
    func gossipDoesNotOverwriteKnownHosts() async throws {
        let recorder = NodeRecorder()
        let manager = makePeerManager(recorder, fallbackNodes: [(host: "9.9.9.9", port: 1111)])
        await manager.start()
        #expect(await eventually { await manager.connectedPeerCount == 1 })
        #expect(await manager.knownPort(of: "9.9.9.9") == 1111)

        let node = try #require(recorder.node(for: "9.9.9.9"))
        await node.send("addr", addrMessage([("9.9.9.9", 2222), ("8.8.8.8", 3333)]))
        #expect(await eventually { await manager.knownPort(of: "8.8.8.8") == 3333 })
        await node.send("addr", addrMessage([("8.8.8.8", 4444), ("9.9.9.9", 5555)]))
        await node.send("ping", PingMessage().serialize())
        #expect(await eventually { node.commandsReceived.contains("pong") })

        // First word stands, and a seed's address is not a peer's to change.
        #expect(await manager.knownPort(of: "9.9.9.9") == 1111)
        #expect(await manager.knownPort(of: "8.8.8.8") == 3333)
        // The host it passed on is dialed on the port it first gave.
        #expect(await eventually { recorder.node(for: "8.8.8.8")?.port == 3333 })
        await manager.stop()
    }

    @Test("One peer cannot fill the address table")
    func gossipIsCappedPerPeer() async throws {
        let recorder = NodeRecorder()
        let manager = makePeerManager(recorder)
        await manager.addPeer(host: "a.test")
        #expect(await eventually { await manager.connectedPeerCount == 1 })
        let node = try #require(recorder.node(for: "a.test"))

        // A thousand hosts in one message: all it is allowed in a minute.
        await node.send("addr", addrMessage((0..<1000).map { ("11.\($0 / 256).\($0 % 256).7", 22556) }))
        await node.send("ping", PingMessage().serialize())
        #expect(await eventually { node.commandsReceived.contains("pong") })

        #expect(await manager.knownAddressCount == 250)
    }

    // MARK: - Broadcasting

    @Test("A broadcast every taker rejects fails with the peer's reason, and the transaction is withdrawn")
    func rejectedBroadcastFails() async throws {
        var script = NodeScript()
        script.fetchesAnnouncedTransactions = true
        script.rejectsTransactionsWith = "bad-txns-inputs-spent"
        let recorder = NodeRecorder(script: script)
        let manager = makePeerManager(recorder, rejectionWindow: .milliseconds(300))
        await manager.addPeer(host: "a.test")
        #expect(await eventually { await manager.connectedPeerCount == 1 })

        await #expect(throws: DogecoinError.broadcastFailed("The network rejected the transaction: bad-txns-inputs-spent")) {
            try await manager.broadcastTransaction(transaction)
        }

        // It reached the peer — and that is all it did. It is no longer on offer.
        let node = try #require(recorder.node(for: "a.test"))
        #expect(node.payloads(of: "tx") == [transaction.rawData])
        await node.send("getdata", GetDataMessage(inventory: [InventoryVector(type: .transaction, hash: transaction.txidInternal)]).serialize())
        try await Task.sleep(for: .milliseconds(100))
        #expect(node.payloads(of: "tx").count == 1)
    }

    @Test("One peer's rejection does not fail a broadcast another peer took")
    func rejectionByOnePeerIsNotFailure() async throws {
        var taking = NodeScript()
        taking.fetchesAnnouncedTransactions = true
        var rejecting = taking
        rejecting.rejectsTransactionsWith = "non-mandatory-script-verify-flag"
        let recorder = NodeRecorder(scripts: ["a.test": rejecting, "b.test": taking])
        let manager = makePeerManager(recorder, rejectionWindow: .milliseconds(300))
        await manager.addPeer(host: "a.test")
        await manager.addPeer(host: "b.test")
        #expect(await eventually { await manager.connectedPeerCount == 2 })

        let txid = try await manager.broadcastTransaction(transaction)

        #expect(txid == transaction.txidHex)
        #expect(recorder.node(for: "b.test")?.payloads(of: "tx") == [transaction.rawData])
    }

    @Test("A rejection of something else is not a rejection of the transaction on offer")
    func unrelatedRejectionIsIgnored() async throws {
        var script = NodeScript()
        script.fetchesAnnouncedTransactions = true
        let recorder = NodeRecorder(script: script)
        let manager = makePeerManager(recorder, rejectionWindow: .milliseconds(300))
        await manager.addPeer(host: "a.test")
        #expect(await eventually { await manager.connectedPeerCount == 1 })
        let node = try #require(recorder.node(for: "a.test"))

        async let txid = manager.broadcastTransaction(transaction)
        #expect(await eventually { node.payloads(of: "tx").count == 1 })
        // Names another transaction; names a block; cut short; not a `tx`.
        await node.send("reject", ScriptedNode.rejection(of: Data(repeating: 0xAB, count: 32), reason: "dust"))
        var blockRejection = VarInt(5).serialize() + Data("block".utf8)
        blockRejection.append(0x10)
        blockRejection.append(VarInt(7).serialize() + Data("invalid".utf8) + transaction.txidInternal)
        await node.send("reject", blockRejection)
        await node.send("reject", ScriptedNode.rejection(of: transaction.txidInternal, reason: "dust").dropLast(1))
        await node.send("reject", Data([0xff]))

        #expect(try await txid == transaction.txidHex)
        #expect(await manager.connectedPeerCount == 1)
    }

    @Test("A peer that connects while a transaction is on offer is told of it")
    func latePeerHearsOfTheOffer() async throws {
        var script = NodeScript()
        script.fetchesAnnouncedTransactions = true
        let recorder = NodeRecorder(script: script)
        let manager = makePeerManager(recorder)
        await manager.addPeer(host: "a.test")
        #expect(await eventually { await manager.connectedPeerCount == 1 })

        _ = try await manager.broadcastTransaction(transaction)
        await manager.addPeer(host: "b.test")

        let nodeB = try #require(await eventually { recorder.node(for: "b.test") != nil } ? recorder.node(for: "b.test") : nil)
        #expect(await eventually { nodeB.payloads(of: "inv") == [offer] })
        #expect(await eventually { nodeB.payloads(of: "tx") == [transaction.rawData] })
    }

    @Test("A standing offer lasts until it is withdrawn")
    func standingOffer() async throws {
        let recorder = NodeRecorder()
        let manager = makePeerManager(recorder)
        await manager.addPeer(host: "a.test")
        #expect(await eventually { await manager.connectedPeerCount == 1 })
        let node = try #require(recorder.node(for: "a.test"))
        let request = GetDataMessage(inventory: [InventoryVector(type: .transaction, hash: transaction.txidInternal)]).serialize()

        await manager.offer(transaction)
        await manager.offer(transaction)
        #expect(await eventually { node.payloads(of: "inv") == [offer, offer] })
        await node.send("getdata", request)
        #expect(await eventually { node.payloads(of: "tx") == [transaction.rawData] })

        await manager.withdraw(transactionID: transaction.txidInternal)
        await node.send("getdata", request)
        await manager.addPeer(host: "b.test")
        #expect(await eventually { await manager.connectedPeerCount == 2 })
        try await Task.sleep(for: .milliseconds(100))

        #expect(node.payloads(of: "tx").count == 1)
        #expect(recorder.node(for: "b.test")?.payloads(of: "inv").isEmpty == true)
    }
}

@Suite("Reject Message")
struct RejectMessageTests {

    @Test("A node's rejection of a transaction is read whole")
    func parsesTransactionRejection() throws {
        let txid = Data(repeating: 0x7E, count: 32)
        let rejection = try #require(RejectMessage.parse(from: ScriptedNode.rejection(of: txid, reason: "bad-txns-inputs-spent", code: 0x12)))

        #expect(rejection == RejectMessage(message: "tx", code: 0x12, reason: "bad-txns-inputs-spent", hash: txid))
    }

    @Test("A rejection without a hash names nothing")
    func parsesRejectionWithoutHash() throws {
        var payload = VarInt(7).serialize() + Data("version".utf8)
        payload.append(0x11)
        payload.append(VarInt(8).serialize() + Data("obsolete".utf8))

        let rejection = try #require(RejectMessage.parse(from: payload))
        #expect(rejection.message == "version")
        #expect(rejection.code == 0x11)
        #expect(rejection.reason == "obsolete")
        #expect(rejection.hash == nil)
    }

    @Test("Text a peer chose is kept only as far as it prints")
    func sanitizesText() throws {
        var payload = VarInt(2).serialize() + Data("tx".utf8)
        payload.append(0x40)
        let reason = Data("du".utf8) + Data([0x0a, 0x1b, 0x00]) + Data("st".utf8)
        payload.append(VarInt(UInt64(reason.count)).serialize() + reason)

        #expect(RejectMessage.parse(from: payload)?.reason == "dust")
    }

    private static let malformed: [Data] = {
        let longCommand: Data = Data([0x0d]) + Data(repeating: 0x61, count: 13) + Data([0x40, 0x00])
        let longReason: Data = Data([0x02, 0x74, 0x78, 0x40, 0x70]) + Data(repeating: 0x61, count: 112)
        return [
            Data(),
            Data([0x02, 0x74]),                                 // command cut short
            Data([0x02, 0x74, 0x78]),                           // no code
            Data([0x02, 0x74, 0x78, 0x40]),                     // no reason length
            Data([0x02, 0x74, 0x78, 0x40, 0x05, 0x64, 0x75]),   // reason cut short
            longCommand,                                        // command longer than any
            longReason,                                         // reason longer than any
            Data(repeating: 0xff, count: 9)                     // hostile length
        ]
    }()

    @Test("Malformed and oversized rejections do not parse", arguments: malformed)
    func rejectsMalformed(payload: Data) {
        #expect(RejectMessage.parse(from: payload) == nil)
    }
}
