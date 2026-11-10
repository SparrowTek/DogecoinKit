import Foundation
import Testing
@testable import DogecoinKit

@Suite("Partial Merkle Tree Checks")
struct PartialMerkleTreeTests {

    private func merkleBlock(root: Data, totalTransactions: UInt32, hashes: [Data], flags: [UInt8]) -> MerkleBlockMessage {
        let header = BlockHeader(version: 1, prevBlock: Data(count: 32), merkleRoot: root, timestamp: 1, bits: 0, nonce: 0)
        return MerkleBlockMessage(header: header, totalTransactions: totalTransactions, hashes: hashes, flags: Data(flags))
    }

    @Test("Identical sibling subtrees are rejected (CVE-2012-2459)")
    func duplicateSiblingsRejected() {
        let txid = Data(repeating: 0xAB, count: 32)
        let block = merkleBlock(root: MerkleTree.hashPair(txid, txid), totalTransactions: 2, hashes: [txid, txid], flags: [0x07])

        #expect(throws: MerkleBlockError.invalidProof) {
            _ = try block.extractMatches()
        }
    }

    @Test("A lone last node is still paired with itself, as Bitcoin's tree requires")
    func oddWidthStillValidates() throws {
        let t0 = Data(repeating: 0x01, count: 32)
        let t1 = Data(repeating: 0x02, count: 32)
        let t2 = Data(repeating: 0x03, count: 32)
        let left = MerkleTree.hashPair(t0, t1)
        let root = MerkleTree.hashPair(left, MerkleTree.hashPair(t2, t2))

        // Flags, depth first: root=1, left subtree=0 (pruned), right subtree=1, t2=1
        let block = merkleBlock(root: root, totalTransactions: 3, hashes: [left, t2], flags: [0b0000_1101])

        let matches = try block.extractMatches()
        #expect(matches.merkleRoot == root)
        #expect(matches.matchedHashes == [t2])
    }

    @Test("Unused trailing flag bytes are rejected")
    func trailingFlagBytesRejected() {
        let txid = Data(repeating: 0x11, count: 32)
        let block = merkleBlock(root: txid, totalTransactions: 1, hashes: [txid], flags: [0x01, 0x00])

        #expect(throws: MerkleBlockError.invalidProof) {
            _ = try block.extractMatches()
        }
    }

    @Test("More hashes than transactions are rejected")
    func tooManyHashesRejected() {
        let txid = Data(repeating: 0x11, count: 32)
        let block = merkleBlock(root: txid, totalTransactions: 1, hashes: [txid, txid], flags: [0x01])

        #expect(throws: MerkleBlockError.invalidProof) {
            _ = try block.extractMatches()
        }
    }

    @Test("Absurd transaction counts are rejected")
    func absurdTransactionCountRejected() {
        let txid = Data(repeating: 0x11, count: 32)
        let block = merkleBlock(root: txid, totalTransactions: .max, hashes: [txid], flags: [0x01])

        #expect(throws: MerkleBlockError.invalidTransactionCount) {
            _ = try block.extractMatches()
        }
    }
}

@Suite("LRU Cache")
struct LRUCacheTests {

    @Test("The least recently used entry is evicted first")
    func evictionOrder() {
        let cache = LRUCache<String, Int>(capacity: 3)
        cache.set("a", 1)
        cache.set("b", 2)
        cache.set("c", 3)

        #expect(cache.get("a") == 1) // "a" is now the most recent
        cache.set("d", 4)            // evicts "b"

        #expect(!cache.contains("b"))
        #expect(cache.contains("a"))
        #expect(cache.contains("c"))
        #expect(cache.contains("d"))
        #expect(cache.count == 3)
    }

    @Test("Updating a key refreshes it and keeps one entry")
    func updateRefreshes() {
        let cache = LRUCache<String, Int>(capacity: 2)
        cache.set("a", 1)
        cache.set("b", 2)
        cache.set("a", 10) // "b" is now the oldest
        cache.set("c", 3)

        #expect(cache.get("a") == 10)
        #expect(!cache.contains("b"))
        #expect(cache.count == 2)
    }

    @Test("Removed slots are reused without evicting live entries")
    func removalFreesSlot() {
        let cache = LRUCache<Int, String>(capacity: 2)
        cache.set(1, "one")
        cache.set(2, "two")
        #expect(cache.remove(1) == "one")

        cache.set(3, "three")
        #expect(cache.contains(2))
        #expect(cache.contains(3))
        #expect(cache.count == 2)

        cache.clear()
        #expect(cache.isEmpty)
        cache.set(4, "four")
        #expect(cache.get(4) == "four")
    }

    @Test("Heavy churn keeps exactly the newest entries")
    func churn() {
        let cache = LRUCache<Int, Int>(capacity: 100)
        for value in 0..<10_000 {
            cache.set(value, value)
        }
        #expect(cache.count == 100)
        #expect((9_900..<10_000).allSatisfy { cache.contains($0) })
        #expect(!cache.contains(9_899))
    }

