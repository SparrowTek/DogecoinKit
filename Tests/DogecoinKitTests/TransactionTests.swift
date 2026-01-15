import Foundation
import Testing
@testable import DogecoinKit

@Suite("Transaction Builder")
struct TransactionTests {
    init() {
        Dogecoin.initialize()
    }

    @Test("Create transaction validates sums")
    func testTransactionValidationInsufficientFunds() throws {
        let mnemonic = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"
        let wallet = try HDWallet(mnemonic: mnemonic, passphrase: "", network: .mainnet)
        let address = try wallet.deriveAddress(account: 0, index: 0, change: false)
        let key = try wallet.derivePrivateKey(account: 0, index: 0, change: false)

        let utxo = UTXO(
            txid: String(repeating: "a", count: 64),
            vout: 0,
            address: address,
            amount: DogecoinAmount(doge: 1),
            scriptPubKey: nil,
            confirmations: 6
        )

        #expect(throws: DogecoinError.self) {
            _ = try createTransaction(
                inputs: [utxo],
                outputs: [(address: address, amount: DogecoinAmount(doge: 2))],
                signingKeysByAddress: [address: key],
                changeAddress: address,
                fee: DogecoinAmount(doge: 0.1)
            )
        }
    }

    @Test("Create transaction requires signing keys for inputs")
    func testTransactionValidationMissingSigningKey() throws {
        let mnemonic = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"
        let wallet = try HDWallet(mnemonic: mnemonic, passphrase: "", network: .mainnet)
        let address = try wallet.deriveAddress(account: 0, index: 0, change: false)

        let utxo = UTXO(
            txid: String(repeating: "b", count: 64),
            vout: 1,
            address: address,
            amount: DogecoinAmount(doge: 5),
            scriptPubKey: nil,
            confirmations: 6
        )

        #expect(throws: DogecoinError.self) {
            _ = try createTransaction(
                inputs: [utxo],
                outputs: [(address: "DFbJ8uS9Q2c8E7yVX7p2XfX9wRkN8qVZ3m", amount: DogecoinAmount(doge: 1))],
                signingKeysByAddress: [:],
                changeAddress: address,
                fee: DogecoinAmount(doge: 0.1)
            )
        }
    }

    @Test("Create transaction signs all inputs with per-address keys")
    func testTransactionSigningMultipleInputs() throws {
        let mnemonic = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"
        let wallet = try HDWallet(mnemonic: mnemonic, passphrase: "", network: .mainnet)

        let address1 = try wallet.deriveAddress(account: 0, index: 0, change: false)
        let address2 = try wallet.deriveAddress(account: 0, index: 1, change: false)
        let key1 = try wallet.derivePrivateKey(account: 0, index: 0, change: false)
        let key2 = try wallet.derivePrivateKey(account: 0, index: 1, change: false)

        let utxos = [
            UTXO(
                txid: String(repeating: "c", count: 64),
                vout: 0,
                address: address1,
                amount: DogecoinAmount(doge: 5),
                scriptPubKey: nil,
                confirmations: 6
            ),
            UTXO(
                txid: String(repeating: "d", count: 64),
                vout: 1,
                address: address2,
                amount: DogecoinAmount(doge: 3),
                scriptPubKey: nil,
                confirmations: 6
            )
        ]

        let signedTx = try createTransaction(
            inputs: utxos,
            outputs: [(address: address1, amount: DogecoinAmount(doge: 7))],
            signingKeysByAddress: [
                address1: key1,
                address2: key2
            ],
            changeAddress: address1,
            fee: DogecoinAmount(doge: 0.1)
        )

        #expect(!signedTx.rawHex.isEmpty)
        #expect(signedTx.txid.count == 64)
    }
}
