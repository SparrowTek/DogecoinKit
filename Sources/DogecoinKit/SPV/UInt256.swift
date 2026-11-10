import Foundation

/// A 256-bit unsigned integer for proof-of-work arithmetic: compact
/// difficulty targets, chain work, and retargeting.
///
/// Mirrors Dogecoin Core's `arith_uint256` where it matters for consensus —
/// `init?(compact:)` and `compact` reproduce `SetCompact` and `GetCompact`
/// exactly, and arithmetic wraps modulo 2²⁵⁶.
struct UInt256: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Little-endian 64-bit limbs; `w0` is least significant.
    private var w0: UInt64
    private var w1: UInt64
    private var w2: UInt64
    private var w3: UInt64

    static let zero = UInt256(0)
    static let one = UInt256(1)
    static let max = ~UInt256.zero

    init(_ value: UInt64) {
        w0 = value
        w1 = 0
        w2 = 0
        w3 = 0
    }

    /// Reads up to 32 bytes, least significant first — the layout of block
    /// hashes, proof-of-work hashes, and stored chain work. Shorter input is
    /// zero-extended.
    init(littleEndian bytes: Data) {
        self = .zero
        for (offset, byte) in bytes.prefix(32).enumerated() {
            self[limb: offset / 8] |= UInt64(byte) << UInt64(offset % 8 * 8)
        }
    }

    /// Decodes a compact ("nBits") target like `arith_uint256::SetCompact`.
    ///
    /// Returns `nil` for encodings Core flags as negative or overflowing. A
    /// zero mantissa decodes to zero, which no hash can meet.
    init?(compact: UInt32) {
        let size = Int(compact >> 24)
        let word = compact & 0x007f_ffff

        let isNegative = word != 0 && compact & 0x0080_0000 != 0
        let overflows = word != 0 && (size > 34 || (word > 0xff && size > 33) || (word > 0xffff && size > 32))
        guard !isNegative, !overflows else { return nil }

        if size <= 3 {
            self.init(UInt64(word >> UInt32(8 * (3 - size))))
        } else {
            self = UInt256(UInt64(word)) << (8 * (size - 3))
        }
    }

    /// The 32-byte little-endian representation.
    var littleEndianData: Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for index in 0..<4 {
            let limb = self[limb: index]
            for shift in stride(from: 0, to: 64, by: 8) {
                bytes.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift)))
            }
        }
        return Data(bytes)
    }

    /// The compact ("nBits") encoding, like `arith_uint256::GetCompact` for
    /// a non-negative value.
    var compact: UInt32 {
        var size = (bitWidth + 7) / 8
        var mantissa: UInt64
        if size <= 3 {
            mantissa = w0 << UInt64(8 * (3 - size))
        } else {
            mantissa = (self >> (8 * (size - 3))).w0
        }

        // 0x00800000 is the sign bit; keep it clear by growing the exponent.
        if mantissa & 0x0080_0000 != 0 {
            mantissa >>= 8
            size += 1
        }

        return UInt32(truncatingIfNeeded: mantissa) & 0x007f_ffff | UInt32(size) << 24
    }

    /// Number of significant bits (0 for zero).
    var bitWidth: Int {
        for index in stride(from: 3, through: 0, by: -1) {
            let limb = self[limb: index]
            if limb != 0 {
                return index * 64 + (64 - limb.leadingZeroBitCount)
            }
        }
        return 0
    }

    /// Big-endian hex, as targets and hashes are displayed.
    var description: String {
        Data(littleEndianData.reversed()).hexString
    }

    // MARK: - Arithmetic

    /// Adds, wrapping modulo 2²⁵⁶.
    static func &+ (lhs: UInt256, rhs: UInt256) -> UInt256 {
        var result = UInt256.zero
        var carry: UInt64 = 0
        for index in 0..<4 {
            let (partial, overflow1) = lhs[limb: index].addingReportingOverflow(rhs[limb: index])
            let (sum, overflow2) = partial.addingReportingOverflow(carry)
            result[limb: index] = sum
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        return result
    }

    /// Subtracts, wrapping modulo 2²⁵⁶.
    static func &- (lhs: UInt256, rhs: UInt256) -> UInt256 {
        var result = UInt256.zero
        var borrow: UInt64 = 0
        for index in 0..<4 {
            let (partial, overflow1) = lhs[limb: index].subtractingReportingOverflow(rhs[limb: index])
            let (difference, overflow2) = partial.subtractingReportingOverflow(borrow)
            result[limb: index] = difference
            borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        return result
    }

    /// Multiplies by a word, wrapping modulo 2²⁵⁶.
    static func &* (lhs: UInt256, rhs: UInt64) -> UInt256 {
        var result = UInt256.zero
        var carry: UInt64 = 0
        for index in 0..<4 {
            let (high, low) = lhs[limb: index].multipliedFullWidth(by: rhs)
            let (sum, overflow) = low.addingReportingOverflow(carry)
            result[limb: index] = sum
            carry = high &+ (overflow ? 1 : 0)
        }
        return result
    }

    /// Divides by a word, rounding toward zero. Division by zero yields zero.
    static func / (lhs: UInt256, rhs: UInt64) -> UInt256 {
        guard rhs != 0 else { return .zero }
        var result = UInt256.zero
        var remainder: UInt64 = 0
        for index in stride(from: 3, through: 0, by: -1) {
            let (quotient, rest) = rhs.dividingFullWidth((high: remainder, low: lhs[limb: index]))
            result[limb: index] = quotient
            remainder = rest
        }
        return result
    }

    /// Divides by a 256-bit value, rounding toward zero. Division by zero
    /// yields zero.
    static func / (lhs: UInt256, rhs: UInt256) -> UInt256 {
        guard rhs != .zero else { return .zero }

        var quotient = UInt256.zero
        var remainder = UInt256.zero
        for bit in stride(from: lhs.bitWidth - 1, through: 0, by: -1) {
            remainder = remainder << 1
            if lhs.isBitSet(bit) {
                remainder.w0 |= 1
            }
            if remainder >= rhs {
                remainder = remainder &- rhs
                quotient.setBit(bit)
            }
        }
        return quotient
    }

    static prefix func ~ (value: UInt256) -> UInt256 {
        var result = value
        for index in 0..<4 {
            result[limb: index] = ~value[limb: index]
        }
        return result
    }

    static func << (value: UInt256, shift: Int) -> UInt256 {
        guard shift > 0 else { return shift == 0 ? value : value >> -shift }
        guard shift < 256 else { return .zero }

        let limbShift = shift / 64
        let bitShift = UInt64(shift % 64)
        var result = UInt256.zero
        for index in stride(from: 3, through: limbShift, by: -1) {
            var limb = value[limb: index - limbShift] << bitShift
            if bitShift > 0, index - limbShift - 1 >= 0 {
                limb |= value[limb: index - limbShift - 1] >> (64 - bitShift)
            }
            result[limb: index] = limb
        }
        return result
    }

    static func >> (value: UInt256, shift: Int) -> UInt256 {
        guard shift > 0 else { return shift == 0 ? value : value << -shift }
        guard shift < 256 else { return .zero }

        let limbShift = shift / 64
        let bitShift = UInt64(shift % 64)
        var result = UInt256.zero
        for index in 0..<(4 - limbShift) {
            var limb = value[limb: index + limbShift] >> bitShift
            if bitShift > 0, index + limbShift + 1 < 4 {
                limb |= value[limb: index + limbShift + 1] << (64 - bitShift)
            }
            result[limb: index] = limb
        }
        return result
    }

    static func < (lhs: UInt256, rhs: UInt256) -> Bool {
        for index in stride(from: 3, through: 0, by: -1) where lhs[limb: index] != rhs[limb: index] {
            return lhs[limb: index] < rhs[limb: index]
        }
        return false
    }

    // MARK: - Bits

    private func isBitSet(_ bit: Int) -> Bool {
        self[limb: bit / 64] >> UInt64(bit % 64) & 1 == 1
    }

    private mutating func setBit(_ bit: Int) {
        self[limb: bit / 64] |= 1 << UInt64(bit % 64)
    }

    private subscript(limb index: Int) -> UInt64 {
        get {
            switch index {
            case 0: w0
            case 1: w1
            case 2: w2
            default: w3
            }
        }
        set {
            switch index {
            case 0: w0 = newValue
            case 1: w1 = newValue
            case 2: w2 = newValue
            default: w3 = newValue
            }
        }
    }
}
