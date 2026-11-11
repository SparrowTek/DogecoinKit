import Foundation
import Testing
@testable import DogecoinKit

/// The four vectors below were generated independently (Python: hash160 of a
/// fixed seed, Base58Check with Dogecoin's version bytes), so they check the
/// Swift decoder against a second implementation. All four share one hash160.
@Suite("Addresses")
struct AddressTests {

    private static let hash160 = "bf1c189252e8715c9ad06c005c65452992f6ff7b"

    private let mainnetP2SH = "A9rmPAxPNGTojaWevb571EYNmCiRLpXzcM"
    private let testnetP2SH = "2NAfii4pWuf6G2zmjBb2ZP3uGGyYZ3YcsPa"
    private let mainnetP2PKH = "DNZbG3Lh3iApH3dM7wjetEifoEmxwUjLaX"
    private let testnetP2PKH = "nmcez45bygdYA2CY9mP78eJy37AFwrUXp2"

    // MARK: - Dogecoin's own

    @Test("Every kind of Dogecoin address is recognized for what it is")
    func kindsAndNetworks() {
        #expect(Address.kind(mainnetP2PKH) == .p2pkh)
        #expect(Address.kind(testnetP2PKH) == .p2pkh)
        #expect(Address.kind(mainnetP2SH) == .p2sh)
        #expect(Address.kind(testnetP2SH) == .p2sh)

        #expect(Address.detectNetwork(mainnetP2PKH) == .mainnet)
        #expect(Address.detectNetwork(mainnetP2SH) == .mainnet)
        #expect(Address.detectNetwork(testnetP2PKH) == .testnet)
        #expect(Address.detectNetwork(testnetP2SH) == .testnet)

        #expect(Address.isMainnet(mainnetP2SH) && !Address.isTestnet(mainnetP2SH))
        #expect(Address.isTestnet(testnetP2SH) && !Address.isMainnet(testnetP2SH))
        for address in [mainnetP2PKH, testnetP2PKH, mainnetP2SH, testnetP2SH] {
            #expect(Address.isValid(address))
        }
    }

    @Test("An address pays the script its kind prescribes")
    func scripts() throws {
        let hash = try #require(Data(hexString: Self.hash160))
        let p2pkh = Data([0x76, 0xa9, 0x14]) + hash + Data([0x88, 0xac])
        let p2sh = Data([0xa9, 0x14]) + hash + Data([0x87])

        #expect(Address.scriptPubKey(for: mainnetP2PKH) == p2pkh)
        #expect(Address.scriptPubKey(for: testnetP2PKH) == p2pkh)
        #expect(Address.scriptPubKey(for: mainnetP2SH) == p2sh)
        #expect(Address.scriptPubKey(for: testnetP2SH) == p2sh)
    }

    @Test("A script leads back to the address that pays it, on either network")
    func addressesOfScripts() throws {
        for (address, network) in [(mainnetP2PKH, DogecoinNetwork.mainnet), (mainnetP2SH, .mainnet), (testnetP2PKH, .testnet), (testnetP2SH, .testnet)] {
            let script = try #require(Address.scriptPubKey(for: address))

            #expect(Address.fromScriptPubKey(script, network: network) == address)
            // As part of a larger buffer, the way a transaction holds it.
            #expect(Address.fromScriptPubKey((Data([0xEE]) + script).dropFirst(), network: network) == address)
        }
    }

    private static func bytes(_ count: Int) -> String {
        String(repeating: "ab", count: count)
    }

    private static let unnamedScripts: [String] = [
        "",
        // A data carrier.
        "6a0b68656c6c6f20776f726c64",
        // Pay-to-public-key.
        "2102" + bytes(32) + "ac",
        // The two standard forms, each a byte short, a byte long, and with
        // one opcode changed.
        "76a914" + bytes(19) + "88ac",
        "76a914" + bytes(21) + "88ac",
        "76a914" + bytes(20) + "88ad",
        "76a915" + bytes(20) + "88ac",
        "a914" + bytes(19) + "87",
        "a914" + bytes(21) + "87",
        "a914" + bytes(20) + "88",
        "a915" + bytes(20) + "87",
    ]

    @Test("A script no address names has none", arguments: unnamedScripts)
    func scriptsWithoutAddress(scriptHex: String) throws {
        let script = try #require(Data(hexString: scriptHex))

        #expect(Address.fromScriptPubKey(script, network: .mainnet) == nil)
        #expect(Address.fromScriptPubKey(script, network: .testnet) == nil)
    }

    @Test("A typed address carries its network, its kind, and its script")
    func typedAddress() throws {
        let address = try DogecoinAddress(mainnetP2SH)

        #expect(address.value == mainnetP2SH)
        #expect(address.network == .mainnet)
        #expect(address.kind == .p2sh)
        #expect(address.scriptPubKey == Address.scriptPubKey(for: mainnetP2SH))
        #expect(address.description == mainnetP2SH)
        #expect(try DogecoinAddress(mainnetP2SH, network: .mainnet) == address)
    }

