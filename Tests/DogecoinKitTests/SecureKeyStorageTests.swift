#if canImport(Security)
import Foundation
import Security
import Testing
@testable import DogecoinKit

/// Credentials kept in memory. A plain `swift test` process cannot reach a
/// Keychain, and without this everything `SecureKeyStorage` does around one
/// would go untested there.
private final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var failure: OSStatus?

    /// The accounts holding an item
    var accounts: [String] {
        lock.withLock { items.keys.sorted() }
    }

    /// Puts raw bytes where an item would be.
    func plant(_ data: Data, account: String) {
        lock.withLock { items[account] = data }
    }

    func data(account: String) -> Data? {
        lock.withLock { items[account] }
    }

    /// Makes every call fail with `status`, as the Keychain does when it
    /// cannot serve one — or, with nil, work again.
    func fail(with status: OSStatus?) {
        lock.withLock { failure = status }
    }

    private func checked<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            if let failure {
                throw KeychainStoreError.unhandled(status: failure)
            }
            return try body()
        }
    }

    func readData(account: String) throws -> Data {
        try checked {
            guard let data = items[account] else { throw KeychainStoreError.notFound }
            return data
        }
    }

    func saveData(_ data: Data, account: String) throws {
        try checked { items[account] = data }
    }

    func exists(account: String) throws -> Bool {
        try checked { items[account] != nil }
    }

    func delete(account: String) throws {
        try checked { items[account] = nil }
    }
}

private let phrase = testPhrase

@Suite("Secure Key Storage")
struct SecureKeyStorageTests {

    private let store = MemoryCredentialStore()
    private let storage: SecureKeyStorage

    init() {
        storage = SecureKeyStorage(serviceName: "com.dogecoinkit.tests", store: store)
    }

    private func account(_ id: String) -> String {
        "wallet.credentials." + id
    }

    // MARK: - Storing and reading

    @Test("What is stored is read back: phrase, passphrase, and network")
    func roundTrip() async throws {
        let mnemonic = try await generateMnemonic(strength: .words24)

        let id = try await storage.storeWalletCredentials(mnemonic: mnemonic, passphrase: "correct horse", network: .testnet)
        let credentials = try await storage.retrieveWalletCredentials(id: id)

        #expect(credentials.mnemonic == mnemonic)
        #expect(credentials.passphrase == "correct horse")
        #expect(credentials.network == .testnet)
        #expect(credentials.storedAt.timeIntervalSinceNow > -60)
    }

    @Test("Without a passphrase, the empty one is stored")
    func defaultPassphrase() async throws {
        let id = try await storage.storeWalletCredentials(mnemonic: phrase, network: .mainnet)

        let credentials = try await storage.retrieveWalletCredentials(id: id)
        #expect(credentials.passphrase.isEmpty)
        #expect(credentials.network == .mainnet)
    }

    @Test("Each wallet gets an item of its own, under an account its id leads to")
    func separateItems() async throws {
        let other = try await generateMnemonic(strength: .words12)

        let first = try await storage.storeWalletCredentials(mnemonic: phrase, network: .mainnet)
        let second = try await storage.storeWalletCredentials(mnemonic: other, network: .testnet)

        #expect(first != second)
        // Wallets already in a Keychain are found by exactly these names.
        #expect(store.accounts == [account(first), account(second)].sorted())
        #expect(try await storage.retrieveWalletCredentials(id: first).mnemonic == phrase)
        #expect(try await storage.retrieveWalletCredentials(id: second).mnemonic == other)
    }

    @Test("Credentials exist until they are deleted, and deleting twice is no error")
    func deleting() async throws {
        let id = try await storage.storeWalletCredentials(mnemonic: phrase, network: .testnet)
        #expect(try await storage.walletCredentialsExist(id: id))

        try await storage.deleteWalletCredentials(id: id)

        #expect(try await !storage.walletCredentialsExist(id: id))
        #expect(store.accounts.isEmpty)
        try await storage.deleteWalletCredentials(id: id)
    }

