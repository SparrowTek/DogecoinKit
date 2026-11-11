import Foundation
import Testing
@testable import DogecoinKit

/// The scan for the wallet's transactions: which peer it asks, what it
/// believes of the answers, and how far it says it has got.
@Suite("SPV Scan", .timeLimit(.minutes(1)))
struct SPVSyncScanTests {

    private static let transaction = ReorgFixtures.transaction
    private static let txid = MerkleTree.doubleSHA256(ReorgFixtures.transaction)
    private static let walletKey = ReorgFixtures.paidPubkeyHash
    private static let transactionMessage = WireMessage(command: "tx", payload: ReorgFixtures.transaction)

    /// Keys that are not the wallet's — enough of them, with a fixed tweak,
    /// that the filter does not match what it was never given.
    private static let otherKeys = (1...50).map { Data(repeating: UInt8($0), count: 20) }

    /// Six blocks; the wallet's transaction is the only one in those at
    /// `paying`.
    private static func chain(paying: Set<Int32> = []) -> [BlockHeader] {
        FabricatedChain.headers(count: 6) { paying.contains($0) ? txid : FabricatedChain.plainRoot($0) }
    }

    /// A node that serves the filtered blocks of `headers` — those at
    /// `matching` with a match, and the transaction after them — except
    /// the ones at `withholding`.
    private static func servingNode(
        _ headers: [BlockHeader],
        matching: Set<Int32> = [],
        withholding: Set<Int32> = [],
        sendsTransactions: Bool = true
    ) -> NodeScript {
        var script = SyncFixture.testnetNode(height: Int32(headers.count))
        for (offset, header) in headers.enumerated() {
            let height = Int32(offset + 1)
            guard !withholding.contains(height) else { continue }
            let matched = matching.contains(height)
            var messages = [FabricatedChain.merkleBlock(for: header, matched: matched)]
            if matched, sendsTransactions {
                messages.append(transactionMessage)
            }
            script.filteredBlocks[header.hash] = messages
        }
        return script
    }

    // MARK: - Peers that do not deliver

