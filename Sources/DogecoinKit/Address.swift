import Foundation
import CryptoKit
import clibdogecoin

/// The script kind a Dogecoin address encodes
public enum AddressKind: Sendable, Equatable {
    /// Pay-to-public-key-hash ("D..." on mainnet, "n..." on testnet)
    case p2pkh
    /// Pay-to-script-hash ("9..."/"A..." on mainnet, "2..." on testnet)
    case p2sh
}

/// Utilities for working with Dogecoin addresses
public enum Address {

    // MARK: - Base58Check version bytes (from Dogecoin chainparams)

    private static let mainnetP2PKHVersion: UInt8 = 0x1E // 30, "D"
    private static let mainnetP2SHVersion: UInt8 = 0x16  // 22, "9"/"A"
    private static let testnetP2PKHVersion: UInt8 = 0x71 // 113, "n"
    private static let testnetP2SHVersion: UInt8 = 0xC4  // 196, "2"

    /// Validate a Dogecoin address (P2PKH or P2SH).
    ///
    /// Stricter than plain Base58Check: the version byte must be one of
    /// Dogecoin's four (mainnet/testnet × P2PKH/P2SH), so addresses from
    /// other chains (e.g. Bitcoin "1...") are rejected rather than passing
    /// on checksum alone.
    /// - Parameter address: The address to validate
    /// - Returns: `true` if the address is valid
    public static func isValid(_ address: String) -> Bool {
        kind(address) != nil
    }

    /// Determine the script kind an address encodes
    /// - Parameter address: The address to inspect
    /// - Returns: The kind, or `nil` if the address is invalid
    public static func kind(_ address: String) -> AddressKind? {
        guard let version = base58CheckVersionByte(address) else { return nil }
        switch version {
        case mainnetP2PKHVersion, testnetP2PKHVersion:
            return .p2pkh
        case mainnetP2SHVersion, testnetP2SHVersion:
            return .p2sh
        default:
            return nil
        }
    }

    /// Check if an address is a mainnet address
    /// - Parameter address: The address to check
    /// - Returns: `true` if the address is a mainnet address
    public static func isMainnet(_ address: String) -> Bool {
        detectNetwork(address) == .mainnet
    }

    /// Check if an address is a testnet address
    /// - Parameter address: The address to check
    /// - Returns: `true` if the address is a testnet address
    public static func isTestnet(_ address: String) -> Bool {
        detectNetwork(address) == .testnet
    }

    /// Detect the network of an address (P2PKH or P2SH)
    /// - Parameter address: The address to check
    /// - Returns: The network, or `nil` if the address is invalid
    public static func detectNetwork(_ address: String) -> DogecoinNetwork? {
        guard kind(address) != nil,
              let version = base58CheckVersionByte(address) else {
            return nil
        }

        switch version {
        case mainnetP2PKHVersion, mainnetP2SHVersion:
            return .mainnet
        case testnetP2PKHVersion, testnetP2SHVersion:
            return .testnet
        default:
            return nil
        }
    }

    // MARK: - Base58Check

    private static let base58Alphabet: [Character] = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    private static let base58Values: [Character: UInt8] = {
        var values: [Character: UInt8] = [:]
        for (index, character) in base58Alphabet.enumerated() {
            values[character] = UInt8(index)
        }
        return values
    }()

