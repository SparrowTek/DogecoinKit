import Testing
import Foundation
@testable import DogecoinKit

@Suite("HeaderDatabase Tests")
struct HeaderDatabaseTests {

    // MARK: - Helper Methods

    private func makeTestRecord(
        height: Int32,
        prevHeight: Int32? = nil,
        isInBestChain: Bool = true
    ) -> HeaderRecord {
        var hash = Data(repeating: 0x00, count: 32)
        var heightBE = height.bigEndian
        withUnsafeMutableBytes(of: &heightBE) { bytes in
            hash.replaceSubrange(0..<4, with: bytes)
        }

        var prevHash = Data(repeating: 0x00, count: 32)
        if let prev = prevHeight {
            var prevBE = prev.bigEndian
            withUnsafeMutableBytes(of: &prevBE) { bytes in
                prevHash.replaceSubrange(0..<4, with: bytes)
            }
        }

        return HeaderRecord(
            hash: hash,
            prevBlockHash: prevHash,
            height: height,
            chainWork: Data(repeating: UInt8(height + 1), count: 32),
            version: 1,
            merkleRoot: Data(repeating: 0xAB, count: 32),
            timestamp: UInt32(1386325540 + height * 60),
            bits: 0x1e0ffff0,
            nonce: UInt32(99943 + height),
            isInBestChain: isInBestChain
        )
    }

    // MARK: - Basic Operations

    @Test("Insert and retrieve header by hash")
    func insertAndRetrieveByHash() throws {
        let db = try HeaderDatabase()
        let record = makeTestRecord(height: 0)

        try db.insertHeader(record)

        let retrieved = try db.getHeader(hash: record.hash)
        #expect(retrieved != nil)
        #expect(retrieved?.height == 0)
        #expect(retrieved?.hash == record.hash)
    }

    @Test("Retrieve header by height")
    func retrieveByHeight() throws {
        let db = try HeaderDatabase()
        let genesis = makeTestRecord(height: 0)
        try db.insertHeader(genesis)

        let retrieved = try db.getHeader(height: 0)
        #expect(retrieved != nil)
        #expect(retrieved?.hash == genesis.hash)
    }

    @Test("Header not found returns nil")
    func headerNotFound() throws {
        let db = try HeaderDatabase()

        let byHash = try db.getHeader(hash: Data(repeating: 0xFF, count: 32))
        #expect(byHash == nil)

        let byHeight = try db.getHeader(height: 999)
        #expect(byHeight == nil)
    }

    @Test("Header exists check")
    func headerExists() throws {
        let db = try HeaderDatabase()
        let record = makeTestRecord(height: 0)

        #expect(try db.headerExists(hash: record.hash) == false)

        try db.insertHeader(record)

        #expect(try db.headerExists(hash: record.hash) == true)
    }

    // MARK: - Chain Tip

    @Test("Get chain tip")
    func getTip() throws {
        let db = try HeaderDatabase()

        for i: Int32 in 0..<3 {
            let record = makeTestRecord(height: i, prevHeight: i > 0 ? i - 1 : nil)
            try db.insertHeader(record)
        }

        let tip = try db.getTip()
        #expect(tip != nil)
        #expect(tip?.height == 2)
    }

    @Test("Get tip returns nil for empty database")
    func getTipEmpty() throws {
        let db = try HeaderDatabase()

        let tip = try db.getTip()
        #expect(tip == nil)
    }

    @Test("Get tip only considers best chain")
    func getTipBestChainOnly() throws {
        let db = try HeaderDatabase()

        // Insert best chain headers at heights 0, 1
        for i: Int32 in 0..<2 {
            let record = makeTestRecord(height: i, prevHeight: i > 0 ? i - 1 : nil, isInBestChain: true)
            try db.insertHeader(record)
        }

        // Insert orphan at height 5 (not in best chain)
        var orphan = makeTestRecord(height: 5, isInBestChain: false)
        orphan.hash = Data(repeating: 0xFF, count: 32) // Different hash
        try db.insertHeader(orphan)

        let tip = try db.getTip()
        #expect(tip?.height == 1) // Should be 1, not 5
    }

