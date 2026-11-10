import Foundation
import Testing
@testable import DogecoinKit

/// Runs every job on a brand-new thread — the worst case of the cooperative
/// pool resuming an actor on a different thread after each suspension point.
///
/// Task executors arrived after the package's minimum OS versions, so this
/// and the one test that uses it are only available from there on.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
private final class FreshThreadExecutor: TaskExecutor {
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        Thread.detachNewThread {
            job.runSynchronously(on: executor)
        }
    }
}

@Suite("Transaction Builder Correctness")
struct TransactionBuilderTests {

    private let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private let recipient = "DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5"
    private let p2shRecipient = "A9rmPAxPNGTojaWevb571EYNmCiRLpXzcM"

    init() async {
        await Dogecoin.initialize()
    }

    private struct Keys {
        let address0: String
        let address1: String
        let change0: String
        let key0: String
        let key1: String
    }

    private func keys() async throws -> Keys {
        let wallet = try await HDWallet(mnemonic: mnemonic, network: .mainnet)
        return Keys(
            address0: try await wallet.deriveAddress(account: 0, index: 0, change: false),
            address1: try await wallet.deriveAddress(account: 0, index: 1, change: false),
            change0: try await wallet.deriveAddress(account: 0, index: 0, change: true),
            key0: try await wallet.derivePrivateKey(account: 0, index: 0, change: false),
            key1: try await wallet.derivePrivateKey(account: 0, index: 1, change: false)
        )
    }

    // MARK: - Golden vectors

    // Signed by the pre-fix libdogecoin path and checked with an independent
    // secp256k1/legacy-sighash implementation: every signature verifies, every
    // amount balances. RFC 6979 makes ECDSA deterministic, so the rewritten
    // builder must reproduce them byte for byte.

    @Test("Single input with change matches the golden transaction")
    func goldenSingleInput() async throws {
        let keys = try await keys()
        let signed = try await createTransaction(
            inputs: [UTXO(txid: String(repeating: "11", count: 32), vout: 0, address: keys.address0, amount: DogecoinAmount(koinu: 1_000_000_000))],
            outputs: [(address: recipient, amount: DogecoinAmount(koinu: 250_000_000))],
            signingKeysByAddress: [keys.address0: keys.key0],
            changeAddress: keys.change0,
            fee: DogecoinAmount(koinu: 22_600_000)
        )

        #expect(signed.rawHex == "01000000011111111111111111111111111111111111111111111111111111111111111111000000006a47304402207dcae7af58ee36f5009be8116789059537dd1df584991da975faf5e8847cee910220592dd634d3e09d86fe345b2bc359790695caf33d51407ca400e76c2ef608ec95012102cc6b0dc33aabcf3a23643e5e2919a80c50fb3dd2129ce409bbc5f0d4643d05e0ffffffff0280b2e60e000000001976a91457b5ed84d604e95a2c79f37cebc54efbbcfa52fc88ac403e5b2b000000001976a91419115174dcc75cce4802aaec82e63b491274c2e288ac00000000")
        #expect(signed.txid == "1d5b76ec494479fdfe70c657d0359e22c7aac8a2550e7a62b513fe3a2ecf0524")
    }