    @Test("A typed address is refused on the network it does not belong to")
    func typedAddressOnTheWrongNetwork() {
        #expect(throws: DogecoinError.invalidAddress(mainnetP2PKH)) {
            _ = try DogecoinAddress(mainnetP2PKH, network: .testnet)
        }
        #expect(throws: DogecoinError.invalidAddress(testnetP2SH)) {
            _ = try DogecoinAddress(testnetP2SH, network: .mainnet)
        }
    }

    @Test("A typed address is stored as its text, and read back only if still valid")
    func typedAddressCoding() throws {
        let addresses = [try DogecoinAddress(mainnetP2PKH), try DogecoinAddress(testnetP2SH)]

        let encoded = try JSONEncoder().encode(addresses)

        #expect(String(decoding: encoded, as: UTF8.self) == #"["\#(mainnetP2PKH)","\#(testnetP2SH)"]"#)
        #expect(try JSONDecoder().decode([DogecoinAddress].self, from: encoded) == addresses)
        #expect(throws: DogecoinError.invalidAddress("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")) {
            _ = try JSONDecoder().decode([DogecoinAddress].self, from: Data(#"["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"]"#.utf8))
        }
    }

    // MARK: - Everyone else's

    /// Addresses of other chains pass their own checksum. Only the version
    /// byte tells them apart, and coins sent to one are gone.
    @Test("An address of another chain is not a Dogecoin address", arguments: [
        "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",   // Bitcoin, pay-to-public-key-hash
        "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy",   // Bitcoin, pay-to-script-hash
    ])
    func foreignAddress(address: String) async {
        // Well-formed, checksum and all — just not Dogecoin's.
        #expect(Base58Check.decode(address)?.count == 21)

        await expectRefused(address)
    }

    @Test("Of all 256 version bytes, only Dogecoin's four make an address")
    func versionBytes() async throws {
        let hash = try #require(Data(hexString: Self.hash160))
        let accepted: [UInt8: (AddressKind, DogecoinNetwork)] = [
            0x1E: (.p2pkh, .mainnet),
            0x16: (.p2sh, .mainnet),
            0x71: (.p2pkh, .testnet),
            0xC4: (.p2sh, .testnet),
        ]

        for version in UInt8.min...UInt8.max {
            let address = Base58Check.encode(Data([version]) + hash)

            if let (kind, network) = accepted[version] {
                #expect(Address.kind(address) == kind, "version \(version)")
                #expect(Address.detectNetwork(address) == network, "version \(version)")
            } else {
                await expectRefused(address)
            }
        }
    }

    @Test("A payload of the wrong length is not an address, whatever its version", arguments: [19, 21, 32])
    func wrongLength(hashLength: Int) async {
        await expectRefused(Base58Check.encode(Data([0x1E]) + Data(repeating: 0xAB, count: hashLength)))
    }

    @Test("Text that is not an address is refused without crashing", arguments: [
        "",
        "not an address",
        "invalid_address",
        "0OIl+/=",
        "🐕🐕🐕🐕🐕",
        // Truncated, and with its last character changed.
        "A9rmPAxPNGTojaWevb571EYNmCiRLpXz",
        "A9rmPAxPNGTojaWevb571EYNmCiRLpXzc1",
        String(repeating: "A", count: 1000),
    ])
    func notAnAddress(text: String) async {
        await expectRefused(text)
    }

    /// Every door an address comes in through has to stay shut.
    private func expectRefused(_ address: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(!Address.isValid(address), sourceLocation: sourceLocation)
        #expect(Address.kind(address) == nil, sourceLocation: sourceLocation)
        #expect(Address.detectNetwork(address) == nil, sourceLocation: sourceLocation)
        #expect(Address.scriptPubKey(for: address) == nil, sourceLocation: sourceLocation)
        #expect(!Address.isMainnet(address) && !Address.isTestnet(address), sourceLocation: sourceLocation)

        #expect(throws: DogecoinError.invalidAddress(address), sourceLocation: sourceLocation) {
            _ = try DogecoinAddress(address)
        }
        #expect(throws: DogecoinError.invalidAddress(address), sourceLocation: sourceLocation) {
            _ = try Address.toPubkeyHash(address)
        }
        #expect(throws: ElectrumError.invalidAddress(address), sourceLocation: sourceLocation) {
            _ = try ElectrumScriptHash(address: address, network: .mainnet)
        }
        // Nothing can be sent to it.
        let builder = TransactionBuilder()
        await #expect(throws: DogecoinError.addOutputFailed, sourceLocation: sourceLocation) {
            try await builder.addOutput(address: address, amount: DogecoinAmount(koinu: 100_000_000))
        }
    }
}
