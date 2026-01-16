import Foundation

public struct BlockMessage: Sendable {
    public let header: BlockHeader
    public let transactions: [Data]

    public init(header: BlockHeader, transactions: [Data]) {
        self.header = header
        self.transactions = transactions
    }

    public func serialize() -> Data {
        var data = Data()
        data.append(header.serializeCore())
        data.append(VarInt(UInt64(transactions.count)).serialize())
        for transaction in transactions {
            data.append(transaction)
        }
        return data
    }

    /// Check if block version indicates AuxPoW (merged mining)
    private static func isAuxPow(version: Int32) -> Bool {
        (version & 0x100) == 0x100
    }

    /// Skip AuxPoW data and return the new offset, or nil if parsing fails
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

    public static func parse(from data: Data) -> BlockMessage? {
        guard data.count >= BlockHeader.size else { return nil }
        guard let header = BlockHeader.parse(from: Data(data.prefix(BlockHeader.size))) else { return nil }

        var offset = BlockHeader.size

        // If this is an AuxPoW block, skip the auxpow data
        if isAuxPow(version: header.version) {
            guard let newOffset = skipAuxPow(in: data, from: offset) else { return nil }
            offset = newOffset
        }
        guard let (txCount, txCountSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
        guard txCount <= UInt64(Int.max) else { return nil }
        offset += txCountSize

        var transactions: [Data] = []
        transactions.reserveCapacity(Int(txCount))

        for _ in 0..<txCount {
            guard let tx = TransactionParser.parseTransaction(from: data, offset: &offset) else { return nil }
            transactions.append(tx)
        }

        return BlockMessage(header: header, transactions: transactions)
    }

    public var transactionHashes: [Data] {
        transactions.map { MerkleTree.doubleSHA256($0) }
    }

    public var merkleRoot: Data? {
        MerkleTree.calculateRoot(from: transactionHashes)
    }
}

struct TransactionParser {
    /// Skip a transaction and return the new offset (for auxpow parsing)
    static func skipTransaction(in data: Data, from offset: Int) -> Int? {
        var pos = offset
        guard parseTransactionImpl(from: data, offset: &pos) != nil else { return nil }
        return pos
    }

    static func parseTransaction(from data: Data, offset: inout Int) -> Data? {
        parseTransactionImpl(from: data, offset: &offset)
    }

    private static func parseTransactionImpl(from data: Data, offset: inout Int) -> Data? {
        let start = offset

        guard data.count >= offset + 4 else { return nil }
        offset += 4

        guard let (inputCount, inputSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
        guard inputCount <= UInt64(Int.max) else { return nil }
        offset += inputSize

        for _ in 0..<inputCount {
            guard data.count >= offset + 36 else { return nil }
            offset += 36

            guard let (scriptLength, scriptSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
            guard scriptLength <= UInt64(Int.max) else { return nil }
            offset += scriptSize

            let scriptBytes = Int(scriptLength)
            guard data.count >= offset + scriptBytes + 4 else { return nil }
            offset += scriptBytes + 4
        }

        guard let (outputCount, outputSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
        guard outputCount <= UInt64(Int.max) else { return nil }
        offset += outputSize

        for _ in 0..<outputCount {
            guard data.count >= offset + 8 else { return nil }
            offset += 8

            guard let (scriptLength, scriptSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
            guard scriptLength <= UInt64(Int.max) else { return nil }
            offset += scriptSize

            let scriptBytes = Int(scriptLength)
            guard data.count >= offset + scriptBytes else { return nil }
            offset += scriptBytes
        }

        guard data.count >= offset + 4 else { return nil }
        offset += 4

        return Data(data[start..<offset])
    }
}
