import Foundation
import Testing
@testable import DogecoinKit

@Suite("AuxPoW Tests")
struct AuxPoWTests {

    // MARK: - Version Detection Tests

    @Test("Detects AuxPoW version flag")
    func auxPowVersionDetection() {
        // AuxPoW flag is bit 8 (0x100)
        #expect(AuxPoW.isAuxPow(version: 0x100) == true)
        #expect(AuxPoW.isAuxPow(version: 0x6422100) == true)  // Common Dogecoin version
        #expect(AuxPoW.isAuxPow(version: 0x20000100) == true) // With version bits

        // Non-AuxPoW versions
        #expect(AuxPoW.isAuxPow(version: 1) == false)
        #expect(AuxPoW.isAuxPow(version: 2) == false)
        #expect(AuxPoW.isAuxPow(version: 0x20000000) == false)
        #expect(AuxPoW.isAuxPow(version: 0) == false)
    }

    // MARK: - Parsing Tests

    @Test("Fails parsing with insufficient data")
    func parsingInsufficientData() {
        // Empty data
        let empty = Data()
        #expect(AuxPoW.parse(from: empty, at: 0) == nil)

        // Data too short for coinbase tx
        let tooShort = Data(repeating: 0, count: 50)
        #expect(AuxPoW.parse(from: tooShort, at: 0) == nil)
    }

    @Test("Parses minimal valid AuxPoW structure")
    func parsingMinimalAuxPoW() {
        // Build a minimal valid AuxPoW structure
        var data = Data()

        // Minimal coinbase transaction (version + no inputs marker for test)
        // Version (4 bytes)
        data.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        // Input count (1)
        data.append(0x01)
        // Prevout: null txid (32 bytes) + index (4 bytes)
        data.append(Data(repeating: 0, count: 32))
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        // ScriptSig length (0)
        data.append(0x00)
        // Sequence
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        // Output count (1)
        data.append(0x01)
        // Value (8 bytes)
        data.append(Data(repeating: 0, count: 8))
        // ScriptPubKey length (0)
        data.append(0x00)
        // Locktime
        data.append(Data(repeating: 0, count: 4))

        // Parent block hash (32 bytes)
        data.append(Data(repeating: 0xAB, count: 32))

        // Coinbase merkle branch (empty)
        data.append(0x00)

        // Coinbase merkle index (4 bytes)
        data.append(Data(repeating: 0, count: 4))

        // Chain merkle branch (empty)
        data.append(0x00)

        // Chain merkle index (4 bytes)
        data.append(Data(repeating: 0, count: 4))

        // Parent block header (80 bytes)
        data.append(Data(repeating: 0x00, count: 80))

        let result = AuxPoW.parse(from: data, at: 0)
        #expect(result != nil)

        if let (auxpow, offset) = result {
            #expect(auxpow.parentBlockHash == Data(repeating: 0xAB, count: 32))
            #expect(auxpow.coinbaseMerkleBranch.isEmpty)
            #expect(auxpow.chainMerkleBranch.isEmpty)
            #expect(auxpow.coinbaseMerkleIndex == 0)
            #expect(auxpow.chainMerkleIndex == 0)
            #expect(offset == data.count)
        }
    }

