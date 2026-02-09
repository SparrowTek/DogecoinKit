import Testing
import Foundation
@testable import DogecoinKit

/// Tests for SecureKeyStorage
/// Note: Keychain tests require a host app context (simulator or device)
/// These tests may fail in pure CLI test runners without Keychain access
@Suite("Secure Key Storage Tests")
struct SecureKeyStorageTests {

    let storage: SecureKeyStorage

    init() async {
        await Dogecoin.initialize()
        storage = SecureKeyStorage(serviceName: "com.dogecoinkit.tests")
    }

    private func requireKeychain() async -> Bool {
        do {
            let id = try await storage.storeMasterKey("availability-probe", network: .testnet)
            try await storage.deleteMasterKey(id: id)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Wallet Credentials Tests

    @Test("Store and retrieve wallet credentials")
    func testStoreAndRetrieveCredentials() async throws {
        guard await requireKeychain() else { return }
        let mnemonic = try await generateMnemonic(strength: .words12)
        let passphrase = "testpassphrase"
        let network = DogecoinNetwork.testnet

        // Store
        let id = try await storage.storeWalletCredentials(
            mnemonic: mnemonic,
            passphrase: passphrase,
            network: network
        )

        #expect(!id.isEmpty)

        // Retrieve
        let retrieved = try await storage.retrieveWalletCredentials(id: id)

        #expect(retrieved.mnemonic == mnemonic)
        #expect(retrieved.passphrase == passphrase)
        #expect(retrieved.network == network)

        // Cleanup
        try await storage.deleteWalletCredentials(id: id)
    }

    @Test("Wallet credentials with empty passphrase")
    func testCredentialsEmptyPassphrase() async throws {
        guard await requireKeychain() else { return }
        let mnemonic = try await generateMnemonic(strength: .words12)

        let id = try await storage.storeWalletCredentials(
            mnemonic: mnemonic,
            network: .mainnet
        )

        let retrieved = try await storage.retrieveWalletCredentials(id: id)

        #expect(retrieved.passphrase.isEmpty)
        #expect(retrieved.network == .mainnet)

        try await storage.deleteWalletCredentials(id: id)
    }

    @Test("Delete wallet credentials")
    func testDeleteCredentials() async throws {
        guard await requireKeychain() else { return }
        let mnemonic = try await generateMnemonic(strength: .words12)

        let id = try await storage.storeWalletCredentials(
            mnemonic: mnemonic,
            network: .testnet
        )

        // Verify exists
        let exists = await storage.walletCredentialsExist(id: id)
        #expect(exists)

        // Delete
        try await storage.deleteWalletCredentials(id: id)

        // Verify gone
        let gone = await storage.walletCredentialsExist(id: id)
        #expect(!gone)
    }

    @Test("Retrieve non-existent credentials throws error")
    func testRetrieveNonExistent() async throws {
        guard await requireKeychain() else { return }
        let fakeID = UUID().uuidString

        await #expect(throws: DogecoinError.self) {
            _ = try await storage.retrieveWalletCredentials(id: fakeID)
        }
    }

    // MARK: - Master Key Tests

    @Test("Store and retrieve master key")
    func testMasterKeyStorage() async throws {
        guard await requireKeychain() else { return }
        let wallet = try await HDWallet.create(strength: .words12, network: .testnet)

        let id = try await storage.storeMasterKey(wallet.masterKey, network: .testnet)

        let (retrievedKey, retrievedNetwork) = try await storage.retrieveMasterKey(id: id)

        #expect(retrievedKey == wallet.masterKey)
        #expect(retrievedNetwork == .testnet)

        try await storage.deleteMasterKey(id: id)
    }

    // MARK: - Private Key Tests

    @Test("Store and retrieve private key")
    func testPrivateKeyStorage() async throws {
        guard await requireKeychain() else { return }
        let keyPair = try await KeyPair.generate(network: .testnet)

        let id = try await storage.storePrivateKey(keyPair.privateKeyWIF, address: keyPair.address)

        let (retrievedKey, retrievedAddress) = try await storage.retrievePrivateKey(id: id)

        #expect(retrievedKey == keyPair.privateKeyWIF)
        #expect(retrievedAddress == keyPair.address)

        try await storage.deletePrivateKey(id: id)
    }

    // MARK: - Convenience Method Tests

    @Test("Create and store wallet")
    func testCreateAndStoreWallet() async throws {
        guard await requireKeychain() else { return }
        let (wallet, keychainID) = try await storage.createAndStoreWallet(
            strength: .words12,
            network: .testnet
        )

        #expect(wallet.mnemonic != nil)
        #expect(!keychainID.isEmpty)

        // Verify we can restore
        let restored = try await storage.restoreWallet(keychainID: keychainID)

        #expect(restored.mnemonic == wallet.mnemonic)
        #expect(restored.network == wallet.network)

        // Cleanup
        try await storage.deleteWalletCredentials(id: keychainID)
    }

    @Test("Import and store wallet")
    func testImportAndStoreWallet() async throws {
        guard await requireKeychain() else { return }
        let mnemonic = try await generateMnemonic(strength: .words12)

        let (wallet, keychainID) = try await storage.importAndStoreWallet(
            mnemonic: mnemonic,
            passphrase: "mypassphrase",
            network: .mainnet
        )

        #expect(wallet.mnemonic == mnemonic)
        #expect(wallet.network == .mainnet)

        // Verify storage
        let credentials = try await storage.retrieveWalletCredentials(id: keychainID)
        #expect(credentials.mnemonic == mnemonic)
        #expect(credentials.passphrase == "mypassphrase")

        // Cleanup
        try await storage.deleteWalletCredentials(id: keychainID)
    }

    @Test("Restore wallet from stored credentials")
    func testRestoreWallet() async throws {
        guard await requireKeychain() else { return }
        // First create and store
        let originalMnemonic = try await generateMnemonic(strength: .words12)
        let keychainID = try await storage.storeWalletCredentials(
            mnemonic: originalMnemonic,
            passphrase: "restore-test",
            network: .testnet
        )

        // Restore
        let wallet = try await storage.restoreWallet(keychainID: keychainID)

        #expect(wallet.mnemonic == originalMnemonic)
        #expect(wallet.network == .testnet)

        // Verify we can derive addresses
        let address = try await wallet.deriveAddress(account: 0, index: 0)
        #expect(address.hasPrefix("n")) // testnet prefix

        // Cleanup
        try await storage.deleteWalletCredentials(id: keychainID)
    }

    // MARK: - Multiple Storage Tests

    @Test("Store multiple wallets with unique IDs")
    func testMultipleWallets() async throws {
        guard await requireKeychain() else { return }
        let mnemonic1 = try await generateMnemonic(strength: .words12)
        let mnemonic2 = try await generateMnemonic(strength: .words12)

        let id1 = try await storage.storeWalletCredentials(mnemonic: mnemonic1, network: .mainnet)
        let id2 = try await storage.storeWalletCredentials(mnemonic: mnemonic2, network: .testnet)

        #expect(id1 != id2)

        let creds1 = try await storage.retrieveWalletCredentials(id: id1)
        let creds2 = try await storage.retrieveWalletCredentials(id: id2)

        #expect(creds1.mnemonic == mnemonic1)
        #expect(creds2.mnemonic == mnemonic2)
        #expect(creds1.network == .mainnet)
        #expect(creds2.network == .testnet)

        // Cleanup
        try await storage.deleteWalletCredentials(id: id1)
        try await storage.deleteWalletCredentials(id: id2)
    }

    // MARK: - Network Encoding Tests

    @Test("DogecoinNetwork Codable conformance")
    func testNetworkCodable() throws {
        struct TestPayload: Codable {
            let network: DogecoinNetwork
        }

        let mainnet = TestPayload(network: .mainnet)
        let testnet = TestPayload(network: .testnet)

        let mainnetData = try JSONEncoder().encode(mainnet)
        let testnetData = try JSONEncoder().encode(testnet)

        let decodedMainnet = try JSONDecoder().decode(TestPayload.self, from: mainnetData)
        let decodedTestnet = try JSONDecoder().decode(TestPayload.self, from: testnetData)

        #expect(decodedMainnet.network == .mainnet)
        #expect(decodedTestnet.network == .testnet)
    }

    // MARK: - StoredWalletCredentials Tests

    @Test("StoredWalletCredentials initialization")
    func testStoredCredentialsInit() {
        let credentials = StoredWalletCredentials(
            mnemonic: "test mnemonic",
            passphrase: "pass",
            network: .mainnet
        )

        #expect(credentials.mnemonic == "test mnemonic")
        #expect(credentials.passphrase == "pass")
        #expect(credentials.network == .mainnet)
        #expect(credentials.storedAt <= Date())
    }

    @Test("StoredWalletCredentials with default passphrase")
    func testStoredCredentialsDefaultPassphrase() {
        let credentials = StoredWalletCredentials(
            mnemonic: "test",
            network: .testnet
        )

        #expect(credentials.passphrase.isEmpty)
    }
}
