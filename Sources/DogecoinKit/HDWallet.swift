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
    ///
    /// The phrase must pass full BIP39 validation — known words and a
    /// matching checksum. BIP39 seeds can be derived from *any* string, so a
    /// mistyped word would otherwise silently open a different, empty wallet.
    /// - Parameters:
    ///   - mnemonic: The BIP39 mnemonic phrase (12-24 words)
    ///   - passphrase: Optional BIP39 passphrase (default: empty)
    ///   - network: The network to use
    /// - Throws: `DogecoinError.invalidMnemonic` if the mnemonic is invalid
    public convenience init(mnemonic: String, passphrase: String = "", network: DogecoinNetwork = .mainnet) async throws {
        guard verifyMnemonic(mnemonic) else {
            throw DogecoinError.invalidMnemonic
        }
        try await self.init(acceptedMnemonic: mnemonic, passphrase: passphrase, network: network)
    }

    /// Derives the wallet for a mnemonic that was accepted earlier, without
    /// re-running BIP39 validation.
    ///
    /// Restoring from secure storage goes through here: the phrase was
    /// validated when it was imported, and a wallet that already holds funds
    /// must stay reachable even if validation rules change later.
    init(acceptedMnemonic mnemonic: String, passphrase: String, network: DogecoinNetwork) async throws {
        try await Dogecoin.ensureInitialized()

        var seed = [UInt8](repeating: 0, count: Int(MAX_SEED_SIZE))
        defer { zeroize(&seed) }

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

        ECC.armCurrentThread()

        var masterKeyBuffer = [CChar](repeating: 0, count: Int(HDKEYLEN))
        defer { zeroize(&masterKeyBuffer) }

        let masterResult: dogecoin_bool = seed.withUnsafeBufferPointer { seedBuffer in
            guard let seedPtr = seedBuffer.baseAddress else { return dogecoin_bool(0) }
            return getHDRootKeyFromSeed(seedPtr, Int32(MAX_SEED_SIZE), network.isTestnet, &masterKeyBuffer)
        }

        guard masterResult == dogecoin_bool(1) else {
            throw DogecoinError.keyGenerationFailed
        }

        let masterKey = Self.stringFromCStringBuffer(masterKeyBuffer)
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
    ) async throws -> HDWallet {
        let mnemonic = try await generateMnemonic(strength: strength)
        return try await HDWallet(mnemonic: mnemonic, passphrase: passphrase, network: network)
    }

    /// Generate a new HD master key without mnemonic
    /// - Parameter network: The network to use
    /// - Returns: A new HDWallet
    /// - Throws: `DogecoinError.keyGenerationFailed` if generation fails
    public static func generateMasterKey(network: DogecoinNetwork = .mainnet) async throws -> HDWallet {
        try await Dogecoin.ensureInitialized()
        ECC.armCurrentThread()

        var masterKeyBuffer = [CChar](repeating: 0, count: Int(HDKEYLEN))
        var addressBuffer = [CChar](repeating: 0, count: Int(P2PKHLEN))
        defer { zeroize(&masterKeyBuffer) }

        let result = generateHDMasterPubKeypair(&masterKeyBuffer, &addressBuffer, network.isTestnet)

        guard result == 1 else {
            throw DogecoinError.keyGenerationFailed
        }

        let masterKey = Self.stringFromCStringBuffer(masterKeyBuffer)
        guard !masterKey.isEmpty else {
            throw DogecoinError.keyGenerationFailed
        }

        return HDWallet(masterKey: masterKey, mnemonic: nil, network: network)
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
    public func deriveAddress(account: UInt32 = 0, index: UInt32 = 0, change: Bool = false) async throws -> String {
        try await deriveAddress(path: network.bip44Path(account: account, change: change, index: index))
    }

    /// Derive an address at a custom derivation path
    /// - Parameters:
    ///   - path: The derivation path (e.g., "m/44'/3'/0'/0/0")
    /// - Returns: The derived P2PKH address
    /// - Throws: `DogecoinError.derivationFailed` if derivation fails
    public func deriveAddress(path: String) async throws -> String {
        try await Dogecoin.ensureInitialized()
        try Self.validateLength(of: path)
        ECC.armCurrentThread()

        var masterKeyBuffer = Self.paddedCString(masterKey, length: Int(HDKEYLEN))
        var pathBuffer = Self.paddedCString(path, length: Int(KEYPATHMAXLEN))
        var addressBuffer = [CChar](repeating: 0, count: Int(P2PKHLEN))
        defer {
            zeroize(&masterKeyBuffer)
            zeroize(&pathBuffer)
        }

        guard getDerivedHDAddressByPath(&masterKeyBuffer, &pathBuffer, &addressBuffer) == 1 else {
            throw DogecoinError.derivationFailed
        }

        let address = Self.stringFromCStringBuffer(addressBuffer)
        guard !address.isEmpty else {
            throw DogecoinError.derivationFailed
        }
        return address
    }

    /// Generate multiple addresses for this wallet
    /// - Parameters:
    ///   - count: Number of addresses to generate
    ///   - account: The account index
    ///   - change: Whether to generate change addresses
    ///   - startIndex: The starting index
    /// - Returns: An array of addresses
    /// - Throws: `DogecoinError.derivationFailed` if `count` is negative or
    ///   the range runs past the last address index
    public func deriveAddresses(
        count: Int,
        account: UInt32 = 0,
        change: Bool = false,
        startIndex: UInt32 = 0
    ) async throws -> [String] {
        guard let count = UInt32(exactly: count),
              case (_, false) = startIndex.addingReportingOverflow(count) else {
            throw DogecoinError.derivationFailed
        }

        var addresses: [String] = []
        addresses.reserveCapacity(Int(count))

        for offset in 0..<count {
            let address = try await deriveAddress(account: account, index: startIndex + offset, change: change)
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
    public func derivePrivateKey(account: UInt32 = 0, index: UInt32 = 0, change: Bool = false) async throws -> String {
        // Centralized path builder — see DogecoinNetwork.bip44Path.
        try await derivePrivateKey(path: network.bip44Path(account: account, change: change, index: index))
    }

    /// Derive a private key in WIF format at a custom derivation path
    /// - Parameters:
    ///   - path: The derivation path (e.g., "m/44'/3'/0'/0/0")
    /// - Returns: The derived private key in WIF format
    /// - Throws: `DogecoinError.derivationFailed` if derivation fails
    public func derivePrivateKey(path: String) async throws -> String {
        try await Dogecoin.ensureInitialized()
        try Self.validateLength(of: path)
        ECC.armCurrentThread()

        var masterKeyBuffer = Self.paddedCString(masterKey, length: Int(HDKEYLEN))
        var pathBuffer = Self.paddedCString(path, length: Int(KEYPATHMAXLEN))

        // getHDNodePrivateKeyWIFByPath's prototype declares this parameter as
        // char[P2PKHLEN], but with outprivkey=true the implementation
        // serializes the full base58 EXTENDED private key ("dgpv...", 111
        // chars) into it via dogecoin_hdnode_serialize_private(..., HDKEYLEN).
        // A P2PKHLEN (35) buffer is overrun by 77 bytes on every call — size
        // it for what the function actually writes.
        var extendedKeyBuffer = [CChar](repeating: 0, count: Int(HDKEYLEN))
        defer {
            zeroize(&masterKeyBuffer)
            zeroize(&pathBuffer)
            zeroize(&extendedKeyBuffer)
        }

        guard let privateKeyPtr = getHDNodePrivateKeyWIFByPath(
            &masterKeyBuffer,
            &pathBuffer,
            &extendedKeyBuffer,
            true  // Output private key
        ) else {
            throw DogecoinError.derivationFailed
        }

        let privateKeyWIF = String(cString: privateKeyPtr)

        // Free the allocated memory from the C function
        dogecoin_free(UnsafeMutableRawPointer(mutating: privateKeyPtr))

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
public func generateMnemonic(strength: MnemonicStrength = .words12) async throws -> String {
    try await Dogecoin.ensureInitialized()

    var mnemonic = [CChar](repeating: 0, count: Int(MAX_MNEMONIC_SIZE))
    var strengthBuffer = Array("\(strength.rawValue)".utf8CString)
    while strengthBuffer.count < 4 { strengthBuffer.append(0) }
    defer { zeroize(&mnemonic) }

    let result = generateRandomEnglishMnemonic(&strengthBuffer, &mnemonic)

    guard result == 0 else {
        throw DogecoinError.keyGenerationFailed
    }

    let phrase = String(decoding: mnemonic.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

    // Defense in depth: never hand out a phrase that would not restore.
    guard phrase.split(separator: " ").count == strength.wordCount, verifyMnemonic(phrase) else {
        throw DogecoinError.keyGenerationFailed
    }

    return phrase
}

private extension HDWallet {
    /// libdogecoin documents paths as at most `KEYPATHMAXLEN - 1` characters
    /// and asserts — aborting the process — on very long ones.
    static func validateLength(of path: String) throws {
        guard path.utf8.count < Int(KEYPATHMAXLEN) else {
            throw DogecoinError.derivationFailed
        }
    }

    static func stringFromCStringBuffer(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// NUL-terminated copy of `string`, zero-padded to at least `length` bytes
    /// for C functions whose prototypes declare fixed-size arrays.
    static func paddedCString(_ string: String, length: Int) -> [CChar] {
        var buffer = Array(string.utf8CString)
        if buffer.count < length {
            buffer.append(contentsOf: repeatElement(0, count: length - buffer.count))
        }
        return buffer
    }
}

private func zeroize(_ buffer: inout [UInt8]) {
    buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
}

private func zeroize(_ buffer: inout [CChar]) {
    buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
}

/// Validate a BIP39 mnemonic phrase using full BIP39 checksum validation
/// - Parameter mnemonic: The mnemonic phrase to validate
/// - Returns: `true` if the mnemonic is valid with correct checksum
public func validateMnemonic(_ mnemonic: String) -> Bool {
    verifyMnemonic(mnemonic)
}
