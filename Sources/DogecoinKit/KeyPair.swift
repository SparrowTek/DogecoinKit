import Foundation
import clibdogecoin

/// A private key (WIF) and the P2PKH address of its compressed public key
struct KeyPair: Sendable, Equatable {
    /// The private key in Wallet Import Format (WIF)
    let privateKeyWIF: String

    /// The P2PKH address
    let address: String

    /// The network this key pair belongs to
    let network: DogecoinNetwork

    /// Generate a new random key pair
    /// - Parameter network: The network to generate the key pair for
    /// - Returns: A new KeyPair
    /// - Throws: `DogecoinError.keyGenerationFailed` if generation fails
    static func generate(network: DogecoinNetwork = .mainnet) throws -> KeyPair {
        try ECC.armCurrentThread()

        var privateKey = [CChar](repeating: 0, count: Int(PRIVKEYWIFLEN))
        var address = [CChar](repeating: 0, count: Int(P2PKHLEN))
        defer { wipe(&privateKey) }

        let result = generatePrivPubKeypair(&privateKey, &address, network.isTestnet)

        guard result == 1 else {
            throw DogecoinError.keyGenerationFailed
        }

        let privateKeyString = String(decoding: privateKey.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let addressString = String(decoding: address.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

        // generatePrivPubKeypair ignores a failed key generation and returns
        // success anyway; only hand out a pair that provably belongs together.
        guard verify(privateKeyWIF: privateKeyString, address: addressString, network: network) else {
            throw DogecoinError.keyGenerationFailed
        }

        return KeyPair(
            privateKeyWIF: privateKeyString,
            address: addressString,
            network: network
        )
    }

    /// Verify that a private key and address match
    /// - Parameters:
    ///   - privateKeyWIF: The private key in WIF format
    ///   - address: The P2PKH address
    ///   - network: The network to verify against
    /// - Returns: `true` if the key pair is valid and matches
    static func verify(privateKeyWIF: String, address: String, network: DogecoinNetwork = .mainnet) -> Bool {
        guard isValidPrivateKey(privateKeyWIF, network: network), (try? ECC.armCurrentThread()) != nil else {
            return false
        }

        var privKey = paddedCString(privateKeyWIF, length: Int(PRIVKEYWIFLEN))
        var addr = paddedCString(address, length: Int(P2PKHLEN))
        defer { wipe(&privKey) }

        return verifyPrivPubKeypair(&privKey, &addr, network.isTestnet) == 1
    }

    /// Get the public key hex from a private key
    /// - Parameters:
    ///   - privateKeyWIF: The private key in WIF format
    ///   - network: The network
    /// - Returns: The compressed public key as hex string
    /// - Throws: `DogecoinError.invalidPrivateKey` if the private key is invalid
    static func publicKeyHex(from privateKeyWIF: String, network: DogecoinNetwork = .mainnet) throws -> String {
        // libdogecoin derives the public key without checking the secret and
        // aborts the process when it is out of range.
        guard isValidPrivateKey(privateKeyWIF, network: network) else {
            throw DogecoinError.invalidPrivateKey
        }

        try ECC.armCurrentThread()

        var privKey = paddedCString(privateKeyWIF, length: Int(PRIVKEYWIFLEN))
        defer { wipe(&privKey) }

        var pubKeyHex = [CChar](repeating: 0, count: Int(PUBKEYHEXLEN))
        var size = pubKeyHex.count

        let result = getPubkeyFromPrivkey(&privKey, network.isTestnet, &pubKeyHex, &size)

        guard result == 1 else {
            throw DogecoinError.invalidPrivateKey
        }

        let bytes = Data(pubKeyHex.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
        return String(decoding: bytes, as: UTF8.self)
    }

    /// NUL-terminated copy of `string`, zero-padded to at least `length`
    /// bytes for C functions whose prototypes declare fixed-size arrays.
    private static func paddedCString(_ string: String, length: Int) -> [CChar] {
        var buffer = Array(string.utf8CString)
        if buffer.count < length {
            buffer.append(contentsOf: repeatElement(0, count: length - buffer.count))
        }
        return buffer
    }

    private static func wipe(_ buffer: inout [CChar]) {
        buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
    }
}

// MARK: - Private Key Validation

extension KeyPair {
    /// WIF prefixes (from Dogecoin chainparams)
    private static let mainnetSecretKeyPrefix: UInt8 = 0x9E
    private static let testnetSecretKeyPrefix: UInt8 = 0xF1

    /// The network a WIF private key belongs to, or `nil` unless libdogecoin
    /// can safely use it: valid Base58Check, a Dogecoin secret-key prefix, a
    /// 32-byte key flagged compressed, and a scalar inside the curve order.
    ///
    /// libdogecoin accepts any WIF that decodes and aborts the process on an
    /// out-of-range key, so every entry point taking a WIF checks this first.
    ///
    /// Only keys for compressed public keys pass. Everything here derives,
    /// verifies, and signs with the compressed key whatever the WIF says, so
    /// a key exported for an uncompressed public key would be accepted and
    /// then never match the address its funds are at.
    static func network(ofPrivateKey wif: String) -> DogecoinNetwork? {
        guard var payload = Base58Check.decode(wif) else { return nil }
        defer { payload.resetBytes(in: payload.startIndex..<payload.endIndex) }

        let network: DogecoinNetwork
        switch payload.first {
        case mainnetSecretKeyPrefix: network = .mainnet
        case testnetSecretKeyPrefix: network = .testnet
        default: return nil
        }

        guard payload.count == 34, payload.last == 0x01,
              ECC.isValidPrivateKey(payload[1..<33]) else {
            return nil
        }
        return network
    }

    /// Whether `wif` is a usable private key on `network`.
    static func isValidPrivateKey(_ wif: String, network: DogecoinNetwork) -> Bool {
        self.network(ofPrivateKey: wif) == network
    }
}

// MARK: - CustomStringConvertible

/// Describes the pair without its private key.
extension KeyPair: CustomStringConvertible {
    var description: String {
        "KeyPair(address: \(address), network: \(network))"
    }
}
