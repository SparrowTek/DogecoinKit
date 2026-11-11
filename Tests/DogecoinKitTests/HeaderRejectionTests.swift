import Foundation
import Testing
@testable import DogecoinKit

/// What a header chain refuses, checked through the door headers come in by.
@Suite("Header Rejections")
struct HeaderRejectionTests {

    // MARK: - Fixtures

    private func testnetChain() async throws -> (chain: HeaderChain, genesis: StoredHeader) {
        let chain = HeaderChain(network: .testnet, storageDirectory: TestDirectories.unique())
        try await chain.setup()
        return (chain, try #require(try await chain.getHeader(height: 0)))
    }

    /// A header that needs no proof of work of its own: it is flagged as
    /// merge-mined, and below the last checkpoint such a header is taken
    /// without its proof — the checkpoints vouch for the chain there.
    private func header(
        on parent: BlockHeader,
        timestamp: UInt32,
        bits: UInt32 = 0x1e0ffff0,
        version: Int32 = 0x100,
        seed: UInt8 = 1
    ) -> BlockHeader {
        BlockHeader(
            version: version,
            prevBlock: parent.hash,
            merkleRoot: Data(repeating: seed, count: 32),
            timestamp: timestamp,
            bits: bits,
            nonce: 0
        )
    }

    /// A chain whose database holds just `ancestors`, the last of them its tip.
    private func chain(_ network: DogecoinNetwork, holding ancestors: [StoredHeader]) async throws -> HeaderChain {
        let directory = TestDirectories.unique()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try HeaderDatabase(path: directory.appendingPathComponent("headers.sqlite").path)
        try database.insertHeaders(ancestors.map { HeaderRecord(storedHeader: $0, isInBestChain: true) })

        let chain = HeaderChain(network: network, storageDirectory: directory)
        try await chain.setup()
        return chain
    }

    /// The error `header` is refused with, or nil if the chain took it.
    private func rejection(of header: BlockHeader, by chain: HeaderChain) async -> HeaderChain.ValidationError? {
        do {
            try await chain.addHeaderValidated(header)
            return nil
        } catch let error as HeaderChain.ValidationError {
            return error
        } catch {
            Issue.record("Unexpected error \(error)")
            return nil
        }
    }

    // MARK: - Proof of work

    @Test("A header whose hash misses its own target is refused, and one that meets it is taken")
    func proofOfWork() async throws {
        let (chain, _) = try await testnetChain()
        let mined = ReorgFixtures.a1
        let unmined = BlockHeader(
            version: mined.version,
            prevBlock: mined.prevBlock,
            merkleRoot: mined.merkleRoot,
            timestamp: mined.timestamp,
            bits: mined.bits,
            nonce: mined.nonce &+ 1
        )

        guard case .invalidProofOfWork(hash: unmined.hashHex, _) = await rejection(of: unmined, by: chain) else {
            Issue.record("An unmined header was not refused for its proof of work")
            return
        }
        #expect(await chain.height == 0)
        #expect(try await chain.getHeader(hash: unmined.hash) == nil)

        try await chain.addHeaderValidated(mined)
        #expect(await chain.tip?.header.hash == mined.hash)
    }

    @Test("A header that claims a target no block may have is refused", arguments: [
        UInt32(0x207f_ffff),   // easier than the easiest allowed
        0x1e80_0000,           // negative
        0x1e00_0000,           // zero
        0xff00_ffff,           // overflows 256 bits
    ])
    func impossibleTarget(bits: UInt32) async throws {
        let (chain, genesis) = try await testnetChain()
        let claimed = header(on: genesis.header, timestamp: genesis.header.timestamp + 60, bits: bits, version: 1)

        guard case .invalidDifficulty(bits: bits) = await rejection(of: claimed, by: chain) else {
            Issue.record("Bits \(String(bits, radix: 16)) were not refused as a target")
            return
        }
        #expect(await chain.height == 0)
    }

    // MARK: - Difficulty

    @Test("On mainnet a header must carry exactly the difficulty the chain's pace calls for")
    func requiredDifficulty() async throws {
        // Two blocks ten minutes apart where one a minute is the aim: the
        // next block has to be easier to find.
        let parentBits: UInt32 = 0x1b01_cd2d
        let first = BlockHeader(
            version: 0x0062_0104,
            prevBlock: Data(repeating: 0x55, count: 32),
            merkleRoot: Data(repeating: 0x01, count: 32),
            timestamp: 1_500_000_000,
            bits: parentBits,
            nonce: 0
        )
        let parent = header(on: first, timestamp: 1_500_000_600, bits: parentBits, version: 0x0062_0104, seed: 2)
        let chain = try await chain(.mainnet, holding: [
            StoredHeader(header: first, height: 2_100_000, chainWork: Data(repeating: 0x01, count: 32)),
            StoredHeader(header: parent, height: 2_100_001, chainWork: Data(repeating: 0x02, count: 32)),
        ])
        #expect(await chain.height == 2_100_001)

        let unchanged = header(on: parent, timestamp: 1_500_000_660, bits: parentBits, version: 0x0062_0104, seed: 3)
        guard case .incorrectDifficulty(height: 2_100_002, bits: parentBits, let expected) = await rejection(of: unchanged, by: chain) else {
            Issue.record("A header that kept its parent's difficulty was not refused")
            return
        }
        // DigiShield lets the target grow by half at most: 0x01cd2d × 1.5.
        #expect(expected == 0x1b02_b3c3)
        #expect(await chain.height == 2_100_001)

        let adjusted = header(on: parent, timestamp: 1_500_000_660, bits: expected, version: 0x0062_0104, seed: 3)
        try await chain.addHeaderValidated(adjusted)
        #expect(await chain.height == 2_100_002)
    }

    // MARK: - Checkpoints

    @Test("A header at a checkpoint's height that is not the checkpointed block is refused")
    func checkpointMismatch() async throws {
        let parent = BlockHeader(
            version: 0x0062_0104,
            prevBlock: Data(repeating: 0x55, count: 32),
            merkleRoot: Data(repeating: 0x01, count: 32),
            timestamp: 1_500_000_000,
            bits: 0x1b01_cd2d,
            nonce: 0
        )
        let chain = try await chain(.mainnet, holding: [
            StoredHeader(header: parent, height: 2_249_999, chainWork: Data(repeating: 0x01, count: 32)),
        ])
        let impostor = header(on: parent, timestamp: 1_500_000_060, bits: 0x1b01_cd2d, version: 0x0062_0104)

        guard case .checkpointMismatch(height: 2_250_000, let expected, let got) = await rejection(of: impostor, by: chain) else {
            Issue.record("A block that is not the checkpointed one was not refused")
            return
        }
        #expect(expected == "0a87a8d4e40dca52763f93812a288741806380cd569537039ee927045c6bc338")
        #expect(got == impostor.hashHex)
        #expect(await chain.height == 2_249_999)
    }

    // MARK: - Time

    @Test("A header may be up to two hours ahead of this device's clock, and no further")
    func futureTimestamps() async throws {
        let (chain, genesis) = try await testnetChain()
        let now = UInt32(Date().timeIntervalSince1970)

        let tooFar = header(on: genesis.header, timestamp: now + 7_200 + 300)
        guard case .futureTooFar(timestamp: tooFar.timestamp) = await rejection(of: tooFar, by: chain) else {
            Issue.record("A header more than two hours ahead was not refused")
            return
        }
        #expect(await chain.height == 0)

        try await chain.addHeaderValidated(header(on: genesis.header, timestamp: now + 7_200 - 300))
        #expect(await chain.height == 1)
    }

    @Test("A header must be later than the median of the eleven before it, not than its parent")
    func medianTimePast() async throws {
        let (chain, genesis) = try await testnetChain()
        let start = genesis.header.timestamp

        // Eleven blocks, ten seconds apart: the median is the sixth one's time.
        var parent = genesis.header
        for index in 1...11 {
            let next = header(on: parent, timestamp: start + UInt32(index) * 10, seed: UInt8(index))
            try await chain.addHeaderValidated(next)
            parent = next
        }
        let median = start + 60
        #expect(parent.timestamp == start + 110)

        let atMedian = header(on: parent, timestamp: median, seed: 0xA0)
        guard case .invalidTimestamp(timestamp: median) = await rejection(of: atMedian, by: chain) else {
            Issue.record("A header timed at the median was not refused")
            return
        }
        #expect(await chain.height == 11)

        // Earlier than its parent by 49 seconds, and still in order.
        try await chain.addHeaderValidated(header(on: parent, timestamp: median + 1, seed: 0xA1))
        #expect(await chain.height == 12)
    }

    // MARK: - Branches

    @Test("A header whose parent the chain has never seen is refused")
    func unknownParent() async throws {
        let (chain, genesis) = try await testnetChain()
        let stranger = BlockHeader(
            version: 0x100,
            prevBlock: Data(repeating: 0xEE, count: 32),
            merkleRoot: Data(repeating: 0x01, count: 32),
            timestamp: genesis.header.timestamp + 60,
            bits: 0x1e0ffff0,
            nonce: 0
        )

        guard case .invalidPreviousBlock = await rejection(of: stranger, by: chain) else {
            Issue.record("A header without a known parent was not refused")
            return
        }
        #expect(await chain.height == 0)
    }

    @Test("Of two branches with the same work, the one seen first stays the best chain")
    func equalWorkKeepsTheFirst() async throws {
        let (chain, genesis) = try await testnetChain()
        let first = header(on: genesis.header, timestamp: genesis.header.timestamp + 60, seed: 1)
        let second = header(on: genesis.header, timestamp: genesis.header.timestamp + 61, seed: 2)

        try await chain.addHeaderValidated(first)
        try await chain.addHeaderValidated(second)

        #expect(await chain.tip?.header.hash == first.hash)
        #expect(try await chain.isHeaderInBestChain(first.hash))
        #expect(try await !chain.isHeaderInBestChain(second.hash))
        // The other branch is kept: one more block on it would decide.
        #expect(try await chain.getHeader(hash: second.hash)?.height == 1)

        let decider = header(on: second, timestamp: genesis.header.timestamp + 120, seed: 3)
        try await chain.addHeaderValidated(decider)
        #expect(await chain.tip?.header.hash == decider.hash)
        #expect(try await chain.isHeaderInBestChain(second.hash))
        #expect(try await !chain.isHeaderInBestChain(first.hash))
    }
}