    @Test("A non-positive capacity is treated as one instead of crashing")
    func zeroCapacity() {
        let cache = LRUCache<Int, Int>(capacity: 0)
        cache.set(1, 1)
        cache.set(2, 2)
        #expect(cache.maxCapacity == 1)
        #expect(cache.get(2) == 2)
        #expect(!cache.contains(1))
    }
}

@Suite("Fee Estimation Bounds")
struct FeeEstimationBoundsTests {

    @Test("Negative counts and sizes cannot trap")
    func negativeInputs() {
        #expect(FeeEstimation.estimateTransactionSize(inputCount: -5, outputCount: -5) == 10)
        #expect(FeeEstimation.calculateFee(sizeBytes: -100, feePerKB: FeeEstimation.standardFeePerKB) == FeeEstimation.minimumFee)
    }

    @Test("Huge counts saturate instead of overflowing")
    func hugeInputs() {
        #expect(FeeEstimation.estimateTransactionSize(inputCount: .max, outputCount: 1) == .max)
        #expect(FeeEstimation.calculateFee(sizeBytes: .max, feePerKB: DogecoinAmount(koinu: .max)).koinu == .max)
    }

    @Test("Amount strings are exact for every koinu value")
    func exactAmountStrings() {
        #expect(DogecoinAmount(koinu: 0).dogeString == "0.00000000")
        #expect(DogecoinAmount(koinu: 5).dogeString == "0.00000005")
        #expect(DogecoinAmount(koinu: 123_456_789).dogeString == "1.23456789")
        #expect(DogecoinAmount(koinu: .max).dogeString == "184467440737.09551615")
    }
}

/// Peer discovery against the real network. Opt-in: `DOGECOINKIT_LIVE_P2P=1`.
@Suite("Live Peer Discovery")
struct LivePeerDiscoveryTests {

    @Test("DNS seeds resolve and peers complete the handshake", .enabled(if: TestEnvironment.runsLiveP2PTests))
    func discoversPeers() async throws {
        let manager = PeerManager(network: .mainnet)
        await manager.start()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline, await manager.connectedPeerCount == 0 {
            try await Task.sleep(for: .milliseconds(250))
        }

        let connected = await manager.connectedPeerCount
        await manager.stop()
        #expect(connected > 0)
    }
}

@Suite("Raw Transaction Decoding")
struct RawTransactionDecodingTests {

    /// A signed legacy transaction and its txid (see TransactionBuilderTests).
    private let legacyHex = "01000000011111111111111111111111111111111111111111111111111111111111111111000000006a47304402207dcae7af58ee36f5009be8116789059537dd1df584991da975faf5e8847cee910220592dd634d3e09d86fe345b2bc359790695caf33d51407ca400e76c2ef608ec95012102cc6b0dc33aabcf3a23643e5e2919a80c50fb3dd2129ce409bbc5f0d4643d05e0ffffffff0280b2e60e000000001976a91457b5ed84d604e95a2c79f37cebc54efbbcfa52fc88ac403e5b2b000000001976a91419115174dcc75cce4802aaec82e63b491274c2e288ac00000000"
    private let legacyTxid = "1d5b76ec494479fdfe70c657d0359e22c7aac8a2550e7a62b513fe3a2ecf0524"

    /// The legacy transaction in BIP 144 form with a two-item witness.
    private func witnessSerialization() throws -> Data {
        let legacy = try #require(Data(hexString: legacyHex))
        var data = Data(legacy.prefix(4))
        data.append(contentsOf: [0x00, 0x01])
        data.append(legacy.dropFirst(4).dropLast(4))
        data.append(contentsOf: [0x02, 0x01, 0xAA, 0x02, 0xBB, 0xCC])
        data.append(legacy.suffix(4))
        return data
    }

    @Test("A legacy transaction re-serializes to its own bytes and txid")
    func legacyRoundTrip() throws {
        let legacy = try #require(Data(hexString: legacyHex))
        let transaction = try #require(RawTransaction(data: legacy))

        #expect(!transaction.hasWitness)
        #expect(transaction.inputs.count == 1)
        #expect(transaction.outputs.map(\.value) == [250_000_000, 727_400_000])
        #expect(transaction.strippedData == legacy)
        #expect(Data(transaction.txid.reversed()).hexString == legacyTxid)
    }

    @Test("Witness data is decoded and left out of the txid")
    func witnessDecoding() throws {
        let transaction = try #require(RawTransaction(data: try witnessSerialization()))
        let legacy = try #require(RawTransaction(hex: legacyHex))

        #expect(transaction.hasWitness)
        #expect(transaction.inputs.first?.witness == [Data([0xAA]), Data([0xBB, 0xCC])])
        #expect(transaction.outputs == legacy.outputs)
        #expect(transaction.txid == legacy.txid)
    }

