import Foundation

public struct MerkleBlockMessage: Sendable {
    public let header: BlockHeader
    public let totalTransactions: UInt32
    public let hashes: [Data]
    public let flags: Data

    public init(
        header: BlockHeader,
        totalTransactions: UInt32,
        hashes: [Data],
        flags: Data
    ) {
        self.header = header
        self.totalTransactions = totalTransactions
        self.hashes = hashes
        self.flags = flags
    }

    public func serialize() -> Data {
        var data = Data()
        data.append(header.serializeCore())

        var total = totalTransactions.littleEndian
        data.append(Data(bytes: &total, count: 4))

        data.append(VarInt(UInt64(hashes.count)).serialize())
        for hash in hashes {
            data.append(hash)
        }

        data.append(VarInt(UInt64(flags.count)).serialize())
        data.append(flags)
        return data
    }

    public static func parse(from data: Data) -> MerkleBlockMessage? {
        guard let headerBytes = data.bytes(at: 0, count: BlockHeader.size),
              let header = BlockHeader.parse(from: headerBytes) else { return nil }

        var offset = BlockHeader.size

        // Merge-mined blocks carry their AuxPoW between header and tree.
        // The header chain has already checked that proof; here it is only
        // stepped over.
        if header.isAuxPoW {
            guard let treeOffset = AuxPoW.endOffset(in: data, at: offset) else { return nil }
            offset = treeOffset
        }
        guard let totalRaw: UInt32 = data.readInteger(at: offset) else { return nil }
        let totalTransactions = UInt32(littleEndian: totalRaw)
        offset += 4

        // Hash count is peer-supplied — bound it by the remaining bytes before
        // reserving capacity so a fabricated count cannot force a huge allocation.
        guard let (hashCount, hashCountSize) = data.readBoundedCount(at: offset, minItemSize: 32) else { return nil }
        offset += hashCountSize

        var hashes: [Data] = []
        hashes.reserveCapacity(hashCount)
        for _ in 0..<hashCount {
            guard let hash = data.bytes(at: offset, count: 32) else { return nil }
            hashes.append(hash)
            offset += 32
        }

        guard let (flagCount, flagStart) = data.readBoundedLength(at: offset),
              let flags = data.bytes(at: flagStart, count: flagCount) else { return nil }

        return MerkleBlockMessage(
            header: header,
            totalTransactions: totalTransactions,
            hashes: hashes,
            flags: flags
        )
    }

    public func extractMatches() throws -> MerkleBlockMatches {
        let tree = PartialMerkleTree(
            totalTransactions: totalTransactions,
            hashes: hashes,
            flags: flags
        )
        let root = try tree.calculateRoot()
        return MerkleBlockMatches(merkleRoot: root, matchedHashes: tree.matchedHashes)
    }
}

public struct MerkleBlockMatches: Sendable {
    public let merkleRoot: Data
    public let matchedHashes: [Data]
}

public enum MerkleBlockError: Error, Sendable {
    case invalidProof
    case invalidTransactionCount
}

/// Most transactions a block can hold: Dogecoin's 1 MB block size limit
/// divided by the 60-byte minimum transaction size.
private let maximumTransactionsPerBlock: UInt32 = 1_000_000 / 60

private final class PartialMerkleTree {
    private let totalTransactions: UInt32
    private let hashes: [Data]
    private let flags: [UInt8]

    private var bitsUsed = 0
    private var hashesUsed = 0
    private(set) var matchedHashes: [Data] = []

    init(totalTransactions: UInt32, hashes: [Data], flags: Data) {
        self.totalTransactions = totalTransactions
        self.hashes = hashes
        self.flags = [UInt8](flags)
    }

    /// Bitcoin Core's `CPartialMerkleTree::ExtractMatches`, including every
    /// sanity check it makes before trusting the tree.
    func calculateRoot() throws -> Data {
        guard totalTransactions > 0, totalTransactions <= maximumTransactionsPerBlock else {
            throw MerkleBlockError.invalidTransactionCount
        }
        // At most one hash per transaction, and at least one flag bit per hash.
        guard hashes.count <= Int(totalTransactions), flags.count * 8 >= hashes.count else {
            throw MerkleBlockError.invalidProof
        }

        let height = treeHeight
        let root = try traverse(height: height, position: 0)

        // Every hash used, and every flag byte needed — no unused trailing data.
        guard hashesUsed == hashes.count, (bitsUsed + 7) / 8 == flags.count else {
            throw MerkleBlockError.invalidProof
        }

        return root
    }

    private var treeHeight: Int {
        var height = 0
        while treeWidth(height: height) > 1 {
            height += 1
        }
        return height
    }

    private func treeWidth(height: Int) -> Int {
        let total = Int(totalTransactions)
        return (total + (1 << height) - 1) >> height
    }

    private func traverse(height: Int, position: Int) throws -> Data {
        let parentHasMatch = try readFlagBit()

        if height == 0 || !parentHasMatch {
            guard hashesUsed < hashes.count else { throw MerkleBlockError.invalidProof }
            let hash = hashes[hashesUsed]
            hashesUsed += 1
            if height == 0 && parentHasMatch {
                matchedHashes.append(hash)
            }
            return hash
        }

        let left = try traverse(height: height - 1, position: position * 2)
        var right = left

        if position * 2 + 1 < treeWidth(height: height - 1) {
            right = try traverse(height: height - 1, position: position * 2 + 1)
            // Identical sibling subtrees can only come from duplicated
            // transactions (CVE-2012-2459), which a valid block never has.
            guard right != left else { throw MerkleBlockError.invalidProof }
        }

        return MerkleTree.hashPair(left, right)
    }

    private func readFlagBit() throws -> Bool {
        let maxBits = flags.count * 8
        guard bitsUsed < maxBits else { throw MerkleBlockError.invalidProof }

        let byte = flags[bitsUsed >> 3]
        let bit = (byte >> (bitsUsed & 7)) & 1
        bitsUsed += 1
        return bit == 1
    }
}
