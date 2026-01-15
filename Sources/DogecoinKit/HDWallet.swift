import Foundation
import clibdogecoin

/// A hierarchical deterministic (HD) wallet supporting BIP32/39/44 standards
public final class HDWallet: Sendable {

    /// The HD master private key (serialized)
    public let masterKey: String

    /// The mnemonic phrase used to generate this wallet (if available)
    public let mnemonic: String?

    /// The network this wallet belongs to
    public let network: DogecoinNetwork
    

    /// Create an HD wallet from a mnemonic phrase
    /// - Parameters:
    ///   - mnemonic: The BIP39 mnemonic phrase (12-24 words)
    ///   - passphrase: Optional BIP39 passphrase (default: empty)
    ///   - network: The network to use
    /// - Throws: `DogecoinError.invalidMnemonic` if the mnemonic is invalid
    public init(mnemonic: String, passphrase: String = "", network: DogecoinNetwork = .mainnet) throws {
        try Dogecoin.ensureInitialized()

        var seed = [UInt8](repeating: 0, count: Int(MAX_SEED_SIZE))
        let seedResult = mnemonic.withCString { mnemonicPtr in
            passphrase.withCString { passPtr in
                seed.withUnsafeMutableBufferPointer { seedBuffer in
                    dogecoin_seed_from_mnemonic(mnemonicPtr, passPtr, seedBuffer.baseAddress)
                }
            }
        }

        guard seedResult == 0 else {
            throw DogecoinError.invalidMnemonic
        }

        var masterKeyBuffer = [CChar](repeating: 0, count: Int(HDKEYLEN))
        let masterResult: dogecoin_bool = seed.withUnsafeBufferPointer { seedBuffer in
            guard let seedPtr = seedBuffer.baseAddress else { return dogecoin_bool(0) }
            return getHDRootKeyFromSeed(seedPtr, Int32(MAX_SEED_SIZE), network.isTestnet, &masterKeyBuffer)
        }

        guard masterResult == dogecoin_bool(1) else {
            throw DogecoinError.keyGenerationFailed
        }

        let masterKey = Self.stringFromCStringBuffer(masterKeyBuffer)
        zeroize(&masterKeyBuffer)
        zeroize(&seed)
        guard !masterKey.isEmpty else {
            throw DogecoinError.keyGenerationFailed
        }

        self.masterKey = masterKey
        self.mnemonic = mnemonic
        self.network = network
    }

    /// Create a new random HD wallet with a generated mnemonic
    /// - Parameters:
    ///   - strength: The entropy strength in bits (128, 160, 192, 224, or 256)
    ///   - passphrase: Optional BIP39 passphrase
    ///   - network: The network to use
    /// - Returns: A new HDWallet with generated mnemonic
    /// - Throws: `DogecoinError` if generation fails
    public static func create(
        strength: MnemonicStrength = .words12,
        passphrase: String = "",
        network: DogecoinNetwork = .mainnet
    ) throws -> HDWallet {
        let mnemonic = try generateMnemonic(strength: strength)
        return try HDWallet(mnemonic: mnemonic, passphrase: passphrase, network: network)
    }

    /// Generate a new HD master key without mnemonic
    /// - Parameter network: The network to use
    /// - Returns: A new HDWallet
    /// - Throws: `DogecoinError.keyGenerationFailed` if generation fails
    public static func generateMasterKey(network: DogecoinNetwork = .mainnet) throws -> HDWallet {
        try Dogecoin.ensureInitialized()

        var masterKeyBuffer = [CChar](repeating: 0, count: Int(HDKEYLEN))
        var addressBuffer = [CChar](repeating: 0, count: Int(P2PKHLEN))

        let result = generateHDMasterPubKeypair(&masterKeyBuffer, &addressBuffer, network.isTestnet)

        guard result == 1 else {
            throw DogecoinError.keyGenerationFailed
        }

        let wallet = HDWallet(
            masterKey: Self.stringFromCStringBuffer(masterKeyBuffer),
            mnemonic: nil,
            network: network
        )

        return wallet
    }

    /// Internal initializer
    private init(masterKey: String, mnemonic: String?, network: DogecoinNetwork) {
        self.masterKey = masterKey
        self.mnemonic = mnemonic
        self.network = network
    }

    /// Derive an address at the given BIP44 path
    /// - Parameters:
    ///   - account: The account index (hardened)
    ///   - index: The address index
    ///   - change: Whether this is a change address (internal) or external
    /// - Returns: The derived P2PKH address
    /// - Throws: `DogecoinError.derivationFailed` if derivation fails
    public func deriveAddress(account: UInt32 = 0, index: UInt32 = 0, change: Bool = false) throws -> String {
        try Dogecoin.ensureInitialized()
        return try deriveAddressFromMasterKey(account: account, index: index, change: change)
    }

