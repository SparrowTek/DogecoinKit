import Foundation
import DogecoinKitShims

/// Dogecoin's proof-of-work consensus rules for one network, ported from
/// Dogecoin Core's `pow.cpp`, `dogecoin.cpp`, and chain parameters.
struct ProofOfWorkRules: Sendable {
    /// The easiest target any block may claim (`consensus.powLimit`).
    let powLimit: UInt256

    /// First height retargeted every block by DigiShield.
    let digishieldHeight: Int32

    /// First height that must be merge-mined; legacy versions are rejected
    /// from here on.
    let auxPowStartHeight: Int32

    /// Whether every non-legacy block version must carry Dogecoin's chain ID.
    let requiresStrictChainID: Bool

    /// First height requiring base version 3 (BIP 66).
    let bip66Height: Int32

    /// First height requiring base version 4 (BIP 65).
    let bip65Height: Int32

    /// Whether `nBits` must match `GetNextWorkRequired` and block versions
    /// must follow the chain-ID, merge-mining, and soft-fork rules.
    ///
    /// The mainnet port has been replayed against every header of the real
    /// chain. Testnet's minimum-difficulty rules have not, so testnet blocks
    /// are only held to the target they claim.
    let enforcesContextualRules: Bool

    /// Dogecoin's merged-mining chain ID.
    static let auxPowChainID: UInt32 = 0x0062

    /// One block a minute.
    static let targetSpacing: Int64 = 60

    /// `0x00000fff…ff`: every hash with at least 20 leading zero bits.
    private static let standardPowLimit = UInt256.max >> 20

    static let mainnet = ProofOfWorkRules(
        powLimit: standardPowLimit,
        digishieldHeight: 145_000,
        auxPowStartHeight: 371_337,
        requiresStrictChainID: true,
        bip66Height: 1_034_383,
        bip65Height: 3_464_751,
        enforcesContextualRules: true
    )

    static let testnet = ProofOfWorkRules(
        powLimit: standardPowLimit,
        digishieldHeight: 145_000,
        auxPowStartHeight: 158_100,
        requiresStrictChainID: false,
        bip66Height: 708_658,
        bip65Height: 1_854_705,
        enforcesContextualRules: false
    )

    static func rules(for network: DogecoinNetwork) -> ProofOfWorkRules {
        switch network {
        case .mainnet: .mainnet
        case .testnet: .testnet
        }
    }

    /// Decodes `bits`, returning the target only if Core would accept it:
    /// not negative, not overflowing, not zero, and no easier than `powLimit`.
    func target(forBits bits: UInt32) -> UInt256? {
        guard let target = UInt256(compact: bits), target != .zero, target <= powLimit else {
            return nil
        }
        return target
    }

    /// The expected number of hashes to find a block at `target` — Core's
    /// `GetBlockProof`, `2²⁵⁶ / (target + 1)`, computed without overflowing.
    static func work(forTarget target: UInt256) -> UInt256 {
        (~target / (target &+ .one)) &+ .one
    }

    /// The `nBits` the block after `parent` must carry — Core's
    /// `GetNextWorkRequired` with Dogecoin's DigiShield retargeting.
    /// - Parameters:
    ///   - parent: The block being built on.
    ///   - ancestor: Looks up the header at a height on `parent`'s branch.
    /// - Returns: `nil` if an ancestor the rule needs is unavailable.
    func requiredBits(after parent: StoredHeader, ancestor: (Int32) -> StoredHeader?) -> UInt32? {
        let height = parent.height + 1
        let timespan = targetTimespan(atHeight: height)
        let interval = Int32(timespan / Self.targetSpacing)

        // Only change once per difficulty adjustment interval.
        guard height % interval == 0 else {
            return parent.header.bits
        }

        // Litecoin's fix: go back the full period, except at the first
        // retarget after genesis.
        let blocksToGoBack = height == interval ? interval - 1 : interval
        guard let first = ancestor(parent.height - blocksToGoBack) else {
            return nil
        }

        return nextWorkRequired(
            lastBits: parent.header.bits,
            lastTime: parent.header.timestamp,
            firstTime: first.header.timestamp,
            height: height
        )
    }

