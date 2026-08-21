import Foundation
import Testing
@testable import DogecoinKit

/// Regression tests for the remote-crash (DoS) surface in the message parsers.
///
/// Every VarInt count or length in a network message is attacker-controlled.
/// Before hardening, several parsers did `Int(count)` / `count * 32` /
/// `reserveCapacity(Int(count))` on those values *before* bounds-checking —
/// `Int(UInt64 > Int.max)` traps in Swift, so a tiny hostile payload could
/// crash the app during SPV sync. These tests feed exactly those payload
/// shapes and expect a nil parse instead of a crash.
@Suite("Untrusted Input Hardening")
struct UntrustedInputHardeningTests {

    /// 0xFF-prefixed VarInt carrying UInt64.max
    private var maxVarInt: Data {
        var data = Data([0xFF])
        var value = UInt64.max.littleEndian
        data.append(Data(bytes: &value, count: 8))
        return data
    }

    /// 0xFF-prefixed VarInt carrying an arbitrary UInt64
    private func varInt(_ value: UInt64) -> Data {
        VarInt(value).serialize()
    }

    /// An 80-byte header with the AuxPoW version bit set
    private var auxPowHeaderBytes: Data {
        var data = Data()
        var version = Int32(0x620102).littleEndian // AuxPoW flag (0x100) set
        data.append(Data(bytes: &version, count: 4))
        data.append(Data(repeating: 0xAA, count: 32)) // prevBlock
        data.append(Data(repeating: 0xBB, count: 32)) // merkleRoot
        data.append(Data(repeating: 0, count: 12))    // timestamp + bits + nonce
        return data
    }

    // MARK: - Data helpers

    @Test("Bounded count rejects values the buffer cannot hold")
    func boundedCountRejectsOversized() {
        var data = maxVarInt
        data.append(Data(repeating: 0, count: 64))

        #expect(data.readBoundedCount(at: 0, minItemSize: 32) == nil)
        #expect(data.readBoundedLength(at: 0) == nil)

        // A count that fits parses normally
        var ok = varInt(2)
        ok.append(Data(repeating: 0, count: 64))
        let parsed = ok.readBoundedCount(at: 0, minItemSize: 32)
        #expect(parsed?.count == 2)
        #expect(parsed?.varIntSize == 1)
    }

    @Test("Bounded length accounts for trailing fixed bytes")
    func boundedLengthTrailing() {
        // 10 remaining bytes: length 6 + trailing 4 fits, length 7 does not
        var data = varInt(6)
        data.append(Data(repeating: 0, count: 10))
        #expect(data.readBoundedLength(at: 0, trailing: 4) != nil)

        var tooBig = varInt(7)
        tooBig.append(Data(repeating: 0, count: 10))
        #expect(tooBig.readBoundedLength(at: 0, trailing: 4) == nil)
    }

    // MARK: - HeadersMessage

    @Test("Headers message with huge merkle-branch count does not crash")
    func headersMessageHostileBranchCount() {
        // header (auxpow flag) + minimal coinbase tx + 32-byte hash + hostile branch VarInt
        var data = varInt(1) // header count
        data.append(auxPowHeaderBytes)

        // Minimal fake coinbase: version + 0 inputs + 0 outputs + locktime
        data.append(Data([0, 0, 0, 1])) // version
        data.append(varInt(0))          // input count
        data.append(varInt(0))          // output count
        data.append(Data([0, 0, 0, 0])) // locktime

        data.append(Data(repeating: 0xCC, count: 32)) // parent block hash
        data.append(maxVarInt)                        // hostile merkle branch length

        #expect(HeadersMessage.parse(from: data) == nil)
    }

    @Test("Headers message with huge script length does not crash")
    func headersMessageHostileScriptLength() {
        var data = varInt(1) // header count
        data.append(auxPowHeaderBytes)

        // Coinbase with one input whose script length is hostile
        data.append(Data([0, 0, 0, 1]))               // version
        data.append(varInt(1))                        // input count
        data.append(Data(repeating: 0, count: 36))    // prevout
        data.append(maxVarInt)                        // hostile script length

        #expect(HeadersMessage.parse(from: data) == nil)
    }

    @Test("Headers message with huge header count does not crash")
    func headersMessageHostileHeaderCount() {
        var data = maxVarInt
        data.append(Data(repeating: 0, count: 200))
        #expect(HeadersMessage.parse(from: data) == nil)
    }

    // MARK: - MerkleBlockMessage

    @Test("Merkle block with hostile hash count does not crash or over-allocate")
    func merkleBlockHostileHashCount() {
        var data = Data()
        var version = Int32(2).littleEndian // no auxpow flag
        data.append(Data(bytes: &version, count: 4))
        data.append(Data(repeating: 0, count: 76)) // rest of header
        data.append(Data([1, 0, 0, 0]))            // totalTransactions
        data.append(maxVarInt)                     // hostile hash count

        #expect(MerkleBlockMessage.parse(from: data) == nil)
    }

    @Test("Merkle block with hostile auxpow branch count does not crash")
    func merkleBlockHostileAuxPowBranch() {
        var data = auxPowHeaderBytes

        // Minimal coinbase tx
        data.append(Data([0, 0, 0, 1])) // version
        data.append(varInt(0))          // inputs
        data.append(varInt(0))          // outputs
        data.append(Data([0, 0, 0, 0])) // locktime

        data.append(Data(repeating: 0, count: 32)) // hashBlock
        data.append(maxVarInt)                     // hostile coinbase branch count

        #expect(MerkleBlockMessage.parse(from: data) == nil)
    }