    @Test("Asking for credentials that were never stored says they are not there")
    func missing() async throws {
        let id = UUID().uuidString

        #expect(try await !storage.walletCredentialsExist(id: id))
        await #expect(throws: DogecoinError.keyNotFound(id)) {
            _ = try await storage.retrieveWalletCredentials(id: id)
        }
        await #expect(throws: DogecoinError.keyNotFound(id)) {
            _ = try await storage.restoreWallet(keychainID: id)
        }
    }

    // MARK: - What gets in

    private static let unusablePhrases: [String] = [
        "",
        "test mnemonic",
        // Every word is on the list, but the checksum is wrong.
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon",
        // Valid once normalized — stored text must already be normalized.
        "Abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
    ]

    @Test("A phrase that is not valid BIP 39 is never stored", arguments: unusablePhrases)
    func invalidPhrase(text: String) async {
        await #expect(throws: DogecoinError.invalidMnemonic) {
            _ = try await storage.storeWalletCredentials(mnemonic: text, network: .testnet)
        }
        #expect(store.accounts.isEmpty)
    }

    @Test("An imported phrase is stored the way its wallet was derived from it, and restores that wallet")
    func importing() async throws {
        let typed = "  Abandon abandon  ABANDON abandon abandon abandon abandon abandon abandon abandon abandon\nabout "
        let expected = try await HDWallet(mnemonic: phrase, passphrase: "extra", network: .testnet)

        let (wallet, id) = try await storage.importAndStoreWallet(mnemonic: typed, passphrase: "extra", network: .testnet)

        #expect(wallet.masterKey == expected.masterKey)
        #expect(try await storage.retrieveWalletCredentials(id: id).mnemonic == phrase)

        let restored = try await storage.restoreWallet(keychainID: id)
        #expect(restored.masterKey == expected.masterKey)
        #expect(restored.network == .testnet)
        #expect(try await restored.deriveAddress(account: 0, index: 0) == expected.deriveAddress(account: 0, index: 0))
        // The passphrase is part of the seed: without it, another wallet.
        #expect(try await HDWallet(mnemonic: phrase, network: .testnet).masterKey != restored.masterKey)
    }

    @Test("A phrase that does not import stores nothing")
    func failedImport() async {
        await #expect(throws: DogecoinError.invalidMnemonic) {
            _ = try await storage.importAndStoreWallet(mnemonic: "abandon abandon abandon", network: .mainnet)
        }
        #expect(store.accounts.isEmpty)
    }

    // MARK: - What is on disk

    @Test("The stored item is the JSON that wallets already in a Keychain were written as")
    func storedFormat() async throws {
        let id = try await storage.storeWalletCredentials(mnemonic: phrase, passphrase: "p", network: .testnet)

        let stored = try #require(store.data(account: account(id)))
        let object = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])

        #expect(Set(object.keys) == ["mnemonic", "passphrase", "network", "storedAt"])
        #expect(object["mnemonic"] as? String == phrase)
        #expect(object["passphrase"] as? String == "p")
        #expect(object["network"] as? Int == 1)
    }

    @Test("An item written by an earlier version still opens its wallet")
    func earlierItem() async throws {
        let id = UUID().uuidString
        let item = #"{"mnemonic":"\#(phrase)","passphrase":"","network":0,"storedAt":786000000}"#
        store.plant(Data(item.utf8), account: account(id))

        let credentials = try await storage.retrieveWalletCredentials(id: id)
        #expect(credentials.mnemonic == phrase)
        #expect(credentials.network == .mainnet)
        #expect(credentials.storedAt == Date(timeIntervalSinceReferenceDate: 786_000_000))

        let expected = try await HDWallet(mnemonic: phrase, network: .mainnet)
        #expect(try await storage.restoreWallet(keychainID: id).masterKey == expected.masterKey)
    }

    private static let unreadableItems: [String] = [
        "not json",
        "{}",
        // A network this version does not know must not be read as mainnet.
        #"{"mnemonic":"abandon","passphrase":"","network":7,"storedAt":0}"#,
        #"{"mnemonic":"abandon","passphrase":"","network":"mainnet","storedAt":0}"#,
    ]

    @Test("An item that cannot be read is an error of its own, not a missing wallet", arguments: unreadableItems)
    func unreadableItem(item: String) async throws {
        let id = UUID().uuidString
        store.plant(Data(item.utf8), account: account(id))

        // It is there: only reading it fails.
        #expect(try await storage.walletCredentialsExist(id: id))
        let retrieval = await #expect(throws: DogecoinError.self) {
            _ = try await storage.retrieveWalletCredentials(id: id)
        }
        guard case .keychainRetrievalFailed = retrieval else {
            Issue.record("Expected keychainRetrievalFailed, got \(String(describing: retrieval))")
            return
        }
        let restore = await #expect(throws: DogecoinError.self) {
            _ = try await storage.restoreWallet(keychainID: id)
        }
        #expect(restore == retrieval)
    }

    // MARK: - When the Keychain cannot answer

    @Test("A Keychain that cannot be reached is reported with its status, by every operation")
    func unreachableKeychain() async throws {
        let id = try await storage.storeWalletCredentials(mnemonic: phrase, network: .testnet)
        // What the Keychain answers while the device is locked.
        store.fail(with: errSecInteractionNotAllowed)
        let reason = "Keychain error (status: -25308)"

        await #expect(throws: DogecoinError.keychainStorageFailed(reason)) {
            _ = try await storage.storeWalletCredentials(mnemonic: phrase, network: .testnet)
        }
        await #expect(throws: DogecoinError.keychainRetrievalFailed(reason)) {
            _ = try await storage.retrieveWalletCredentials(id: id)
        }
        await #expect(throws: DogecoinError.keychainRetrievalFailed(reason)) {
            _ = try await storage.restoreWallet(keychainID: id)
        }
        // "Cannot tell" must never read as "not there": a caller that took
        // it for that would set the wallet up anew.
        await #expect(throws: DogecoinError.keychainRetrievalFailed(reason)) {
            _ = try await storage.walletCredentialsExist(id: id)
        }
        await #expect(throws: DogecoinError.keychainDeletionFailed(reason)) {
            try await storage.deleteWalletCredentials(id: id)
        }

        store.fail(with: nil)
        #expect(try await storage.retrieveWalletCredentials(id: id).mnemonic == phrase)
    }

    // MARK: - Leaks

    @Test("Credentials describe themselves without their secrets")
    func description() {
        let credentials = StoredWalletCredentials(mnemonic: phrase, passphrase: "hunter2", network: .mainnet)

        for text in [String(describing: credentials), String(reflecting: credentials), "\(credentials)"] {
            #expect(!text.contains("abandon"))
            #expect(!text.contains("hunter2"))
        }
    }

    @Test("A network is stored as 0 or 1, and nothing else reads as one")
    func networkCoding() throws {
        let encoded = try JSONEncoder().encode([DogecoinNetwork.mainnet, .testnet])

        #expect(String(decoding: encoded, as: UTF8.self) == "[0,1]")
        #expect(try JSONDecoder().decode([DogecoinNetwork].self, from: encoded) == [.mainnet, .testnet])
        for unknown in ["[2]", "[-1]", #"["mainnet"]"#] {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode([DogecoinNetwork].self, from: Data(unknown.utf8))
            }
        }
    }
}