    /// Core's `CalculateDogecoinNextWorkRequired`.
    private func nextWorkRequired(lastBits: UInt32, lastTime: UInt32, firstTime: UInt32, height: Int32) -> UInt32? {
        let timespan = targetTimespan(atHeight: height)
        let actualTimespan = Int64(lastTime) - Int64(firstTime)

        var modulatedTimespan = actualTimespan
        let minimumTimespan: Int64
        let maximumTimespan: Int64

        if height >= digishieldHeight {
            // DigiShield's amplitude filter; integer division truncates
            // toward zero, exactly like C++.
            modulatedTimespan = timespan + (actualTimespan - timespan) / 8
            minimumTimespan = timespan - timespan / 4
            maximumTimespan = timespan + timespan / 2
        } else if height > 10_000 {
            minimumTimespan = timespan / 4
            maximumTimespan = timespan * 4
        } else if height > 5_000 {
            minimumTimespan = timespan / 8
            maximumTimespan = timespan * 4
        } else {
            minimumTimespan = timespan / 16
            maximumTimespan = timespan * 4
        }
        modulatedTimespan = Swift.min(Swift.max(modulatedTimespan, minimumTimespan), maximumTimespan)

        guard let lastTarget = UInt256(compact: lastBits) else {
            return nil
        }

        var target = (lastTarget &* UInt64(modulatedTimespan)) / UInt64(timespan)
        if target > powLimit {
            target = powLimit
        }
        return target.compact
    }

    /// Core's chain-ID and merge-mining activation rules: a non-legacy
    /// version carries Dogecoin's chain ID, merge-mined blocks only appear
    /// from the AuxPoW start, and legacy versions only before it.
    func allowsVersion(of header: BlockHeader, atHeight height: Int32) -> Bool {
        if requiresStrictChainID, !header.isLegacy, header.chainID != Self.auxPowChainID {
            return false
        }
        return height >= auxPowStartHeight ? !header.isLegacy : !header.isAuxPoW
    }

    /// Whether the base version is new enough for the soft forks active at
    /// `height`: 3 from BIP 66 on, 4 from BIP 65 on. Dogecoin never enforced
    /// BIP 34's version 2.
    func meetsSoftForkVersion(of header: BlockHeader, atHeight height: Int32) -> Bool {
        if height >= bip65Height {
            return header.baseVersion >= 4
        }
        if height >= bip66Height {
            return header.baseVersion >= 3
        }
        return true
    }

    /// Four hours before DigiShield (retargeting every 240 blocks), one
    /// minute after it (retargeting every block).
    private func targetTimespan(atHeight height: Int32) -> Int64 {
        height >= digishieldHeight ? 60 : 4 * 60 * 60
    }
}

extension BlockHeader {
    /// Dogecoin's proof-of-work hash — scrypt over the 80-byte header — as a
    /// number, or `nil` if the header does not serialize to 80 bytes.
    var scryptHashValue: UInt256? {
        let serialized = [UInt8](serializeCore())
        guard serialized.count == Self.size else { return nil }

        var hash = [UInt8](repeating: 0, count: 32)
        serialized.withUnsafeBufferPointer { input in
            hash.withUnsafeMutableBufferPointer { output in
                dogecoinkit_scrypt_pow_hash(input.baseAddress, output.baseAddress)
            }
        }

        // libdogecoin writes display (big-endian) order.
        return UInt256(littleEndian: Data(hash.reversed()))
    }

    /// The version without its merged-mining bits (Core's `GetBaseVersion`).
    /// Like C++, `%` keeps the sign, so a negative version stays below every
    /// soft-fork minimum.
    var baseVersion: Int32 {
        version % 0x100
    }

    /// The merged-mining chain ID carried in the top 16 version bits.
    var chainID: UInt32 {
        UInt32(bitPattern: version) >> 16
    }

    /// Whether the version flags an attached AuxPoW proof.
    var isAuxPoW: Bool {
        AuxPoW.isAuxPow(version: version)
    }

    /// Pre-merged-mining version: 1, or Dogecoin's one stray version 2
    /// without a chain ID (Core's `IsLegacy`).
    var isLegacy: Bool {
        version == 1 || (version == 2 && chainID == 0)
    }
}