    @Test("Unknown optional data, truncation, and trailing bytes are rejected")
    func malformedWitnessForms() throws {
        var unknownFlag = try witnessSerialization()
        unknownFlag[5] = 0x03
        #expect(RawTransaction(data: unknownFlag) == nil)

        let truncated = try witnessSerialization().dropLast(6)
        #expect(RawTransaction(data: Data(truncated)) == nil)

        let trailing = try witnessSerialization() + Data([0x00])
        #expect(RawTransaction(data: trailing) == nil)
    }

    @Test("An empty input list with a zero flag reads as Core reads it")
    func emptyTransaction() throws {
        let transaction = try #require(RawTransaction(data: Data([1, 0, 0, 0, 0x00, 0x00, 0, 0, 0, 0])))
        #expect(transaction.inputs.isEmpty)
        #expect(transaction.outputs.isEmpty)
        #expect(!transaction.hasWitness)
    }
}

@Suite("Block Version Rules")
struct BlockVersionRuleTests {

    private func header(version: Int32) -> BlockHeader {
        BlockHeader(version: version, prevBlock: Data(count: 32), merkleRoot: Data(count: 32), timestamp: 1, bits: 0x1e0fffff, nonce: 0)
    }

    private let rules = ProofOfWorkRules.mainnet

    @Test("Merge-mined versions start, and legacy versions stop, at the AuxPoW height")
    func mergeMiningActivation() {
        #expect(rules.allowsVersion(of: header(version: 1), atHeight: 371_336))
        #expect(!rules.allowsVersion(of: header(version: 1), atHeight: 371_337))
        #expect(!rules.allowsVersion(of: header(version: 0x0062_0104), atHeight: 371_336))
        #expect(rules.allowsVersion(of: header(version: 0x0062_0104), atHeight: 371_337))
        #expect(rules.allowsVersion(of: header(version: 0x0062_0004), atHeight: 400_000))
    }

    @Test("Foreign chain IDs are rejected on mainnet")
    func strictChainID() {
        #expect(!rules.allowsVersion(of: header(version: 0x0063_0104), atHeight: 400_000))
        #expect(ProofOfWorkRules.testnet.allowsVersion(of: header(version: 0x0063_0104), atHeight: 400_000))
    }

    @Test("BIP 66 and BIP 65 raise the minimum base version")
    func softForkVersions() {
        #expect(rules.meetsSoftForkVersion(of: header(version: 2), atHeight: 1_034_382))
        #expect(!rules.meetsSoftForkVersion(of: header(version: 2), atHeight: 1_034_383))
        #expect(rules.meetsSoftForkVersion(of: header(version: 0x0062_0103), atHeight: 3_464_750))
        #expect(!rules.meetsSoftForkVersion(of: header(version: 0x0062_0103), atHeight: 3_464_751))
        #expect(rules.meetsSoftForkVersion(of: header(version: 0x0062_0104), atHeight: 6_000_000))
        #expect(!rules.meetsSoftForkVersion(of: header(version: -4), atHeight: 6_000_000))
    }

    @Test("HeaderChain rejects a merge-mined header before merged mining began")
    func earlyAuxPoWRejected() async throws {
        let directory = TestDirectories.unique()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let chain = HeaderChain(network: .mainnet, storageDirectory: directory)
        await chain.setup()
        let genesis = try #require(await chain.getHeader(height: 0))

        let early = BlockHeader(version: 0x0062_0104, prevBlock: genesis.header.hash, merkleRoot: Data(count: 32), timestamp: genesis.header.timestamp + 60, bits: 0x1e0ffff0, nonce: 0)
        let result = await chain.addHeaders([HeadersMessage.Entry(header: early, auxpow: nil)])

        #expect(result.added == 0)
        guard case .invalidVersion(height: 1, _) = result.failure else {
            Issue.record("expected invalidVersion, got \(String(describing: result.failure))")
            return
        }
    }
}

@Suite("Header Ban Policy")
struct HeaderBanPolicyTests {

    @Test("Failures Core does not penalize never get a peer banned")
    func sparedFailures() {
        let spared: [HeaderChain.ValidationError] = [
            .invalidPreviousBlock,
            .databaseError(HeaderDatabaseError.databaseNotOpen),
            .futureTooFar(timestamp: .max),
            .invalidTimestamp(timestamp: 0),
            .obsoleteVersion(height: 6_000_000, version: 2),
        ]
        for failure in spared {
            #expect(!SPVSyncManager.isBannable(failure), "\(failure) should not ban")
        }
    }

    @Test("Consensus violations get a peer banned")
    func bannedFailures() {
        let banned: [HeaderChain.ValidationError] = [
            .checkpointMismatch(height: 0, expected: "a", got: "b"),
            .invalidProofOfWork(hash: "a", target: "b"),
            .invalidDifficulty(bits: 0),
            .auxPowRequired(height: 6_000_000),
            .auxPowValidationFailed(.invalidCoinbaseMerkleProof),
            .forkBelowCheckpoint(height: 1),
            .incorrectDifficulty(height: 1, bits: 1, expected: 2),
            .invalidVersion(height: 1, version: 1),
        ]
        for failure in banned {
            #expect(SPVSyncManager.isBannable(failure), "\(failure) should ban")
        }
    }
}
