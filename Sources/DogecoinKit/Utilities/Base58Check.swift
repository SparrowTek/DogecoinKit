import Foundation

/// Base58Check: Base58 text with a four-byte double-SHA-256 checksum, the
/// encoding of addresses and WIF private keys.
enum Base58Check {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

    /// Digit value of each ASCII character, or -1 outside the alphabet.
    private static let digitValues: [Int8] = {
        var values = [Int8](repeating: -1, count: 128)
        for (digit, character) in alphabet.enumerated() {
            values[Int(character)] = Int8(digit)
        }
        return values
    }()

    /// Encodes `payload` followed by its checksum.
    static func encode(_ payload: Data) -> String {
        let bytes = payload + MerkleTree.doubleSHA256(payload).prefix(4)

        // Base-58 digits, least significant first.
        var digits: [UInt8] = []
        for byte in bytes {
            var carry = Int(byte)
            for index in digits.indices {
                carry += Int(digits[index]) << 8
                digits[index] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }

        // Each leading zero byte is written as the zero digit, "1".
        let leadingZeros = bytes.prefix { $0 == 0 }.count
        let characters = repeatElement(alphabet[0], count: leadingZeros) + digits.reversed().map { alphabet[Int($0)] }
        return String(decoding: characters, as: UTF8.self)
    }

    /// Decodes a Base58Check string and returns its payload without the
    /// checksum.
    /// - Parameters:
    ///   - string: The encoded text
    ///   - maximumLength: Longest input accepted — it bounds the decoding work
    ///     on hostile input
    /// - Returns: The payload, or `nil` if the text is not Base58, is too
    ///   long, or fails its checksum
    static func decode(_ string: String, maximumLength: Int = 64) -> Data? {
        let characters = Array(string.utf8)
        guard !characters.isEmpty, characters.count <= maximumLength else { return nil }

        // Base-256 digits, least significant first.
        var bytes: [UInt8] = []
        for character in characters {
            guard character < 128 else { return nil }
            let digit = digitValues[Int(character)]
            guard digit >= 0 else { return nil }

            var carry = Int(digit)
            for index in bytes.indices {
                carry += Int(bytes[index]) * 58
                bytes[index] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xFF))
                carry >>= 8
            }
        }

        let leadingZeros = characters.prefix { $0 == alphabet[0] }.count
        let decoded = Data(repeating: 0, count: leadingZeros) + Data(bytes.reversed())
        guard decoded.count > 4 else { return nil }

        let payload = Data(decoded.dropLast(4))
        guard decoded.suffix(4).elementsEqual(MerkleTree.doubleSHA256(payload).prefix(4)) else { return nil }
        return payload
    }
}
