import Foundation

extension Data {
    /// The same bytes indexed from zero.
    ///
    /// Message parsers use fixed offsets, so their public entry points rebase
    /// first: a caller passing a slice (whose indices start mid-buffer) would
    /// otherwise shift every field or trap on an out-of-range subscript.
    var rebased: Data {
        startIndex == 0 ? self : Data(self)
    }

    /// Copies `length` bytes starting at `offset` (relative to `startIndex`),
    /// or returns nil if the range does not fit.
    func bytes(at offset: Int, count length: Int) -> Data? {
        guard offset >= 0, length >= 0, count - offset >= length else { return nil }
        let start = startIndex + offset
        return Data(self[start..<(start + length)])
    }

    /// Reads a fixed-width integer in memory byte order at `offset`, which is
    /// relative to `startIndex` so slices behave like zero-based buffers.
    func readInteger<T: FixedWidthInteger>(at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, count - offset >= size else { return nil }

        let start = startIndex + offset
        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { (buffer: UnsafeMutableRawBufferPointer) in
            _ = copyBytes(to: buffer, from: start..<(start + size))
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
