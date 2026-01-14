import Testing
import Foundation
@testable import DogecoinKit

/// Tests for SecureKeyStorage
/// Note: Keychain tests require a host app context (simulator or device)
/// These tests may fail in pure CLI test runners without Keychain access
@Suite("Secure Key Storage Tests")
struct SecureKeyStorageTests {

    let storage: SecureKeyStorage

    init() {
        Dogecoin.initialize()
        storage = SecureKeyStorage(serviceName: "com.dogecoinkit.tests")
    }

    // MARK: - Wallet Credentials Tests

    @Test("Store and retrieve wallet credentials")
    func testStoreAndRetrieveCredentials() throws {
        let mnemonic = try generateMnemonic(strength: .words12)
        let passphrase = "testpassphrase"
        let network = DogecoinNetwork.testnet

        // Store
        let id = try storage.storeWalletCredentials(
            mnemonic: mnemonic,
            passphrase: passphrase,
            network: network
        )

        #expect(!id.isEmpty)

        // Retrieve
        let retrieved = try storage.retrieveWalletCredentials(id: id)

        #expect(retrieved.mnemonic == mnemonic)
        #expect(retrieved.passphrase == passphrase)
        #expect(retrieved.network == network)

        // Cleanup
        try storage.deleteWalletCredentials(id: id)
    }

    @Test("Wallet credentials with empty passphrase")
    func testCredentialsEmptyPassphrase() throws {
        let mnemonic = try generateMnemonic(strength: .words12)

        let id = try storage.storeWalletCredentials(
            mnemonic: mnemonic,
            network: .mainnet
        )

        let retrieved = try storage.retrieveWalletCredentials(id: id)

        #expect(retrieved.passphrase.isEmpty)
        #expect(retrieved.network == .mainnet)

        try storage.deleteWalletCredentials(id: id)
    }

    @Test("Delete wallet credentials")
    func testDeleteCredentials() throws {
        let mnemonic = try generateMnemonic(strength: .words12)

        let id = try storage.storeWalletCredentials(
            mnemonic: mnemonic,
            network: .testnet
        )

        // Verify exists
        #expect(storage.walletCredentialsExist(id: id))

        // Delete
        try storage.deleteWalletCredentials(id: id)

        // Verify gone
        #expect(!storage.walletCredentialsExist(id: id))
    }

    @Test("Retrieve non-existent credentials throws error")
    func testRetrieveNonExistent() throws {
        let fakeID = UUID().uuidString

        #expect(throws: DogecoinError.self) {
            _ = try storage.retrieveWalletCredentials(id: fakeID)
        }
    }

    // MARK: - Master Key Tests

    @Test("Store and retrieve master key")
    func testMasterKeyStorage() throws {
        let wallet = try HDWallet.create(strength: .words12, network: .testnet)

        let id = try storage.storeMasterKey(wallet.masterKey, network: .testnet)

        let (retrievedKey, retrievedNetwork) = try storage.retrieveMasterKey(id: id)

        #expect(retrievedKey == wallet.masterKey)
        #expect(retrievedNetwork == .testnet)

        try storage.deleteMasterKey(id: id)
    }

    // MARK: - Private Key Tests

    @Test("Store and retrieve private key")
    func testPrivateKeyStorage() throws {
        let keyPair = try KeyPair.generate(network: .testnet)

        let id = try storage.storePrivateKey(keyPair.privateKeyWIF, address: keyPair.address)

        let (retrievedKey, retrievedAddress) = try storage.retrievePrivateKey(id: id)

        #expect(retrievedKey == keyPair.privateKeyWIF)
        #expect(retrievedAddress == keyPair.address)

        try storage.deletePrivateKey(id: id)
    }

    // MARK: - Convenience Method Tests

    @Test("Create and store wallet")
    func testCreateAndStoreWallet() throws {
        let (wallet, keychainID) = try storage.createAndStoreWallet(
            strength: .words12,
            network: .testnet
        )

        #expect(wallet.mnemonic != nil)
        #expect(!keychainID.isEmpty)

        // Verify we can restore
        let restored = try storage.restoreWallet(keychainID: keychainID)

        #expect(restored.mnemonic == wallet.mnemonic)
        #expect(restored.network == wallet.network)

        // Cleanup
        try storage.deleteWalletCredentials(id: keychainID)
    }

    @Test("Import and store wallet")
    func testImportAndStoreWallet() throws {
        let mnemonic = try generateMnemonic(strength: .words12)

        let (wallet, keychainID) = try storage.importAndStoreWallet(
            mnemonic: mnemonic,
            passphrase: "mypassphrase",
            network: .mainnet
        )

        #expect(wallet.mnemonic == mnemonic)
        #expect(wallet.network == .mainnet)

        // Verify storage
        let credentials = try storage.retrieveWalletCredentials(id: keychainID)
        #expect(credentials.mnemonic == mnemonic)
        #expect(credentials.passphrase == "mypassphrase")

        // Cleanup
        try storage.deleteWalletCredentials(id: keychainID)
    }

    @Test("Restore wallet from stored credentials")
    func testRestoreWallet() throws {
        // First create and store
        let originalMnemonic = try generateMnemonic(strength: .words12)
        let keychainID = try storage.storeWalletCredentials(
            mnemonic: originalMnemonic,
            passphrase: "restore-test",
            network: .testnet
        )

        // Restore
        let wallet = try storage.restoreWallet(keychainID: keychainID)

        #expect(wallet.mnemonic == originalMnemonic)
        #expect(wallet.network == .testnet)

        // Verify we can derive addresses
        let address = try wallet.deriveAddress(account: 0, index: 0)
        #expect(address.hasPrefix("n")) // testnet prefix

        // Cleanup
        try storage.deleteWalletCredentials(id: keychainID)
    }

    // MARK: - Multiple Storage Tests

    @Test("Store multiple wallets with unique IDs")
    func testMultipleWallets() throws {
        let mnemonic1 = try generateMnemonic(strength: .words12)
        let mnemonic2 = try generateMnemonic(strength: .words12)

        let id1 = try storage.storeWalletCredentials(mnemonic: mnemonic1, network: .mainnet)
        let id2 = try storage.storeWalletCredentials(mnemonic: mnemonic2, network: .testnet)

        #expect(id1 != id2)

        let creds1 = try storage.retrieveWalletCredentials(id: id1)
        let creds2 = try storage.retrieveWalletCredentials(id: id2)

        #expect(creds1.mnemonic == mnemonic1)
        #expect(creds2.mnemonic == mnemonic2)
        #expect(creds1.network == .mainnet)
        #expect(creds2.network == .testnet)

        // Cleanup
        try storage.deleteWalletCredentials(id: id1)
        try storage.deleteWalletCredentials(id: id2)
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
