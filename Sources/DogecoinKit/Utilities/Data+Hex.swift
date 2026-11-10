import Foundation

extension Data {
    /// Decodes a hex string, accepting upper- and lowercase digits.
    ///
    /// Returns `nil` for odd-length input or any character outside
    /// `[0-9a-fA-F]` — including signs, whitespace, and `0x` prefixes, which
    /// integer parsing would otherwise quietly accept.
    init?(hexString: String) {
        let digits = hexString.utf8
        guard digits.count.isMultiple(of: 2) else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)

        var highNibble: UInt8?
        for digit in digits {
            guard let nibble = Self.nibble(digit) else { return nil }
            if let high = highNibble {
                bytes.append(high << 4 | nibble)
                highNibble = nil
            } else {
                highNibble = nibble
            }
        }

        self.init(bytes)
    }

    /// Lowercase hex encoding, two digits per byte.
    var hexString: String {
        let alphabet = Array("0123456789abcdef".utf8)
        var digits = [UInt8]()
        digits.reserveCapacity(count * 2)
        for byte in self {
            digits.append(alphabet[Int(byte >> 4)])
            digits.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: digits, as: UTF8.self)
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