// MARK: - The real Keychain

/// Keychain items need an entitled host (an app, on a device or simulator).
/// A plain `swift test` process has none, so these are skipped there — and
/// reported as skipped — rather than passing without running.
private let needsKeychain: ConditionTrait = .enabled("The Keychain is not reachable from this test process") {
    // Only writing shows it: an unentitled process may ask about items — and
    // is told there are none — but cannot add one.
    let storage = SecureKeyStorage(serviceName: keychainServiceName)
    do {
        let id = try await storage.storeWalletCredentials(mnemonic: phrase, network: .testnet)
        try await storage.deleteWalletCredentials(id: id)
        return true
    } catch {
        return false
    }
}

private let keychainServiceName = "com.dogecoinkit.tests"

@Suite("Keychain")
struct KeychainTests {

    @Test("Every item is readable only while this device is unlocked, and never leaves it")
    func protection() {
        let protection = KeychainStore.protection

        #expect(protection[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(protection[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(protection.count == 2)
    }

    @Test("Credentials make the round trip through the real Keychain, protected as they should be", needsKeychain)
    func realKeychain() async throws {
        let storage = SecureKeyStorage(serviceName: keychainServiceName)
        let id = try await storage.storeWalletCredentials(mnemonic: phrase, passphrase: "p", network: .testnet)

        do {
            let credentials = try await storage.retrieveWalletCredentials(id: id)
            #expect(credentials.mnemonic == phrase)
            #expect(credentials.passphrase == "p")
            #expect(try await storage.walletCredentialsExist(id: id))

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainServiceName,
                kSecAttrAccount as String: "wallet.credentials." + id,
                kSecUseDataProtectionKeychain as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnAttributes as String: true,
            ]
            var item: CFTypeRef?
            #expect(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess)
            let attributes = try #require(item as? [String: Any])
            #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            #expect(attributes[kSecAttrSynchronizable as String] as? Bool != true)
        } catch {
            try? await storage.deleteWalletCredentials(id: id)
            throw error
        }

        try await storage.deleteWalletCredentials(id: id)
        #expect(try await !storage.walletCredentialsExist(id: id))
    }
}
#endif