    @Test("Merkle block with hostile flag length does not crash")
    func merkleBlockHostileFlagLength() {
        var data = Data()
        var version = Int32(2).littleEndian
        data.append(Data(bytes: &version, count: 4))
        data.append(Data(repeating: 0, count: 76))
        data.append(Data([1, 0, 0, 0])) // totalTransactions
        data.append(varInt(1))          // one hash
        data.append(Data(repeating: 0xDD, count: 32))
        data.append(maxVarInt)          // hostile flag byte count

        #expect(MerkleBlockMessage.parse(from: data) == nil)
    }

    // MARK: - BlockMessage (reachable via unsolicited `block` message)

    @Test("Block message with hostile transaction count does not crash")
    func blockMessageHostileTxCount() {
        var data = Data()
        var version = Int32(2).littleEndian
        data.append(Data(bytes: &version, count: 4))
        data.append(Data(repeating: 0, count: 76))
        data.append(maxVarInt) // hostile tx count

        #expect(BlockMessage.parse(from: data) == nil)
    }

    @Test("Block message with hostile auxpow script length does not crash")
    func blockMessageHostileAuxPowScript() {
        var data = auxPowHeaderBytes

        // Coinbase tx with hostile input script length
        data.append(Data([0, 0, 0, 1]))            // version
        data.append(varInt(1))                     // input count
        data.append(Data(repeating: 0, count: 36)) // prevout
        data.append(maxVarInt)                     // hostile script length

        #expect(BlockMessage.parse(from: data) == nil)
    }

    @Test("Transaction parser rejects hostile witness item lengths")
    func transactionParserHostileWitness() {
        var data = Data()
        data.append(Data([0, 0, 0, 1])) // version
        data.append(Data([0x00, 0x01])) // segwit marker + flag
        data.append(varInt(1))          // input count
        data.append(Data(repeating: 0, count: 36)) // prevout
        data.append(varInt(0))          // empty script
        data.append(Data([0, 0, 0, 0])) // sequence
        data.append(varInt(0))          // output count
        data.append(varInt(1))          // witness stack count
        data.append(maxVarInt)          // hostile item length

        var offset = 0
        #expect(TransactionParser.parseTransaction(from: data, offset: &offset) == nil)
    }

    // MARK: - SPV bloom matching

    @Test("Bloom matching rejects hostile script lengths instead of trapping")
    func bloomMatchHostileScript() {
        let filter = BloomFilter(elementCount: 10, falsePositiveRate: 0.001, tweak: 0)

        var raw = Data()
        raw.append(Data([0, 0, 0, 1]))             // version
        raw.append(varInt(1))                      // input count
        raw.append(Data(repeating: 0, count: 36))  // outpoint
        raw.append(maxVarInt)                      // hostile script length

        #expect(SPVSyncManager.transactionMatchesBloomFilter(raw, filter: filter) == false)
    }

    // MARK: - AuxPoW division guard

    @Test("AuxPoW validation rejects 32+ element chain branches instead of dividing by zero")
    func auxPowChainBranchShiftGuard() {
        // A 32-element chain merkle branch used to make `1 << 32 == 0` (UInt32
        // smart shift) and trap on the chain-ID division inside validate().
        let branch = Array(repeating: Data(repeating: 0xEE, count: 32), count: 32)

        // Coinbase embedding the AuxPoW magic so validation reaches the
        // chain-ID step: version + 1 input (35-byte script with magic+root+size+nonce) + 0 outputs + locktime
        var script = Data([0xFA, 0xBE, 0x6D, 0x6D])   // magic
        script.append(Data(repeating: 0x11, count: 32)) // merkle root
        script.append(Data([1, 0, 0, 0]))               // merkle size
        script.append(Data([0, 0, 0, 0]))               // merkle nonce

        var coinbase = Data([1, 0, 0, 0])               // version
        coinbase.append(VarInt(1).serialize())          // input count
        coinbase.append(Data(repeating: 0, count: 36))  // prevout
        coinbase.append(VarInt(UInt64(script.count)).serialize())
        coinbase.append(script)
        coinbase.append(Data([0xFF, 0xFF, 0xFF, 0xFF])) // sequence
        coinbase.append(VarInt(0).serialize())          // output count
        coinbase.append(Data([0, 0, 0, 0]))             // locktime

        // Parent header with an impossible-to-fail target (0x207FFFFF is the
        // easiest compact difficulty)
        let parentHeader = BlockHeader(
            version: 1,
            prevBlock: Data(repeating: 0, count: 32),
            merkleRoot: Data(repeating: 0, count: 32),
            timestamp: 0,
            bits: 0x207FFFFF,
            nonce: 0
        )

        let auxpow = AuxPoW(
            coinbaseTx: coinbase,
            parentBlockHash: Data(repeating: 0, count: 32),
            coinbaseMerkleBranch: [],
            coinbaseMerkleIndex: 0,
            chainMerkleBranch: branch,
            chainMerkleIndex: 0,
            parentBlockHeader: parentHeader
        )

        // Must throw a validation error — never trap. (It will fail earlier on
        // the merkle proof, which is fine; the point is it cannot crash.)
        #expect(throws: AuxPoW.ValidationError.self) {
            try auxpow.validate(dogecoinBlockHash: Data(repeating: 0, count: 32))
        }
    }

    // MARK: - Electrum server policy

    @Test("Default Electrum server lists are SSL-only")
    func electrumServersAreSSLOnly() {
        #expect(ElectrumServerList.mainnetServers.allSatisfy { $0.useSSL })
        #expect(ElectrumServerList.testnetServers.allSatisfy { $0.useSSL })
        #expect(!ElectrumServerList.mainnetServers.isEmpty)
        #expect(!ElectrumServerList.testnetServers.isEmpty)
    }
}
