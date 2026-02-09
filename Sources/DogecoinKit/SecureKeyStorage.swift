import Foundation
import Security

// MARK: - Stored Credential Types

private enum KeychainStoreError: Error {
    case notFound
    case invalidData
    case unhandled(status: OSStatus)
}

extension KeychainStoreError: CustomStringConvertible {
    var description: String {
        switch self {
        case .notFound:
            return "Key not found"
        case .invalidData:
            return "Invalid keychain data"
        case .unhandled(let status):
            return "Keychain error (status: \(status))"
        }
    }
}

private struct KeychainStore {
    let service: String
    let account: String
    let accessGroup: String?

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    func read() throws -> String {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = kCFBooleanTrue

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeychainStoreError.notFound }
        guard status == errSecSuccess else { throw KeychainStoreError.unhandled(status: status) }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return value
    }

    func save(_ value: String) throws {
        let data = value.data(using: .utf8) ?? Data()
        var newItem = baseQuery
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(newItem as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.unhandled(status: updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw KeychainStoreError.unhandled(status: status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandled(status: status)
        }
    }
}

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

/// Manages secure storage of wallet credentials in the iOS Keychain
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
public actor SecureKeyStorage {

    /// The service name used for Keychain storage
    public nonisolated let serviceName: String

    /// Optional access group for Keychain sharing between apps
    public nonisolated let accessGroup: String?

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

            let store = KeychainStore(service: serviceName, account: accountName, accessGroup: accessGroup)
            try store.save(jsonString)
            return id
        } catch let error as DogecoinError {
            throw error
        } catch let error as KeychainStoreError {
            throw DogecoinError.keychainStorageFailed("\(error)")
        } catch {
            throw DogecoinError.keychainStorageFailed(error.localizedDescription)
        }
    }

    /// Retrieve wallet credentials from the Keychain
    /// - Parameter id: The identifier returned from `storeWalletCredentials`
    /// - Returns: The stored wallet credentials
    /// - Throws: `DogecoinError.keyNotFound` if not found, or `DogecoinError.keychainRetrievalFailed` on error
    public func retrieveWalletCredentials(id: String) throws -> StoredWalletCredentials {
let accountName = Self.walletCredentialsPrefix + id

        do {
            let store = KeychainStore(service: serviceName, account: accountName, accessGroup: accessGroup)
            let jsonString = try store.read()

            guard let jsonData = jsonString.data(using: .utf8) else {
                throw DogecoinError.keychainRetrievalFailed("Failed to decode stored data")
            }

            let credentials = try JSONDecoder().decode(StoredWalletCredentials.self, from: jsonData)
            return credentials
        } catch let error as DogecoinError {
            throw error
        } catch KeychainStoreError.notFound {
            throw DogecoinError.keyNotFound(id)
        } catch let error as KeychainStoreError {
            throw DogecoinError.keychainRetrievalFailed("\(error)")
        } catch {
            throw DogecoinError.keychainRetrievalFailed(error.localizedDescription)
        }
    }

    /// Delete wallet credentials from the Keychain
    /// - Parameter id: The identifier of the credentials to delete
    /// - Throws: `DogecoinError.keychainDeletionFailed` if deletion fails
    public func deleteWalletCredentials(id: String) throws {
let accountName = Self.walletCredentialsPrefix + id

        do {
            let store = KeychainStore(service: serviceName, account: accountName, accessGroup: accessGroup)
            try store.delete()
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
let id = UUID().uuidString
        let accountName = Self.masterKeyPrefix + id

        // Store as JSON with metadata
        let payload = MasterKeyPayload(masterKey: masterKey, network: network, storedAt: Date())

        do {
            let jsonData = try JSONEncoder().encode(payload)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw DogecoinError.keychainStorageFailed("Failed to encode master key")
            }

            let store = KeychainStore(service: serviceName, account: accountName, accessGroup: accessGroup)
            try store.save(jsonString)
            return id
        } catch let error as DogecoinError {
            throw error
        } catch let error as KeychainStoreError {
            throw DogecoinError.keychainStorageFailed("\(error)")
        } catch {
            throw DogecoinError.keychainStorageFailed(error.localizedDescription)
        }
    }

    /// Retrieve a master key from the Keychain
    /// - Parameter id: The identifier returned from `storeMasterKey`
    /// - Returns: A tuple containing the master key and network
    /// - Throws: `DogecoinError.keyNotFound` if not found
    public func retrieveMasterKey(id: String) throws -> (masterKey: String, network: DogecoinNetwork) {
let accountName = Self.masterKeyPrefix + id

        do {
            let store = KeychainStore(service: serviceName, account: accountName, accessGroup: accessGroup)
            let jsonString = try store.read()

            guard let jsonData = jsonString.data(using: .utf8) else {
                throw DogecoinError.keychainRetrievalFailed("Failed to decode stored data")
            }

            let payload = try JSONDecoder().decode(MasterKeyPayload.self, from: jsonData)
            return (payload.masterKey, payload.network)
        } catch let error as DogecoinError {
            throw error
        } catch KeychainStoreError.notFound {
            throw DogecoinError.keyNotFound(id)
        } catch let error as KeychainStoreError {
            throw DogecoinError.keychainRetrievalFailed("\(error)")
        } catch {
            throw DogecoinError.keyNotFound(id)
        }
    }

    /// Delete a master key from the Keychain
    /// - Parameter id: The identifier of the key to delete
    /// - Throws: `DogecoinError.keychainDeletionFailed` if deletion fails
    public func deleteMasterKey(id: String) throws {
let accountName = Self.masterKeyPrefix + id

        do {
            let store = KeychainStore(service: serviceName, account: accountName, accessGroup: accessGroup)
            try store.delete()
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
let id = UUID().uuidString
        let accountName = Self.privateKeyPrefix + id

        let payload = PrivateKeyPayload(privateKeyWIF: privateKeyWIF, address: address, storedAt: Date())

        do {
            let jsonData = try JSONEncoder().encode(payload)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw DogecoinError.keychainStorageFailed("Failed to encode private key")
            }

            let store = KeychainStore(service: serviceName, account: accountName, accessGroup: accessGroup)
            try store.save(jsonString)
            return id
        } catch let error as DogecoinError {
            throw error
        } catch let error as KeychainStoreError {
            throw DogecoinError.keychainStorageFailed("\(error)")
        } catch {
            throw DogecoinError.keychainStorageFailed(error.localizedDescription)
        }
    }

    /// Retrieve an individual private key from the Keychain
    /// - Parameter id: The identifier returned from `storePrivateKey`
    /// - Returns: A tuple containing the private key WIF and associated address
    /// - Throws: `DogecoinError.keyNotFound` if not found
    public func retrievePrivateKey(id: String) throws -> (privateKeyWIF: String, address: String) {
let accountName = Self.privateKeyPrefix + id

        do {
            let store = KeychainStore(service: serviceName, account: accountName, accessGroup: accessGroup)
            let jsonString = try store.read()

            guard let jsonData = jsonString.data(using: .utf8) else {
                throw DogecoinError.keychainRetrievalFailed("Failed to decode stored data")
            }

            let payload = try JSONDecoder().decode(PrivateKeyPayload.self, from: jsonData)
            return (payload.privateKeyWIF, payload.address)
        } catch let error as DogecoinError {
            throw error
        } catch KeychainStoreError.notFound {
            throw DogecoinError.keyNotFound(id)
        } catch let error as KeychainStoreError {
            throw DogecoinError.keychainRetrievalFailed("\(error)")
        } catch {
            throw DogecoinError.keyNotFound(id)
        }
    }

    /// Delete an individual private key from the Keychain
    /// - Parameter id: The identifier of the key to delete
    /// - Throws: `DogecoinError.keychainDeletionFailed` if deletion fails
    public func deletePrivateKey(id: String) throws {
let accountName = Self.privateKeyPrefix + id

        do {
            let store = KeychainStore(service: serviceName, account: accountName, accessGroup: accessGroup)
            try store.delete()
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
    ) async throws -> (wallet: HDWallet, keychainID: String) {
        // Create the wallet
        let wallet = try await HDWallet.create(strength: strength, passphrase: passphrase, network: network)

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
    public func restoreWallet(keychainID: String) async throws -> HDWallet {
        let credentials = try retrieveWalletCredentials(id: keychainID)

        return try await HDWallet(
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
    ) async throws -> (wallet: HDWallet, keychainID: String) {
        // Validate and create wallet from mnemonic
        let wallet = try await HDWallet(mnemonic: mnemonic, passphrase: passphrase, network: network)

        // Store credentials securely
        let keychainID = try storeWalletCredentials(
            mnemonic: mnemonic,
            passphrase: passphrase,
            network: network
        )

        return (wallet, keychainID)
    }
}