    // MARK: - Header Count

    @Test("Get header count")
    func getHeaderCount() throws {
        let db = try HeaderDatabase()

        #expect(try db.getHeaderCount() == 0)

        for i: Int32 in 0..<5 {
            let record = makeTestRecord(height: i, prevHeight: i > 0 ? i - 1 : nil)
            try db.insertHeader(record)
        }

        #expect(try db.getHeaderCount() == 5)
    }

    // MARK: - Range Queries

    @Test("Get headers in range")
    func getHeadersInRange() throws {
        let db = try HeaderDatabase()

        for i: Int32 in 0..<10 {
            let record = makeTestRecord(height: i, prevHeight: i > 0 ? i - 1 : nil)
            try db.insertHeader(record)
        }

        let headers = try db.getHeaders(fromHeight: 3, toHeight: 7)
        #expect(headers.count == 5)
        #expect(headers.first?.height == 3)
        #expect(headers.last?.height == 7)
    }

    // MARK: - Batch Insert

    @Test("Batch insert headers")
    func batchInsert() throws {
        let db = try HeaderDatabase()

        var records: [HeaderRecord] = []
        for i: Int32 in 0..<100 {
            records.append(makeTestRecord(height: i, prevHeight: i > 0 ? i - 1 : nil))
        }

        try db.insertHeaders(records)

        #expect(try db.getHeaderCount() == 100)
        #expect(try db.getTip()?.height == 99)
    }

    // MARK: - Extending the Best Chain

    @Test("A run of headers is appended to the best chain together")
    func appendToBestChain() throws {
        let db = try HeaderDatabase()
        let genesis = makeTestRecord(height: 0)
        try db.insertHeader(genesis)

        let run = (1...250).map { makeTestRecord(height: Int32($0), prevHeight: Int32($0) - 1) }
        try db.appendToBestChain(run, after: genesis.hash)

        #expect(try db.getTip()?.height == 250)
        #expect(try db.getHeader(height: 137)?.hash == run[136].hash)
        #expect(try db.getHeaders(fromHeight: 249, toHeight: 300).map(\.height) == [249, 250])

        // Nothing to append is nothing to check, either.
        try db.appendToBestChain([], after: Data(repeating: 0xEE, count: 32))
    }

    @Test("Headers are not appended to a chain whose tip is no longer where the caller thinks")
    func appendRefusesAfterTheTipMoved() throws {
        let db = try HeaderDatabase()
        let genesis = makeTestRecord(height: 0)
        let one = makeTestRecord(height: 1, prevHeight: 0)
        try db.insertHeaders([genesis, one])

        // Another connection has added block 1; this one still builds on
        // the genesis block.
        var rival = makeTestRecord(height: 1, prevHeight: 0)
        rival.hash = Data(repeating: 0xBB, count: 32)

        #expect(throws: HeaderDatabaseError.chainChanged) {
            try db.appendToBestChain([rival], after: genesis.hash)
        }