    @Test("Two inputs with different keys match the golden transaction")
    func goldenTwoInputs() async throws {
        let keys = try await keys()
        let signed = try await createTransaction(
            inputs: [
                UTXO(txid: "4f8a2b6c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2", vout: 3, address: keys.address0, amount: DogecoinAmount(koinu: 523_456_789)),
                UTXO(txid: "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90", vout: 1, address: keys.address1, amount: DogecoinAmount(koinu: 1_234_567_890)),
            ],
            outputs: [
                (address: recipient, amount: DogecoinAmount(koinu: 1_500_000_001)),
                (address: keys.address1, amount: DogecoinAmount(koinu: 100_000_000)),
            ],
            signingKeysByAddress: [keys.address0: keys.key0, keys.address1: keys.key1],
            changeAddress: keys.change0,
            fee: DogecoinAmount(koinu: 40_000_000)
        )

        #expect(signed.rawHex == "0100000002a291807f6e5d4c3b2a1908f7e6d5c4b3a291807f6e5d4c3b2a1f0e9d6c2b8a4f030000006a47304402200e24025bc7efd465deb19d4d5d0b30eaa149c7b6a7e82ade2d33d7e34bcf096c02206be1d2778e77bda00f7bb0b07842e17ee66969cc654705ee17c0bf11684a8cbf012102cc6b0dc33aabcf3a23643e5e2919a80c50fb3dd2129ce409bbc5f0d4643d05e0ffffffff908f7e6d5c4b3a291807f6e5d4c3b2a1908f7e6d5c4b3a291807f6e5d4c3b2a1010000006a4730440220306f3156c8ed5e5f2e5094b0e0cd54d0ef9b87a6db7cffc1a4e7b08e08320a6f02207fc83279cc1d6e200c9eb0f44cfa1625cf67cbf2ab4c306a1e9977f4b98b51640121025a8ad8881f6facdc949c4a4d03257414153faea67e96acf57344660080610788ffffffff03012f6859000000001976a91457b5ed84d604e95a2c79f37cebc54efbbcfa52fc88ac00e1f505000000001976a9143bf96544e911ca728f5fabf5a4f3b65deab684c488ace6e90807000000001976a91419115174dcc75cce4802aaec82e63b491274c2e288ac00000000")
        #expect(signed.txid == "55a2cfa76824cae55672d914feb9b76b19a1bef9f29e30dd5daa17522f806907")
    }

    @Test("P2SH recipient with change matches the golden transaction")
    func goldenP2SHWithChange() async throws {
        let keys = try await keys()
        let signed = try await createTransaction(
            inputs: [UTXO(txid: String(repeating: "33", count: 32), vout: 7, address: keys.address0, amount: DogecoinAmount(koinu: 900_000_000))],
            outputs: [(address: p2shRecipient, amount: DogecoinAmount(koinu: 123_456_789))],
            signingKeysByAddress: [keys.address0: keys.key0],
            changeAddress: keys.change0,
            fee: DogecoinAmount(koinu: 22_600_000)
        )

        #expect(signed.rawHex == "01000000013333333333333333333333333333333333333333333333333333333333333333070000006b483045022100d4241dfaa8c464222b3d6d4d3978c00a3db0d6749fd476ecc78c826512c5a29402206ce5aa627836b27b40b20816c3ba138e7fc1753bd62e7cd595ec828925a2caf0012102cc6b0dc33aabcf3a23643e5e2919a80c50fb3dd2129ce409bbc5f0d4643d05e0ffffffff0215cd5b070000000017a914bf1c189252e8715c9ad06c005c65452992f6ff7b87ab42f02c000000001976a91419115174dcc75cce4802aaec82e63b491274c2e288ac00000000")
    }

    @Test("Exact spend without change matches the golden transaction")
    func goldenExactSpend() async throws {
        let keys = try await keys()
        let signed = try await createTransaction(
            inputs: [UTXO(txid: String(repeating: "44", count: 32), vout: 2, address: keys.address0, amount: DogecoinAmount(koinu: 300_000_000))],
            outputs: [(address: recipient, amount: DogecoinAmount(koinu: 280_000_000))],
            signingKeysByAddress: [keys.address0: keys.key0],
            changeAddress: keys.change0,
            fee: DogecoinAmount(koinu: 20_000_000)
        )

        #expect(signed.rawHex == "01000000014444444444444444444444444444444444444444444444444444444444444444020000006a473044022076dfab0f703fde010207a0d769a9ec3be30742ac327c2cd4be195a6988f1c773022076bfd8725e6ac627ff049add7c8f8284918d0afbd57500d9a522e99f073354b1012102cc6b0dc33aabcf3a23643e5e2919a80c50fb3dd2129ce409bbc5f0d4643d05e0ffffffff010076b010000000001976a91457b5ed84d604e95a2c79f37cebc54efbbcfa52fc88ac00000000")
    }

