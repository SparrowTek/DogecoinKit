import Testing
@testable import DogecoinKit

@Suite("Fee Estimation Tests")
struct FeeEstimationTests {

    // MARK: - Size Estimation Tests

    @Test("Estimate transaction size - simple")
    func testEstimateSimpleSize() {
        // 1 input, 2 outputs (recipient + change)
        let size = FeeEstimation.estimateTransactionSize(inputCount: 1, outputCount: 2)

        // Expected: 10 (base) + 148 (1 input) + 68 (2 outputs) = 226 bytes
        #expect(size == 226)
    }

    @Test("Estimate transaction size - multiple inputs")
    func testEstimateMultiInputSize() {
        // 3 inputs, 2 outputs
        let size = FeeEstimation.estimateTransactionSize(inputCount: 3, outputCount: 2)

        // Expected: 10 + 444 (3 inputs) + 68 = 522 bytes
        #expect(size == 522)
    }

    @Test("Estimate send size helper")
    func testEstimateSendSize() {
        // Verify the helper method for typical send (1 recipient + 1 change = 2 outputs)
        let sizeWithHelper = FeeEstimation.estimateSendSize(inputCount: 2)
        let sizeManual = FeeEstimation.estimateTransactionSize(inputCount: 2, outputCount: 2)

        #expect(sizeWithHelper == sizeManual)
    }

    // MARK: - Fee Calculation Tests

    @Test("Calculate fee - standard priority")
    func testCalculateFeeStandard() {
        let fee = FeeEstimation.estimateFee(
            inputCount: 1,
            outputCount: 2,
            priority: .standard
        )

        // Size: 226 bytes
        // Standard fee: 1 DOGE per KB = 100,000,000 koinu per 1000 bytes
        // Fee: 226 * 100,000,000 / 1000 = 22,600,000 koinu
        // But minimum fee is 1,000,000, so actual = max(22,600,000, 1,000,000) = 22,600,000
        #expect(fee.koinu == 22_600_000)
    }

    @Test("Calculate fee - low priority")
    func testCalculateFeeLow() {
        let fee = FeeEstimation.estimateFee(
            inputCount: 1,
            outputCount: 2,
            priority: .low
        )

        // Low fee: 0.1 DOGE per KB = 10,000,000 koinu per 1000 bytes
        // Fee: 226 * 10,000,000 / 1000 = 2,260,000 koinu
        #expect(fee.koinu == 2_260_000)
    }

    @Test("Calculate fee - high priority")
    func testCalculateFeeHigh() {
        let fee = FeeEstimation.estimateFee(
            inputCount: 1,
            outputCount: 2,
            priority: .high
        )

        // High fee: 2 DOGE per KB = 200,000,000 koinu per 1000 bytes
        // Fee: 226 * 200,000,000 / 1000 = 45,200,000 koinu
        #expect(fee.koinu == 45_200_000)
    }

    @Test("Minimum fee enforced")
    func testMinimumFeeEnforced() {
        // Very small transaction with low fee should still meet minimum
        let fee = FeeEstimation.calculateFee(
            sizeBytes: 1, // Very small
            feePerKB: DogecoinAmount(koinu: 1000) // Very low rate
        )

        // Should be minimum fee, not calculated fee
        #expect(fee == FeeEstimation.minimumFee)
        #expect(fee.koinu == 1_000_000) // 0.01 DOGE
    }

    // MARK: - Constants Tests

    @Test("Standard fee per KB")
    func testStandardFeeRate() {
        #expect(FeeEstimation.standardFeePerKB.doge == 1.0)
    }

    @Test("Low fee per KB")
    func testLowFeeRate() {
        #expect(FeeEstimation.lowFeePerKB.doge == 0.1)
    }

    @Test("High fee per KB")
    func testHighFeeRate() {
        #expect(FeeEstimation.highFeePerKB.doge == 2.0)
    }

    @Test("Minimum fee")
    func testMinimumFee() {
        #expect(FeeEstimation.minimumFee.doge == 0.01)
    }

    // MARK: - Priority Tests

    @Test("Priority fee rates")
    func testPriorityFeeRates() {
        #expect(FeeEstimation.Priority.low.feePerKB == FeeEstimation.lowFeePerKB)
        #expect(FeeEstimation.Priority.standard.feePerKB == FeeEstimation.standardFeePerKB)
        #expect(FeeEstimation.Priority.high.feePerKB == FeeEstimation.highFeePerKB)
    }

    @Test("Priority display names")
    func testPriorityDisplayNames() {
        #expect(FeeEstimation.Priority.low.displayName == "Economy")
        #expect(FeeEstimation.Priority.standard.displayName == "Standard")
        #expect(FeeEstimation.Priority.high.displayName == "Priority")
    }

    // MARK: - Typical Fee Tests

