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

    /// Check if block version indicates AuxPoW (merged mining)
    private static func isAuxPow(version: Int32) -> Bool {
        (version & 0x100) == 0x100
    }

    /// Skip AuxPoW data and return the new offset, or nil if parsing fails
    /// AuxPoW structure: coinbase_tx, coinbase_merkle_branch, side_mask,
    /// blockchain_merkle_branch, side_mask, parent_block_header
    private static func skipAuxPow(in data: Data, from offset: Int) -> Int? {
        var pos = offset

        // Skip coinbase transaction
        guard let txEnd = TransactionParser.skipTransaction(in: data, from: pos) else { return nil }
        pos = txEnd

        // Skip coinbase merkle branch (varint count + 32*count bytes)
        guard let (branchCount1, branchSize1) = VarInt.parse(from: Data(data[pos...])) else { return nil }
        pos += branchSize1
        let branch1Bytes = Int(branchCount1) * 32
        guard data.count >= pos + branch1Bytes else { return nil }
        pos += branch1Bytes

        // Skip coinbase branch side mask (4 bytes)
        guard data.count >= pos + 4 else { return nil }
        pos += 4

        // Skip blockchain link merkle branch (varint count + 32*count bytes)
        guard let (branchCount2, branchSize2) = VarInt.parse(from: Data(data[pos...])) else { return nil }
        pos += branchSize2
        let branch2Bytes = Int(branchCount2) * 32
        guard data.count >= pos + branch2Bytes else { return nil }
        pos += branch2Bytes

        // Skip blockchain branch side mask (4 bytes)
        guard data.count >= pos + 4 else { return nil }
        pos += 4

        // Skip parent block header (80 bytes)
        guard data.count >= pos + 80 else { return nil }
        pos += 80

        return pos
    }

    public static func parse(from data: Data) -> MerkleBlockMessage? {
        guard data.count >= BlockHeader.size + 4 else { return nil }
        guard let header = BlockHeader.parse(from: Data(data.prefix(BlockHeader.size))) else { return nil }

        var offset = BlockHeader.size

        // If this is an AuxPoW block, skip the auxpow data
        if isAuxPow(version: header.version) {
            guard let newOffset = skipAuxPow(in: data, from: offset) else { return nil }
            offset = newOffset
        }
        guard let totalRaw: UInt32 = data.readInteger(at: offset) else { return nil }
        let totalTransactions = UInt32(littleEndian: totalRaw)
        offset += 4

        guard let (hashCount, hashCountSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
        guard hashCount <= UInt64(Int.max) else { return nil }
        offset += hashCountSize

        var hashes: [Data] = []
        hashes.reserveCapacity(Int(hashCount))
        for _ in 0..<hashCount {
            guard data.count >= offset + 32 else { return nil }
            hashes.append(Data(data[offset..<offset + 32]))
            offset += 32
        }

        guard let (flagCount, flagSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
        guard flagCount <= UInt64(Int.max) else { return nil }
        offset += flagSize
        guard data.count >= offset + Int(flagCount) else { return nil }
        let flags = Data(data[offset..<offset + Int(flagCount)])

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

    func calculateRoot() throws -> Data {
        guard totalTransactions > 0 else { throw MerkleBlockError.invalidTransactionCount }

        let height = treeHeight
        let root = try traverse(height: height, position: 0)

        guard hashesUsed == hashes.count else { throw MerkleBlockError.invalidProof }
        guard bitsUsed <= flags.count * 8 else { throw MerkleBlockError.invalidProof }

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
