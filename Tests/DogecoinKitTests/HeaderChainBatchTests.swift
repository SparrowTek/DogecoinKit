import Foundation
import Testing
@testable import DogecoinKit

/// Headers arrive two thousand to a message. They are checked in memory and
/// written together — and the result must be exactly what adding them one
/// at a time gives.
@Suite("Header Chain Batches")
struct HeaderChainBatchTests {

    /// Headers flagged as merge-mined: below testnet's last checkpoint a
    /// chain takes those on trust, so none has to be mined.
    private static func entries(_ count: Int, branch: UInt32 = 0) -> [HeadersMessage.Entry] {
        FabricatedChain.headers(count: count, version: 0x100, branch: branch).map { HeadersMessage.Entry(header: $0) }
    }

    private func openChain(at directory: URL = TestDirectories.unique()) async throws -> HeaderChain {
        let chain = HeaderChain(network: .testnet, storageDirectory: directory)
        try await chain.setup()
        return chain
    }

    /// The best-chain block at each height from 1 through `height`, read
    /// from the file by a connection of its own.
    private func bestChain(in directory: URL, through height: Int32) throws -> [Data?] {
        let database = try HeaderDatabase(readOnlyPath: directory.appendingPathComponent("headers.sqlite").path)
        return try (1...height).map { try database.getHeader(height: $0)?.hash }
    }

    @Test("A chain added in batches is the chain added one header at a time")
    func batchesMatchSingleHeaders() async throws {
        let entries = Self.entries(2500)
        let directory = TestDirectories.unique()
        let batched = try await openChain(at: directory)
        let single = try await openChain()

        let first = await batched.addHeaders(Array(entries.prefix(2000)))
        let second = await batched.addHeaders(Array(entries.dropFirst(2000)))
        for entry in entries {
            try await single.addHeaderValidated(entry.header)
        }

        #expect(first.added == 2000 && first.failure == nil && first.forkHeight == nil)
        #expect(second.added == 500 && second.failure == nil)
        #expect(await batched.height == 2500)
        #expect(await batched.tip?.header.hash == entries.last?.header.hash)
        #expect(await batched.tip?.chainWork == single.tip?.chainWork)

        for height: Int32 in [1, 2, 11, 12, 1234, 1999, 2000, 2001, 2500] {
            let stored = try #require(try await batched.getHeader(height: height))
            #expect(stored.header == entries[Int(height) - 1].header)
            #expect(stored.chainWork == (try await single.getHeader(height: height))?.chainWork)
            #expect(try await batched.isHeaderInBestChain(stored.header.hash))
        }
        #expect(try await batched.getHeader(height: 2501) == nil)

        // And it is all on disk: a chain opened on the same file finds it.
        let reopened = try await openChain(at: directory)
        #expect(await reopened.height == 2500)
        #expect(await reopened.tip?.header.hash == entries.last?.header.hash)
        #expect(try bestChain(in: directory, through: 2500) == entries.map(\.header.hash))
    }

    @Test("Headers the chain already has are not counted or stored again")
    func knownHeadersAreSkipped() async throws {
        let entries = Self.entries(30)
        let chain = try await openChain()

        #expect(await chain.addHeaders(Array(entries.prefix(20))).added == 20)
        // Overlaps what is there, then goes on.
        let overlapping = await chain.addHeaders(Array(entries.dropFirst(10)))

        #expect(overlapping.added == 10)
        #expect(overlapping.failure == nil)
        #expect(await chain.height == 30)
        #expect(await chain.addHeaders(entries).added == 0)
    }

    @Test("A header that fails mid-batch stops it there, and what came before is kept")
    func failureMidBatch() async throws {
        var entries = Self.entries(10)
        // The sixth claims a time no later than the blocks before it.
        let sixth = entries[5].header
        entries[5] = HeadersMessage.Entry(header: BlockHeader(
            version: sixth.version,
            prevBlock: sixth.prevBlock,
            merkleRoot: sixth.merkleRoot,
            timestamp: FabricatedChain.genesisTimestamp,
            bits: sixth.bits,
            nonce: sixth.nonce
        ))
        let directory = TestDirectories.unique()
        let chain = try await openChain(at: directory)

        let result = await chain.addHeaders(entries)

        #expect(result.added == 5)
        guard case .invalidTimestamp = result.failure else {
            Issue.record("Expected an invalid timestamp, got \(String(describing: result.failure))")
            return
        }
        #expect(await chain.height == 5)
        #expect(await chain.tip?.header.hash == entries[4].header.hash)
        #expect(try await openChain(at: directory).height == 5)

        // The good headers after it never connected, so they are unknown.
        #expect(try await chain.getHeader(hash: entries[6].header.hash) == nil)
    }

    @Test("A side branch that arrives mid-batch is stored without disturbing the batch around it")
    func sideBranchInsideABatch() async throws {
        let main = Self.entries(8)
        let side = Self.entries(3, branch: 7)
        let chain = try await openChain()

        // Three of the main chain, three of a branch from genesis, five more.
        let result = await chain.addHeaders(Array(main.prefix(3)) + side + Array(main.dropFirst(3)))

        #expect(result.added == 11)
        #expect(result.failure == nil)
        #expect(result.forkHeight == nil)
        #expect(await chain.height == 8)
        #expect(await chain.tip?.header.hash == main.last?.header.hash)
        for entry in side {
            #expect(try await chain.getHeader(hash: entry.header.hash) != nil)
            #expect(try await !chain.isHeaderInBestChain(entry.header.hash))
        }
    }

