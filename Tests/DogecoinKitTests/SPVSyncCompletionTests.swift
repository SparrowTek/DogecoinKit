import Foundation
import Testing
@testable import DogecoinKit

/// When a header sync calls the chain complete, how high it aims, and how
/// long it stays with a peer that is slow to get it there.
@Suite("SPV Sync Completion", .timeLimit(.minutes(1)))
struct SPVSyncCompletionTests {

    /// A node at the fixture chain's tip with nothing to add.
    private static let atTip = NodeScript(startHeight: SyncFixture.tipHeight, headersReply: SyncFixture.noHeaders)

    /// One real header as the payload of a `headers` message.
    private static func headersPayload(entry index: Int) -> Data {
        var payload = VarInt(1).serialize()
        payload.append(Data(hexString: RealChainFixtures.mergeMinedEntries[index]) ?? Data())
        payload.append(0)
        return payload
    }

    // MARK: - Completion

    @Test("With one peer connected, the chain is not called complete until others have had time to disagree")
    func lonePeerCompletionWaits() async throws {
        let recorder = NodeRecorder(script: Self.atTip)
        let events = SyncEventLog()
        let (sync, peerManager) = try await SyncFixture.mainnet(
            recorder, delegate: events, timing: testTiming(loneCompletion: .milliseconds(500))
        )

        await peerManager.addPeer(host: "a.test")
        let node = try #require(await eventually { recorder.node(for: "a.test") != nil } ? recorder.node(for: "a.test") : nil)
        #expect(await eventually { node.payloads(of: "getheaders").count == 1 })

        // The one peer has said there is nothing new. It may be the one
        // that lags.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await sync.state != .synchronized)
        #expect(events.completionCount == 0)

        // Nobody else turned up: its word is taken after all.
        #expect(await eventually { await sync.state == .synchronized })
        #expect(await eventually { events.completionCount == 1 })
        await sync.stop()
    }

    @Test("A second peer with nothing to add settles it at once")
    func secondPeerSettlesCompletion() async throws {
        let recorder = NodeRecorder(script: Self.atTip)
        let events = SyncEventLog()
        let (sync, peerManager) = try await SyncFixture.mainnet(
            recorder, delegate: events, timing: testTiming(loneCompletion: .seconds(60))
        )

        await peerManager.addPeer(host: "a.test")
        let nodeA = try #require(await eventually { recorder.node(for: "a.test") != nil } ? recorder.node(for: "a.test") : nil)
        #expect(await eventually { nodeA.payloads(of: "getheaders").count == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await sync.state != .synchronized)

        await peerManager.addPeer(host: "b.test")

        #expect(await eventually { await sync.state == .synchronized })
        #expect(await eventually { events.completionCount == 1 })
        // It announced no more than the chain has: there was nothing to ask it.
        #expect(recorder.node(for: "b.test")?.payloads(of: "getheaders").isEmpty == true)
        await sync.stop()
    }

    @Test("One lagging peer does not get to call the chain complete when another knows more")
    func laggingPeerDoesNotComplete() async throws {
        let recorder = NodeRecorder(scripts: [
            "a.test": Self.atTip,
            "b.test": NodeScript(startHeight: SyncFixture.extendedHeight, headersReply: RealChainFixtures.headersPayload()),
        ])
        let events = SyncEventLog()
        let (sync, peerManager) = try await SyncFixture.mainnet(
            recorder, delegate: events, timing: testTiming(loneCompletion: .seconds(60))
        )

        await peerManager.addPeer(host: "a.test")
        let nodeA = try #require(await eventually { recorder.node(for: "a.test") != nil } ? recorder.node(for: "a.test") : nil)
        #expect(await eventually { nodeA.payloads(of: "getheaders").count == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(events.completionCount == 0)

        await peerManager.addPeer(host: "b.test")

        // Completion is reported once — at the height the second peer
        // brought the chain to, not the one the first stopped at.
        #expect(await eventually { events.completionCount == 1 })
        #expect(await sync.currentHeight == SyncFixture.extendedHeight)
        try await Task.sleep(for: .milliseconds(100))
        #expect(events.completionCount == 1)
        await sync.stop()
    }

    // MARK: - Target

