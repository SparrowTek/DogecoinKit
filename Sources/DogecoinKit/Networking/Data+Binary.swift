import Foundation

extension Data {
    func readInteger<T: FixedWidthInteger>(at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, count >= offset + size else { return nil }

        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { (buffer: UnsafeMutableRawBufferPointer) in
            _ = copyBytes(to: buffer, from: offset..<(offset + size))
        }

        return value
    }

    /// Parse a VarInt at `offset` without slicing. Returns `(value, bytesConsumed)`.
    func readVarInt(at offset: Int) -> (value: UInt64, size: Int)? {
        guard offset >= 0, offset < count else { return nil }
        let first: UInt8 = self[startIndex + offset]

        switch first {
        case ..<0xFD:
            return (UInt64(first), 1)
        case 0xFD:
            guard let raw: UInt16 = readInteger(at: offset + 1) else { return nil }
            return (UInt64(UInt16(littleEndian: raw)), 3)
        case 0xFE:
            guard let raw: UInt32 = readInteger(at: offset + 1) else { return nil }
            return (UInt64(UInt32(littleEndian: raw)), 5)
        default:
            guard let raw: UInt64 = readInteger(at: offset + 1) else { return nil }
            return (UInt64(littleEndian: raw), 9)
        }
    }

    /// Parse an untrusted VarInt count at `offset`, requiring that `count`
    /// items of at least `minItemSize` bytes each could still fit in the
    /// remaining buffer. Peer-supplied counts must never be trusted blindly:
    /// `Int(hugeUInt64)` traps and `reserveCapacity` on a fabricated count is
    /// a memory DoS, so this returns nil for any count the buffer cannot hold.
    func readBoundedCount(at offset: Int, minItemSize: Int) -> (count: Int, varIntSize: Int)? {
        guard minItemSize > 0 else { return nil }
        guard let (raw, varIntSize) = readVarInt(at: offset) else { return nil }
        let remaining = count - offset - varIntSize
        guard remaining >= 0 else { return nil }
        guard raw <= UInt64(remaining / minItemSize) else { return nil }
        return (Int(raw), varIntSize)
    }

    /// Parse an untrusted VarInt length at `offset` and validate that the
    /// length itself plus `trailing` fixed bytes fit in the remaining buffer.
    /// Returns the length and the end offset just past the length's payload.
    func readBoundedLength(at offset: Int, trailing: Int = 0) -> (length: Int, payloadStart: Int)? {
        guard trailing >= 0 else { return nil }
        guard let (raw, varIntSize) = readVarInt(at: offset) else { return nil }
        let payloadStart = offset + varIntSize
        let remaining = count - payloadStart - trailing
        guard remaining >= 0, raw <= UInt64(remaining) else { return nil }
        return (Int(raw), payloadStart)
    }
}
