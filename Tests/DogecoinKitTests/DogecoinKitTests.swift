import Testing
@testable import DogecoinKit

@Suite("Dogecoin Library Tests")
struct DogecoinKitTests {

    init() {
        Dogecoin.initialize()
    }

    @Test("Library initialization")
    func testInitialization() {
        #expect(Dogecoin.initialized)
    }

    @Test("Generate key pair for mainnet")
    func testGenerateKeyPairMainnet() throws {
        let keyPair = try KeyPair.generate(network: .mainnet)

        #expect(!keyPair.privateKeyWIF.isEmpty)
        #expect(!keyPair.address.isEmpty)
        #expect(keyPair.network == .mainnet)
        #expect(keyPair.address.hasPrefix("D"))
    }

    @Test("Generate key pair for testnet")
    func testGenerateKeyPairTestnet() throws {
        let keyPair = try KeyPair.generate(network: .testnet)

        #expect(!keyPair.privateKeyWIF.isEmpty)
        #expect(!keyPair.address.isEmpty)
        #expect(keyPair.network == .testnet)
        #expect(keyPair.address.hasPrefix("n"))
    }

    @Test("Verify key pair")
    func testVerifyKeyPair() throws {
        let keyPair = try KeyPair.generate(network: .testnet)

        let isValid = KeyPair.verify(
            privateKeyWIF: keyPair.privateKeyWIF,
            address: keyPair.address,
            network: keyPair.network
        )

        #expect(isValid)
    }

    @Test("Generate mnemonic")
    func testGenerateMnemonic() throws {
        let mnemonic = try generateMnemonic(strength: .words12)
        let words = mnemonic.split(separator: " ")

        #expect(words.count == 12)
    }

    @Test("HD wallet from mnemonic")
    func testHDWalletFromMnemonic() throws {
        let mnemonic = try generateMnemonic(strength: .words12)
        let wallet = try HDWallet(mnemonic: mnemonic, network: .testnet)

        #expect(!wallet.masterKey.isEmpty)
        #expect(wallet.mnemonic == mnemonic)
        #expect(wallet.network == .testnet)
    }

    @Test("Derive addresses from HD wallet")
    func testDeriveAddresses() throws {
        let mnemonic = try generateMnemonic(strength: .words12)
        let wallet = try HDWallet(mnemonic: mnemonic, network: .testnet)

        let address0 = try wallet.deriveAddress(account: 0, index: 0)
        let address1 = try wallet.deriveAddress(account: 0, index: 1)

        #expect(!address0.isEmpty)
        #expect(!address1.isEmpty)
        #expect(address0 != address1)
        #expect(address0.hasPrefix("n"))
    }

    @Test("Address validation")
    func testAddressValidation() {
        // Valid mainnet address (example)
        let validMainnet = "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"
        #expect(Address.isValid(validMainnet))
        #expect(Address.isMainnet(validMainnet))
        #expect(!Address.isTestnet(validMainnet))

        // Invalid address
        let invalid = "invalid_address"
        #expect(!Address.isValid(invalid))
    }

    @Test("Amount conversion")
    func testAmountConversion() throws {
        let amount = DogecoinAmount(doge: 1.5)

        #expect(amount.koinu == 150_000_000)
        #expect(amount.doge == 1.5)

        let fromString = try DogecoinAmount(dogeString: "2.5")
        #expect(fromString.koinu == 250_000_000)
    }

    @Test("Amount arithmetic")
    func testAmountArithmetic() {
        let a = DogecoinAmount(doge: 1.0)
        let b = DogecoinAmount(doge: 0.5)

        let sum = a + b
        #expect(sum.doge == 1.5)

        let diff = a - b
        #expect(diff.doge == 0.5)
    }

    @Test("Transaction builder creation")
    func testTransactionBuilder() throws {
        let builder = try TransactionBuilder()
        // Just verify it was created successfully (would throw if failed)
        _ = builder
    }
}