    // MARK: - Regressions

    @Test("Exact spend to a P2SH address without change succeeds")
    func exactSpendToP2SH() async throws {
        // libdogecoin's finalize_transaction required the last output to be
        // P2PKH when there was no change, so this send used to fail outright.
        let keys = try await keys()
        let signed = try await createTransaction(
            inputs: [UTXO(txid: String(repeating: "55", count: 32), vout: 0, address: keys.address0, amount: DogecoinAmount(koinu: 300_000_000))],
            outputs: [(address: p2shRecipient, amount: DogecoinAmount(koinu: 280_000_000))],
            signingKeysByAddress: [keys.address0: keys.key0],
            changeAddress: keys.change0,
            fee: DogecoinAmount(koinu: 20_000_000)
        )

        let decoded = try #require(RawTransaction(hex: signed.rawHex))
        #expect(decoded.inputs.count == 1)
        #expect(decoded.outputs == [
            RawTransaction.Output(value: 280_000_000, script: try #require(Address.scriptPubKey(for: p2shRecipient)))
        ])
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    @Test("Builder steps survive resuming on a different thread after every await")
    func builderSurvivesThreadHops() async throws {
        let keys = try await keys()

        // Before the fix, libdogecoin's thread-local transaction table made
        // the second step fail (addInputFailed) as soon as the actor hopped.
        let rawHex = try await withTaskExecutorPreference(FreshThreadExecutor()) {
            let builder = try await TransactionBuilder()
            try await builder.addInput(txid: String(repeating: "11", count: 32), vout: 0)
            try await builder.addOutput(address: recipient, amount: DogecoinAmount(koinu: 250_000_000))
            _ = try await builder.finalize(
                destinationAddress: recipient,
                fee: DogecoinAmount(koinu: 22_600_000),
                totalAmount: DogecoinAmount(koinu: 1_000_000_000),
                changeAddress: keys.change0
            )
            try await builder.signInput(index: 0, privateKeyWIF: keys.key0)
            return try await builder.getRawTransaction()
        }

        #expect(rawHex.hasPrefix("0100000001111111"))
        #expect(rawHex == "01000000011111111111111111111111111111111111111111111111111111111111111111000000006a47304402207dcae7af58ee36f5009be8116789059537dd1df584991da975faf5e8847cee910220592dd634d3e09d86fe345b2bc359790695caf33d51407ca400e76c2ef608ec95012102cc6b0dc33aabcf3a23643e5e2919a80c50fb3dd2129ce409bbc5f0d4643d05e0ffffffff0280b2e60e000000001976a91457b5ed84d604e95a2c79f37cebc54efbbcfa52fc88ac403e5b2b000000001976a91419115174dcc75cce4802aaec82e63b491274c2e288ac00000000")
    }

