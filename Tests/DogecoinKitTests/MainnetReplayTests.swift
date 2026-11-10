import Foundation
import Testing
@testable import DogecoinKit

/// Replays a full mainnet header database through the consensus rules.
///
/// Opt-in: set `DOGECOINKIT_MAINNET_HEADERS` to the path of a `headers.sqlite`
/// produced by DogecoinNodeSync. Every real header must satisfy the exact
/// `nBits` `GetNextWorkRequired` demands, the version rules, the target
/// limit, and — for the pre-merged-mining era — its own scrypt proof of work.
@Suite("Mainnet Replay")
struct MainnetReplayTests {

    private var databasePath: String? {
        ProcessInfo.processInfo.environment["DOGECOINKIT_MAINNET_HEADERS"]
    }

    @Test("Every mainnet header satisfies difficulty, version, and work rules")
    func replayMainnet() throws {
        guard let databasePath else { return }

        let database = try HeaderDatabase(path: databasePath)
        let tipHeight = try #require(try database.getTip()).height
        let rules = ProofOfWorkRules.mainnet

        // Rolling window: DigiShield needs one block back, the pre-DigiShield
        // retarget needs 240.
        var window: [Int32: StoredHeader] = [:]
        var chainWork = UInt256.zero
        var verifiedScrypt = 0
        let batchSize: Int32 = 20_000

        var batchStart: Int32 = 0
        while batchStart <= tipHeight {
            let batchEnd = min(batchStart + batchSize - 1, tipHeight)
            let records = try database.getHeaders(fromHeight: batchStart, toHeight: batchEnd)
            try #require(records.count == Int(batchEnd - batchStart + 1), "gap in best chain at \(batchStart)")

            for record in records {
                let stored = record.toStoredHeader()
                let header = stored.header
                let height = stored.height

                let target = try #require(rules.target(forBits: header.bits), "bits \(header.bits) out of range at \(height)")
                chainWork = chainWork &+ ProofOfWorkRules.work(forTarget: target)
                #expect(UInt256(littleEndian: stored.chainWork) == chainWork, "chain work diverges at \(height)")

                if height > 0 {
                    let parent = try #require(window[height - 1])
                    #expect(header.prevBlock == parent.header.hash, "linkage broken at \(height)")

                    let expected = rules.requiredBits(after: parent) { window[$0] }
                    #expect(expected == header.bits, "difficulty mismatch at \(height): \(header.bits) vs \(String(describing: expected))")

                    #expect(rules.allowsVersion(of: header, atHeight: height), "version \(header.version) breaks chain-ID or merge-mining rules at \(height)")
                    #expect(rules.meetsSoftForkVersion(of: header, atHeight: height), "obsolete version \(header.version) at \(height)")
                }

                if !header.isAuxPoW {
                    let hash = try #require(header.scryptHashValue)
                    #expect(hash <= target, "scrypt PoW fails at \(height)")
                    verifiedScrypt += 1
                }

                window[height] = stored
                window.removeValue(forKey: height - 241)
            }

            batchStart = batchEnd + 1
        }

        print("Replayed \(tipHeight + 1) headers; scrypt-verified \(verifiedScrypt) non-AuxPoW headers")
    }
}
