import Foundation
import Vault

// MARK: - Stored Credential Types

/// Represents wallet credentials stored in the Keychain
public struct StoredWalletCredentials: Codable, Sendable {
    /// The BIP39 mnemonic phrase
    public let mnemonic: String

    /// The optional BIP39 passphrase (empty string if none)
    public let passphrase: String

    /// The network this wallet was created for
    public let network: DogecoinNetwork

    /// Timestamp when these credentials were stored
    public let storedAt: Date

    public init(mnemonic: String, passphrase: String = "", network: DogecoinNetwork) {
        self.mnemonic = mnemonic
        self.passphrase = passphrase
        self.network = network
        self.storedAt = Date()
    }
}

/// Codable conformance for DogecoinNetwork
extension DogecoinNetwork: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Int.self)
        self = value == 1 ? .testnet : .mainnet
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self == .testnet ? 1 : 0)
    }
}

// MARK: - Secure Key Storage

/// Manages secure storage of wallet credentials in the iOS Keychain via Vault
///
/// This class provides a thread-safe interface for storing, retrieving, and deleting
/// sensitive wallet data such as mnemonic phrases and master keys.
///
/// ## Usage
///
/// ```swift
/// let storage = SecureKeyStorage(serviceName: "com.myapp.wallet")
///
/// // Store credentials
/// let id = try storage.storeWalletCredentials(
///     mnemonic: "abandon abandon...",
///     passphrase: "",
///     network: .mainnet
/// )
///
/// // Retrieve credentials
/// let credentials = try storage.retrieveWalletCredentials(id: id)
///
/// // Delete when done
/// try storage.deleteWalletCredentials(id: id)
/// ```
public final class SecureKeyStorage: Sendable {

    /// The service name used for Keychain storage
    public let serviceName: String

    /// Optional access group for Keychain sharing between apps
    public let accessGroup: String?

    /// Thread-safe lock for operations
    private let lock = NSLock()

    /// Prefix for wallet credential keys
    private static let walletCredentialsPrefix = "wallet.credentials."

    /// Prefix for master key storage
    private static let masterKeyPrefix = "wallet.masterkey."

    /// Prefix for individual private key storage
    private static let privateKeyPrefix = "wallet.privatekey."

    /// Create a new secure key storage instance
    /// - Parameters:
    ///   - serviceName: The service identifier for Keychain entries (e.g., "com.myapp.wallet")
    ///   - accessGroup: Optional access group for sharing between apps
    public init(serviceName: String, accessGroup: String? = nil) {
        self.serviceName = serviceName
        self.accessGroup = accessGroup
    }

    // MARK: - Wallet Credentials

