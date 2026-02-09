import Testing
@testable import DogecoinKit

@Suite("Dogecoin Library Tests")
struct DogecoinKitTests {

    init() async {
        await Dogecoin.initialize()
    }

    @Test("Library initialization")
    func testInitialization() async {
        let initialized = await Dogecoin.initialized
        #expect(initialized)
    }

    @Test("Generate key pair for mainnet")
    func testGenerateKeyPairMainnet() async throws {
        let keyPair = try await KeyPair.generate(network: .mainnet)

        #expect(!keyPair.privateKeyWIF.isEmpty)
        #expect(!keyPair.address.isEmpty)
        #expect(keyPair.network == .mainnet)
        #expect(keyPair.address.hasPrefix("D"))
    }

    @Test("Generate key pair for testnet")
    func testGenerateKeyPairTestnet() async throws {
        let keyPair = try await KeyPair.generate(network: .testnet)

        #expect(!keyPair.privateKeyWIF.isEmpty)
        #expect(!keyPair.address.isEmpty)
        #expect(keyPair.network == .testnet)
        #expect(keyPair.address.hasPrefix("n"))
    }

    @Test("Verify key pair")
    func testVerifyKeyPair() async throws {
        let keyPair = try await KeyPair.generate(network: .testnet)

        let isValid = KeyPair.verify(
            privateKeyWIF: keyPair.privateKeyWIF,
            address: keyPair.address,
            network: keyPair.network
        )

        #expect(isValid)
    }

    @Test("Generate mnemonic")
    func testGenerateMnemonic() async throws {
        let mnemonic = try await generateMnemonic(strength: .words12)
        let words = mnemonic.split(separator: " ")

        #expect(words.count == 12)
    }

    @Test("HD wallet from mnemonic")
    func testHDWalletFromMnemonic() async throws {
        let mnemonic = try await generateMnemonic(strength: .words12)
        let wallet = try await HDWallet(mnemonic: mnemonic, network: .testnet)

        #expect(!wallet.masterKey.isEmpty)
        #expect(wallet.mnemonic == mnemonic)
        #expect(wallet.network == .testnet)
    }

    @Test("Derive addresses from HD wallet")
    func testDeriveAddresses() async throws {
        let mnemonic = try await generateMnemonic(strength: .words12)
        let wallet = try await HDWallet(mnemonic: mnemonic, network: .testnet)

        let address0 = try await wallet.deriveAddress(account: 0, index: 0)
        let address1 = try await wallet.deriveAddress(account: 0, index: 1)

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

    @Test("Invalid amount strings throw")
    func testInvalidAmountStrings() {
        #expect(throws: DogecoinError.self) {
            _ = try DogecoinAmount(dogeString: "-1")
        }
        #expect(throws: DogecoinError.self) {
            _ = try DogecoinAmount(dogeString: "1.123456789")
        }
        #expect(throws: DogecoinError.self) {
            _ = try DogecoinAmount(dogeString: "abc")
        }
    }

    @Test("Amount subtraction saturates at zero")
    func testAmountSubtractionSaturatesAtZero() {
        let small = DogecoinAmount(koinu: 100)
        let large = DogecoinAmount(koinu: 200)

        let result = small - large
        #expect(result == .zero)
    }

    @Test("Amount addition saturates at UInt64 max")
    func testAmountAdditionSaturatesAtMax() {
        let nearMax = DogecoinAmount(koinu: UInt64.max - 10)
        let result = nearMax + DogecoinAmount(koinu: 100)
        #expect(result.koinu == UInt64.max)
    }

    @Test("Transaction builder creation")
    func testTransactionBuilder() async throws {
        let builder = try await TransactionBuilder()
        // Just verify it was created successfully (would throw if failed)
        _ = builder
    }
}