    @Test("A peer that serves headers but not every filtered block is dropped, and the scan goes on with another")
    func withholdingPeerIsReplaced() async throws {
        let headers = Self.chain()
        let recorder = NodeRecorder(scripts: [
            // Serves blocks 1 to 3 and 5, 6 — but never block 4.
            "a.test": Self.servingNode(headers, withholding: [4]),
            "b.test": Self.servingNode(headers),
        ])
        let events = SyncEventLog()
        let (sync, peerManager) = try await SyncFixture.fabricated(
            headers, recorder: recorder, delegate: events, timing: testTiming(filteredBlock: .milliseconds(300))
        )

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })
        await sync.configureBloomFilter(elements: Self.otherKeys, tweak: 0, startHeight: 1)

        // The scan gets as far as block 3 and no further: block 4 is
        // missing, and what came after it does not count yet.
        #expect(await eventually { events.scanHeights.last == 3 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(events.scanHeights.max() == 3)

        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { events.scanHeights.last == 6 })

        // The peer that kept block 4 back is gone, and its host is left
        // alone for now.
        #expect(await peerManager.connectedPeers.map(\.host) == ["b.test"])
        await peerManager.addPeer(host: "a.test")
        #expect(recorder.all.count { $0.host == "a.test" } == 1)

        // The other was asked for everything from block 4 on, block 4 included.
        let nodeB = try #require(recorder.node(for: "b.test"))
        #expect(Set(nodeB.filteredBlocksRequested) == Set(headers.dropFirst(3).map(\.hash)))
        // The height only ever went up.
        #expect(events.scanHeights == events.scanHeights.sorted())
        #expect(await sync.filteredBlocksInFlightCount == 0)
        await sync.stop()
    }

    @Test("A peer that says it lacks the blocks stays connected, and is not asked for blocks again")
    func peerWithoutBlocksIsSkipped() async throws {
        let headers = Self.chain()
        var lacking = SyncFixture.testnetNode(height: 6)
        lacking.deniesUnknownFilteredBlocks = true
        let recorder = NodeRecorder(scripts: ["a.test": lacking, "b.test": Self.servingNode(headers)])
        let events = SyncEventLog()
        let (sync, peerManager) = try await SyncFixture.fabricated(headers, recorder: recorder, delegate: events)

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })
        await sync.configureBloomFilter(elements: Self.otherKeys, tweak: 0, startHeight: 1)
        let nodeA = try #require(recorder.node(for: "a.test"))
        #expect(await eventually { nodeA.commandsReceived.contains("getdata") })

        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { events.scanHeights.last == 6 })

        // Useful for headers still: it was not dropped. But the blocks were
        // asked of it once only.
        #expect(await peerManager.connectedPeerCount == 2)
        #expect(nodeA.payloads(of: "getdata").count == 1)
        #expect(recorder.node(for: "b.test")?.filteredBlocksRequested == headers.map(\.hash))
        await sync.stop()
    }

    @Test("A merkle block from a peer it was not asked of counts for nothing")
    func merkleBlockFromAnotherPeerIsIgnored() async throws {
        let headers = Self.chain()
        // Neither node answers a request for filtered blocks.
        let recorder = NodeRecorder(script: SyncFixture.testnetNode(height: 6))
        let events = SyncEventLog()
        let (sync, peerManager) = try await SyncFixture.fabricated(headers, recorder: recorder, delegate: events)

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })
        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { await peerManager.connectedPeerCount == 2 })

        await sync.configureBloomFilter(elements: Self.otherKeys, tweak: 0, startHeight: 1)
        let nodeA = try #require(recorder.node(for: "a.test"))
        let nodeB = try #require(recorder.node(for: "b.test"))
        #expect(await eventually { nodeA.filteredBlocksRequested.count == 6 })
        #expect(nodeB.filteredBlocksRequested.isEmpty)

        // The blocks were asked of one peer; the other sends them.
        for header in headers {
            let block = FabricatedChain.merkleBlock(for: header, matched: false)
            await nodeB.send(block.command, block.payload)
        }
        try await Task.sleep(for: .milliseconds(150))

        #expect(events.scanHeights.isEmpty)
        #expect(await sync.filteredBlocksInFlightCount == 6)
        #expect(await peerManager.connectedPeerCount == 2)
        await sync.stop()
    }

    // MARK: - The filter and the blocks

    @Test("No block is asked for before the peer has the filter")
    func filterIsLoadedBeforeBlocksAreRequested() async throws {
        let headers = Self.chain()
        let recorder = NodeRecorder(script: Self.servingNode(headers))
        let events = SyncEventLog()
        let (sync, peerManager) = try await SyncFixture.fabricated(headers, recorder: recorder, delegate: events)

        // Configured before any peer is there, and again once one is.
        await sync.configureBloomFilter(elements: Self.otherKeys, tweak: 0, startHeight: 1)
        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { events.scanHeights.last == 6 })

        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { await peerManager.connectedPeerCount == 2 })
        await sync.configureBloomFilter(elements: Self.otherKeys, tweak: 1, startHeight: 1)
        // The scan runs again from the start: six more blocks, all answered.
        #expect(await eventually { recorder.all.flatMap(\.filteredBlocksRequested).count == 12 })
        #expect(await eventually { await sync.filteredBlocksInFlightCount == 0 })

        // A node without a filter answers a request for a filtered block
        // with nothing at all.
        for node in recorder.all {
            let commands = node.commandsReceived
            if let firstRequest = commands.firstIndex(of: "getdata") {
                let filterLoaded = try #require(commands.firstIndex(of: "filterload"))
                #expect(filterLoaded < firstRequest, "\(node.host): \(commands)")
            }
        }
        await sync.stop()
    }

    @Test("After the filter changes, a block is not taken from what the old filter found in it")
    func staleAnswersAreNotTakenForTheNewFilter() async throws {
        let headers = Self.chain(paying: [3])
        // The node answers nothing by itself: the test plays its part, so
        // that the order of things is the test's to choose.
        var script = SyncFixture.testnetNode(height: 6)
        script.answersPing = false
        let recorder = NodeRecorder(script: script)
        let events = SyncEventLog()
        let (sync, peerManager) = try await SyncFixture.fabricated(headers, recorder: recorder, delegate: events)
        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })
        let node = try #require(recorder.node(for: "a.test"))

        // A filter that does not hold the wallet's key; all six blocks are
        // asked for.
        await sync.configureBloomFilter(elements: Self.otherKeys, tweak: 0, startHeight: 1)
        #expect(await eventually { node.filteredBlocksRequested.count == 6 })

        // The wallet's key is added and the scan starts over — while the
        // node's answers to the first round are still on their way.
        await sync.configureBloomFilter(elements: Self.otherKeys + [Self.walletKey], tweak: 0, startHeight: 1)
        #expect(await eventually { node.payloads(of: "filterload").count == 2 })
        #expect(await eventually { !node.payloads(of: "ping").isEmpty })

        // They arrive: under the old filter, block 3 held nothing.
        for header in headers {
            let stale = FabricatedChain.merkleBlock(for: header, matched: false)
            await node.send(stale.command, stale.payload)
        }
        try await Task.sleep(for: .milliseconds(150))

        // None of it counted, and the blocks have not been asked for again:
        // the node has yet to show it is past its old answers.
        #expect(events.scanHeights.isEmpty)
        #expect(node.filteredBlocksRequested.count == 6)

        // It answers its pings — the one that followed the new filter
        // among them. Now they are.
        for ping in node.payloads(of: "ping") {
            await node.send("pong", ping)
        }
        #expect(await eventually { node.filteredBlocksRequested.count == 12 })
        for (offset, header) in headers.enumerated() {
            let fresh = FabricatedChain.merkleBlock(for: header, matched: offset == 2)
            await node.send(fresh.command, fresh.payload)
            if offset == 2 {
                await node.send(Self.transactionMessage.command, Self.transactionMessage.payload)
            }
        }

        #expect(await eventually { events.scanHeights.last == 6 })
        #expect(events.transactionEvents == [.confirmed(blockHash: headers[2].hash, height: 3)])
        await sync.stop()
    }

    // MARK: - What a block must bring before it counts

    @Test("The scan does not pass a block whose transaction has not arrived")
    func scanWaitsForTheTransaction() async throws {
        let headers = Self.chain(paying: [3])
        let recorder = NodeRecorder(scripts: [
            // Names the transaction in block 3's proof, and never sends it.
            "a.test": Self.servingNode(headers, matching: [3], sendsTransactions: false),
            "b.test": Self.servingNode(headers, matching: [3]),
        ])
        let events = SyncEventLog()
        let (sync, peerManager) = try await SyncFixture.fabricated(
            headers, recorder: recorder, delegate: events, timing: testTiming(filteredBlock: .milliseconds(300))
        )

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })
        await sync.configureBloomFilter(elements: [Self.walletKey], startHeight: 1)

        // Blocks 4 to 6 have arrived whole. Block 3 has not: a wallet that
        // resumed above it would never see its payment.
        #expect(await eventually { events.scanHeights.last == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(events.scanHeights.max() == 2)
        #expect(events.transactionEvents.isEmpty)

        // The peer that owes the transaction times out; the next one
        // delivers it, and only then does the scan move on.
        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { events.scanHeights.last == 6 })

        // The payment is reported before any height at or above its block.
        let payment = SyncEventLog.TransactionEvent.confirmed(blockHash: headers[2].hash, height: 3)
        #expect(events.transactionEvents == [payment])
        #expect(events.milestones == [.scanned(through: 2), .transaction(payment), .scanned(through: 6)])
        await sync.stop()
    }

    @Test("A transaction the filter let through by accident is not reported as the wallet's")
    func falsePositiveIsNotReported() async throws {
        let headers = Self.chain(paying: [2])
        let recorder = NodeRecorder(script: Self.servingNode(headers, matching: [2]))
        let events = SyncEventLog()
        let (sync, peerManager) = try await SyncFixture.fabricated(headers, recorder: recorder, delegate: events)

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })

        // The wallet watches other keys. The node sends the transaction
        // all the same, as it would for a false positive of its filter.
        await sync.configureBloomFilter(elements: Self.otherKeys, tweak: 0, startHeight: 1)
        #expect(await eventually { events.scanHeights.last == 6 })

        #expect(events.transactionEvents.isEmpty)
        #expect(await sync.filteredBlocksInFlightCount == 0)
        #expect(await peerManager.connectedPeerCount == 1)
        await sync.stop()
    }

    @Test("A transaction that spends an output found paying the wallet is the wallet's too")
    func spendOfAFoundOutputIsRelevant() async throws {
        // Spends output 0 of the wallet's transaction to a key nobody watches.
        var spend = Data([0x01, 0x00, 0x00, 0x00, 0x01])
        spend.append(Self.txid)
        spend.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x01])
        spend.append(contentsOf: [0x00, 0xe1, 0xf5, 0x05, 0x00, 0x00, 0x00, 0x00, 0x19, 0x76, 0xa9, 0x14])
        spend.append(Data(repeating: 0x99, count: 20))
        spend.append(contentsOf: [0x88, 0xac, 0x00, 0x00, 0x00, 0x00])
        let spendID = MerkleTree.doubleSHA256(spend)

        for (flags, expected) in [(UInt8(1), 2), (UInt8(0), 1)] {
            var script = SyncFixture.testnetNode(height: 6)
            script.transactions = [Self.txid: Self.transaction, spendID: spend]
            let recorder = NodeRecorder(script: script)
            let events = SyncEventLog()
            let (sync, peerManager) = try await SyncFixture.fabricated(Self.chain(), recorder: recorder, delegate: events)
            await peerManager.addPeer(host: "a.test")
            #expect(await eventually { await sync.state == .synchronized })
            await sync.configureBloomFilter(elements: [Self.walletKey], flags: flags, startHeight: 7)

            // Flag 1 asks peers to add what matches to their filter; the
            // wallet does the same with its own list. Flag 0 asks for nothing.
            let node = try #require(recorder.node(for: "a.test"))
            await node.send("inv", SyncFixture.transactionAnnouncement(Self.txid))
            #expect(await eventually { events.transactionEvents == [.unconfirmed] })
            await node.send("inv", SyncFixture.transactionAnnouncement(spendID))
            #expect(await eventually { node.transactionsRequested == [Self.txid, spendID] })
            try await Task.sleep(for: .milliseconds(100))

            #expect(events.transactionEvents.count == expected, "flags \(flags)")
            await sync.stop()
        }
    }

    // MARK: - Reporting how far the scan has got

    @Test("The scan height follows the blocks scanned, in order, and steps back when the chain is reorganized")
    func scanHeightFollowsTheChain() async throws {
        let a1 = ReorgFixtures.a1
        let b1 = ReorgFixtures.b1
        let b2 = ReorgFixtures.b2

        var script = NodeScript()
        script.magic = NetworkConstants.testnetMagic
        script.startHeight = 1
        script.headersReply = ReorgFixtures.headersPayload([a1])
        script.filteredBlocks = [
            a1.hash: [FabricatedChain.merkleBlock(for: a1, matched: true), Self.transactionMessage],
            b1.hash: [FabricatedChain.merkleBlock(for: b1, matched: true)],
            b2.hash: [FabricatedChain.merkleBlock(for: b2, matched: false)],
        ]
        let recorder = NodeRecorder(script: script)
        let events = SyncEventLog()
        let (sync, peerManager) = await SyncFixture.testnet(recorder, delegate: events)

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.currentHeight == 1 })
        await sync.configureBloomFilter(elements: [Self.walletKey], startHeight: 1)
        #expect(await eventually { events.scanHeights.last == 1 })

        let node = try #require(recorder.node(for: "a.test"))
        await node.send("headers", ReorgFixtures.headersPayload([b1, b2]))
        #expect(await eventually { events.scanHeights.last == 2 })

        // Each height is reported after the transactions found up to it —
        // and the reorganization takes the scan back below the fork before
        // it climbs the new branch.
        #expect(events.milestones == [
            .transaction(.confirmed(blockHash: a1.hash, height: 1)),
            .scanned(through: 1),
            .transaction(.reorged(previousBlockHash: a1.hash, previousHeight: 1)),
            .scanned(through: 0),
            .transaction(.confirmed(blockHash: b1.hash, height: 1)),
            .scanned(through: 2),
        ])
        await sync.stop()
    }

    @Test("A scan that starts above the chain's tip waits there, and says nothing below it needs scanning")
    func scanStartingAboveTheTip() async throws {
        let recorder = NodeRecorder(script: SyncFixture.testnetNode(height: 6))
        let events = SyncEventLog()
        let (sync, peerManager) = try await SyncFixture.fabricated(Self.chain(), recorder: recorder, delegate: events)
        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })

        await sync.configureBloomFilter(elements: [Self.walletKey], startHeight: 7)

        #expect(await eventually { events.scanHeights.last == 6 })
        #expect(events.scanHeights == [6])
        #expect(recorder.node(for: "a.test")?.filteredBlocksRequested.isEmpty == true)
        await sync.stop()
    }

    // MARK: - What is asked for, and of whom

    @Test("By default the filter asks peers to add what matches, so spends of it match too")
    func defaultFilterFlags() async throws {
        let recorder = NodeRecorder(script: SyncFixture.testnetNode(height: 6))
        let (sync, peerManager) = try await SyncFixture.fabricated(Self.chain(), recorder: recorder)
        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })

        await sync.configureBloomFilter(elements: [Self.walletKey], startHeight: 7)

        let node = try #require(recorder.node(for: "a.test"))
        #expect(await eventually { !node.payloads(of: "filterload").isEmpty })
        // The update flags are the message's last byte: 1 is BLOOM_UPDATE_ALL.
        #expect(node.payloads(of: "filterload").last?.last == 1)
        await sync.stop()
    }

    @Test("A transaction two peers announce is asked of the first only, even before it has arrived")
    func announcedTransactionIsRequestedOnce() async throws {
        // Neither node answers a request for a transaction, either way.
        var script = SyncFixture.testnetNode(height: 6)
        script.deniesUnknownTransactions = false
        let recorder = NodeRecorder(script: script)
        let (sync, peerManager) = try await SyncFixture.fabricated(Self.chain(), recorder: recorder)
        await peerManager.addPeer(host: "a.test")
        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { await peerManager.connectedPeerCount == 2 })
        await sync.configureBloomFilter(elements: [Self.walletKey], startHeight: 7)
        let nodeA = try #require(recorder.node(for: "a.test"))
        let nodeB = try #require(recorder.node(for: "b.test"))

        let announcement = SyncFixture.transactionAnnouncement(Self.txid)
        await nodeA.send("inv", announcement)
        #expect(await eventually { nodeA.transactionsRequested == [Self.txid] })
        await nodeB.send("inv", announcement)
        await nodeA.send("inv", announcement)
        try await Task.sleep(for: .milliseconds(150))

        #expect(nodeA.transactionsRequested == [Self.txid])
        #expect(nodeB.transactionsRequested.isEmpty)
        await sync.stop()
    }

    @Test("A transaction a peer turns out not to have may be asked of another")
    func transactionNotFoundIsRequestedAgain() async throws {
        var lacking = SyncFixture.testnetNode(height: 6)
        lacking.deniesUnknownTransactions = true
        var holding = lacking
        holding.transactions = [Self.txid: Self.transaction]
        let recorder = NodeRecorder(scripts: ["a.test": lacking, "b.test": holding])
        let events = SyncEventLog()
        let (sync, peerManager) = try await SyncFixture.fabricated(Self.chain(), recorder: recorder, delegate: events)
        await peerManager.addPeer(host: "a.test")
        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { await peerManager.connectedPeerCount == 2 })
        await sync.configureBloomFilter(elements: [Self.walletKey], startHeight: 7)
        let nodeA = try #require(recorder.node(for: "a.test"))
        let nodeB = try #require(recorder.node(for: "b.test"))

        let announcement = SyncFixture.transactionAnnouncement(Self.txid)
        await nodeA.send("inv", announcement)
        #expect(await eventually { nodeA.transactionsRequested == [Self.txid] })
        // Its `notfound` has been handled once the next message is.
        await nodeA.send("ping", PingMessage().serialize())
        #expect(await eventually { nodeA.commandsReceived.contains("pong") })

        await nodeB.send("inv", announcement)
        #expect(await eventually { events.transactionEvents == [.unconfirmed] })
        #expect(nodeB.transactionsRequested == [Self.txid])
        await sync.stop()
    }

    @Test("An announced block is fetched by the scan, once, whoever announces it")
    func announcedBlockIsFetchedOnce() async throws {
        let newEntries = RealChainFixtures.parsedEntries()
        let newBlock = try #require(newEntries.first).header.hash
        // The first is asked for headers when it connects, and has none
        // then. Whichever is asked after the announcement has the new ones.
        var first = NodeScript(startHeight: SyncFixture.tipHeight)
        first.headersReplies = [SyncFixture.noHeaders, RealChainFixtures.headersPayload(), SyncFixture.noHeaders]
        var second = first
        second.headersReplies = [RealChainFixtures.headersPayload(), SyncFixture.noHeaders]
        let recorder = NodeRecorder(scripts: ["a.test": first, "b.test": second])
        let events = SyncEventLog()
        let (sync, peerManager) = try await SyncFixture.mainnet(recorder, delegate: events)

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })
        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { await peerManager.connectedPeerCount == 2 })
        await sync.configureBloomFilter(elements: Self.otherKeys, tweak: 0, startHeight: SyncFixture.tipHeight + 1)
        let nodes = recorder.all

        // Both announce the new block.
        for node in nodes {
            await node.send("inv", SyncFixture.blockAnnouncement(newBlock))
        }
        #expect(await eventually { await sync.currentHeight == SyncFixture.extendedHeight })
        #expect(await eventually { nodes.flatMap(\.filteredBlocksRequested).count == 3 })
        try await Task.sleep(for: .milliseconds(150))

        // Its header was fetched, and then the scan asked one peer for it
        // and the two blocks after it — not each announcer, and not twice.
        let requested = nodes.flatMap(\.filteredBlocksRequested)
        #expect(requested.sorted { $0.hexString < $1.hexString } == newEntries.map(\.header.hash).sorted { $0.hexString < $1.hexString })
        #expect(nodes.count { !$0.filteredBlocksRequested.isEmpty } == 1)
        await sync.stop()
    }

    // MARK: - Sent transactions

    @Test("A sent transaction is offered again and again, to new peers too, until a block confirms it")
    func sentTransactionIsOfferedUntilConfirmed() async throws {
        let headers = Self.chain(paying: [6])
        // The node names the transaction in block 6's proof without sending
        // it: it has seen the wallet offer it.
        let recorder = NodeRecorder(script: Self.servingNode(headers, matching: [6], sendsTransactions: false))
        let events = SyncEventLog()
        let (sync, peerManager) = try await SyncFixture.fabricated(
            headers, recorder: recorder, delegate: events, timing: testTiming(reannouncement: .milliseconds(100))
        )
        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })
        let nodeA = try #require(recorder.node(for: "a.test"))
        let offer = SyncFixture.transactionAnnouncement(Self.txid)

        try await sync.announceUntilConfirmed(Self.transaction.hexString)
        #expect(await eventually { nodeA.payloads(of: "inv").count >= 3 })
        #expect(nodeA.payloads(of: "inv").allSatisfy { $0 == offer })

        // A peer that connects now hears of it at once.
        await peerManager.addPeer(host: "b.test")
        let nodeB = try #require(await eventually { recorder.node(for: "b.test") != nil } ? recorder.node(for: "b.test") : nil)
        #expect(await eventually { nodeB.payloads(of: "inv").first == offer })

        // The scan reaches the block that holds it.
        await sync.configureBloomFilter(elements: [Self.walletKey], startHeight: 1)
        let confirmed = SyncEventLog.TransactionEvent.confirmed(blockHash: headers[5].hash, height: 6)
        #expect(await eventually { events.transactionEvents == [confirmed] })

        // And with that the offers end.
        try await Task.sleep(for: .milliseconds(150))
        let offered = nodeA.payloads(of: "inv").count
        try await Task.sleep(for: .milliseconds(300))
        #expect(nodeA.payloads(of: "inv").count == offered)
        await sync.stop()
    }

    @Test("Something that is not a transaction is not offered")
    func malformedTransactionIsNotOffered() async throws {
        let recorder = NodeRecorder(script: SyncFixture.testnetNode(height: 6))
        let (sync, peerManager) = try await SyncFixture.fabricated(Self.chain(), recorder: recorder)
        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })

        for rawHex in ["", "zz", "0100", Self.transaction.hexString + "00"] {
            await #expect(throws: DogecoinError.internalError("Invalid transaction hex")) {
                try await sync.announceUntilConfirmed(rawHex)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.node(for: "a.test")?.payloads(of: "inv").isEmpty == true)
        await sync.stop()
    }
}
