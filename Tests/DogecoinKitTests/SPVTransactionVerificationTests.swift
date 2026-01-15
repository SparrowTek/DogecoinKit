import Foundation
import Testing
@testable import DogecoinKit

@Suite("SPV Transaction Verification Tests")
struct SPVTransactionVerificationTests {
    @Test("Bloom filter contains inserted element")
    func testBloomFilterInsert() {
        var filter = BloomFilter(elementCount: 1, falsePositiveRate: 0.0001, tweak: 1, flags: 0)
        let element = Data([0x01, 0x02, 0x03, 0x04])
        filter.insert(element)
        #expect(filter.contains(element))
    }

    @Test("Merkle block matches single transaction")
    func testMerkleBlockSingleTransaction() throws {
        let txid = Data(repeating: 0x11, count: 32)
        let header = BlockHeader(
            version: 1,
            prevBlock: Data(repeating: 0, count: 32),
            merkleRoot: txid,
            timestamp: 1,
            bits: 0,
            nonce: 0
        )

        let merkleBlock = MerkleBlockMessage(
            header: header,
            totalTransactions: 1,
            hashes: [txid],
            flags: Data([0x01])
        )

        let matches = try merkleBlock.extractMatches()
        #expect(matches.merkleRoot == txid)
        #expect(matches.matchedHashes == [txid])
    }

    @Test("Merkle block matches two transactions")
    func testMerkleBlockTwoTransactions() throws {
        let txid1 = Data(repeating: 0x01, count: 32)
        let txid2 = Data(repeating: 0x02, count: 32)
        let root = MerkleTree.hashPair(txid1, txid2)

        let header = BlockHeader(
            version: 1,
            prevBlock: Data(repeating: 0, count: 32),
            merkleRoot: root,
            timestamp: 1,
            bits: 0,
            nonce: 0
        )

        let merkleBlock = MerkleBlockMessage(
            header: header,
            totalTransactions: 2,
            hashes: [txid1, txid2],
            flags: Data([0x07])
        )

        let matches = try merkleBlock.extractMatches()
        #expect(matches.merkleRoot == root)
        #expect(matches.matchedHashes == [txid1, txid2])
    }
}
