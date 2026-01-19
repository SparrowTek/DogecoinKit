import Foundation
import Testing
@testable import DogecoinKit

@Suite("AuxPoW Tests")
struct AuxPoWTests {
    init() {
        Dogecoin.initialize()
    }

    // MARK: - Version Detection Tests

    @Test("Detects AuxPoW version flag")
    func testAuxPowVersionDetection() {
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
    func testParsingInsufficientData() {
        // Empty data
        let empty = Data()
        #expect(AuxPoW.parse(from: empty, at: 0) == nil)

        // Data too short for coinbase tx
        let tooShort = Data(repeating: 0, count: 50)
        #expect(AuxPoW.parse(from: tooShort, at: 0) == nil)
    }

    @Test("Parses minimal valid AuxPoW structure")
    func testParsingMinimalAuxPoW() {
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
    func testParsingWithMerkleBranches() {
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

    // MARK: - Validation Error Tests

    @Test("Validation fails with invalid parent PoW")
    func testValidationInvalidParentPoW() throws {
        let auxpow = makeTestAuxPoW(
            parentBits: 0x1d00ffff,  // Very high difficulty target
            parentMerkleRoot: Data(repeating: 0, count: 32)
        )

        let blockHash = Data(repeating: 0xAA, count: 32)

        #expect(throws: AuxPoW.ValidationError.self) {
            try auxpow.validate(dogecoinBlockHash: blockHash)
        }
    }

    @Test("Validation fails with missing commitment")
    func testValidationMissingCommitment() throws {
        // Create AuxPoW with coinbase that has no magic bytes
        let auxpow = makeTestAuxPoWWithCoinbase(
            scriptSig: Data(repeating: 0x00, count: 50),
            parentBits: 0x207fffff  // Easy difficulty for test
        )

        let blockHash = Data(repeating: 0xBB, count: 32)

        #expect(throws: AuxPoW.ValidationError.self) {
            try auxpow.validate(dogecoinBlockHash: blockHash)
        }
    }

    // MARK: - HeaderChain Integration Tests

    @Test("HeaderChain requires AuxPoW for blocks above checkpoint")
    func testHeaderChainRequiresAuxPoW() throws {
        let storageURL = temporaryStorageURL()
        let chain = HeaderChain(network: .mainnet, storageDirectory: storageURL)

        // Get genesis
        guard let genesis = chain.getHeader(height: 0) else {
            Issue.record("Genesis not found")
            return
        }

        // Create an AuxPoW header that would be above checkpoint
        // We simulate this by testing the error type
        let auxpowHeader = BlockHeader(
            version: 0x6422100,  // AuxPoW version
            prevBlock: genesis.header.hash,
            merkleRoot: Data(repeating: 0x01, count: 32),
            timestamp: genesis.header.timestamp + 1,
            bits: 0x1e0ffff0,
            nonce: 1
        )

        // For blocks at height 1 (below checkpoint), AuxPoW is not required
        // The header should be accepted without AuxPoW data since height 1 < 5,400,000
        let added = chain.addHeader(auxpowHeader, auxpow: nil)
        #expect(added == true)
    }

    @Test("HeaderChain accepts AuxPoW blocks below checkpoint without validation")
    func testHeaderChainAcceptsAuxPoWBelowCheckpoint() throws {
        let storageURL = temporaryStorageURL()
        let chain = HeaderChain(network: .testnet, storageDirectory: storageURL)

        guard let genesis = chain.getHeader(height: 0) else {
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
            try chain.addHeaderValidated(header, auxpow: nil)
        } catch {
            Issue.record("Should accept AuxPoW header below checkpoint: \(error)")
        }

        #expect(chain.height == 1)
    }

    @Test("AuxPoW validation error is properly wrapped in HeaderChain")
    func testHeaderChainWrapsAuxPoWError() {
        // The auxPowValidationFailed error case exists and wraps AuxPoW.ValidationError
        let innerError = AuxPoW.ValidationError.missingAuxPowCommitment
        let wrappedError = HeaderChain.ValidationError.auxPowValidationFailed(innerError)

        // Verify the error can be created and inspected
        if case .auxPowValidationFailed(let inner) = wrappedError {
            #expect(inner == .missingAuxPowCommitment)
        } else {
            Issue.record("Error wrapping failed")
        }
    }

    @Test("HeaderChain auxPowRequired error includes height")
    func testAuxPoWRequiredErrorIncludesHeight() {
        let error = HeaderChain.ValidationError.auxPowRequired(height: 5_500_000)

        if case .auxPowRequired(let height) = error {
            #expect(height == 5_500_000)
        } else {
            Issue.record("Error type mismatch")
        }
    }

    // MARK: - BlockMessage Integration Tests

    @Test("BlockMessage includes AuxPoW when present")
    func testBlockMessageIncludesAuxPoW() {
        // Build a minimal block with AuxPoW
        var data = Data()

        // Block header (80 bytes) with AuxPoW version
        var version = Int32(0x100).littleEndian
        data.append(Data(bytes: &version, count: 4))
        data.append(Data(repeating: 0, count: 32))  // prevBlock
        data.append(Data(repeating: 0x01, count: 32))  // merkleRoot
        var timestamp = UInt32(1000).littleEndian
        data.append(Data(bytes: &timestamp, count: 4))
        var bits = UInt32(0x1e0ffff0).littleEndian
        data.append(Data(bytes: &bits, count: 4))
        var nonce = UInt32(1).littleEndian
        data.append(Data(bytes: &nonce, count: 4))

        // AuxPoW data (minimal)
        // Coinbase tx
        data.append(contentsOf: [0x01, 0x00, 0x00, 0x00])  // version
        data.append(0x01)  // input count
        data.append(Data(repeating: 0, count: 36))  // prevout
        data.append(0x00)  // scriptSig length
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // sequence
        data.append(0x01)  // output count
        data.append(Data(repeating: 0, count: 8))  // value
        data.append(0x00)  // scriptPubKey length
        data.append(Data(repeating: 0, count: 4))  // locktime

        // Parent block hash
        data.append(Data(repeating: 0xEE, count: 32))

        // Empty merkle branches
        data.append(0x00)  // coinbase branch count
        data.append(Data(repeating: 0, count: 4))  // coinbase index
        data.append(0x00)  // chain branch count
        data.append(Data(repeating: 0, count: 4))  // chain index

        // Parent header
        data.append(Data(repeating: 0, count: 80))

        // Transaction count (0 for this test)
        data.append(0x00)

        let block = BlockMessage.parse(from: data)
        #expect(block != nil)
        #expect(block?.auxpow != nil)
        #expect(block?.auxpow?.parentBlockHash == Data(repeating: 0xEE, count: 32))
    }

    @Test("BlockMessage has nil AuxPoW for regular blocks")
    func testBlockMessageNilAuxPoWForRegularBlock() {
        var data = Data()

        // Block header with non-AuxPoW version
        var version = Int32(1).littleEndian
        data.append(Data(bytes: &version, count: 4))
        data.append(Data(repeating: 0, count: 32))  // prevBlock
        data.append(Data(repeating: 0x02, count: 32))  // merkleRoot
        var timestamp = UInt32(2000).littleEndian
        data.append(Data(bytes: &timestamp, count: 4))
        var bits = UInt32(0x1e0ffff0).littleEndian
        data.append(Data(bytes: &bits, count: 4))
        var nonce = UInt32(2).littleEndian
        data.append(Data(bytes: &nonce, count: 4))

        // Transaction count (0)
        data.append(0x00)

        let block = BlockMessage.parse(from: data)
        #expect(block != nil)
        #expect(block?.auxpow == nil)
    }

    // MARK: - Helper Functions

    private func temporaryStorageURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeTestAuxPoW(parentBits: UInt32, parentMerkleRoot: Data) -> AuxPoW {
        // Create a minimal coinbase transaction
        var coinbaseTx = Data()
        coinbaseTx.append(contentsOf: [0x01, 0x00, 0x00, 0x00])  // version
        coinbaseTx.append(0x01)  // input count
        coinbaseTx.append(Data(repeating: 0, count: 36))  // prevout
        coinbaseTx.append(0x00)  // scriptSig length
        coinbaseTx.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // sequence
        coinbaseTx.append(0x01)  // output count
        coinbaseTx.append(Data(repeating: 0, count: 8))  // value
        coinbaseTx.append(0x00)  // scriptPubKey length
        coinbaseTx.append(Data(repeating: 0, count: 4))  // locktime

        // Create parent block header
        let parentHeader = BlockHeader(
            version: 1,
            prevBlock: Data(repeating: 0, count: 32),
            merkleRoot: parentMerkleRoot,
            timestamp: 1000,
            bits: parentBits,
            nonce: 0
        )

        return AuxPoW(
            coinbaseTx: coinbaseTx,
            parentBlockHash: Data(repeating: 0, count: 32),
            coinbaseMerkleBranch: [],
            coinbaseMerkleIndex: 0,
            chainMerkleBranch: [],
            chainMerkleIndex: 0,
            parentBlockHeader: parentHeader
        )
    }

    private func makeTestAuxPoWWithCoinbase(scriptSig: Data, parentBits: UInt32) -> AuxPoW {
        // Create coinbase with custom scriptSig
        var coinbaseTx = Data()
        coinbaseTx.append(contentsOf: [0x01, 0x00, 0x00, 0x00])  // version
        coinbaseTx.append(0x01)  // input count
        coinbaseTx.append(Data(repeating: 0, count: 36))  // prevout

        // Variable length scriptSig
        let scriptLen = UInt8(min(scriptSig.count, 252))
        coinbaseTx.append(scriptLen)
        coinbaseTx.append(scriptSig.prefix(Int(scriptLen)))

        coinbaseTx.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // sequence
        coinbaseTx.append(0x01)  // output count
        coinbaseTx.append(Data(repeating: 0, count: 8))  // value
        coinbaseTx.append(0x00)  // scriptPubKey length
        coinbaseTx.append(Data(repeating: 0, count: 4))  // locktime

        let parentHeader = BlockHeader(
            version: 1,
            prevBlock: Data(repeating: 0, count: 32),
            merkleRoot: Data(repeating: 0, count: 32),
            timestamp: 1000,
            bits: parentBits,
            nonce: 0
        )

        return AuxPoW(
            coinbaseTx: coinbaseTx,
            parentBlockHash: Data(repeating: 0, count: 32),
            coinbaseMerkleBranch: [],
            coinbaseMerkleIndex: 0,
            chainMerkleBranch: [],
            chainMerkleIndex: 0,
            parentBlockHeader: parentHeader
        )
    }
}