    /// Decode a Base58Check string and return its version byte, or nil if the
    /// string is not valid Base58Check with a 21-byte payload (version + hash160).
    private static func base58CheckVersionByte(_ string: String) -> UInt8? {
        // Dogecoin addresses are ~34 characters; anything much longer cannot
        // be one, and the cap bounds decoding work on hostile input.
        guard !string.isEmpty, string.count <= 64 else { return nil }

        var bytes: [UInt8] = []
        var leadingZeros = 0
        var seenNonZero = false

        for character in string {
            guard let value = base58Values[character] else { return nil }
            if !seenNonZero {
                if value == 0 {
                    leadingZeros += 1
                    continue
                }
                seenNonZero = true
            }

            var carry = UInt32(value)
            for index in bytes.indices.reversed() {
                carry += UInt32(bytes[index]) * 58
                bytes[index] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }

        let decoded = Data(repeating: 0, count: leadingZeros) + Data(bytes)

        // version (1) + hash160 (20) + checksum (4)
        guard decoded.count == 25 else { return nil }

        let payload = decoded.prefix(21)
        let checksum = decoded.suffix(4)
        let hash1 = SHA256.hash(data: payload)
        let hash2 = Data(SHA256.hash(data: Data(hash1)))
        guard checksum.elementsEqual(hash2.prefix(4)) else { return nil }

        return decoded[decoded.startIndex]
    }

    /// Get the address from a public key hex
    /// - Parameters:
    ///   - publicKeyHex: The public key in hex format
    ///   - network: The network to generate the address for
    /// - Returns: The P2PKH address
    /// - Throws: `DogecoinError.invalidPublicKey` if the public key is invalid
    public static func fromPublicKey(_ publicKeyHex: String, network: DogecoinNetwork = .mainnet) async throws -> String {
        try await Dogecoin.ensureInitialized()
        ECC.armCurrentThread()

        var pubKeyBuffer = Array(publicKeyHex.utf8CString)
        while pubKeyBuffer.count < Int(PUBKEYHEXLEN) { pubKeyBuffer.append(0) }

        var addressBuffer = [CChar](repeating: 0, count: Int(P2PKHLEN))

        let result = getAddressFromPubkey(&pubKeyBuffer, network.isTestnet, &addressBuffer)

        guard result == 1 else {
            throw DogecoinError.invalidPublicKey
        }

        let bytes = Data(addressBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Get the pubkey hash from an address
    /// - Parameter address: The P2PKH address (P2SH addresses are rejected —
    ///   they encode a script hash, and building a P2PKH script from one
    ///   would produce an unspendable output)
    /// - Returns: The pubkey hash as hex string
    /// - Throws: `DogecoinError.invalidAddress` if the address is invalid
    public static func toPubkeyHash(_ address: String) throws -> String {
        guard kind(address) == .p2pkh else {
            throw DogecoinError.invalidAddress(address)
        }

        var addressBuffer = Array(address.utf8CString)
        while addressBuffer.count < Int(P2PKHLEN) { addressBuffer.append(0) }

        var hashBuffer = [CChar](repeating: 0, count: Int(SCRIPTPUBKEYLEN))

        let result = dogecoin_p2pkh_address_to_pubkey_hash(&addressBuffer, &hashBuffer)

        guard result == 1 else {
            throw DogecoinError.invalidAddress(address)
        }

        let bytes = Data(hashBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Create an address from a pubkey hash
    /// - Parameters:
    ///   - pubkeyHash: The pubkey hash as hex string
    ///   - network: The network
    /// - Returns: The P2PKH address
    /// - Throws: `DogecoinError.invalidPublicKey` if the hash is invalid
    public static func fromPubkeyHash(_ pubkeyHash: String, network: DogecoinNetwork = .mainnet) async throws -> String {
        try await Dogecoin.ensureInitialized()
        ECC.armCurrentThread()

        var hashBuffer = Array(pubkeyHash.utf8CString)
        while hashBuffer.count < Int(PUBKEYHASHLEN) { hashBuffer.append(0) }

        var addressBuffer = [CChar](repeating: 0, count: Int(P2PKHLEN))

        let result = getAddrFromPubkeyHash(&hashBuffer, network.isTestnet, &addressBuffer)

        guard result == 1 else {
            throw DogecoinError.invalidPublicKey
        }

        let bytes = Data(addressBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Address Type

/// Represents a validated Dogecoin address
public struct DogecoinAddress: Sendable, Equatable, Hashable {
    /// The address string
    public let value: String

    /// The network this address belongs to
    public let network: DogecoinNetwork

    /// Create a validated address
    /// - Parameters:
    ///   - address: The address string
    ///   - network: Expected network (optional, will be detected if nil)
    /// - Throws: `DogecoinError.invalidAddress` if the address is invalid
    public init(_ address: String, network: DogecoinNetwork? = nil) throws {
        guard Address.isValid(address) else {
            throw DogecoinError.invalidAddress(address)
        }

        self.value = address

        if let network = network {
            // Verify the network matches
            let detectedNetwork = Address.detectNetwork(address)
            guard detectedNetwork == network else {
                throw DogecoinError.invalidAddress(address)
            }
            self.network = network
        } else {
            // Detect the network
            guard let detectedNetwork = Address.detectNetwork(address) else {
                throw DogecoinError.invalidAddress(address)
            }
            self.network = detectedNetwork
        }
    }

    /// The pubkey hash of this address
    public var pubkeyHash: String {
        get throws {
            try Address.toPubkeyHash(value)
        }
    }
}

// MARK: - CustomStringConvertible

extension DogecoinAddress: CustomStringConvertible {
    public var description: String {
        value
    }
}

// MARK: - ExpressibleByStringLiteral

extension DogecoinAddress: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        do {
            try self.init(value)
        } catch {
            fatalError("Invalid Dogecoin address literal: \(value)")
        }
    }
}

// MARK: - Codable

extension DogecoinAddress: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let address = try container.decode(String.self)
        try self.init(address)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