    @Test("Parses AuxPoW with merkle branches")
    func parsingWithMerkleBranches() {
        var data = Data()

        // Minimal coinbase transaction
        data.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // version
        data.append(0x01) // input count
        data.append(Data(repeating: 0, count: 32)) // null txid
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // index
        data.append(0x00) // scriptSig length
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // sequence
        data.append(0x01) // output count
        data.append(Data(repeating: 0, count: 8)) // value
        data.append(0x00) // scriptPubKey length
        data.append(Data(repeating: 0, count: 4)) // locktime

        // Parent block hash
        data.append(Data(repeating: 0xCD, count: 32))

        // Coinbase merkle branch with 2 hashes
        data.append(0x02)
        data.append(Data(repeating: 0x11, count: 32))
        data.append(Data(repeating: 0x22, count: 32))

        // Coinbase merkle index
        data.append(contentsOf: [0x01, 0x00, 0x00, 0x00])

        // Chain merkle branch with 1 hash
        data.append(0x01)
        data.append(Data(repeating: 0x33, count: 32))

        // Chain merkle index
        data.append(contentsOf: [0x02, 0x00, 0x00, 0x00])

        // Parent block header
        data.append(Data(repeating: 0x44, count: 80))

        let result = AuxPoW.parse(from: data, at: 0)
        #expect(result != nil)

        if let (auxpow, _) = result {
            #expect(auxpow.coinbaseMerkleBranch.count == 2)
            #expect(auxpow.coinbaseMerkleBranch[0] == Data(repeating: 0x11, count: 32))
            #expect(auxpow.coinbaseMerkleBranch[1] == Data(repeating: 0x22, count: 32))
            #expect(auxpow.coinbaseMerkleIndex == 1)
            #expect(auxpow.chainMerkleBranch.count == 1)
            #expect(auxpow.chainMerkleBranch[0] == Data(repeating: 0x33, count: 32))
            #expect(auxpow.chainMerkleIndex == 2)
        }
    }

    // MARK: - HeaderChain Integration Tests

    @Test("HeaderChain accepts AuxPoW blocks below checkpoint without validation")
    func headerChainAcceptsAuxPoWBelowCheckpoint() async throws {
        let storageURL = TestDirectories.unique()
        let chain = HeaderChain(network: .testnet, storageDirectory: storageURL)
        try await chain.setup()

        guard let genesis = try await chain.getHeader(height: 0) else {
            Issue.record("Genesis not found")
            return
        }

        // Create AuxPoW header at height 1 (well below testnet checkpoint of 5,900,000)
        let header = BlockHeader(
            version: 0x100,  // AuxPoW flag
            prevBlock: genesis.header.hash,
            merkleRoot: Data(repeating: 0x02, count: 32),
            timestamp: genesis.header.timestamp + 1,
            bits: 0x1e0ffff0,
            nonce: 2
        )

        // Should succeed without AuxPoW data
        do {
            try await chain.addHeaderValidated(header, auxpow: nil)
        } catch {
            Issue.record("Should accept AuxPoW header below checkpoint: \(error)")
        }

        let height = await chain.height
        #expect(height == 1)
    }

    // MARK: - Merkle Blocks

    @Test("A merge-mined block's merkle tree is found behind its proof, for real blocks")
    func merkleBlockStepsOverAuxPoW() throws {
        for entryHex in RealChainFixtures.mergeMinedEntries {
            let entry = try #require(Data(hexString: entryHex))
            let header = try #require(BlockHeader.parse(from: entry.prefix(BlockHeader.size)))
            #expect(header.isAuxPoW)

            // Stepping over the proof ends where parsing it does: at the
            // end of the entry.
            #expect(AuxPoW.endOffset(in: entry, at: BlockHeader.size) == entry.count)
            #expect(AuxPoW.parse(from: entry, at: BlockHeader.size)?.1 == entry.count)

            // The merkle block a node sends for it: header, proof, then
            // a tree with one unmatched transaction.
            let root = Data(repeating: 0x5A, count: 32)
            var payload = entry
            payload.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
            payload.append(0x01)
            payload.append(root)
            payload.append(contentsOf: [0x01, 0x00])

            let merkleBlock = try #require(MerkleBlockMessage.parse(from: payload))
            #expect(merkleBlock.header == header)
            #expect(merkleBlock.totalTransactions == 1)
            #expect(merkleBlock.hashes == [root])
            #expect(merkleBlock.flags == Data([0x00]))
        }
    }

    @Test("A merkle block whose proof is cut short does not parse")
    func truncatedAuxPoWInMerkleBlock() throws {
        let entryHex = try #require(RealChainFixtures.mergeMinedEntries.first)
        let entry = try #require(Data(hexString: entryHex))

        for cut in [1, 40, 81, 200] {
            let truncated = Data(entry.dropLast(cut))
            #expect(AuxPoW.endOffset(in: truncated, at: BlockHeader.size) == nil)
            #expect(MerkleBlockMessage.parse(from: truncated + Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00])) == nil)
        }
    }

    // MARK: - Helper Functions

    /// A header flagged as merge-mined, carrying Dogecoin's chain ID.
}