    @Test("The target is never below what the chain has reached")
    func targetFollowsTheChain() async throws {
        let recorder = NodeRecorder(scripts: [
            // Announces a height the chain is already past.
            "a.test": NodeScript(startHeight: SyncFixture.tipHeight - 500, headersReply: SyncFixture.noHeaders),
            "b.test": NodeScript(startHeight: SyncFixture.tipHeight - 500, headersReply: RealChainFixtures.headersPayload()),
        ])
        let (sync, peerManager) = try await SyncFixture.mainnet(recorder)

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.state == .synchronized })
        #expect(await sync.targetHeight == SyncFixture.tipHeight)

        // Blocks arrive that no peer had when it connected.
        await peerManager.addPeer(host: "b.test")
        #expect(await eventually { await peerManager.connectedPeerCount == 2 })
        let newBlock = try #require(RealChainFixtures.parsedEntries().first).header.hash
        await recorder.node(for: "b.test")?.send("inv", SyncFixture.blockAnnouncement(newBlock))

        #expect(await eventually { await sync.currentHeight == SyncFixture.extendedHeight })
        #expect(await eventually { await sync.targetHeight == SyncFixture.extendedHeight })
        await sync.stop()
    }

    // MARK: - Peers that hold the sync back

    @Test("A peer that hands over less than a full message, short of the target, is not asked again at once")
    func shortReplyIsNotChased() async throws {
        // Claims a chain a thousand blocks longer, then deals its headers
        // out one at a time.
        var script = NodeScript(startHeight: SyncFixture.tipHeight + 1000)
        script.headersReplies = (0..<3).map(Self.headersPayload(entry:))
        let recorder = NodeRecorder(script: script)
        // Checked at the pace a real sync is, so that a second request
        // within this test can only be an immediate one.
        let (sync, peerManager) = try await SyncFixture.mainnet(recorder, timing: testTiming(check: .seconds(5)))

        await peerManager.addPeer(host: "a.test")
        #expect(await eventually { await sync.currentHeight == SyncFixture.tipHeight + 1 })
        try await Task.sleep(for: .milliseconds(250))

        // A message that is not full is all a peer has. Asking again and
        // again would let it keep the sync waiting a header at a time.
        #expect(recorder.node(for: "a.test")?.payloads(of: "getheaders").count == 1)
        #expect(await sync.currentHeight == SyncFixture.tipHeight + 1)
        #expect(await sync.state != .synchronized)
        await sync.stop()
    }

    @Test("A peer that is slow with message after message is left for another, when there is one")
    func slowPeerIsLeft() async throws {
        let headers = FabricatedChain.headers(count: 2000)
        // Sends a full message each time — headers the chain already has,
        // which is no offense — and takes its time over every one.
        var slow = SyncFixture.testnetNode(height: 50_000)
        slow.headersReply = ReorgFixtures.headersPayload(headers)
        slow.headersReplyDelay = .milliseconds(80)
        // The other never answers at all.
        var silent = SyncFixture.testnetNode(height: 50_000)
        silent.headersReply = nil

        let recorder = NodeRecorder(scripts: ["a.test": slow, "b.test": silent])
        let (sync, peerManager) = try await SyncFixture.fabricated(
            headers, recorder: recorder, timing: testTiming(slowHeaderReply: .milliseconds(30))
        )

        await peerManager.addPeer(host: "a.test")
        let nodeA = try #require(await eventually { recorder.node(for: "a.test") != nil } ? recorder.node(for: "a.test") : nil)
        #expect(await eventually { !nodeA.payloads(of: "getheaders").isEmpty })
        await peerManager.addPeer(host: "b.test")

        // Three slow answers in a row, and the sync turns to the other peer.
        let nodeB = try #require(await eventually { recorder.node(for: "b.test") != nil } ? recorder.node(for: "b.test") : nil)
        #expect(await eventually { !nodeB.payloads(of: "getheaders").isEmpty })
        #expect(nodeA.payloads(of: "getheaders").count == 3)
        // Slow is not wrong: nobody was dropped for it.
        #expect(await peerManager.connectedPeerCount == 2)
        await sync.stop()
    }

    @Test("A slow peer that is the only one is kept")
    func slowPeerAloneIsKept() async throws {
        let headers = FabricatedChain.headers(count: 2000)
        var slow = SyncFixture.testnetNode(height: 50_000)
        slow.headersReply = ReorgFixtures.headersPayload(headers)
        slow.headersReplyDelay = .milliseconds(60)

        let recorder = NodeRecorder(script: slow)
        // Checked at the pace a real sync is: were the peer given up on, it
        // would not be asked again within this test.
        let (sync, peerManager) = try await SyncFixture.fabricated(
            headers, recorder: recorder, timing: testTiming(check: .seconds(5), slowHeaderReply: .milliseconds(20))
        )

        await peerManager.addPeer(host: "a.test")
        let node = try #require(await eventually { recorder.node(for: "a.test") != nil } ? recorder.node(for: "a.test") : nil)

        // Slow headers are better than none.
        #expect(await eventually { node.payloads(of: "getheaders").count >= 6 })
        #expect(await peerManager.connectedPeerCount == 1)
        await sync.stop()
    }

    // MARK: - A chain that cannot be stored

    @Test("A sync whose header database cannot be opened fails, says so, and can be started again")
    func unopenableDatabaseFailsTheSync() async throws {
        // A file where the storage directory should be.
        let blocked = TestDirectories.unique()
        try FileManager.default.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blocked)

        let recorder = NodeRecorder(script: Self.atTip)
        let peerManager = makePeerManager(recorder)
        let chain = HeaderChain(network: .mainnet, storageDirectory: blocked)
        let sync = SPVSyncManager(network: .mainnet, peerManager: peerManager, headerChain: chain, timing: testTiming())
        let events = SyncEventLog()
        await sync.setDelegate(events)

        await sync.start()

        #expect(await sync.state == .error(HeaderDatabaseError.databaseNotOpen))
        #expect(await eventually { events.failureCount == 1 })
        #expect(await !chain.isOpen)
        #expect(await sync.currentHeight == -1)

        // With the obstacle gone, starting again works.
        try FileManager.default.removeItem(at: blocked)
        await sync.start()
        #expect(await sync.state == .connecting)
        #expect(await sync.currentHeight == 0)
        #expect(events.failureCount == 1)
        await sync.stop()
    }

    @Test("Creating a manager on a database that cannot be opened throws")
    func createThrowsForUnopenableDatabase() async throws {
        let blocked = TestDirectories.unique()
        try FileManager.default.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blocked)

        await #expect(throws: (any Error).self) {
            _ = try await SPVSyncManager.create(network: .testnet, storageDirectory: blocked)
        }

        let manager = try await SPVSyncManager.create(network: .testnet, storageDirectory: TestDirectories.unique())
        #expect(await manager.currentHeight == 0)
    }
}