    @Test("A branch that overtakes mid-batch replaces the best chain, and reports where it forked")
    func reorganizationInsideABatch() async throws {
        let main = Self.entries(3)
        let side = Self.entries(5, branch: 7)
        let directory = TestDirectories.unique()
        let chain = try await openChain(at: directory)

        let result = await chain.addHeaders(main + side)

        #expect(result.added == 8)
        #expect(result.failure == nil)
        #expect(result.forkHeight == 0)
        #expect(await chain.height == 5)
        #expect(try bestChain(in: directory, through: 5) == side.map(\.header.hash))
    }

    // MARK: - Two connections to one file

    @Test("Two chains on one file never leave two best blocks at a height")
    func twoChainsOnOneFile() async throws {
        let directory = TestDirectories.unique()
        let first = try await openChain(at: directory)
        let second = try await openChain(at: directory)
        let branchA = Self.entries(6, branch: 1)
        let branchB = Self.entries(6, branch: 2)

        // The first extends the chain; the second still believes it ends
        // at the genesis block.
        #expect(await first.addHeaders(Array(branchA.prefix(5))).added == 5)
        let behind = await second.addHeaders(Array(branchB.prefix(3)))

        // It found out, looked again, and stored its headers as the side
        // branch they are.
        #expect(behind.added == 3)
        #expect(behind.failure == nil)
        #expect(behind.forkHeight == nil)
        #expect(await second.height == 5)
        #expect(try bestChain(in: directory, through: 5) == branchA.prefix(5).map(\.header.hash))

        // Its branch then grows past the other's: a reorganization the
        // first chain knows nothing of.
        let overtaking = await second.addHeaders(Array(branchB.dropFirst(3)))
        #expect(overtaking.forkHeight == 0)
        #expect(await second.height == 6)

        // The first adds to what it thinks is the tip.
        let stale = await first.addHeaders([branchA[5]])
        #expect(stale.added == 1)
        #expect(stale.failure == nil)
        #expect(await first.height == 6)
        #expect(await first.tip?.header.hash == branchB[5].header.hash)

        // One block at every height, all of the branch that won.
        #expect(try bestChain(in: directory, through: 6) == branchB.map(\.header.hash))
        let database = try HeaderDatabase(readOnlyPath: directory.appendingPathComponent("headers.sqlite").path)
        #expect(try database.getHeaderCount() == 13)
        #expect(try database.getHeader(hash: branchA[5].header.hash)?.isInBestChain == false)
    }

    // MARK: - A chain that is not open

    @Test("A chain whose database cannot be opened says so, wherever it is asked")
    func unopenedChainThrows() async throws {
        let blocked = TestDirectories.unique()
        try FileManager.default.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blocked)
        let chain = HeaderChain(network: .testnet, storageDirectory: blocked)

        await #expect(throws: (any Error).self) {
            try await chain.setup()
        }
        #expect(await !chain.isOpen)
        #expect(await chain.height == -1)

        // Absent and unreadable are different answers.
        await #expect(throws: HeaderDatabaseError.databaseNotOpen) {
            _ = try await chain.getHeader(height: 0)
        }
        await #expect(throws: HeaderDatabaseError.databaseNotOpen) {
            _ = try await chain.getHeader(hash: FabricatedChain.genesisHash)
        }
        await #expect(throws: HeaderDatabaseError.databaseNotOpen) {
            _ = try await chain.isHeaderInBestChain(FabricatedChain.genesisHash)
        }
        await #expect(throws: HeaderDatabaseError.databaseNotOpen) {
            _ = try await chain.getBlockLocator()
        }
        let result = await chain.addHeaders(Self.entries(1))
        #expect(result.added == 0)
        guard case .databaseError = result.failure else {
            Issue.record("Expected a database error, got \(String(describing: result.failure))")
            return
        }

        // Setting up again, once it can work, does.
        try FileManager.default.removeItem(at: blocked)
        try await chain.setup()
        #expect(await chain.isOpen)
        #expect(try await chain.getHeader(height: 0)?.header.hash == FabricatedChain.genesisHash)
        #expect(await chain.addHeaders(Self.entries(4)).added == 4)
    }

    @Test("Opening a chain corrects best-chain flags that disagree with its tip")
    func setupRepairsFlags() async throws {
        let entries = Self.entries(12)
        let directory = TestDirectories.unique()
        do {
            let chain = try await openChain(at: directory)
            #expect(await chain.addHeaders(entries).added == 12)
        }

        // Block 9 loses its flag, as an interrupted write could leave it.
        do {
            let database = try HeaderDatabase(path: directory.appendingPathComponent("headers.sqlite").path)
            try database.executeWithoutTransaction("UPDATE headers SET isInBestChain = 0 WHERE height = 9")
            #expect(try database.getHeader(height: 9) == nil)
        }

        let reopened = try await openChain(at: directory)

        #expect(try await reopened.getHeader(height: 9)?.header.hash == entries[8].header.hash)
        #expect(await reopened.height == 12)
        #expect(try bestChain(in: directory, through: 12) == entries.map(\.header.hash))
    }
}
