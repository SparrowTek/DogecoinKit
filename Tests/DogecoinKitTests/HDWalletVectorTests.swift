import Foundation
import Testing
import clibdogecoin
@testable import DogecoinKit

@Suite("HD Wallet Vectors")
struct HDWalletVectorTests {
    init() async {
        await Dogecoin.initialize()
    }

    @Test("Mnemonic seed with passphrase matches known vector")
    func testSeedWithPassphraseVector() {
        let mnemonic = "chief prevent advice search broccoli dish pride grow evidence bicycle cushion lady"
        let passphrase = "TREZOR"
        let expectedHex = "31113f96716b7d5b8d58a49c5e1f6d6300ff307b35eef3cecfdb97869e514ad330f0a7dcec4ed2feeebf8d2267ebfefeb149df84642ca091befd25ea15d36076"

        var seed = [UInt8](repeating: 0, count: Int(MAX_SEED_SIZE))
        let result = mnemonic.withCString { mnemonicPtr in
            passphrase.withCString { passPtr in
                seed.withUnsafeMutableBufferPointer { seedBuffer in
                    dogecoin_seed_from_mnemonic(mnemonicPtr, passPtr, seedBuffer.baseAddress)
                }
            }
        }

        #expect(result == 0)
        guard let expected = Data(hexString: expectedHex) else {
            #expect(Bool(false))
            return
        }
        #expect(Data(seed) == expected)
    }

    @Test("HD wallet derived from mnemonic matches known vectors")
    func testHDWalletVectors() async throws {
        let mnemonic = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"

        let testnetWallet = try await HDWallet(mnemonic: mnemonic, passphrase: "", network: .testnet)
        #expect(testnetWallet.masterKey == "tprv8ZgxMBicQKsPd66qSfNTYkdM76NsJ368nHs7r1WnKhmUbdx4Gwkhk175pvpe2A652Xzszhg2qf55w8qpRzNBwMboA3R6PoABT36eHV89dRZ")

        let testnetAddress = try await testnetWallet.deriveAddress(account: 0, index: 0, change: false)
        #expect(testnetAddress == "naTzLkBZLpUVXykb3sSP1Wzzz9GzzM4BVU")

        let mainnetWallet = try await HDWallet(mnemonic: mnemonic, passphrase: "", network: .mainnet)
        let mainnetAddress = try await mainnetWallet.deriveAddress(account: 0, index: 0, change: false)
        #expect(mainnetAddress == "DTdKu8YgcxoXyjFCDtCeKimaZzsK27rcwT")
    }

    @Test("Derived private keys match known vectors")
    func testDerivedPrivateKeyVectors() async throws {
        let mnemonic = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"
        let wallet = try await HDWallet(mnemonic: mnemonic, passphrase: "", network: .mainnet)

        let externalKey = try await wallet.derivePrivateKey(account: 1, index: 1, change: false)
        #expect(externalKey == "QPhPcYBCZPPc73Ldrdj6Ubc8SiiRqwRns6nuEqgzshiqJA6WEp62")

        let changeKey = try await wallet.derivePrivateKey(account: 1, index: 1, change: true)
        #expect(changeKey == "QQiHajxrYwkCK1zkbmt2ZTKSQyy64jUPVbw4CDYJBchg975TRBJu")
    }
}