    /// Derive an address using the master key directly
    private func deriveAddressFromMasterKey(account: UInt32, index: UInt32, change: Bool) throws -> String {
        var masterKeyBuffer = Array(masterKey.utf8CString)
        while masterKeyBuffer.count < Int(HDKEYLEN) { masterKeyBuffer.append(0) }

        let coinType = network == .mainnet ? "3" : "1"
        let path = "m/44'/\(coinType)'/\(account)'/\(change ? 1 : 0)/\(index)"

        var pathBuffer = Array(path.utf8CString)
        while pathBuffer.count < Int(KEYPATHMAXLEN) { pathBuffer.append(0) }

        var addressBuffer = [CChar](repeating: 0, count: Int(P2PKHLEN))

        let result = getDerivedHDAddressByPath(
            &masterKeyBuffer,
            &pathBuffer,
            &addressBuffer,
            0
        )

        guard result == 1 else {
            zeroize(&masterKeyBuffer)
            zeroize(&pathBuffer)
            zeroize(&addressBuffer)
            throw DogecoinError.derivationFailed
        }

        let address = Self.stringFromCStringBuffer(addressBuffer)
        zeroize(&masterKeyBuffer)
        zeroize(&pathBuffer)
        zeroize(&addressBuffer)
        return address
    }

    /// Derive an address at a custom derivation path
    /// - Parameters:
    ///   - path: The derivation path (e.g., "m/44'/3'/0'/0/0")
    /// - Returns: The derived P2PKH address
    /// - Throws: `DogecoinError.derivationFailed` if derivation fails
    public func deriveAddress(path: String) throws -> String {
        try Dogecoin.ensureInitialized()

        var masterKeyBuffer = Array(masterKey.utf8CString)
        while masterKeyBuffer.count < Int(HDKEYLEN) { masterKeyBuffer.append(0) }

        var pathBuffer = Array(path.utf8CString)
        while pathBuffer.count < Int(KEYPATHMAXLEN) { pathBuffer.append(0) }

        var addressBuffer = [CChar](repeating: 0, count: Int(P2PKHLEN))

        let result = getDerivedHDAddressByPath(
            &masterKeyBuffer,
            &pathBuffer,
            &addressBuffer,
            0  // Don't output private key
        )

        guard result == 1 else {
            zeroize(&masterKeyBuffer)
            zeroize(&pathBuffer)
            zeroize(&addressBuffer)
            throw DogecoinError.derivationFailed
        }

        let address = Self.stringFromCStringBuffer(addressBuffer)
        zeroize(&masterKeyBuffer)
        zeroize(&pathBuffer)
        zeroize(&addressBuffer)
        return address
    }

    /// Generate multiple addresses for this wallet
    /// - Parameters:
    ///   - count: Number of addresses to generate
    ///   - account: The account index
    ///   - change: Whether to generate change addresses
    ///   - startIndex: The starting index
    /// - Returns: An array of addresses
    public func deriveAddresses(
        count: Int,
        account: UInt32 = 0,
        change: Bool = false,
        startIndex: UInt32 = 0
    ) throws -> [String] {
        var addresses: [String] = []
        addresses.reserveCapacity(count)

        for i in 0..<UInt32(count) {
            let address = try deriveAddress(account: account, index: startIndex + i, change: change)
            addresses.append(address)
        }

        return addresses
    }

    /// Derive a private key in WIF format at the given BIP44 path
    /// - Parameters:
    ///   - account: The account index (hardened)
    ///   - index: The address index
    ///   - change: Whether this is a change address (internal) or external
    /// - Returns: The derived private key in WIF format
    /// - Throws: `DogecoinError.derivationFailed` if derivation fails
    public func derivePrivateKey(account: UInt32 = 0, index: UInt32 = 0, change: Bool = false) throws -> String {
        try Dogecoin.ensureInitialized()

        // Build BIP44 derivation path: m/44'/3'/account'/change/index
        // For Dogecoin: coin type is 3 (mainnet) or 1 (testnet)
        let coinType = network == .mainnet ? "3" : "1"
        let changePath = change ? "1" : "0"
        let path = "m/44'/\(coinType)'/\(account)'/\(changePath)/\(index)"

        var masterKeyBuffer = Array(masterKey.utf8CString)
        while masterKeyBuffer.count < Int(HDKEYLEN) { masterKeyBuffer.append(0) }

        var pathBuffer = Array(path.utf8CString)
        while pathBuffer.count < Int(KEYPATHMAXLEN) { pathBuffer.append(0) }

        var addressBuffer = [CChar](repeating: 0, count: Int(P2PKHLEN))

        // Use getHDNodePrivateKeyWIFByPath to get the private key
        guard let privateKeyPtr = getHDNodePrivateKeyWIFByPath(
            &masterKeyBuffer,
            &pathBuffer,
            &addressBuffer,
            true  // Output private key
        ) else {
            zeroize(&masterKeyBuffer)
            zeroize(&pathBuffer)
            zeroize(&addressBuffer)
            throw DogecoinError.derivationFailed
        }

        let privateKeyWIF = String(cString: privateKeyPtr)

        // Free the allocated memory from the C function
        dogecoin_free(UnsafeMutableRawPointer(mutating: privateKeyPtr))
        zeroize(&masterKeyBuffer)
        zeroize(&pathBuffer)
        zeroize(&addressBuffer)

        guard !privateKeyWIF.isEmpty else {
            throw DogecoinError.derivationFailed
        }

        return privateKeyWIF
    }