    @Test("Many concurrent sends all produce the same signed transaction")
    func concurrentSendsAgree() async throws {
        let keys = try await keys()
        let expected = try await createTransaction(
            inputs: [UTXO(txid: String(repeating: "11", count: 32), vout: 0, address: keys.address0, amount: DogecoinAmount(koinu: 1_000_000_000))],
            outputs: [(address: recipient, amount: DogecoinAmount(koinu: 250_000_000))],
            signingKeysByAddress: [keys.address0: keys.key0],
            changeAddress: keys.change0,
            fee: DogecoinAmount(koinu: 22_600_000)
        )

        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try await createTransaction(
                        inputs: [UTXO(txid: String(repeating: "11", count: 32), vout: 0, address: keys.address0, amount: DogecoinAmount(koinu: 1_000_000_000))],
                        outputs: [(address: recipient, amount: DogecoinAmount(koinu: 250_000_000))],
                        signingKeysByAddress: [keys.address0: keys.key0],
                        changeAddress: keys.change0,
                        fee: DogecoinAmount(koinu: 22_600_000)
                    ).rawHex
                }
            }
            for try await rawHex in group {
                #expect(rawHex == expected.rawHex)
            }
        }
    }

    @Test("A signing key that does not own the input is rejected before signing")
    func mismatchedSigningKeyRejected() async throws {
        let keys = try await keys()
        await #expect(throws: DogecoinError.self) {
            _ = try await createTransaction(
                inputs: [UTXO(txid: String(repeating: "66", count: 32), vout: 0, address: keys.address0, amount: DogecoinAmount(koinu: 500_000_000))],
                outputs: [(address: recipient, amount: DogecoinAmount(koinu: 100_000_000))],
                signingKeysByAddress: [keys.address0: keys.key1],
                changeAddress: keys.change0,
                fee: DogecoinAmount(koinu: 20_000_000)
            )
        }
    }

    @Test("Spending the same outpoint twice is rejected")
    func duplicateInputRejected() async throws {
        let keys = try await keys()
        let utxo = UTXO(txid: String(repeating: "77", count: 32), vout: 1, address: keys.address0, amount: DogecoinAmount(koinu: 500_000_000))
        #expect(throws: DogecoinError.self) {
            _ = try planTransaction(
                inputs: [utxo, utxo],
                outputs: [(address: recipient, amount: DogecoinAmount(koinu: 100_000_000))],
                fee: DogecoinAmount(koinu: 20_000_000),
                changeAddress: keys.change0
            )
        }
    }

    @Test("A recorded input script that pays someone else is rejected")
    func foreignInputScriptRejected() async throws {
        let keys = try await keys()
        let foreignScript = try #require(Address.scriptPubKey(for: recipient)).hexString
        await #expect(throws: DogecoinError.self) {
            _ = try await createTransaction(
                inputs: [UTXO(txid: String(repeating: "88", count: 32), vout: 0, address: keys.address0, amount: DogecoinAmount(koinu: 500_000_000), scriptPubKey: foreignScript)],
                outputs: [(address: recipient, amount: DogecoinAmount(koinu: 100_000_000))],
                signingKeysByAddress: [keys.address0: keys.key0],
                changeAddress: keys.change0,
                fee: DogecoinAmount(koinu: 20_000_000)
            )
        }
    }

    @Test("An empty recorded input script is treated as unknown")
    func emptyInputScriptAccepted() async throws {
        let keys = try await keys()
        let signed = try await createTransaction(
            inputs: [UTXO(txid: String(repeating: "99", count: 32), vout: 0, address: keys.address0, amount: DogecoinAmount(koinu: 500_000_000), scriptPubKey: "")],
            outputs: [(address: recipient, amount: DogecoinAmount(koinu: 100_000_000))],
            signingKeysByAddress: [keys.address0: keys.key0],
            changeAddress: keys.change0,
            fee: DogecoinAmount(koinu: 20_000_000)
        )
        #expect(RawTransaction(hex: signed.rawHex)?.inputs.count == 1)
    }

    @Test("Builder rejects malformed outpoints and amounts")
    func builderValidatesInputs() async throws {
        let builder = try await TransactionBuilder()

        await #expect(throws: DogecoinError.self) {
            try await builder.addInput(txid: "+1" + String(repeating: "0", count: 62), vout: 0)
        }
        await #expect(throws: DogecoinError.self) {
            try await builder.addInput(txid: String(repeating: "ab", count: 32), vout: -1)
        }
        await #expect(throws: DogecoinError.self) {
            try await builder.addOutput(address: recipient, amount: .zero)
        }
        await #expect(throws: DogecoinError.self) {
            try await builder.addOutput(address: recipient, amount: DogecoinAmount(koinu: DogecoinAmount.maxMoney.koinu + 1))
        }

        // A testnet output in a transaction whose first output is mainnet
        let testnetAddress = try await HDWallet(mnemonic: mnemonic, network: .testnet).deriveAddress()
        #expect(Address.isTestnet(testnetAddress))
        try await builder.addOutput(address: recipient, amount: DogecoinAmount(koinu: 1_000_000))
        await #expect(throws: DogecoinError.self) {
            try await builder.addOutput(address: testnetAddress, amount: DogecoinAmount(koinu: 1_000_000))
        }
    }

    @Test("Finalize refuses to drop change on the floor")
    func finalizeRequiresChangeAddressForChange() async throws {
        let builder = try await TransactionBuilder()
        try await builder.addInput(txid: String(repeating: "ab", count: 32), vout: 0)
        try await builder.addOutput(address: recipient, amount: DogecoinAmount(koinu: 100_000_000))

        await #expect(throws: DogecoinError.self) {
            _ = try await builder.finalize(
                destinationAddress: recipient,
                fee: DogecoinAmount(koinu: 10_000_000),
                totalAmount: DogecoinAmount(koinu: 500_000_000),
                changeAddress: nil
            )
        }
    }

    @Test("Finalized builders reject further edits")
    func finalizedBuilderIsSealed() async throws {
        let builder = try await TransactionBuilder()
        try await builder.addInput(txid: String(repeating: "ab", count: 32), vout: 0)
        try await builder.addOutput(address: recipient, amount: DogecoinAmount(koinu: 100_000_000))
        _ = try await builder.finalize(
            destinationAddress: recipient,
            fee: DogecoinAmount(koinu: 10_000_000),
            totalAmount: DogecoinAmount(koinu: 110_000_000)
        )

        await #expect(throws: DogecoinError.self) {
            try await builder.addInput(txid: String(repeating: "cd", count: 32), vout: 1)
        }
    }

    @Test("Signing before finalize is refused, since nothing would return the change")
    func signingRequiresFinalize() async throws {
        let keys = try await keys()
        let builder = try await TransactionBuilder()
        try await builder.addInput(txid: String(repeating: "ab", count: 32), vout: 0)
        try await builder.addOutput(address: recipient, amount: DogecoinAmount(koinu: 100_000_000))

        await #expect(throws: DogecoinError.transactionValidationFailed("Finalize the transaction before signing it")) {
            try await builder.sign(privateKeyWIF: keys.key0)
        }
        await #expect(throws: DogecoinError.transactionValidationFailed("Finalize the transaction before signing it")) {
            try await builder.signInput(index: 0, privateKeyWIF: keys.key0)
        }
    }

    @Test("An input cannot be signed twice")
    func doubleSigningIsRefused() async throws {
        let keys = try await keys()
        let builder = try await TransactionBuilder()
        try await builder.addInput(txid: String(repeating: "ab", count: 32), vout: 0)
        try await builder.addOutput(address: recipient, amount: DogecoinAmount(koinu: 100_000_000))
        _ = try await builder.finalize(
            destinationAddress: recipient,
            fee: DogecoinAmount(koinu: 10_000_000),
            totalAmount: DogecoinAmount(koinu: 110_000_000)
        )

        try await builder.signInput(index: 0, privateKeyWIF: keys.key0)
        let signed = try await builder.getRawTransaction()

        await #expect(throws: DogecoinError.transactionValidationFailed("Input 0 is already signed")) {
            try await builder.signInput(index: 0, privateKeyWIF: keys.key1)
        }
        await #expect(throws: DogecoinError.transactionValidationFailed("Input 0 is already signed")) {
            try await builder.sign(privateKeyWIF: keys.key0)
        }
        #expect(try await builder.getRawTransaction() == signed)
    }

    @Test("Signing with an unusable key fails before libdogecoin sees it")
    func unusableSigningKey() async throws {
        let builder = try await TransactionBuilder()
        try await builder.addInput(txid: String(repeating: "ab", count: 32), vout: 0)
        try await builder.addOutput(address: recipient, amount: DogecoinAmount(koinu: 100_000_000))
        _ = try await builder.finalize(
            destinationAddress: recipient,
            fee: DogecoinAmount(koinu: 10_000_000),
            totalAmount: DogecoinAmount(koinu: 110_000_000)
        )

        let zeroKey = Base58Check.encode(Data([0x9E]) + Data(count: 32) + Data([0x01]))
        await #expect(throws: DogecoinError.invalidPrivateKey) {
            try await builder.signInput(index: 0, privateKeyWIF: zeroKey)
        }
    }

    @Test("Inputs, outputs, and change on different networks are rejected")
    func mixedNetworksAreRejected() async throws {
        let keys = try await keys()
        let testnetWallet = try await HDWallet(mnemonic: mnemonic, network: .testnet)
        let testnetAddress = try await testnetWallet.deriveAddress(account: 0, index: 0)

        await #expect(throws: DogecoinError.transactionValidationFailed("Inputs, outputs, and change must be on the same network")) {
            _ = try await createTransaction(
                inputs: [UTXO(txid: String(repeating: "11", count: 32), vout: 0, address: keys.address0, amount: DogecoinAmount(koinu: 1_000_000_000))],
                outputs: [(address: testnetAddress, amount: DogecoinAmount(koinu: 250_000_000))],
                signingKeysByAddress: [keys.address0: keys.key0],
                changeAddress: keys.change0,
                fee: DogecoinAmount(koinu: 22_600_000)
            )
        }
        await #expect(throws: DogecoinError.transactionValidationFailed("Inputs, outputs, and change must be on the same network")) {
            _ = try await createTransaction(
                inputs: [UTXO(txid: String(repeating: "11", count: 32), vout: 0, address: keys.address0, amount: DogecoinAmount(koinu: 1_000_000_000))],
                outputs: [(address: recipient, amount: DogecoinAmount(koinu: 250_000_000))],
                signingKeysByAddress: [keys.address0: keys.key0],
                changeAddress: testnetAddress,
                fee: DogecoinAmount(koinu: 22_600_000)
            )
        }
    }

    // MARK: - Mnemonic validation

    @Test("HDWallet rejects a phrase with a bad checksum")
    func walletRejectsBadChecksum() async throws {
        // Every word is valid BIP39, but the last word breaks the checksum.
        let invalid = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
        await #expect(throws: DogecoinError.invalidMnemonic) {
            _ = try await HDWallet(mnemonic: invalid, network: .mainnet)
        }
    }

    @Test("HDWallet rejects a capitalized phrase instead of deriving a different wallet")
    func walletRejectsCapitalizedPhrase() async throws {
        await #expect(throws: DogecoinError.invalidMnemonic) {
            _ = try await HDWallet(mnemonic: "Abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", network: .mainnet)
        }
    }

    @Test("Restoring an already-accepted phrase does not re-validate it")
    func restoreSkipsValidation() async throws {
        let invalid = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
        let wallet = try await HDWallet(acceptedMnemonic: invalid, passphrase: "", network: .mainnet)
        #expect(!wallet.masterKey.isEmpty)
    }

    @Test("deriveAddresses rejects negative counts and index overflow")
    func deriveAddressesBounds() async throws {
        let wallet = try await HDWallet(mnemonic: mnemonic, network: .mainnet)
        await #expect(throws: DogecoinError.self) {
            _ = try await wallet.deriveAddresses(count: -1)
        }
        await #expect(throws: DogecoinError.self) {
            _ = try await wallet.deriveAddresses(count: 2, startIndex: UInt32.max)
        }
        let addresses = try await wallet.deriveAddresses(count: 0)
        #expect(addresses.isEmpty)
    }
}
