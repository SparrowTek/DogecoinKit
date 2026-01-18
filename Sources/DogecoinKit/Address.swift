import Foundation
import clibdogecoin

/// Utilities for working with Dogecoin addresses
public enum Address {

    /// Validate a Dogecoin address
    /// - Parameter address: The address to validate
    /// - Returns: `true` if the address is valid
    public static func isValid(_ address: String) -> Bool {
        var addressBuffer = Array(address.utf8CString)
        while addressBuffer.count < Int(P2PKHLEN) { addressBuffer.append(0) }

        let result = verifyP2pkhAddress(&addressBuffer, address.count)
        return result == 1
    }

    /// Check if an address is a mainnet address
    /// - Parameter address: The address to check
    /// - Returns: `true` if the address is a mainnet address
    public static func isMainnet(_ address: String) -> Bool {
        guard isValid(address) else { return false }

        var addressBuffer = Array(address.utf8CString)
        while addressBuffer.count < Int(P2PKHLEN) { addressBuffer.append(0) }

        return isMainnetFromB58Prefix(&addressBuffer) == 1
    }

    /// Check if an address is a testnet address
    /// - Parameter address: The address to check
    /// - Returns: `true` if the address is a testnet address
    public static func isTestnet(_ address: String) -> Bool {
        guard isValid(address) else { return false }

        var addressBuffer = Array(address.utf8CString)
        while addressBuffer.count < Int(P2PKHLEN) { addressBuffer.append(0) }

        return isTestnetFromB58Prefix(&addressBuffer) == 1
    }

    /// Detect the network of an address
    /// - Parameter address: The address to check
    /// - Returns: The network, or `nil` if the address is invalid
    public static func detectNetwork(_ address: String) -> DogecoinNetwork? {
        guard isValid(address) else { return nil }

        if isMainnet(address) {
            return .mainnet
        } else if isTestnet(address) {
            return .testnet
        }

        return nil
    }

    /// Get the address from a public key hex
    /// - Parameters:
    ///   - publicKeyHex: The public key in hex format
    ///   - network: The network to generate the address for
    /// - Returns: The P2PKH address
    /// - Throws: `DogecoinError.invalidPublicKey` if the public key is invalid
    public static func fromPublicKey(_ publicKeyHex: String, network: DogecoinNetwork = .mainnet) throws -> String {
        try Dogecoin.ensureInitialized()

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
    /// - Parameter address: The P2PKH address
    /// - Returns: The pubkey hash as hex string
    /// - Throws: `DogecoinError.invalidAddress` if the address is invalid
    public static func toPubkeyHash(_ address: String) throws -> String {
        guard isValid(address) else {
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
    public static func fromPubkeyHash(_ pubkeyHash: String, network: DogecoinNetwork = .mainnet) throws -> String {
        try Dogecoin.ensureInitialized()

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
