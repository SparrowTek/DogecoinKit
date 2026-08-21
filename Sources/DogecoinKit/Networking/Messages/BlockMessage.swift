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

        // Transaction count is peer-supplied — bound it by the remaining bytes
        // (a minimal transaction is 10 bytes) before reserving capacity.
        guard let (txCount, txCountSize) = data.readBoundedCount(at: offset, minItemSize: 10) else { return nil }
        offset += txCountSize

        var transactions: [Data] = []
        transactions.reserveCapacity(txCount)

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

        // Every count and length below is peer-supplied — bound each by the
        // remaining bytes before use so a fabricated VarInt can only fail the
        // parse, never trap on Int conversion, overflow, or over-allocation.

        // Input count (each input is at least 36 + 1 + 4 bytes)
        guard let (inputCount, inputSize) = data.readBoundedCount(at: offset, minItemSize: 41) else { return nil }
        offset += inputSize

        // Inputs
        for _ in 0..<inputCount {
            // Previous output (32 bytes txid + 4 bytes index)
            guard data.count >= offset + 36 else { return nil }
            offset += 36

            // Script sig length and script (sequence follows)
            guard let (scriptBytes, scriptStart) = data.readBoundedLength(at: offset, trailing: 4) else { return nil }
            offset = scriptStart + scriptBytes + 4  // script + sequence
        }

        // Output count (each output is at least 8 + 1 bytes)
        guard let (outputCount, outputSize) = data.readBoundedCount(at: offset, minItemSize: 9) else { return nil }
        offset += outputSize

        // Outputs
        for _ in 0..<outputCount {
            // Value (8 bytes)
            guard data.count >= offset + 8 else { return nil }
            offset += 8

            // Script pubkey length and script
            guard let (scriptBytes, scriptStart) = data.readBoundedLength(at: offset) else { return nil }
            offset = scriptStart + scriptBytes
        }

        // Witness data (only for SegWit transactions)
        if isSegWit {
            // One witness per input
            for _ in 0..<inputCount {
                // Number of stack items for this input (each is at least 1 byte)
                guard let (stackItemCount, stackItemCountSize) = data.readBoundedCount(at: offset, minItemSize: 1) else { return nil }
                offset += stackItemCountSize

                // Each stack item
                for _ in 0..<stackItemCount {
                    guard let (itemBytes, itemStart) = data.readBoundedLength(at: offset) else { return nil }
                    offset = itemStart + itemBytes
                }
            }
        }

        // Locktime (4 bytes)
        guard data.count >= offset + 4 else { return nil }
        offset += 4

        return Data(data[start..<offset])
    }
}
