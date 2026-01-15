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

    public static func parse(from data: Data) -> BlockMessage? {
        guard data.count >= BlockHeader.size else { return nil }
        guard let header = BlockHeader.parse(from: Data(data.prefix(BlockHeader.size))) else { return nil }

        var offset = BlockHeader.size
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

private struct TransactionParser {
    static func parseTransaction(from data: Data, offset: inout Int) -> Data? {
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
