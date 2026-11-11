import Foundation

/// A decoded transaction, in legacy or BIP 144 witness serialization.
///
/// The library uses it to check what libdogecoin actually serialized before
/// anything is signed, to read what a funding transaction really pays, and
/// to decode the parent coinbase of merge-mined blocks — whose chain may use
/// segregated witness even though Dogecoin does not. A wallet uses it to
/// read the transactions a server or a peer sends: nothing in them is
/// trusted, and decoding one can only fail, never trap.
public struct RawTransaction: Sendable, Equatable {
    public struct Input: Sendable, Equatable {
        /// The id of the transaction whose output is spent, in internal
        /// byte order: reversed, it is the id as it is usually written
        public let previousTxid: Data
        public let previousIndex: UInt32
        public let script: Data
        public let sequence: UInt32
        /// Witness stack items; empty unless the transaction carries witness data
        public internal(set) var witness: [Data] = []
    }

    public struct Output: Sendable, Equatable {
        /// In koinu. Decoding does not bound it: a transaction that is not
        /// known to be in a block can claim any amount.
        public let value: UInt64
        public let script: Data
    }

    public let version: Int32
    public let inputs: [Input]
    public let outputs: [Output]
    public let lockTime: UInt32

    public init?(hex: String) {
        guard let data = Data(hexString: hex) else { return nil }
        self.init(data: data)
    }

    /// Decodes exactly as Dogecoin Core's `UnserializeTransaction` does with
    /// witness data allowed. Every count and length is bounded by the
    /// remaining bytes, so malformed input fails the decode instead of
    /// trapping or over-allocating, and trailing bytes are rejected.
    public init?(data: Data) {
        guard let (transaction, end) = Self.decode(in: data, at: 0), end == data.count else { return nil }
        self = transaction
    }

    /// Decodes the transaction that starts `offset` bytes into `data`, which
    /// may hold more after it — as an AuxPoW proof does after its coinbase.
    /// - Returns: The transaction and the offset just past it
    static func decode(in data: Data, at start: Int) -> (transaction: RawTransaction, end: Int)? {
        guard start >= 0 else { return nil }
        var offset = start

        guard let version: Int32 = data.readInteger(at: offset) else { return nil }
        offset += 4

        guard var inputs = readInputs(from: data, at: &offset) else { return nil }
        var outputs: [Output] = []
        var flags: UInt8 = 0

        if inputs.isEmpty {
            // An empty input list is BIP 144's marker; the flag byte follows.
            guard let flag: UInt8 = data.readInteger(at: offset) else { return nil }
            flags = flag
            offset += 1

            if flags != 0 {
                guard let witnessInputs = readInputs(from: data, at: &offset),
                      let witnessOutputs = readOutputs(from: data, at: &offset) else { return nil }
                inputs = witnessInputs
                outputs = witnessOutputs
            }
        } else {
            guard let legacyOutputs = readOutputs(from: data, at: &offset) else { return nil }
            outputs = legacyOutputs
        }

        if flags & 1 == 1 {
            flags ^= 1
            for index in inputs.indices {
                guard let witness = readWitness(from: data, at: &offset) else { return nil }
                inputs[index].witness = witness
            }
        }

        // Core rejects unknown optional data.
        guard flags == 0 else { return nil }

        guard let lockTime: UInt32 = data.readInteger(at: offset) else { return nil }
        offset += 4

        let transaction = RawTransaction(
            version: Int32(littleEndian: version),
            inputs: inputs,
            outputs: outputs,
            lockTime: UInt32(littleEndian: lockTime)
        )
        return (transaction, offset)
    }

    private init(version: Int32, inputs: [Input], outputs: [Output], lockTime: UInt32) {
        self.version = version
        self.inputs = inputs
        self.outputs = outputs
        self.lockTime = lockTime
    }

    /// Whether any input carries witness data. Dogecoin transactions never do.
    public var hasWitness: Bool {
        inputs.contains { !$0.witness.isEmpty }
    }

    /// The serialization without witness data — the bytes a txid commits to.
    var strippedData: Data {
        var data = Data()
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }

        data.append(VarInt(UInt64(inputs.count)).serialize())
        for input in inputs {
            data.append(input.previousTxid)
            withUnsafeBytes(of: input.previousIndex.littleEndian) { data.append(contentsOf: $0) }
            data.append(VarInt(UInt64(input.script.count)).serialize())
            data.append(input.script)
            withUnsafeBytes(of: input.sequence.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(VarInt(UInt64(outputs.count)).serialize())
        for output in outputs {
            withUnsafeBytes(of: output.value.littleEndian) { data.append(contentsOf: $0) }
            data.append(VarInt(UInt64(output.script.count)).serialize())
            data.append(output.script)
        }

        withUnsafeBytes(of: lockTime.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// The transaction id in internal byte order: double SHA-256 of the
    /// serialization without witness data, as Core's `GetHash` computes it.
    /// Reversed, it is the id as it is usually written.
    public var txid: Data {
        MerkleTree.doubleSHA256(strippedData)
    }

    // MARK: - Decoding

    private static func readInputs(from data: Data, at offset: inout Int) -> [Input]? {
        // 32-byte txid + 4-byte index + empty script + 4-byte sequence
        guard let (count, countSize) = data.readBoundedCount(at: offset, minItemSize: 41) else { return nil }
        offset += countSize

        var inputs: [Input] = []
        inputs.reserveCapacity(count)
        for _ in 0..<count {
            guard let previousTxid = data.bytes(at: offset, count: 32),
                  let previousIndex: UInt32 = data.readInteger(at: offset + 32) else { return nil }
            offset += 36

            guard let (scriptLength, scriptStart) = data.readBoundedLength(at: offset, trailing: 4),
                  let script = data.bytes(at: scriptStart, count: scriptLength),
                  let sequence: UInt32 = data.readInteger(at: scriptStart + scriptLength) else { return nil }
            offset = scriptStart + scriptLength + 4

            inputs.append(Input(
                previousTxid: previousTxid,
                previousIndex: UInt32(littleEndian: previousIndex),
                script: script,
                sequence: UInt32(littleEndian: sequence)
            ))
        }
        return inputs
    }

    private static func readOutputs(from data: Data, at offset: inout Int) -> [Output]? {
        // 8-byte value + empty script
        guard let (count, countSize) = data.readBoundedCount(at: offset, minItemSize: 9) else { return nil }
        offset += countSize

        var outputs: [Output] = []
        outputs.reserveCapacity(count)
        for _ in 0..<count {
            guard let value: UInt64 = data.readInteger(at: offset) else { return nil }
            offset += 8

            guard let (scriptLength, scriptStart) = data.readBoundedLength(at: offset),
                  let script = data.bytes(at: scriptStart, count: scriptLength) else { return nil }
            offset = scriptStart + scriptLength

            outputs.append(Output(value: UInt64(littleEndian: value), script: script))
        }
        return outputs
    }

    private static func readWitness(from data: Data, at offset: inout Int) -> [Data]? {
        // Each stack item is at least its one-byte length.
        guard let (count, countSize) = data.readBoundedCount(at: offset, minItemSize: 1) else { return nil }
        offset += countSize

        var items: [Data] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            guard let (length, start) = data.readBoundedLength(at: offset),
                  let item = data.bytes(at: start, count: length) else { return nil }
            items.append(item)
            offset = start + length
        }
        return items
    }
}
