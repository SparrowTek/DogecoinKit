import Foundation
import Testing
@testable import DogecoinKit

/// P2SH address validation coverage. All vectors below were generated
/// independently (Python: hash160 of a fixed seed, Base58Check with Dogecoin
/// version bytes) so they exercise the Swift decoder against a second
/// implementation, and all four share the same hash160.
@Suite("Address P2SH Validation")
struct AddressP2SHTests {
    init() async {
        await Dogecoin.initialize()
    }

    private let mainnetP2SH = "A9rmPAxPNGTojaWevb571EYNmCiRLpXzcM"
    private let testnetP2SH = "2NAfii4pWuf6G2zmjBb2ZP3uGGyYZ3YcsPa"
    private let mainnetP2PKH = "DNZbG3Lh3iApH3dM7wjetEifoEmxwUjLaX"
    private let testnetP2PKH = "nmcez45bygdYA2CY9mP78eJy37AFwrUXp2"

    @Test("Valid P2SH addresses pass validation")
    func p2shIsValid() {
        #expect(Address.isValid(mainnetP2SH))
        #expect(Address.isValid(testnetP2SH))
    }

    @Test("Kind detection distinguishes P2PKH and P2SH")
    func kindDetection() {
        #expect(Address.kind(mainnetP2SH) == .p2sh)
        #expect(Address.kind(testnetP2SH) == .p2sh)
        #expect(Address.kind(mainnetP2PKH) == .p2pkh)
        #expect(Address.kind(testnetP2PKH) == .p2pkh)
        #expect(Address.kind("not an address") == nil)
        #expect(Address.kind("") == nil)
    }

    @Test("Network detection covers P2SH")
    func networkDetection() {
        #expect(Address.detectNetwork(mainnetP2SH) == .mainnet)
        #expect(Address.detectNetwork(testnetP2SH) == .testnet)
        #expect(Address.isMainnet(mainnetP2SH))
        #expect(Address.isTestnet(testnetP2SH))
        #expect(!Address.isTestnet(mainnetP2SH))
        #expect(!Address.isMainnet(testnetP2SH))
    }

    @Test("P2PKH detection still works after the P2SH extension")
    func p2pkhStillValid() {
        #expect(Address.isValid(mainnetP2PKH))
        #expect(Address.detectNetwork(mainnetP2PKH) == .mainnet)
        #expect(Address.isValid(testnetP2PKH))
        #expect(Address.detectNetwork(testnetP2PKH) == .testnet)
    }

    @Test("Corrupted checksum is rejected")
    func corruptChecksumRejected() {
        let corrupt = "A9rmPAxPNGTojaWevb571EYNmCiRLpXzc1"
        #expect(!Address.isValid(corrupt))
        #expect(Address.kind(corrupt) == nil)
    }

    @Test("Hostile inputs are rejected without crashing")
    func hostileInputs() {
        #expect(!Address.isValid(String(repeating: "A", count: 1000)))
        #expect(!Address.isValid("0OIl+/="))
        #expect(!Address.isValid("A9rmPAxPNGTojaWevb571EYNmCiRLpXz"))  // truncated
        #expect(!Address.isValid("🐕🐕🐕🐕🐕"))
    }

    @Test("DogecoinAddress wrapper accepts P2SH")
    func typedWrapperAcceptsP2SH() throws {
        let address = try DogecoinAddress(mainnetP2SH)
        #expect(address.network == .mainnet)
        #expect(address.value == mainnetP2SH)
    }
}
