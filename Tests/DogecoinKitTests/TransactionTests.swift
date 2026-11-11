import Foundation
import Testing
@testable import DogecoinKit

@Suite("Transaction Builder")
struct TransactionTests {

    @Test("Create transaction validates sums")
    func transactionValidationInsufficientFunds() async throws {
        let mnemonic = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"
        let wallet = try await HDWallet(mnemonic: mnemonic, passphrase: "", network: .mainnet)
        let address = try await wallet.deriveAddress(account: 0, index: 0, change: false)
        let key = try await wallet.derivePrivateKey(account: 0, index: 0, change: false)

        let utxo = UTXO(
            txid: String(repeating: "a", count: 64),
            vout: 0,
            address: address,
            amount: DogecoinAmount(doge: 1),
            scriptPubKey: nil,
            confirmations: 6
        )

        await #expect(throws: DogecoinError.transactionValidationFailed("Inputs do not cover outputs and fee")) {
            _ = try await createTransaction(
                inputs: [utxo],
                outputs: [(address: address, amount: DogecoinAmount(doge: 2))],
                signingKeysByAddress: [address: key],
                changeAddress: address,
                fee: DogecoinAmount(doge: 0.1)
            )
        }
    }

    @Test("Create transaction requires signing keys for inputs")
    func transactionValidationMissingSigningKey() async throws {
        let mnemonic = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"
        let wallet = try await HDWallet(mnemonic: mnemonic, passphrase: "", network: .mainnet)
        let address = try await wallet.deriveAddress(account: 0, index: 0, change: false)

        let utxo = UTXO(
            txid: String(repeating: "b", count: 64),
            vout: 1,
            address: address,
            amount: DogecoinAmount(doge: 5),
            scriptPubKey: nil,
            confirmations: 6
        )

        // A valid recipient, so nothing but the missing key can fail.
        await #expect(throws: DogecoinError.transactionValidationFailed("Missing signing key for address \(address)")) {
            _ = try await createTransaction(
                inputs: [utxo],
                outputs: [(address: "DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5", amount: DogecoinAmount(doge: 1))],
                signingKeysByAddress: [:],
                changeAddress: address,
                fee: DogecoinAmount(doge: 0.1)
            )
        }
    }

    @Test("Create transaction signs all inputs with per-address keys")
    func transactionSigningMultipleInputs() async throws {
        let mnemonic = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"
        let wallet = try await HDWallet(mnemonic: mnemonic, passphrase: "", network: .mainnet)

        let address1 = try await wallet.deriveAddress(account: 0, index: 0, change: false)
        let address2 = try await wallet.deriveAddress(account: 0, index: 1, change: false)
        let key1 = try await wallet.derivePrivateKey(account: 0, index: 0, change: false)
        let key2 = try await wallet.derivePrivateKey(account: 0, index: 1, change: false)

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

        let signedTx = try await createTransaction(
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

    // MARK: - Planning

    private static let planningMnemonic = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"

    private func planningAddress() async throws -> String {
        try await HDWallet(mnemonic: Self.planningMnemonic, passphrase: "", network: .mainnet)
            .deriveAddress(account: 0, index: 0, change: false)
    }

    private func inputs(_ count: Int, of koinu: UInt64, at address: String) -> [UTXO] {
        (0..<count).map { index in
            UTXO(txid: String(repeating: "e", count: 64), vout: index, address: address, amount: DogecoinAmount(koinu: koinu), confirmations: 6)
        }
    }

    @Test("Planning folds dust change into fee")
    func planDropsDustChange() async throws {
        let address = try await planningAddress()

        let plan = try planTransaction(
            inputs: inputs(1, of: 100_000_000, at: address),
            outputs: [(address: address, amount: DogecoinAmount(koinu: 98_500_000))],
            fee: DogecoinAmount(koinu: 1_000_000),
            changeAddress: address
        )

        #expect(plan.change == .zero)
        #expect(plan.changeAddress == nil)
        #expect(plan.fee == DogecoinAmount(koinu: 1_500_000))
        #expect(plan.outputCount == 1)
    }

    @Test("Planning pays the fee asked for and returns the rest as change")
    func planKeepsRequestedFee() async throws {
        let address = try await planningAddress()

        let plan = try planTransaction(
            inputs: inputs(1, of: 100_000_000, at: address),
            outputs: [(address: address, amount: DogecoinAmount(koinu: 50_000_000))],
            fee: DogecoinAmount(koinu: 10_000_000),
            changeAddress: address
        )

        #expect(plan.fee == DogecoinAmount(koinu: 10_000_000))
        #expect(plan.change == DogecoinAmount(koinu: 40_000_000))
        #expect(plan.changeAddress == address)
        #expect(plan.outputCount == 2)
    }

    @Test("Planning raises a fee nodes would not relay to the least they do")
    func planRaisesFeeToRelayMinimum() async throws {
        let address = try await planningAddress()

        // One input, two outputs: 226 bytes at 0.001 DOGE per 1000.
        let plan = try planTransaction(
            inputs: inputs(1, of: 100_000_000, at: address),
            outputs: [(address: address, amount: DogecoinAmount(koinu: 50_000_000))],
            fee: .zero,
            changeAddress: address
        )

        #expect(plan.fee == DogecoinAmount(koinu: 22_600))
        #expect(plan.change == DogecoinAmount(koinu: 50_000_000 - 22_600))
    }

    @Test("A flat fee that underpays a large transaction is raised to what its size needs")
    func planScalesMinimumWithSize() async throws {
        let address = try await planningAddress()

        // A hundred inputs and two outputs are 14,878 bytes: a hundredth of
        // a DOGE no longer covers the relay minimum.
        let plan = try planTransaction(
            inputs: inputs(100, of: 100_000_000, at: address),
            outputs: [(address: address, amount: DogecoinAmount(koinu: 5_000_000_000))],
            fee: DogecoinAmount(koinu: 1_000_000),
            changeAddress: address
        )

        #expect(plan.fee == DogecoinAmount(koinu: 1_487_800))
        #expect(plan.change == DogecoinAmount(koinu: 5_000_000_000 - 1_487_800))
    }

    @Test("An output below the soft dust limit raises the minimum by the limit")
    func planAddsDustSurcharge() async throws {
        let address = try await planningAddress()

        let plan = try planTransaction(
            inputs: inputs(1, of: 100_000_000, at: address),
            outputs: [(address: address, amount: DogecoinAmount(koinu: 500_000))],
            fee: .zero,
            changeAddress: address
        )

        #expect(plan.fee == DogecoinAmount(koinu: 1_022_600))
        #expect(plan.change == DogecoinAmount(koinu: 100_000_000 - 500_000 - 1_022_600))
    }

    @Test("An output below the hard dust limit is refused")
    func planRejectsHardDust() async throws {
        let address = try await planningAddress()

        #expect(throws: DogecoinError.transactionValidationFailed("Output amount is below the network's dust limit")) {
            _ = try planTransaction(
                inputs: inputs(1, of: 100_000_000, at: address),
                outputs: [(address: address, amount: DogecoinAmount(koinu: 99_999))],
                fee: DogecoinAmount(koinu: 1_000_000),
                changeAddress: address
            )
        }

        // The limit itself is fine.
        let plan = try planTransaction(
            inputs: inputs(1, of: 100_000_000, at: address),
            outputs: [(address: address, amount: DogecoinAmount(koinu: 100_000))],
            fee: DogecoinAmount(koinu: 2_000_000),
            changeAddress: address
        )
        #expect(plan.fee == DogecoinAmount(koinu: 2_000_000))
    }

    @Test("Inputs that do not cover the outputs and the raised fee are refused")
    func planRejectsUncoveredMinimum() async throws {
        let address = try await planningAddress()

        // 192 bytes need 19,200 koinu; the input leaves 19,199.
        #expect(throws: DogecoinError.transactionValidationFailed("Inputs do not cover outputs and fee")) {
            _ = try planTransaction(
                inputs: inputs(1, of: 100_000_000, at: address),
                outputs: [(address: address, amount: DogecoinAmount(koinu: 100_000_000 - 19_199))],
                fee: .zero,
                changeAddress: address
            )
        }

        let exact = try planTransaction(
            inputs: inputs(1, of: 100_000_000, at: address),
            outputs: [(address: address, amount: DogecoinAmount(koinu: 100_000_000 - 19_200))],
            fee: .zero,
            changeAddress: address
        )
        #expect(exact.fee == DogecoinAmount(koinu: 19_200))
        #expect(exact.change == .zero)
    }

    @Test("Planning enforces standard size limits")
    func planRejectsOversizedTransaction() async throws {
        let address = try await planningAddress()

        #expect(throws: DogecoinError.transactionValidationFailed("Transaction exceeds standard size limit")) {
            _ = try planTransaction(
                inputs: inputs(700, of: 100_000_000, at: address),
                outputs: [(address: address, amount: DogecoinAmount(koinu: 1_000_000_000))],
                fee: DogecoinAmount(koinu: 100_000_000),
                changeAddress: address
            )
        }
    }

    @Test("Change that has no room for an output is never paid away as fee")
    func planNeverBurnsChange() async throws {
        let address = try await planningAddress()

        // 675 inputs and two outputs are 99,980 bytes; the change output
        // would make it 100,014. The 655 DOGE left over must not become fee.
        #expect(throws: DogecoinError.transactionValidationFailed("Transaction exceeds standard size limit")) {
            _ = try planTransaction(
                inputs: inputs(675, of: 100_000_000, at: address),
                outputs: [
                    (address: address, amount: DogecoinAmount(koinu: 1_000_000_000)),
                    (address: address, amount: DogecoinAmount(koinu: 1_000_000_000))
                ],
                fee: DogecoinAmount(koinu: 100_000_000),
                changeAddress: address
            )
        }
    }

    @Test("A plan from SpendPlan is built exactly as planned")
    func spendPlanAndTransactionPlanAgree() async throws {
        let address = try await planningAddress()
        let coins = [
            UTXO(txid: String(repeating: "a", count: 64), vout: 0, address: address, amount: DogecoinAmount(koinu: 300_000_000), confirmations: 6),
            UTXO(txid: String(repeating: "b", count: 64), vout: 0, address: address, amount: DogecoinAmount(koinu: 500_000_000), confirmations: 6)
        ]
        let appFee = DogecoinAmount(koinu: 100_000_000)

        for payment in [DogecoinAmount(koinu: 250_000_000), SpendPlan.maximumPayment(from: coins, alongside: [appFee])] {
            let spend = try SpendPlan(paying: [payment, appFee], from: coins)
            let plan = try planTransaction(
                inputs: spend.inputs,
                outputs: [(address: address, amount: payment), (address: address, amount: appFee)],
                fee: spend.fee,
                changeAddress: address
            )

            #expect(plan.fee == spend.fee)
            #expect(plan.change == spend.change)
        }
    }
}