    @Test("Typical fee")
    func testTypicalFee() {
        let typical = FeeEstimation.typicalFee
        let manual = FeeEstimation.estimateFee(inputCount: 1, outputCount: 2, priority: .standard)

        #expect(typical == manual)
    }

    @Test("Estimate send fee")
    func testEstimateSendFee() {
        let fee = FeeEstimation.estimateSendFee(inputCount: 2, priority: .standard)
        let expected = FeeEstimation.estimateFee(inputCount: 2, outputCount: 2, priority: .standard)

        #expect(fee == expected)
    }

    // MARK: - All Priorities Tests

    @Test("Estimate all priorities")
    func testEstimateAllPriorities() {
        let fees = FeeEstimation.estimateAllPriorities(inputCount: 1, outputCount: 2)

        #expect(fees.count == 3)
        #expect(fees[.low] != nil)
        #expect(fees[.standard] != nil)
        #expect(fees[.high] != nil)

        // Verify ordering: low < standard < high
        #expect(fees[.low]!.koinu < fees[.standard]!.koinu)
        #expect(fees[.standard]!.koinu < fees[.high]!.koinu)
    }

    // MARK: - UTXO Selection Tests

    @Test("Select UTXOs with fee - sufficient funds")
    func testSelectUTXOsWithFeeSufficient() {
        let utxos = [
            UTXO(txid: "tx1", vout: 0, address: "D1", amount: DogecoinAmount(doge: 100), confirmations: 10),
            UTXO(txid: "tx2", vout: 0, address: "D1", amount: DogecoinAmount(doge: 50), confirmations: 10)
        ]

        let targetAmount = DogecoinAmount(doge: 30)
        let result = FeeEstimation.selectUTXOsWithFee(targetAmount: targetAmount, utxos: utxos)

        #expect(result != nil)
        #expect(result!.utxos.count == 1) // Should only need the 100 DOGE UTXO
        #expect(result!.utxos.first?.txid == "tx1") // Largest first
        #expect(result!.fee.koinu > 0) // Fee should be calculated
    }

    @Test("Select UTXOs with fee - needs multiple")
    func testSelectUTXOsWithFeeMultiple() {
        let utxos = [
            UTXO(txid: "tx1", vout: 0, address: "D1", amount: DogecoinAmount(doge: 30), confirmations: 10),
            UTXO(txid: "tx2", vout: 0, address: "D1", amount: DogecoinAmount(doge: 40), confirmations: 10),
            UTXO(txid: "tx3", vout: 0, address: "D1", amount: DogecoinAmount(doge: 20), confirmations: 10)
        ]

        let targetAmount = DogecoinAmount(doge: 60)
        let result = FeeEstimation.selectUTXOsWithFee(targetAmount: targetAmount, utxos: utxos)

        #expect(result != nil)
        // Need at least 2 UTXOs to cover 60 DOGE + fee
        #expect(result!.utxos.count >= 2)
    }

    @Test("Select UTXOs with fee - insufficient funds")
    func testSelectUTXOsWithFeeInsufficient() {
        let utxos = [
            UTXO(txid: "tx1", vout: 0, address: "D1", amount: DogecoinAmount(doge: 10), confirmations: 10)
        ]

        let targetAmount = DogecoinAmount(doge: 100)
        let result = FeeEstimation.selectUTXOsWithFee(targetAmount: targetAmount, utxos: utxos)

        #expect(result == nil)
    }

    // MARK: - Max Sendable Tests

    @Test("Max sendable amount - single UTXO")
    func testMaxSendableSingle() {
        let utxos = [
            UTXO(txid: "tx1", vout: 0, address: "D1", amount: DogecoinAmount(doge: 100), confirmations: 10)
        ]

        let maxSendable = FeeEstimation.maxSendableAmount(utxos: utxos)

        // Should be total - fee for 1 input, 1 output
        let expectedFee = FeeEstimation.estimateFee(inputCount: 1, outputCount: 1)
        let expectedMax = DogecoinAmount(doge: 100) - expectedFee

        #expect(maxSendable == expectedMax)
    }

    @Test("Max sendable amount - empty")
    func testMaxSendableEmpty() {
        let maxSendable = FeeEstimation.maxSendableAmount(utxos: [])

        #expect(maxSendable == .zero)
    }

    @Test("Max sendable amount - dust UTXOs")
    func testMaxSendableDust() {
        // UTXOs that are worth less than the fee to spend them
        let utxos = [
            UTXO(txid: "tx1", vout: 0, address: "D1", amount: DogecoinAmount(koinu: 100), confirmations: 10)
        ]

        let maxSendable = FeeEstimation.maxSendableAmount(utxos: utxos)

        // Should be zero since fee would exceed the amount
        #expect(maxSendable == .zero)
    }
}
