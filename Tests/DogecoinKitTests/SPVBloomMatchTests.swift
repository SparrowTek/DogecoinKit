import Foundation
import Testing
@testable import DogecoinKit

@Suite("SPV Bloom Match + Progress")
struct SPVBloomMatchTests {

    // MARK: - Helpers

    /// Build a minimal 1-in/1-out P2PKH transaction for bloom-match testing.
    /// - Parameters:
    ///   - prevTxid: 32-byte previous txid (natural / internal order)
    ///   - vout: output index of the input
    ///   - pubkeyHash: 20-byte pubkey hash for the output
    /// - Returns: Serialized raw tx bytes.
    private func makeP2PKHTx(prevTxid: Data, vout: UInt32, pubkeyHash: Data) -> Data {
        precondition(prevTxid.count == 32)
        precondition(pubkeyHash.count == 20)

        var data = Data()

        // version = 1 (LE)
        var version: UInt32 = 1
        data.append(Data(bytes: &version, count: 4))

        // 1 input
        data.append(0x01) // varint input count

        // prev txid
        data.append(prevTxid)
        // vout (LE)
        var voutLE = vout.littleEndian
        data.append(Data(bytes: &voutLE, count: 4))
        // empty scriptSig
        data.append(0x00)
        // sequence
        data.append(contentsOf: [0xff, 0xff, 0xff, 0xff])

        // 1 output
        data.append(0x01) // varint output count
        // value = 100_000_000 koinu (LE)
        var value: UInt64 = 100_000_000
        data.append(Data(bytes: &value, count: 8))
        // scriptPubKey: 76 a9 14 <20> 88 ac (25 bytes)
        data.append(0x19) // varint script length
        data.append(0x76) // OP_DUP
        data.append(0xa9) // OP_HASH160
        data.append(0x14) // push 20
        data.append(pubkeyHash)
        data.append(0x88) // OP_EQUALVERIFY
        data.append(0xac) // OP_CHECKSIG

        // locktime
        data.append(contentsOf: [0, 0, 0, 0])

        return data
    }

    private func makeBloomFilter(inserting elements: [Data]) -> BloomFilter {
        var filter = BloomFilter(
            elementCount: max(1, elements.count),
            falsePositiveRate: 0.0001,
            tweak: 0,
            flags: 0
        )
        for element in elements {
            filter.insert(element)
        }
        return filter
    }

    // MARK: - transactionMatchesBloomFilter

    @Test("Filter matching the output pubkey hash accepts the tx")
    func testMatchesOnPubkeyHashPush() {
        let pubkeyHash = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        let prevTxid = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        let tx = makeP2PKHTx(prevTxid: prevTxid, vout: 0, pubkeyHash: pubkeyHash)
        let filter = makeBloomFilter(inserting: [pubkeyHash])

        #expect(SPVSyncManager.transactionMatchesBloomFilter(tx, filter: filter))
    }

    @Test("Filter matching the full output scriptPubKey accepts the tx")
    func testMatchesOnFullScriptPubKey() {
        let pubkeyHash = Data(repeating: 0xAB, count: 20)
        let prevTxid = Data(repeating: 0x01, count: 32)
        let tx = makeP2PKHTx(prevTxid: prevTxid, vout: 0, pubkeyHash: pubkeyHash)

        var scriptPubKey = Data()
        scriptPubKey.append(0x76) // OP_DUP
        scriptPubKey.append(0xa9) // OP_HASH160
        scriptPubKey.append(0x14)
        scriptPubKey.append(pubkeyHash)
        scriptPubKey.append(0x88)
        scriptPubKey.append(0xac)

        let filter = makeBloomFilter(inserting: [scriptPubKey])

        #expect(SPVSyncManager.transactionMatchesBloomFilter(tx, filter: filter))
    }

    @Test("Filter matching the input outpoint accepts the tx")
    func testMatchesOnOutpoint() {
        let pubkeyHash = Data(repeating: 0xCD, count: 20)
        let prevTxid = Data(repeating: 0x42, count: 32)
        let vout: UInt32 = 5
        let tx = makeP2PKHTx(prevTxid: prevTxid, vout: vout, pubkeyHash: pubkeyHash)

        // Outpoint as transmitted in the raw tx: prev-txid (internal) ‖ vout LE
        var outpoint = prevTxid
        var voutLE = vout.littleEndian
        outpoint.append(Data(bytes: &voutLE, count: 4))

        let filter = makeBloomFilter(inserting: [outpoint])

        #expect(SPVSyncManager.transactionMatchesBloomFilter(tx, filter: filter))
    }

    @Test("Unrelated filter rejects the tx")
    func testRejectsUnrelatedFilter() {
        let txPubkeyHash = Data(repeating: 0x11, count: 20)
        let tx = makeP2PKHTx(
            prevTxid: Data(repeating: 0x22, count: 32),
            vout: 0,
            pubkeyHash: txPubkeyHash
        )

        // Filter loaded with an unrelated pubkey hash / outpoint — no match.
        let unrelated = Data(repeating: 0xFF, count: 20)
        let filter = makeBloomFilter(inserting: [unrelated])

        #expect(!SPVSyncManager.transactionMatchesBloomFilter(tx, filter: filter))
    }

    @Test("Malformed raw tx is rejected rather than crashing")
    func testMalformedTxRejected() {
        let filter = makeBloomFilter(inserting: [Data(repeating: 0xAA, count: 20)])

        // Version byte only — nothing else — any parse must bail out as false.
        let truncated = Data([0x01, 0x00, 0x00, 0x00])
        #expect(!SPVSyncManager.transactionMatchesBloomFilter(truncated, filter: filter))

        #expect(!SPVSyncManager.transactionMatchesBloomFilter(Data(), filter: filter))
    }

    // MARK: - computeProgress

    @Test("Progress is zero when target height is zero")
    func testProgressZeroTarget() {
        #expect(SPVSyncManager.computeProgress(height: 0, target: 0) == 0)
        #expect(SPVSyncManager.computeProgress(height: 500, target: 0) == 0)
    }

    @Test("Progress is ratio in the normal range")
    func testProgressRatio() {
        let value = SPVSyncManager.computeProgress(height: 500, target: 1000)
        #expect(value == 0.5)
    }

    @Test("Progress clamps at 1.0 when height overshoots the snapshot target")
    func testProgressClampsHigh() {
        // A snapshot where chain height has moved past target between reads.
        let value = SPVSyncManager.computeProgress(height: 1500, target: 1000)
        #expect(value == 1.0)
    }

    @Test("Progress clamps at 0.0 for negative height")
    func testProgressClampsLow() {
        let value = SPVSyncManager.computeProgress(height: -10, target: 1000)
        #expect(value == 0.0)
    }
}
