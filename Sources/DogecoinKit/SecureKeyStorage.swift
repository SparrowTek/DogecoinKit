// The Keychain is Apple-only; on Android, keep secrets in the Android Keystore.
#if canImport(Security)
import Foundation
import Security
#if canImport(os)
import os.log
#endif

private let keychainLogger = Logger(subsystem: "DogecoinKit", category: "keychain")

// MARK: - Stored Credential Types

enum KeychainStoreError: Error {
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

/// Where credentials are kept, one item to an account: the Keychain, or —
/// in tests, which run where no Keychain can be reached — memory.
///
/// Failures are thrown as `KeychainStoreError`.
protocol CredentialStore: Sendable {
    /// The item's bytes. Callers pass them straight into a decoder, so they
    /// never pass through an intermediate `String`. (The decoded credentials
    /// are still Swift strings, which the language cannot zeroize.)
    func readData(account: String) throws -> Data

    /// Writes the item, replacing what is there.
    func saveData(_ data: Data, account: String) throws

    /// Whether the item exists — asked without reading its secret.
    func exists(account: String) throws -> Bool

    /// Deletes the item. Deleting one that is not there is not a failure.
    func delete(account: String) throws
}

struct KeychainStore: CredentialStore {
    let service: String
    let accessGroup: String?