        // Nothing was written: one block at height 1, and it is the first.
        #expect(try db.getHeaderCount() == 2)
        #expect(try db.getHeader(height: 1)?.hash == one.hash)
        #expect(try db.getHeader(hash: rival.hash) == nil)
    }

    // MARK: - Best Chain Updates

    @Test("Replacing the best chain above a height unflags what was there and flags the new branch")
    func replaceBestChain() throws {
        let db = try HeaderDatabase()
        for height: Int32 in 0..<10 {
            try db.insertHeader(makeTestRecord(height: height, prevHeight: height > 0 ? height - 1 : nil))
        }
        var branch = makeTestRecord(height: 6, prevHeight: 5, isInBestChain: false)
        branch.hash = Data(repeating: 0xB6, count: 32)
        try db.insertHeader(branch)

        try db.replaceBestChain(above: 5, with: [branch.hash])

        #expect(try db.getTip()?.hash == branch.hash)
        #expect(try db.getHeader(height: 6)?.hash == branch.hash)
        for height: Int32 in 7..<10 {
            #expect(try db.getHeader(height: height) == nil)
        }
        // The blocks that lost are still there, by hash.
        #expect(try db.getHeader(hash: makeTestRecord(height: 9).hash)?.isInBestChain == false)
        #expect(try db.getHeaderCount() == 11)
    }

    @Test("The best chain is not replaced when its tip is no longer the one being replaced")
    func replaceBestChainChecksTheTip() throws {
        let db = try HeaderDatabase()
        for height: Int32 in 0..<4 {
            try db.insertHeader(makeTestRecord(height: height, prevHeight: height > 0 ? height - 1 : nil))
        }
        var branch = makeTestRecord(height: 2, prevHeight: 1, isInBestChain: false)
        branch.hash = Data(repeating: 0xB2, count: 32)
        try db.insertHeader(branch)

        // The caller believes the tip is still block 2.
        #expect(throws: HeaderDatabaseError.chainChanged) {
            try db.replaceBestChain(above: 1, with: [branch.hash], expectedTip: makeTestRecord(height: 2).hash)
        }
        #expect(try db.getTip()?.height == 3)
        #expect(try db.getHeader(height: 2)?.hash == makeTestRecord(height: 2).hash)

        try db.replaceBestChain(above: 1, with: [branch.hash], expectedTip: makeTestRecord(height: 3).hash)
        #expect(try db.getTip()?.hash == branch.hash)
    }

    // MARK: - Repair

    @Test("A sound chain needs no repair")
    func repairLeavesASoundChainAlone() throws {
        let db = try HeaderDatabase()
        for height: Int32 in 0..<20 {
            try db.insertHeader(makeTestRecord(height: height, prevHeight: height > 0 ? height - 1 : nil))
        }

        #expect(try db.repairBestChain(depth: 100) == 0)
        #expect(try db.getTip()?.height == 19)
        #expect(try HeaderDatabase().repairBestChain(depth: 100) == 0)
    }

    @Test("Best-chain flags that disagree with the tip's ancestry are corrected")
    func repairCorrectsFlags() throws {
        let db = try HeaderDatabase()
        for height: Int32 in 0..<10 {
            // Block 6 has lost its flag, as an interrupted write could leave it.
            try db.insertHeader(makeTestRecord(height: height, prevHeight: height > 0 ? height - 1 : nil, isInBestChain: height != 6))
        }
        // And a block the tip does not descend from carries one at height 4.
        var stray = makeTestRecord(height: 4, prevHeight: 3)
        stray.hash = Data(repeating: 0x5A, count: 32)
        try db.insertHeader(stray)

        #expect(try db.getHeader(height: 6) == nil)

        #expect(try db.repairBestChain(depth: 100) == 2)

        #expect(try db.getHeader(height: 6)?.hash == makeTestRecord(height: 6).hash)
        #expect(try db.getHeader(height: 4)?.hash == makeTestRecord(height: 4).hash)
        #expect(try db.getHeader(hash: stray.hash)?.isInBestChain == false)
        #expect(try db.repairBestChain(depth: 100) == 0)
    }

    @Test("Repair only looks as deep as it is asked to")
    func repairDepth() throws {
        let db = try HeaderDatabase()
        for height: Int32 in 0..<10 {
            try db.insertHeader(makeTestRecord(height: height, prevHeight: height > 0 ? height - 1 : nil, isInBestChain: height != 2))
        }

        #expect(try db.repairBestChain(depth: 5) == 0)
        #expect(try db.getHeader(height: 2) == nil)
        #expect(try db.repairBestChain(depth: 7) == 1)
        #expect(try db.getHeader(height: 2) != nil)
    }

    @Test("Repair stops where the stored chain does, and corrects what it could reach")
    func repairStopsAtAMissingParent() throws {
        let db = try HeaderDatabase()
        // No block 3: the database starts, in effect, at block 4.
        for height: Int32 in [0, 1, 2, 4, 5, 6] {
            try db.insertHeader(makeTestRecord(height: height, prevHeight: height > 0 ? height - 1 : nil, isInBestChain: height != 5 && height != 1))
        }

        #expect(try db.repairBestChain(depth: 100) == 1)
        #expect(try db.getHeader(height: 5) != nil)
        // Beyond the gap nothing is known, and nothing is touched.
        #expect(try db.getHeader(height: 1) == nil)
        #expect(try db.getTip()?.height == 6)
    }

    // MARK: - Query Plans

    @Test("Every lookup by height is answered from the best-chain index, never by reading the table", arguments: [
        HeaderDatabase.Query.tip,
        HeaderDatabase.Query.bestChainAtHeight,
        HeaderDatabase.Query.bestChainRange,
        HeaderDatabase.Query.unflagAbove,
        HeaderDatabase.Query.unflagOthersAtHeight
    ])
    func heightQueriesUseTheIndex(sql: String) throws {
        let plan = try HeaderDatabase().queryPlan(for: sql.replacingOccurrences(of: "?", with: "1"))

        #expect(!plan.isEmpty)
        #expect(plan.allSatisfy { $0.contains("idx_headers_best_chain_height") }, "\(plan)")
        #expect(!plan.contains { $0.hasPrefix("SCAN") }, "\(plan)")
    }

    // MARK: - Block Locator

    @Test("Get block locator")
    func getBlockLocator() throws {
        let db = try HeaderDatabase()

        for i: Int32 in 0..<20 {
            let record = makeTestRecord(height: i, prevHeight: i > 0 ? i - 1 : nil)
            try db.insertHeader(record)
        }

        let locator = try db.getBlockLocator()
        let tip = try db.getTip()
        let genesis = try db.getHeader(height: 0)

        // Should have tip first
        #expect(locator.first == tip?.hash)

        // Should include genesis
        #expect(locator.contains(genesis?.hash ?? Data()))

        // Should have reasonable number of entries
        #expect(locator.count > 1)
        #expect(locator.count <= 20)
    }

    @Test("Block locator empty for empty database")
    func blockLocatorEmpty() throws {
        let db = try HeaderDatabase()

        let locator = try db.getBlockLocator()
        #expect(locator.isEmpty)
    }

    // MARK: - Schema

    @Test("A new database carries only the indexes its queries use")
    func indexes() throws {
        let indexes = try HeaderDatabase().indexNames()

        // The primary key's own index, and the one every height lookup uses.
        #expect(indexes == ["sqlite_autoindex_headers_1", "idx_headers_best_chain_height"])
    }

    @Test("Opening an older database drops the unused indexes and keeps its headers")
    func migrationDropsUnusedIndexes() throws {
        let directory = TestDirectories.unique()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("headers.sqlite").path

        do {
            // Put a database back the way the first schema version left it.
            let database = try HeaderDatabase(path: path)
            try database.insertHeaders([makeTestRecord(height: 0), makeTestRecord(height: 1, prevHeight: 0)])
            try database.executeWithoutTransaction("CREATE INDEX headers_on_prevBlockHash ON headers(prevBlockHash)")
            try database.executeWithoutTransaction("CREATE INDEX idx_headers_merkle_root ON headers(merkleRoot)")
            try database.executeWithoutTransaction("CREATE INDEX headers_on_height ON headers(height)")
            try database.executeWithoutTransaction("DELETE FROM grdb_migrations WHERE identifier IN ('v2_drop_unused_indexes', 'v3_drop_height_index')")
            #expect(try database.indexNames().contains("idx_headers_merkle_root"))
            #expect(try database.indexNames().contains("headers_on_height"))
        }

        let reopened = try HeaderDatabase(path: path)
        let indexes = try reopened.indexNames()

        // The primary key's own index, and the one every height lookup uses.
        #expect(indexes == ["sqlite_autoindex_headers_1", "idx_headers_best_chain_height"])
        #expect(try reopened.getHeaderCount() == 2)
        #expect(try reopened.getTip()?.height == 1)
    }

    @Test("A read-only database can be read but not changed")
    func readOnlyOpen() throws {
        let directory = TestDirectories.unique()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("headers.sqlite").path

        do {
            let database = try HeaderDatabase(path: path)
            try database.insertHeader(makeTestRecord(height: 0))
        }

        let readOnly = try HeaderDatabase(readOnlyPath: path)
        #expect(try readOnly.getTip()?.height == 0)
        #expect(try readOnly.getHeaderCount() == 1)
        #expect(throws: (any Error).self) {
            try readOnly.insertHeader(makeTestRecord(height: 1, prevHeight: 0))
        }
    }

    @Test("Opening something that is not a database fails as unreadable")
    func unreadableFile() throws {
        let directory = TestDirectories.unique()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("headers.sqlite")
        try Data("version https://git-lfs.github.com/spec/v1\n".utf8).write(to: url)

        do {
            _ = try HeaderDatabase(readOnlyPath: url.path).getTip()
            Issue.record("A text file opened as a header database")
        } catch {
            #expect(HeaderDatabase.indicatesUnreadableFile(error))
        }
    }

    // MARK: - Conversion Tests

    @Test("HeaderRecord to StoredHeader conversion")
    func recordToStoredHeaderConversion() throws {
        let record = makeTestRecord(height: 42)
        let stored = record.toStoredHeader()

        #expect(stored.height == 42)
        #expect(stored.header.version == record.version)
        #expect(stored.header.prevBlock == record.prevBlockHash)
        #expect(stored.header.merkleRoot == record.merkleRoot)
        #expect(stored.header.timestamp == record.timestamp)
        #expect(stored.header.bits == record.bits)
        #expect(stored.header.nonce == record.nonce)
        #expect(stored.chainWork == record.chainWork)
    }

    @Test("StoredHeader to HeaderRecord conversion")
    func storedHeaderToRecordConversion() throws {
        let header = BlockHeader(
            version: 1,
            prevBlock: Data(repeating: 0x11, count: 32),
            merkleRoot: Data(repeating: 0x22, count: 32),
            timestamp: 1234567890,
            bits: 0x1e0ffff0,
            nonce: 12345
        )
        let stored = StoredHeader(
            header: header,
            height: 100,
            chainWork: Data(repeating: 0x33, count: 32)
        )

        let record = HeaderRecord(storedHeader: stored, isInBestChain: true)

        #expect(record.hash == header.hash)
        #expect(record.height == 100)
        #expect(record.prevBlockHash == header.prevBlock)
        #expect(record.merkleRoot == header.merkleRoot)
        #expect(record.chainWork == stored.chainWork)
        #expect(record.isInBestChain == true)
    }

    @Test("Chain work is stored without its padding and read back whole")
    func chainWorkIsTrimmed() throws {
        // Mainnet's total at height 6,341,590: ten significant bytes.
        let work = try #require(Data(hexString: "87fa006fa856d853453300000000000000000000000000000000000000000000"))
        let header = BlockHeader(version: 1, prevBlock: Data(count: 32), merkleRoot: Data(count: 32), timestamp: 1, bits: 0x1e0ffff0, nonce: 1)

        let record = HeaderRecord(storedHeader: StoredHeader(header: header, height: 7, chainWork: work))
        #expect(record.chainWork == work.prefix(10))

        let db = try HeaderDatabase()
        try db.insertHeader(record)
        let read = try #require(try db.getHeader(height: 7))
        #expect(read.chainWork.count == 10)
        #expect(read.toStoredHeader().chainWork == work)

        // Rows written before, at their full 32 bytes, read the same.
        var padded = record
        padded.hash = Data(repeating: 0x77, count: 32)
        padded.height = 8
        padded.chainWork = work
        try db.insertHeader(padded)
        #expect(try db.getHeader(height: 8)?.toStoredHeader().chainWork == work)

        // No work at all — and nothing but zeros — is still a number.
        #expect(HeaderRecord.trimmed(Data(count: 32)).isEmpty)
        #expect(HeaderRecord.padded(Data()) == Data(count: 32))
        #expect(UInt256(littleEndian: HeaderRecord.trimmed(work)) == UInt256(littleEndian: work))
    }
}
