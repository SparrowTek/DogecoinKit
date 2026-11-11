import Foundation
import Testing
@testable import DogecoinKit

/// Header validation against real mainnet data (see `RealChainFixtures`).
@Suite("Real Chain Validation")
struct RealChainValidationTests {

    private func realEntries() throws -> [HeadersMessage.Entry] {
        let entries = RealChainFixtures.parsedEntries()
        try #require(entries.count == 3, "fixture headers failed to parse")
        return entries
    }

    // MARK: - AuxPoW

    @Test("Real merge-mined headers carry valid AuxPoW proofs")
    func realProofsValidate() throws {
        for entry in try realEntries() {
            let auxpow = try #require(entry.auxpow, "merge-mined header lost its proof in parsing")
            try auxpow.validate(for: entry.header)
        }
    }

    @Test("AuxPoW proofs survive a serialize/parse round trip")
    func proofRoundTrip() throws {
        let entries = try realEntries()
        let reparsed = try #require(HeadersMessage.parse(from: HeadersMessage(entries: entries).serialize()))
        #expect(reparsed.entries == entries)
    }

    @Test("A proof whose parent block misses the target is rejected")
    func tamperedParentNonce() throws {
        let entry = try #require(try realEntries().first)
        let auxpow = try #require(entry.auxpow)
        let parent = auxpow.parentBlockHeader
        let forged = AuxPoW(
            coinbaseTx: auxpow.coinbaseTx,
            parentBlockHash: auxpow.parentBlockHash,
            coinbaseMerkleBranch: auxpow.coinbaseMerkleBranch,
            coinbaseMerkleIndex: auxpow.coinbaseMerkleIndex,
            chainMerkleBranch: auxpow.chainMerkleBranch,
            chainMerkleIndex: auxpow.chainMerkleIndex,
            parentBlockHeader: BlockHeader(
                version: parent.version,
                prevBlock: parent.prevBlock,
                merkleRoot: parent.merkleRoot,
                timestamp: parent.timestamp,
                bits: parent.bits,
                nonce: parent.nonce &+ 1
            )
        )

        let error = #expect(throws: AuxPoW.ValidationError.self) {
            try forged.validate(for: entry.header)
        }
        guard case .invalidParentProofOfWork = error else {
            Issue.record("Expected invalidParentProofOfWork, got \(String(describing: error))")
            return
        }
    }

    @Test("A proof reused for a different Dogecoin header is rejected")
    func proofForDifferentHeader() throws {
        let entries = try realEntries()
        let auxpow = try #require(entries[0].auxpow)

        // The second header's hash is not committed in the first proof.
        #expect(throws: AuxPoW.ValidationError.missingAuxPowCommitment) {
            try auxpow.validate(for: entries[1].header)
        }
    }

    @Test("A coinbase that is not in the parent block is rejected")
    func tamperedCoinbase() throws {
        let entry = try #require(try realEntries().first)
        let auxpow = try #require(entry.auxpow)
        var coinbase = auxpow.coinbaseTx
        coinbase[coinbase.endIndex - 5] ^= 0x01 // flip a bit in the last output's script/locktime

        let forged = AuxPoW(
            coinbaseTx: coinbase,
            parentBlockHash: auxpow.parentBlockHash,
            coinbaseMerkleBranch: auxpow.coinbaseMerkleBranch,
            coinbaseMerkleIndex: auxpow.coinbaseMerkleIndex,
            chainMerkleBranch: auxpow.chainMerkleBranch,
            chainMerkleIndex: auxpow.chainMerkleIndex,
            parentBlockHeader: auxpow.parentBlockHeader
        )

        #expect(throws: AuxPoW.ValidationError.invalidCoinbaseMerkleProof) {
            try forged.validate(for: entry.header)
        }
    }

    @Test("A coinbase claimed at a non-zero position is rejected")
    func nonFirstCoinbase() throws {
        let entry = try #require(try realEntries().first)
        let auxpow = try #require(entry.auxpow)
        let forged = AuxPoW(
            coinbaseTx: auxpow.coinbaseTx,
            parentBlockHash: auxpow.parentBlockHash,
            coinbaseMerkleBranch: auxpow.coinbaseMerkleBranch,
            coinbaseMerkleIndex: 1,
            chainMerkleBranch: auxpow.chainMerkleBranch,
            chainMerkleIndex: auxpow.chainMerkleIndex,
            parentBlockHeader: auxpow.parentBlockHeader
        )

        #expect(throws: AuxPoW.ValidationError.coinbaseIndexMismatch) {
            try forged.validate(for: entry.header)
        }
    }

    /// The proof with its parent coinbase re-serialized in BIP 144 witness
    /// form, as a parent chain with segregated witness may relay it.
    private func witnessSerialized(_ auxpow: AuxPoW) -> AuxPoW {
        let legacy = auxpow.coinbaseTx
        var coinbase = Data(legacy.prefix(4))                                 // version
        coinbase.append(contentsOf: [0x00, 0x01])                             // marker, flag
        coinbase.append(legacy.dropFirst(4).dropLast(4))                      // inputs, outputs
        coinbase.append(contentsOf: [0x01, 0x20] + [UInt8](repeating: 0, count: 32))  // witness reserved value
        coinbase.append(legacy.suffix(4))                                     // lock time

        return AuxPoW(
            coinbaseTx: coinbase,
            parentBlockHash: auxpow.parentBlockHash,
            coinbaseMerkleBranch: auxpow.coinbaseMerkleBranch,
            coinbaseMerkleIndex: auxpow.coinbaseMerkleIndex,
            chainMerkleBranch: auxpow.chainMerkleBranch,
            chainMerkleIndex: auxpow.chainMerkleIndex,
            parentBlockHeader: auxpow.parentBlockHeader
        )
    }

    @Test("A parent coinbase in witness serialization validates by its txid")
    func witnessCoinbaseValidates() throws {
        for entry in try realEntries() {
            let auxpow = witnessSerialized(try #require(entry.auxpow))
            let coinbase = try #require(RawTransaction(data: auxpow.coinbaseTx))

            #expect(coinbase.hasWitness)
            #expect(coinbase.strippedData == entry.auxpow?.coinbaseTx)
            try auxpow.validate(for: entry.header)
        }
    }

    @Test("Headers carrying a witness-serialized coinbase parse and connect")
    func witnessCoinbaseThroughHeaderChain() async throws {
        let entries = try realEntries().map { entry in
            HeadersMessage.Entry(header: entry.header, auxpow: entry.auxpow.map(witnessSerialized))
        }
        let reparsed = try #require(HeadersMessage.parse(from: HeadersMessage(entries: entries).serialize()))
        #expect(reparsed.entries == entries)

        let chain = try await chainAtFixtureTip()
        let result = await chain.addHeaders(reparsed.entries)
        #expect(result.added == 3)
        #expect(result.failure == nil)
    }

    @Test("The expected chain index matches Dogecoin Core's formula")
    func expectedIndexVector() {
        // With a zero-height tree every nonce maps to slot 0.
        #expect(AuxPoW.expectedChainIndex(nonce: 0xDEADBEEF, chainID: 0x62, merkleHeight: 0) == 0)

        // rand = ((n * 1103515245 + 12345) + chainID) * 1103515245 + 12345, mod 2^h
        var expected: UInt32 = 7
        expected = expected &* 1_103_515_245 &+ 12_345
        expected = expected &+ 0x62
        expected = expected &* 1_103_515_245 &+ 12_345
        #expect(AuxPoW.expectedChainIndex(nonce: 7, chainID: 0x62, merkleHeight: 5) == expected % 32)
    }

    // MARK: - Difficulty

    @Test("Real headers carry exactly the bits DigiShield requires")
    func realDifficultyMatches() throws {
        var chain = RealChainFixtures.storedAncestors()
        try #require(chain.count == 11)

        for entry in try realEntries() {
            let parent = try #require(chain.last)
            #expect(entry.header.prevBlock == parent.header.hash)

            let expected = ProofOfWorkRules.mainnet.requiredBits(after: parent) { height in
                chain.first { $0.height == height }
            }
            #expect(expected == entry.header.bits)

            chain.append(StoredHeader(header: entry.header, height: parent.height + 1))
        }
    }

    @Test("Compact targets round-trip through Core's encoding")
    func compactRoundTrip() throws {
        for bits: UInt32 in [0x1e0ffff0, 0x1e0fffff, 0x1b01cc26, 0x1a0170b2, 0x1d00ffff, 0x04123456] {
            let target = try #require(UInt256(compact: bits))
            #expect(target.compact == bits)
        }

        // Non-canonical encodings decode, and re-encode canonically like Core
        #expect(UInt256(compact: 0x03000001)?.compact == 0x01010000)

        // Negative and overflowing encodings are rejected outright
        #expect(UInt256(compact: 0x04923456) == nil)
        #expect(UInt256(compact: 0x23000001) == nil)

        // Nothing easier than the proof-of-work limit is accepted
        #expect(ProofOfWorkRules.mainnet.target(forBits: 0x1e0fffff) != nil)
        #expect(ProofOfWorkRules.mainnet.target(forBits: 0x1f00ffff) == nil)
        #expect(ProofOfWorkRules.mainnet.target(forBits: 0x00000000) == nil)
    }

    @Test("Block work is 2^256 / (target + 1)")
    func blockWork() throws {
        // Genesis target 0x00000ffff0... → work 0x100010 (1048592)
        let genesisTarget = try #require(UInt256(compact: 0x1e0ffff0))
        #expect(ProofOfWorkRules.work(forTarget: genesisTarget) == UInt256(0x100010))
        #expect(ProofOfWorkRules.work(forTarget: .max) == .one)
    }

    // MARK: - HeaderChain end to end

    private func chainAtFixtureTip() async throws -> HeaderChain {
        try await RealChainFixtures.headerChainAtTip()
    }

    @Test("HeaderChain accepts real merge-mined headers with their proofs")
    func headerChainAcceptsRealHeaders() async throws {
        let chain = try await chainAtFixtureTip()
        #expect(await chain.height == 6_341_590)

        let result = await chain.addHeaders(try realEntries())
        #expect(result.added == 3)
        #expect(result.failure == nil)
        #expect(await chain.height == 6_341_593)
    }

    @Test("HeaderChain rejects a merge-mined header that arrives without its proof")
    func headerChainRequiresProof() async throws {
        let chain = try await chainAtFixtureTip()
        let entry = try #require(try realEntries().first)

        let result = await chain.addHeaders([HeadersMessage.Entry(header: entry.header, auxpow: nil)])
        #expect(result.added == 0)
        guard case .auxPowRequired = result.failure else {
            Issue.record("expected auxPowRequired, got \(String(describing: result.failure))")
            return
        }
        #expect(await chain.height == 6_341_590)
    }

    @Test("HeaderChain rejects a proof that belongs to another header")
    func headerChainRejectsSwappedProof() async throws {
        let chain = try await chainAtFixtureTip()
        let entries = try realEntries()

        let result = await chain.addHeaders([HeadersMessage.Entry(header: entries[0].header, auxpow: entries[1].auxpow)])
        #expect(result.added == 0)
        guard case .auxPowValidationFailed = result.failure else {
            Issue.record("expected auxPowValidationFailed, got \(String(describing: result.failure))")
            return
        }
    }

    @Test("HeaderChain stops a batch at the first invalid header")
    func headerChainStopsAtFirstFailure() async throws {
        let chain = try await chainAtFixtureTip()
        let entries = try realEntries()

        let batch = [entries[0], HeadersMessage.Entry(header: entries[1].header, auxpow: nil), entries[2]]
        let result = await chain.addHeaders(batch)
        #expect(result.added == 1)
        #expect(result.failure != nil)
        #expect(await chain.height == 6_341_591)
    }

    @Test("Headers forking below the last passed checkpoint are rejected")
    func forkBelowCheckpointRejected() async throws {
        let chain = try await chainAtFixtureTip()
        let genesis = try #require(try await chain.getHeader(height: 0))

        // Block 1's real header builds on genesis — a fork millions of blocks
        // below the 5.4M checkpoint the fixture chain has passed.
        let block1 = BlockHeader(
            version: 1,
            prevBlock: genesis.header.hash,
            merkleRoot: try #require(Data(hexString: "1C525F1049E519256961F407E96E22AEF391581DE98686524EF500769F777E5F")),
            timestamp: 1_386_474_927,
            bits: 0x1e0ffff0,
            nonce: 1_417_875_456
        )

        let error = await #expect(throws: HeaderChain.ValidationError.self) {
            try await chain.addHeaderValidated(block1)
        }
        guard case .forkBelowCheckpoint(height: 1) = error else {
            Issue.record("Expected forkBelowCheckpoint, got \(String(describing: error))")
            return
        }
    }
}
