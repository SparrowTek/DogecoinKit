import Foundation
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
        guard let payload = base58CheckPayload(address) else { return nil }
        switch payload[payload.startIndex] {
        case mainnetP2PKHVersion, testnetP2PKHVersion:
            return .p2pkh
        case mainnetP2SHVersion, testnetP2SHVersion:
            return .p2sh
        default:
            return nil
        }
    }

    /// The output script that pays to an address.
    ///
    /// P2PKH: `OP_DUP OP_HASH160 <hash160> OP_EQUALVERIFY OP_CHECKSIG`;
    /// P2SH: `OP_HASH160 <hash160> OP_EQUAL`.
    /// - Parameter address: A mainnet or testnet P2PKH or P2SH address
    /// - Returns: The script bytes, or `nil` if the address is invalid
    public static func scriptPubKey(for address: String) -> Data? {
        guard let payload = base58CheckPayload(address) else { return nil }
        let hash160 = payload.dropFirst()
        switch payload[payload.startIndex] {
        case mainnetP2PKHVersion, testnetP2PKHVersion:
            return Data([0x76, 0xa9, 0x14]) + hash160 + Data([0x88, 0xac])
        case mainnetP2SHVersion, testnetP2SHVersion:
            return Data([0xa9, 0x14]) + hash160 + Data([0x87])
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
        guard let payload = base58CheckPayload(address) else { return nil }

        switch payload[payload.startIndex] {
        case mainnetP2PKHVersion, mainnetP2SHVersion:
            return .mainnet
        case testnetP2PKHVersion, testnetP2SHVersion:
            return .testnet
        default:
            return nil
        }
    }

    // MARK: - Base58Check

    /// The 21-byte payload (version + hash160) of a Base58Check address, or
    /// nil if the string is not valid Base58Check of that size.
    private static func base58CheckPayload(_ string: String) -> Data? {
        guard let payload = Base58Check.decode(string), payload.count == 21 else { return nil }
        return payload
    }

    /// The P2PKH address paying to a public key hash.
    static func p2pkhAddress(hash160: Data, network: DogecoinNetwork) -> String {
        let version = network == .mainnet ? mainnetP2PKHVersion : testnetP2PKHVersion
        return Base58Check.encode(Data([version]) + hash160)
    }

    /// RIPEMD-160 of SHA-256: the hash a P2PKH address commits to.
    static func hash160(_ data: Data) -> Data {
        var sha256 = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            sha256_raw(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count, &sha256)
        }
        var ripemd160 = [UInt8](repeating: 0, count: 20)
        rmd160(sha256, UInt32(sha256.count), &ripemd160)
        return Data(ripemd160)
    }

    /// Get the address from a public key hex
    /// - Parameters:
    ///   - publicKeyHex: The public key in hex, compressed (33 bytes) or
    ///     uncompressed (65 bytes)
    ///   - network: The network to generate the address for
    /// - Returns: The P2PKH address the key controls in that form
    /// - Throws: `DogecoinError.invalidPublicKey` if the hex is not a point
    ///   on secp256k1
    public static func fromPublicKey(_ publicKeyHex: String, network: DogecoinNetwork = .mainnet) async throws -> String {
        try await Dogecoin.ensureInitialized()

        // Public keys often come from transactions anyone can craft; never
        // let an invalid one reach libdogecoin, which aborts on it.
        guard let publicKey = Data(hexString: publicKeyHex), ECC.isValidPublicKey(publicKey) else {
            throw DogecoinError.invalidPublicKey
        }
        return p2pkhAddress(hash160: hash160(publicKey), network: network)
    }

    /// Get the P2PKH output script for an address
    ///
    /// Despite the name (kept for source compatibility), this returns the full
    /// 25-byte scriptPubKey — `76a914<hash160>88ac` — not the bare 20-byte
    /// hash, matching libdogecoin's `dogecoin_p2pkh_address_to_pubkey_hash`.
    /// Use ``scriptPubKey(for:)`` for raw bytes or for P2SH addresses.
    /// - Parameter address: The P2PKH address (P2SH addresses are rejected —
    ///   they encode a script hash, and building a P2PKH script from one
    ///   would produce an unspendable output)
    /// - Returns: The P2PKH scriptPubKey as lowercase hex
    /// - Throws: `DogecoinError.invalidAddress` if the address is invalid
    public static func toPubkeyHash(_ address: String) throws -> String {
        guard kind(address) == .p2pkh, let script = scriptPubKey(for: address) else {
            throw DogecoinError.invalidAddress(address)
        }
        return script.hexString
    }

    /// Create an address from a pubkey hash
    /// - Parameters:
    ///   - pubkeyHash: Hex of the 20-byte public key hash, or of the full
    ///     25-byte P2PKH script that ``toPubkeyHash(_:)`` returns
    ///   - network: The network
    /// - Returns: The P2PKH address
    /// - Throws: `DogecoinError.invalidPublicKey` if the hex is neither form
    public static func fromPubkeyHash(_ pubkeyHash: String, network: DogecoinNetwork = .mainnet) async throws -> String {
        guard let bytes = Data(hexString: pubkeyHash) else {
            throw DogecoinError.invalidPublicKey
        }

        switch bytes.count {
        case 20:
            return p2pkhAddress(hash160: bytes, network: network)
        case 25 where bytes.starts(with: [0x76, 0xa9, 0x14]) && bytes.suffix(2).elementsEqual([0x88, 0xac]):
            return p2pkhAddress(hash160: bytes.subdata(in: 3..<23), network: network)
        default:
            throw DogecoinError.invalidPublicKey
        }
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
