import Foundation
import Testing
@testable import DogecoinKit

/// Inputs that would reach a libdogecoin `assert` — which aborts the whole
/// process, release builds included — must be rejected in Swift first.
@Suite("libdogecoin Boundary")
struct LibdogecoinBoundaryTests {

    init() async {
        await Dogecoin.initialize()
    }

    /// The secp256k1 generator — the public key of private key 1.
    private let generatorCompressed = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
    private let generatorUncompressed = "0479be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8"

    /// A compressed mainnet WIF for a raw 32-byte secret.
    private func mainnetWIF(secretHex: String) throws -> String {
        let secret = try #require(Data(hexString: secretHex))
        return Base58Check.encode(Data([0x9E]) + secret + Data([0x01]))
    }

    // MARK: - Public keys

    @Test("Addresses from public keys commit to the right hash, compressed or not")
    func publicKeyAddresses() async throws {
        let compressed = try await Address.fromPublicKey(generatorCompressed)
        let uncompressed = try await Address.fromPublicKey(generatorUncompressed)

        #expect(try Address.toPubkeyHash(compressed) == "76a914751e76e8199196d454941c45d1b3a323f1433bd688ac")
        #expect(try Address.toPubkeyHash(uncompressed) == "76a91491b24bf9f5288532960ac687abb035127b1d28a588ac")
    }

    @Test("Public keys off the curve throw instead of aborting", arguments: [
        "02" + String(repeating: "ff", count: 32),  // x beyond the field
        "05" + String(repeating: "11", count: 32),  // no such prefix
        String(repeating: "00", count: 33),
        "0479be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b9",
        "0279be66",
        "not hex",
    ])
    func invalidPublicKeys(publicKeyHex: String) async {
        await #expect(throws: DogecoinError.invalidPublicKey) {
            _ = try await Address.fromPublicKey(publicKeyHex)
        }
    }

    // MARK: - Public key hashes

    @Test("A bare hash and a full P2PKH script give the same address")
    func pubkeyHashForms() async throws {
        let address = "DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5"
        let script = try Address.toPubkeyHash(address)
        let hash = String(script.dropFirst(6).dropLast(4))

        #expect(try await Address.fromPubkeyHash(script) == address)
        #expect(try await Address.fromPubkeyHash(hash) == address)

        let testnetAddress = try await Address.fromPubkeyHash(hash, network: .testnet)
        #expect(Address.isTestnet(testnetAddress))
    }

    @Test("Anything but a 20-byte hash or a P2PKH script is rejected", arguments: [
        String(repeating: "ab", count: 19),
        String(repeating: "ab", count: 21),
        "a914" + String(repeating: "ab", count: 20) + "87",          // P2SH script
        "76a914" + String(repeating: "ab", count: 20) + "88ad",      // wrong last opcode
        "zz" + String(repeating: "ab", count: 19),
    ])
    func invalidPubkeyHashes(pubkeyHash: String) async {
        await #expect(throws: DogecoinError.invalidPublicKey) {
            _ = try await Address.fromPubkeyHash(pubkeyHash)
        }
    }

    // MARK: - Private keys

    @Test("Out-of-range private keys throw instead of aborting", arguments: [
        String(repeating: "00", count: 32),
        "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141",  // the curve order
        String(repeating: "ff", count: 32),
    ])
    func outOfRangePrivateKeys(secretHex: String) async throws {
        let wif = try mainnetWIF(secretHex: secretHex)

        #expect(KeyPair.network(ofPrivateKey: wif) == nil)
        #expect(!KeyPair.verify(privateKeyWIF: wif, address: "DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5"))
        await #expect(throws: DogecoinError.invalidPrivateKey) {
            _ = try await KeyPair.publicKeyHex(from: wif)
        }
    }

    @Test("The largest valid private key is accepted")
    func largestPrivateKey() async throws {
        let wif = try mainnetWIF(secretHex: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140")
        #expect(KeyPair.network(ofPrivateKey: wif) == .mainnet)
        #expect(try await KeyPair.publicKeyHex(from: wif).count == 66)
    }

    @Test("Private key 1 controls the generator's address")
    func privateKeyOne() async throws {
        let wif = try mainnetWIF(secretHex: String(repeating: "00", count: 31) + "01")
        let address = try await Address.fromPublicKey(generatorCompressed)

        #expect(try await KeyPair.publicKeyHex(from: wif) == generatorCompressed)
        #expect(KeyPair.verify(privateKeyWIF: wif, address: address))
        #expect(!KeyPair.verify(privateKeyWIF: wif, address: address, network: .testnet))
    }

    @Test("Generated keys report their network")
    func generatedKeyNetworks() async throws {
        let mainnet = try await KeyPair.generate(network: .mainnet)
        let testnet = try await KeyPair.generate(network: .testnet)

        #expect(KeyPair.network(ofPrivateKey: mainnet.privateKeyWIF) == .mainnet)
        #expect(KeyPair.network(ofPrivateKey: testnet.privateKeyWIF) == .testnet)
        #expect(KeyPair.network(ofPrivateKey: "DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5") == nil)
    }

    // MARK: - Derivation paths

    @Test("Derivation paths too long for libdogecoin throw instead of aborting")
    func overlongPaths() async throws {
        let wallet = try await HDWallet(mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        let path = "m/" + Array(repeating: "0", count: 600).joined(separator: "/")

        await #expect(throws: DogecoinError.derivationFailed) {
            _ = try await wallet.deriveAddress(path: path)
        }
        await #expect(throws: DogecoinError.derivationFailed) {
            _ = try await wallet.derivePrivateKey(path: path)
        }
        #expect(try await wallet.deriveAddress(path: "m/44'/3'/0'/0/0") == wallet.deriveAddress(account: 0, index: 0))
    }
}

@Suite("Base58Check")
struct Base58CheckTests {

    @Test("Addresses round-trip through decoding and encoding")
    func roundTrip() throws {
        for address in ["DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5", "A9rmPAxPNGTojaWevb571EYNmCiRLpXzcM"] {
            let payload = try #require(Base58Check.decode(address))
            #expect(payload.count == 21)
            #expect(Base58Check.encode(payload) == address)
        }
    }

    @Test("Leading zero bytes are written as leading ones")
    func leadingZeros() throws {
        let payload = Data([0, 0, 1, 2, 3])
        let encoded = Base58Check.encode(payload)

        #expect(encoded.hasPrefix("11"))
        #expect(!encoded.hasPrefix("111"))
        #expect(Base58Check.decode(encoded) == payload)
    }

    @Test("Malformed text is rejected", arguments: [
        "",
        "0D8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5",   // '0' is not Base58
        "ID8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5",   // nor is 'I'
        "DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ6",   // checksum
        "DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQé",
        String(repeating: "z", count: 65),
    ])
    func malformed(text: String) {
        #expect(Base58Check.decode(text) == nil)
    }
}
