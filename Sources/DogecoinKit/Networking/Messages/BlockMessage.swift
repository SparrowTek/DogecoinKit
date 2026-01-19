import Foundation

public struct BlockMessage: Sendable {
    public let header: BlockHeader
    public let transactions: [Data]
    /// AuxPoW data for merged-mined blocks (nil for regular blocks)
    public let auxpow: AuxPoW?

    public init(header: BlockHeader, transactions: [Data], auxpow: AuxPoW? = nil) {
        self.header = header
        self.transactions = transactions
        self.auxpow = auxpow
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
        var auxpow: AuxPoW?

        // If this is an AuxPoW block, parse the auxpow data
        if AuxPoW.isAuxPow(version: header.version) {
            guard let (parsed, newOffset) = AuxPoW.parse(from: data, at: offset) else { return nil }
            auxpow = parsed
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

        return BlockMessage(header: header, transactions: transactions, auxpow: auxpow)
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

        // Version (4 bytes)
        guard data.count >= offset + 4 else { return nil }
        offset += 4

        // Check for SegWit marker (0x00) and flag (0x01)
        // SegWit transactions have marker=0x00, flag=0x01 after version
        var isSegWit = false
        if data.count >= offset + 2 && data[offset] == 0x00 && data[offset + 1] == 0x01 {
            isSegWit = true
            offset += 2  // Skip marker and flag
        }

        // Input count
        guard let (inputCount, inputSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
        guard inputCount <= UInt64(Int.max) else { return nil }
        offset += inputSize

        // Inputs
        for _ in 0..<inputCount {
            // Previous output (32 bytes txid + 4 bytes index)
            guard data.count >= offset + 36 else { return nil }
            offset += 36

            // Script sig length and script
            guard let (scriptLength, scriptSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
            guard scriptLength <= UInt64(Int.max) else { return nil }
            offset += scriptSize

            let scriptBytes = Int(scriptLength)
            guard data.count >= offset + scriptBytes + 4 else { return nil }
            offset += scriptBytes + 4  // script + sequence
        }

        // Output count
        guard let (outputCount, outputSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
        guard outputCount <= UInt64(Int.max) else { return nil }
        offset += outputSize

        // Outputs
        for _ in 0..<outputCount {
            // Value (8 bytes)
            guard data.count >= offset + 8 else { return nil }
            offset += 8

            // Script pubkey length and script
            guard let (scriptLength, scriptSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
            guard scriptLength <= UInt64(Int.max) else { return nil }
            offset += scriptSize

            let scriptBytes = Int(scriptLength)
            guard data.count >= offset + scriptBytes else { return nil }
            offset += scriptBytes
        }

        // Witness data (only for SegWit transactions)
        if isSegWit {
            // One witness per input
            for _ in 0..<inputCount {
                // Number of stack items for this input
                guard let (stackItemCount, stackItemCountSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
                offset += stackItemCountSize

                // Each stack item
                for _ in 0..<stackItemCount {
                    guard let (itemLength, itemLengthSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
                    offset += itemLengthSize

                    let itemBytes = Int(itemLength)
                    guard data.count >= offset + itemBytes else { return nil }
                    offset += itemBytes
                }
            }
        }

        // Locktime (4 bytes)
        guard data.count >= offset + 4 else { return nil }
        offset += 4

        return Data(data[start..<offset])
    }
}