    /// Store wallet credentials securely in the Keychain
    /// - Parameters:
    ///   - mnemonic: The BIP39 mnemonic phrase
    ///   - passphrase: Optional BIP39 passphrase (default: empty)
    ///   - network: The Dogecoin network
    /// - Returns: A unique identifier for retrieving these credentials later
    /// - Throws: `DogecoinError.keychainStorageFailed` if storage fails
    public func storeWalletCredentials(
        mnemonic: String,
        passphrase: String = "",
        network: DogecoinNetwork
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let credentials = StoredWalletCredentials(
            mnemonic: mnemonic,
            passphrase: passphrase,
            network: network
        )

        let id = UUID().uuidString
        let accountName = Self.walletCredentialsPrefix + id

        do {
            let jsonData = try JSONEncoder().encode(credentials)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw DogecoinError.keychainStorageFailed("Failed to encode credentials")
            }

            let config = KeychainConfiguration(
                serviceName: serviceName,
                accessGroup: accessGroup,
                accountName: accountName
            )

            try Vault.savePrivateKey(jsonString, keychainConfiguration: config)
            return id
        } catch let error as DogecoinError {
            throw error
        } catch {
            throw DogecoinError.keychainStorageFailed(error.localizedDescription)
        }
    }

    /// Retrieve wallet credentials from the Keychain
    /// - Parameter id: The identifier returned from `storeWalletCredentials`
    /// - Returns: The stored wallet credentials
    /// - Throws: `DogecoinError.keyNotFound` if not found, or `DogecoinError.keychainRetrievalFailed` on error
    public func retrieveWalletCredentials(id: String) throws -> StoredWalletCredentials {
        lock.lock()
        defer { lock.unlock() }

        let accountName = Self.walletCredentialsPrefix + id

        do {
            let config = KeychainConfiguration(
                serviceName: serviceName,
                accessGroup: accessGroup,
                accountName: accountName
            )

            let jsonString = try Vault.getPrivateKey(keychainConfiguration: config)

            guard let jsonData = jsonString.data(using: .utf8) else {
                throw DogecoinError.keychainRetrievalFailed("Failed to decode stored data")
            }

            let credentials = try JSONDecoder().decode(StoredWalletCredentials.self, from: jsonData)
            return credentials
        } catch let error as DogecoinError {
            throw error
        } catch let error as VaultError {
            if case .noKeychainConfiguration = error {
                throw DogecoinError.keyNotFound(id)
            }
            throw DogecoinError.keychainRetrievalFailed(error.localizedDescription)
        } catch {
            throw DogecoinError.keychainRetrievalFailed(error.localizedDescription)
        }
    }

    /// Delete wallet credentials from the Keychain
    /// - Parameter id: The identifier of the credentials to delete
    /// - Throws: `DogecoinError.keychainDeletionFailed` if deletion fails
    public func deleteWalletCredentials(id: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let accountName = Self.walletCredentialsPrefix + id

        do {
            let config = KeychainConfiguration(
                serviceName: serviceName,
                accessGroup: accessGroup,
                accountName: accountName
            )

            try Vault.deletePrivateKey(keychainConfiguration: config)
        } catch {
            throw DogecoinError.keychainDeletionFailed(error.localizedDescription)
        }
    }

    /// Check if wallet credentials exist for the given ID
    /// - Parameter id: The identifier to check
    /// - Returns: `true` if credentials exist
    public func walletCredentialsExist(id: String) -> Bool {
        do {
            _ = try retrieveWalletCredentials(id: id)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Master Key Storage

    /// Store a master private key securely
    /// - Parameters:
    ///   - masterKey: The HD master private key
    ///   - network: The Dogecoin network
    /// - Returns: A unique identifier for retrieving the key later
    /// - Throws: `DogecoinError.keychainStorageFailed` if storage fails
    public func storeMasterKey(_ masterKey: String, network: DogecoinNetwork) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let id = UUID().uuidString
        let accountName = Self.masterKeyPrefix + id

        // Store as JSON with metadata
        let payload = MasterKeyPayload(masterKey: masterKey, network: network, storedAt: Date())

        do {
            let jsonData = try JSONEncoder().encode(payload)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw DogecoinError.keychainStorageFailed("Failed to encode master key")
            }

            let config = KeychainConfiguration(
                serviceName: serviceName,
                accessGroup: accessGroup,
                accountName: accountName
            )

            try Vault.savePrivateKey(jsonString, keychainConfiguration: config)
            return id
        } catch let error as DogecoinError {
            throw error
        } catch {
            throw DogecoinError.keychainStorageFailed(error.localizedDescription)
        }
    }

    /// Retrieve a master key from the Keychain
    /// - Parameter id: The identifier returned from `storeMasterKey`
    /// - Returns: A tuple containing the master key and network
    /// - Throws: `DogecoinError.keyNotFound` if not found
    public func retrieveMasterKey(id: String) throws -> (masterKey: String, network: DogecoinNetwork) {
        lock.lock()
        defer { lock.unlock() }

        let accountName = Self.masterKeyPrefix + id

        do {
            let config = KeychainConfiguration(
                serviceName: serviceName,
                accessGroup: accessGroup,
                accountName: accountName
            )

            let jsonString = try Vault.getPrivateKey(keychainConfiguration: config)

            guard let jsonData = jsonString.data(using: .utf8) else {
                throw DogecoinError.keychainRetrievalFailed("Failed to decode stored data")
            }

            let payload = try JSONDecoder().decode(MasterKeyPayload.self, from: jsonData)
            return (payload.masterKey, payload.network)
        } catch let error as DogecoinError {
            throw error
        } catch {
            throw DogecoinError.keyNotFound(id)
        }
    }

    /// Delete a master key from the Keychain
    /// - Parameter id: The identifier of the key to delete
    /// - Throws: `DogecoinError.keychainDeletionFailed` if deletion fails
    public func deleteMasterKey(id: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let accountName = Self.masterKeyPrefix + id

        do {
            let config = KeychainConfiguration(
                serviceName: serviceName,
                accessGroup: accessGroup,
                accountName: accountName
            )

            try Vault.deletePrivateKey(keychainConfiguration: config)
        } catch {
            throw DogecoinError.keychainDeletionFailed(error.localizedDescription)
        }
    }

    // MARK: - Private Key Storage (for individual keys)

    /// Store an individual private key (WIF format)
    /// - Parameters:
    ///   - privateKeyWIF: The private key in Wallet Import Format
    ///   - address: The associated address (for identification)
    /// - Returns: A unique identifier for retrieving the key later
    /// - Throws: `DogecoinError.keychainStorageFailed` if storage fails
    public func storePrivateKey(_ privateKeyWIF: String, address: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let id = UUID().uuidString
        let accountName = Self.privateKeyPrefix + id

        let payload = PrivateKeyPayload(privateKeyWIF: privateKeyWIF, address: address, storedAt: Date())

        do {
            let jsonData = try JSONEncoder().encode(payload)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw DogecoinError.keychainStorageFailed("Failed to encode private key")
            }

            let config = KeychainConfiguration(
                serviceName: serviceName,
                accessGroup: accessGroup,
                accountName: accountName
            )

            try Vault.savePrivateKey(jsonString, keychainConfiguration: config)
            return id
        } catch let error as DogecoinError {
            throw error
        } catch {
            throw DogecoinError.keychainStorageFailed(error.localizedDescription)
        }
    }

    /// Retrieve an individual private key from the Keychain
    /// - Parameter id: The identifier returned from `storePrivateKey`
    /// - Returns: A tuple containing the private key WIF and associated address
    /// - Throws: `DogecoinError.keyNotFound` if not found
    public func retrievePrivateKey(id: String) throws -> (privateKeyWIF: String, address: String) {
        lock.lock()
        defer { lock.unlock() }

        let accountName = Self.privateKeyPrefix + id

        do {
            let config = KeychainConfiguration(
                serviceName: serviceName,
                accessGroup: accessGroup,
                accountName: accountName
            )

            let jsonString = try Vault.getPrivateKey(keychainConfiguration: config)

            guard let jsonData = jsonString.data(using: .utf8) else {
                throw DogecoinError.keychainRetrievalFailed("Failed to decode stored data")
            }

            let payload = try JSONDecoder().decode(PrivateKeyPayload.self, from: jsonData)
            return (payload.privateKeyWIF, payload.address)
        } catch let error as DogecoinError {
            throw error
        } catch {
            throw DogecoinError.keyNotFound(id)
        }
    }

    /// Delete an individual private key from the Keychain
    /// - Parameter id: The identifier of the key to delete
    /// - Throws: `DogecoinError.keychainDeletionFailed` if deletion fails
    public func deletePrivateKey(id: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let accountName = Self.privateKeyPrefix + id

        do {
            let config = KeychainConfiguration(
                serviceName: serviceName,
                accessGroup: accessGroup,
                accountName: accountName
            )

            try Vault.deletePrivateKey(keychainConfiguration: config)
        } catch {
            throw DogecoinError.keychainDeletionFailed(error.localizedDescription)
        }
    }
}