    /// Derive a private key in WIF format at a custom derivation path
    /// - Parameters:
    ///   - path: The derivation path (e.g., "m/44'/3'/0'/0/0")
    /// - Returns: The derived private key in WIF format
    /// - Throws: `DogecoinError.derivationFailed` if derivation fails
    public func derivePrivateKey(path: String) throws -> String {
        try Dogecoin.ensureInitialized()

        var masterKeyBuffer = Array(masterKey.utf8CString)
        while masterKeyBuffer.count < Int(HDKEYLEN) { masterKeyBuffer.append(0) }

        var pathBuffer = Array(path.utf8CString)
        while pathBuffer.count < Int(KEYPATHMAXLEN) { pathBuffer.append(0) }

        var addressBuffer = [CChar](repeating: 0, count: Int(P2PKHLEN))

        guard let privateKeyPtr = getHDNodePrivateKeyWIFByPath(
            &masterKeyBuffer,
            &pathBuffer,
            &addressBuffer,
            true
        ) else {
            zeroize(&masterKeyBuffer)
            zeroize(&pathBuffer)
            zeroize(&addressBuffer)
            throw DogecoinError.derivationFailed
        }

        let privateKeyWIF = String(cString: privateKeyPtr)
        dogecoin_free(UnsafeMutableRawPointer(mutating: privateKeyPtr))
        zeroize(&masterKeyBuffer)
        zeroize(&pathBuffer)
        zeroize(&addressBuffer)

        guard !privateKeyWIF.isEmpty else {
            throw DogecoinError.derivationFailed
        }

        return privateKeyWIF
    }
}

// MARK: - Mnemonic Generation

/// Mnemonic phrase strength options
public enum MnemonicStrength: Int, Sendable, CaseIterable {
    /// 12 words (128 bits of entropy)
    case words12 = 128
    /// 15 words (160 bits of entropy)
    case words15 = 160
    /// 18 words (192 bits of entropy)
    case words18 = 192
    /// 21 words (224 bits of entropy)
    case words21 = 224
    /// 24 words (256 bits of entropy)
    case words24 = 256

    /// The number of words in the mnemonic
    public var wordCount: Int {
        switch self {
        case .words12: return 12
        case .words15: return 15
        case .words18: return 18
        case .words21: return 21
        case .words24: return 24
        }
    }
}

/// Generate a random BIP39 mnemonic phrase
/// - Parameter strength: The entropy strength
/// - Returns: The mnemonic phrase as a string
/// - Throws: `DogecoinError.keyGenerationFailed` if generation fails
public func generateMnemonic(strength: MnemonicStrength = .words12) throws -> String {
    try Dogecoin.ensureInitialized()

    var mnemonic = [CChar](repeating: 0, count: Int(MAX_MNEMONIC_SIZE))
    var strengthBuffer = Array("\(strength.rawValue)".utf8CString)
    while strengthBuffer.count < 4 { strengthBuffer.append(0) }

    let result = generateRandomEnglishMnemonic(&strengthBuffer, &mnemonic)

    guard result == 0 else {
        throw DogecoinError.keyGenerationFailed
    }

    return String(cString: mnemonic)
}

private extension HDWallet {
    static func stringFromCStringBuffer(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}

private func zeroize(_ buffer: inout [UInt8]) {
    for index in buffer.indices {
        buffer[index] = 0
    }
}

private func zeroize(_ buffer: inout [CChar]) {
    for index in buffer.indices {
        buffer[index] = 0
    }
}

/// Validate a BIP39 mnemonic phrase using full BIP39 checksum validation
/// - Parameter mnemonic: The mnemonic phrase to validate
/// - Returns: `true` if the mnemonic is valid with correct checksum
public func validateMnemonic(_ mnemonic: String) -> Bool {
    verifyMnemonic(mnemonic)
}
