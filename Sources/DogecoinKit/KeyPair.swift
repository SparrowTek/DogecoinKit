import Foundation
import clibdogecoin

/// A simple Dogecoin key pair consisting of a private key (WIF) and address
public struct KeyPair: Sendable, Equatable, Hashable {
    /// The private key in Wallet Import Format (WIF)
    public let privateKeyWIF: String

    /// The P2PKH address
    public let address: String

    /// The network this key pair belongs to
    public let network: DogecoinNetwork

    /// Generate a new random key pair
    /// - Parameter network: The network to generate the key pair for
    /// - Returns: A new KeyPair
    /// - Throws: `DogecoinError.keyGenerationFailed` if generation fails
    public static func generate(network: DogecoinNetwork = .mainnet) throws -> KeyPair {
        try Dogecoin.ensureInitialized()

        var privateKey = [CChar](repeating: 0, count: Int(PRIVKEYWIFLEN))
        var address = [CChar](repeating: 0, count: Int(P2PKHLEN))

        let result = generatePrivPubKeypair(&privateKey, &address, network.isTestnet)

        guard result == 1 else {
            throw DogecoinError.keyGenerationFailed
        }

        return KeyPair(
            privateKeyWIF: String(cString: privateKey),
            address: String(cString: address),
            network: network
        )
    }

    /// Verify that a private key and address match
    /// - Parameters:
    ///   - privateKeyWIF: The private key in WIF format
    ///   - address: The P2PKH address
    ///   - network: The network to verify against
    /// - Returns: `true` if the key pair is valid and matches
    public static func verify(privateKeyWIF: String, address: String, network: DogecoinNetwork = .mainnet) -> Bool {
        var privKey = Array(privateKeyWIF.utf8CString)
        var addr = Array(address.utf8CString)

        // Ensure buffers are large enough
        while privKey.count < Int(PRIVKEYWIFLEN) { privKey.append(0) }
        while addr.count < Int(P2PKHLEN) { addr.append(0) }

        let result = verifyPrivPubKeypair(&privKey, &addr, network.isTestnet)
        return result == 1
    }

    /// Get the public key hex from a private key
    /// - Parameters:
    ///   - privateKeyWIF: The private key in WIF format
    ///   - network: The network
    /// - Returns: The public key as hex string
    /// - Throws: `DogecoinError.invalidPrivateKey` if the private key is invalid
    public static func publicKeyHex(from privateKeyWIF: String, network: DogecoinNetwork = .mainnet) throws -> String {
        try Dogecoin.ensureInitialized()

        var privKey = Array(privateKeyWIF.utf8CString)
        while privKey.count < Int(PRIVKEYWIFLEN) { privKey.append(0) }

        var pubKeyHex = [CChar](repeating: 0, count: Int(PUBKEYHEXLEN))
        var size = pubKeyHex.count

        let result = getPubkeyFromPrivkey(&privKey, network.isTestnet, &pubKeyHex, &size)

        guard result == 1 else {
            throw DogecoinError.invalidPrivateKey
        }

        return String(cString: pubKeyHex)
    }
}

// MARK: - CustomStringConvertible

extension KeyPair: CustomStringConvertible {
    public var description: String {
        "KeyPair(address: \(address), network: \(network))"
    }
}

// MARK: - Codable

extension KeyPair: Codable {
    enum CodingKeys: String, CodingKey {
        case privateKeyWIF
        case address
        case isTestnet
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.privateKeyWIF = try container.decode(String.self, forKey: .privateKeyWIF)
        self.address = try container.decode(String.self, forKey: .address)
        let isTestnet = try container.decode(Bool.self, forKey: .isTestnet)
        self.network = isTestnet ? .testnet : .mainnet
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(privateKeyWIF, forKey: .privateKeyWIF)
        try container.encode(address, forKey: .address)
        try container.encode(network == .testnet, forKey: .isTestnet)
    }
}
