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
    func testInsertAndRetrieveByHash() throws {
        let db = try HeaderDatabase()
        let record = makeTestRecord(height: 0)

        try db.insertHeader(record)

        let retrieved = try db.getHeader(hash: record.hash)
        #expect(retrieved != nil)
        #expect(retrieved?.height == 0)
        #expect(retrieved?.hash == record.hash)
    }

    @Test("Retrieve header by height")
    func testRetrieveByHeight() throws {
        let db = try HeaderDatabase()
        let genesis = makeTestRecord(height: 0)
        try db.insertHeader(genesis)

        let retrieved = try db.getHeader(height: 0)
        #expect(retrieved != nil)
        #expect(retrieved?.hash == genesis.hash)
    }

    @Test("Header not found returns nil")
    func testHeaderNotFound() throws {
        let db = try HeaderDatabase()

        let byHash = try db.getHeader(hash: Data(repeating: 0xFF, count: 32))
        #expect(byHash == nil)

        let byHeight = try db.getHeader(height: 999)
        #expect(byHeight == nil)
    }

    @Test("Header exists check")
    func testHeaderExists() throws {
        let db = try HeaderDatabase()
        let record = makeTestRecord(height: 0)

        #expect(try db.headerExists(hash: record.hash) == false)

        try db.insertHeader(record)

        #expect(try db.headerExists(hash: record.hash) == true)
    }

    // MARK: - Chain Tip

    @Test("Get chain tip")
    func testGetTip() throws {
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
    func testGetTipEmpty() throws {
        let db = try HeaderDatabase()

        let tip = try db.getTip()
        #expect(tip == nil)
    }

    @Test("Get tip only considers best chain")
    func testGetTipBestChainOnly() throws {
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
    func testGetHeaderCount() throws {
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
    func testGetHeadersInRange() throws {
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
    func testBatchInsert() throws {
        let db = try HeaderDatabase()

        var records: [HeaderRecord] = []
        for i: Int32 in 0..<100 {
            records.append(makeTestRecord(height: i, prevHeight: i > 0 ? i - 1 : nil))
        }

        try db.insertHeaders(records)

        #expect(try db.getHeaderCount() == 100)
        #expect(try db.getTip()?.height == 99)
    }

    @Test("Batch insert with progress")
    func testBatchInsertWithProgress() throws {
        let db = try HeaderDatabase()

        var records: [HeaderRecord] = []
        for i: Int32 in 0..<250 {
            records.append(makeTestRecord(height: i, prevHeight: i > 0 ? i - 1 : nil))
        }

        var progressCalls: [(Int, Int)] = []
        try db.insertHeadersBatched(records, batchSize: 100) { inserted, total in
            progressCalls.append((inserted, total))
        }

        #expect(try db.getHeaderCount() == 250)
        #expect(progressCalls.count == 3) // 100, 200, 250
        #expect(progressCalls.last?.0 == 250)
        #expect(progressCalls.last?.1 == 250)
    }

    // MARK: - Best Chain Updates

    @Test("Update best chain status")
    func testUpdateBestChainStatus() throws {
        let db = try HeaderDatabase()

        let record = makeTestRecord(height: 0, isInBestChain: true)
        try db.insertHeader(record)

        // Verify it's in best chain
        #expect(try db.getHeader(height: 0) != nil)

        // Remove from best chain
        try db.updateBestChainStatus(hash: record.hash, isInBestChain: false)

        // Should no longer be found by height (height query only finds best chain)
        #expect(try db.getHeader(height: 0) == nil)

        // But should still be found by hash
        #expect(try db.getHeader(hash: record.hash) != nil)
    }

    @Test("Clear best chain markers above height")
    func testClearBestChainMarkers() throws {
        let db = try HeaderDatabase()

        for i: Int32 in 0..<10 {
            let record = makeTestRecord(height: i, prevHeight: i > 0 ? i - 1 : nil)
            try db.insertHeader(record)
        }

        // Clear best chain markers above height 5
        try db.clearBestChainMarkers(aboveHeight: 5)

        // Headers 0-5 should still be in best chain
        for i: Int32 in 0...5 {
            #expect(try db.getHeader(height: i) != nil)
        }

        // Headers 6-9 should no longer be in best chain (by height lookup)
        for i: Int32 in 6..<10 {
            #expect(try db.getHeader(height: i) == nil)
        }

        // Tip should now be at height 5
        #expect(try db.getTip()?.height == 5)
    }

    // MARK: - Block Locator

    @Test("Get block locator")
    func testGetBlockLocator() throws {
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
    func testBlockLocatorEmpty() throws {
        let db = try HeaderDatabase()

        let locator = try db.getBlockLocator()
        #expect(locator.isEmpty)
    }

    // MARK: - Merkle Root Lookup

    @Test("Get header by merkle root")
    func testGetHeaderByMerkleRoot() throws {
        let db = try HeaderDatabase()

        var record = makeTestRecord(height: 0)
        let uniqueMerkleRoot = Data(repeating: 0xCD, count: 32)
        record.merkleRoot = uniqueMerkleRoot
        try db.insertHeader(record)

        let found = try db.getHeader(merkleRoot: uniqueMerkleRoot)
        #expect(found != nil)
        #expect(found?.height == 0)
    }

    // MARK: - Conversion Tests

    @Test("HeaderRecord to StoredHeader conversion")
    func testRecordToStoredHeaderConversion() throws {
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
    func testStoredHeaderToRecordConversion() throws {
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
}