// MARK: - Internal Payload Types

/// Internal payload for master key storage
private struct MasterKeyPayload: Codable {
    let masterKey: String
    let network: DogecoinNetwork
    let storedAt: Date
}

/// Internal payload for private key storage
private struct PrivateKeyPayload: Codable {
    let privateKeyWIF: String
    let address: String
    let storedAt: Date
}

// MARK: - Convenience Extensions

extension SecureKeyStorage {

    /// Create and securely store a new HD wallet
    /// - Parameters:
    ///   - strength: The mnemonic strength (default: 12 words)
    ///   - passphrase: Optional BIP39 passphrase
    ///   - network: The Dogecoin network
    /// - Returns: A tuple containing the new wallet and its storage ID
    /// - Throws: `DogecoinError` if wallet creation or storage fails
    public func createAndStoreWallet(
        strength: MnemonicStrength = .words12,
        passphrase: String = "",
        network: DogecoinNetwork = .mainnet
    ) throws -> (wallet: HDWallet, keychainID: String) {
        // Create the wallet
        let wallet = try HDWallet.create(strength: strength, passphrase: passphrase, network: network)

        // Store credentials securely
        guard let mnemonic = wallet.mnemonic else {
            throw DogecoinError.internalError("Wallet created without mnemonic")
        }

        let keychainID = try storeWalletCredentials(
            mnemonic: mnemonic,
            passphrase: passphrase,
            network: network
        )

        return (wallet, keychainID)
    }

    /// Restore an HD wallet from stored credentials
    /// - Parameter keychainID: The ID returned from `createAndStoreWallet` or `storeWalletCredentials`
    /// - Returns: The restored HD wallet
    /// - Throws: `DogecoinError` if retrieval or wallet creation fails
    public func restoreWallet(keychainID: String) throws -> HDWallet {
        let credentials = try retrieveWalletCredentials(id: keychainID)

        return try HDWallet(
            mnemonic: credentials.mnemonic,
            passphrase: credentials.passphrase,
            network: credentials.network
        )
    }

    /// Import a wallet from a mnemonic and store it securely
    /// - Parameters:
    ///   - mnemonic: The BIP39 mnemonic phrase
    ///   - passphrase: Optional BIP39 passphrase
    ///   - network: The Dogecoin network
    /// - Returns: A tuple containing the imported wallet and its storage ID
    /// - Throws: `DogecoinError` if the mnemonic is invalid or storage fails
    public func importAndStoreWallet(
        mnemonic: String,
        passphrase: String = "",
        network: DogecoinNetwork = .mainnet
    ) throws -> (wallet: HDWallet, keychainID: String) {
        // Validate and create wallet from mnemonic
        let wallet = try HDWallet(mnemonic: mnemonic, passphrase: passphrase, network: network)

        // Store credentials securely
        let keychainID = try storeWalletCredentials(
            mnemonic: mnemonic,
            passphrase: passphrase,
            network: network
        )

        return (wallet, keychainID)
    }
}