    private func baseQuery(account: String) -> [String: Any] {
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

    /// How every item is protected: readable only while the device is
    /// unlocked, never migrated to another device through a backup, and
    /// never synchronized through iCloud Keychain.
    static var protection: [String: Any] {
        [
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    func readData(account: String) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = kCFBooleanTrue

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeychainStoreError.notFound }
        guard status == errSecSuccess else { throw KeychainStoreError.unhandled(status: status) }
        guard let data = item as? Data else {
            throw KeychainStoreError.invalidData
        }
        return data
    }

    /// Writes the item under ``protection``, whether it is new or replaces
    /// an older one.
    func saveData(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes = Self.protection.merging([kSecValueData as String: data]) { _, new in new }

        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.unhandled(status: updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw KeychainStoreError.unhandled(status: status)
        }
    }

    /// Asked without reading the secret, so the answer costs no decryption
    /// and leaves no copy of the data behind.
    func exists(account: String) throws -> Bool {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw KeychainStoreError.unhandled(status: status)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
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

/// Describes the credentials without the secrets, so logging or
/// interpolating a value can never print a recovery phrase.
extension StoredWalletCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "StoredWalletCredentials(network: \(network), storedAt: \(storedAt))"
    }

    public var debugDescription: String {
        description
    }
}

// MARK: - Secure Key Storage

/// Manages secure storage of wallet credentials in the Keychain (iOS and macOS)
///
/// This actor provides a thread-safe interface for storing, retrieving, and deleting
/// a wallet's recovery phrase.
///
/// ## Usage
///
/// ```swift
/// let storage = SecureKeyStorage(serviceName: "com.myapp.wallet")
///
/// // Store credentials
/// let id = try await storage.storeWalletCredentials(
///     mnemonic: "abandon abandon...",
///     passphrase: "",
///     network: .mainnet
/// )
///
/// // Retrieve credentials
/// let credentials = try await storage.retrieveWalletCredentials(id: id)
///
/// // Delete when done
/// try await storage.deleteWalletCredentials(id: id)
/// ```
public actor SecureKeyStorage {

    /// The service name used for Keychain storage
    public nonisolated let serviceName: String

    /// Optional access group for Keychain sharing between apps
    public nonisolated let accessGroup: String?

    /// Prefix for wallet credential keys
    private static let walletCredentialsPrefix = "wallet.credentials."

    private let store: any CredentialStore

    /// Create a new secure key storage instance
    /// - Parameters:
    ///   - serviceName: The service identifier for Keychain entries (e.g., "com.myapp.wallet")
    ///   - accessGroup: Optional access group for sharing between apps
    public init(serviceName: String, accessGroup: String? = nil) {
        self.init(
            serviceName: serviceName,
            accessGroup: accessGroup,
            store: KeychainStore(service: serviceName, accessGroup: accessGroup)
        )
    }

    init(serviceName: String, accessGroup: String? = nil, store: any CredentialStore) {
        self.serviceName = serviceName
        self.accessGroup = accessGroup
        self.store = store
    }

    // MARK: - Wallet Credentials

    /// Store wallet credentials securely in the Keychain
    ///
    /// Only a phrase that passes ``verifyMnemonic(_:language:)`` is stored.
    /// ``restoreWallet(keychainID:)`` derives the wallet from the stored
    /// text without checking it again, so nothing unchecked may get in.
    /// - Parameters:
    ///   - mnemonic: The BIP39 mnemonic phrase, as
    ///     ``normalizedMnemonic(_:)`` writes it
    ///   - passphrase: Optional BIP39 passphrase (default: empty)
    ///   - network: The Dogecoin network
    /// - Returns: A unique identifier for retrieving these credentials later
    /// - Throws: `DogecoinError.invalidMnemonic` if the phrase is not valid,
    ///   or `DogecoinError.keychainStorageFailed` if storage fails
    public func storeWalletCredentials(
        mnemonic: String,
        passphrase: String = "",
        network: DogecoinNetwork
    ) throws -> String {
        guard verifyMnemonic(mnemonic) else {
            throw DogecoinError.invalidMnemonic
        }

        let credentials = StoredWalletCredentials(
            mnemonic: mnemonic,
            passphrase: passphrase,
            network: network
        )

        let id = UUID().uuidString
        let accountName = Self.walletCredentialsPrefix + id

        do {
            // Zeroed once the Keychain has its own copy. (The encoder's
            // working memory and the Swift strings are beyond reach.)
            var jsonData = try JSONEncoder().encode(credentials)
            defer { jsonData.resetBytes(in: jsonData.startIndex..<jsonData.endIndex) }

            try store.saveData(jsonData, account: accountName)
            keychainLogger.info("Stored wallet credentials id=\(id, privacy: .public) network=\(String(describing: network), privacy: .public)")
            return id
        } catch let error as KeychainStoreError {
            keychainLogger.error("Store wallet credentials failed id=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw DogecoinError.keychainStorageFailed("\(error)")
        } catch {
            keychainLogger.error("Store wallet credentials failed id=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
            var jsonData = try store.readData(account: accountName)
            defer { jsonData.resetBytes(in: jsonData.startIndex..<jsonData.endIndex) }
            let credentials = try JSONDecoder().decode(StoredWalletCredentials.self, from: jsonData)
            keychainLogger.debug("Retrieved wallet credentials id=\(id, privacy: .public)")
            return credentials
        } catch KeychainStoreError.notFound {
            keychainLogger.error("Wallet credentials not found id=\(id, privacy: .public)")
            throw DogecoinError.keyNotFound(id)
        } catch let error as KeychainStoreError {
            keychainLogger.error("Retrieve wallet credentials failed id=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw DogecoinError.keychainRetrievalFailed("\(error)")
        } catch {
            keychainLogger.error("Retrieve wallet credentials failed id=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw DogecoinError.keychainRetrievalFailed(error.localizedDescription)
        }
    }

    /// Delete wallet credentials from the Keychain
    /// - Parameter id: The identifier of the credentials to delete
    /// - Throws: `DogecoinError.keychainDeletionFailed` if deletion fails
    public func deleteWalletCredentials(id: String) throws {
        let accountName = Self.walletCredentialsPrefix + id

        do {
            try store.delete(account: accountName)
            keychainLogger.info("Deleted wallet credentials id=\(id, privacy: .public)")
        } catch {
            // `"\(error)"`, not `localizedDescription`: only the former
            // carries the Keychain status code.
            keychainLogger.error("Delete wallet credentials failed id=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw DogecoinError.keychainDeletionFailed("\(error)")
        }
    }

    /// Check if wallet credentials exist for the given ID
    ///
    /// The Keychain is only asked whether the item is there; the phrase is
    /// not read.
    /// - Parameter id: The identifier to check
    /// - Returns: `true` if credentials exist
    /// - Throws: `DogecoinError.keychainRetrievalFailed` when the Keychain
    ///   cannot say — while the device is locked, for one. That is not the
    ///   same as the credentials being gone.
    public func walletCredentialsExist(id: String) throws -> Bool {
        do {
            return try store.exists(account: Self.walletCredentialsPrefix + id)
        } catch {
            keychainLogger.error("Could not check wallet credentials id=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw DogecoinError.keychainRetrievalFailed("\(error)")
        }
    }
}

// MARK: - Convenience Extensions

extension SecureKeyStorage {

    /// Restore an HD wallet from stored credentials
    /// - Parameter keychainID: The ID returned from `importAndStoreWallet` or `storeWalletCredentials`
    /// - Returns: The restored HD wallet
    /// - Throws: `DogecoinError` if retrieval or wallet creation fails
    public func restoreWallet(keychainID: String) async throws -> HDWallet {
        let credentials = try retrieveWalletCredentials(id: keychainID)

        // The phrase was validated when it was stored; a wallet holding funds
        // must stay restorable — from exactly the stored text — even if
        // validation gets stricter later.
        return try await HDWallet(
            acceptedMnemonic: credentials.mnemonic,
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

        // Store the phrase the wallet was derived from — the normalized
        // one — so restoring opens the same wallet.
        let keychainID = try storeWalletCredentials(
            mnemonic: wallet.mnemonic,
            passphrase: passphrase,
            network: network
        )

        return (wallet, keychainID)
    }
}
#endif
