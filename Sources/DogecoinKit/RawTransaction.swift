import Foundation

/// A decoded transaction, in legacy or BIP 144 witness serialization.
///
/// Used to check what libdogecoin actually serialized before anything is
/// signed, to read what a funding transaction really pays, and to decode the
/// parent coinbase of merge-mined blocks — whose chain may use segregated
/// witness even though Dogecoin does not.
struct RawTransaction: Sendable, Equatable {
    struct Input: Sendable, Equatable {
        /// Previous transaction id in internal (little-endian) byte order
        let previousTxid: Data
        let previousIndex: UInt32
        let script: Data
        let sequence: UInt32
        /// Witness stack items; empty unless the transaction carries witness data
        var witness: [Data] = []
    }

    struct Output: Sendable, Equatable {
        let value: UInt64
        let script: Data
    }

    let version: Int32
    let inputs: [Input]
    let outputs: [Output]
    let lockTime: UInt32

    init?(hex: String) {
        guard let data = Data(hexString: hex) else { return nil }
        self.init(data: data)
    }

    /// Decodes exactly as Dogecoin Core's `UnserializeTransaction` does with
    /// witness data allowed. Every count and length is bounded by the
    /// remaining bytes, so malformed input fails the decode instead of
    /// trapping or over-allocating, and trailing bytes are rejected.
    init?(data: Data) {
        var offset = 0

        guard let version: Int32 = data.readInteger(at: offset) else { return nil }
        offset += 4

        guard var inputs = Self.readInputs(from: data, at: &offset) else { return nil }
        var outputs: [Output] = []
        var flags: UInt8 = 0

        if inputs.isEmpty {
            // An empty input list is BIP 144's marker; the flag byte follows.
            guard let flag: UInt8 = data.readInteger(at: offset) else { return nil }
            flags = flag
            offset += 1

            if flags != 0 {
                guard let witnessInputs = Self.readInputs(from: data, at: &offset),
                      let witnessOutputs = Self.readOutputs(from: data, at: &offset) else { return nil }
                inputs = witnessInputs
                outputs = witnessOutputs
            }
        } else {
            guard let legacyOutputs = Self.readOutputs(from: data, at: &offset) else { return nil }
            outputs = legacyOutputs
        }

        if flags & 1 == 1 {
            flags ^= 1
            for index in inputs.indices {
                guard let witness = Self.readWitness(from: data, at: &offset) else { return nil }
                inputs[index].witness = witness
            }
        }

        // Core rejects unknown optional data.
        guard flags == 0 else { return nil }

        guard let lockTime: UInt32 = data.readInteger(at: offset) else { return nil }
        offset += 4

        guard offset == data.count else { return nil }

        self.version = Int32(littleEndian: version)
        self.inputs = inputs
        self.outputs = outputs
        self.lockTime = UInt32(littleEndian: lockTime)
    }

    /// Whether any input carries witness data. Dogecoin transactions never do.
    var hasWitness: Bool {
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
    var txid: Data {
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
