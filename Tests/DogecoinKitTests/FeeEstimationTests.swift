import Testing
@testable import DogecoinKit

@Suite("Fee Estimation")
struct FeeEstimationTests {

    // MARK: - Policy

    @Test("Policy constants are Dogecoin Core's defaults")
    func policyConstants() {
        // RECOMMENDED_MIN_TX_FEE, DEFAULT_MIN_RELAY_TX_FEE,
        // DEFAULT_DUST_LIMIT, and DEFAULT_HARD_DUST_LIMIT in Core 1.14.6+.
        #expect(FeeEstimation.recommendedFeePerKB == DogecoinAmount(koinu: 1_000_000))
        #expect(FeeEstimation.minimumRelayFeePerKB == DogecoinAmount(koinu: 100_000))
        #expect(FeeEstimation.softDustLimit == DogecoinAmount(koinu: 1_000_000))
        #expect(FeeEstimation.hardDustLimit == DogecoinAmount(koinu: 100_000))
        #expect(FeeEstimation.maxStandardTxSize == 100_000)
    }

    @Test("Standard is the recommended rate, nothing is cheaper, and priority pays five times as much")
    func rates() {
        #expect(FeeEstimation.Priority.standard.feePerKB == FeeEstimation.recommendedFeePerKB)
        #expect(FeeEstimation.Priority.low.feePerKB == FeeEstimation.recommendedFeePerKB)
        #expect(FeeEstimation.Priority.high.feePerKB == DogecoinAmount(koinu: 5_000_000))
        #expect(FeeEstimation.standardFeePerKB == FeeEstimation.Priority.standard.feePerKB)
        #expect(FeeEstimation.lowFeePerKB == FeeEstimation.Priority.low.feePerKB)
        #expect(FeeEstimation.highFeePerKB == FeeEstimation.Priority.high.feePerKB)
    }

    // MARK: - Size

    @Test("Size of the usual shapes", arguments: [
        // 8 fixed + 1 + 1 for the counts, 148 per input, 34 per output
        (inputs: 1, outputs: 1, size: 192),
        (inputs: 1, outputs: 2, size: 226),
        (inputs: 3, outputs: 2, size: 522),
        (inputs: 0, outputs: 0, size: 10)
    ])
    func size(inputs: Int, outputs: Int, size: Int) {
        #expect(FeeEstimation.estimateTransactionSize(inputCount: inputs, outputCount: outputs) == size)
    }

    @Test("Counts of 253 and more take three bytes to write")
    func sizeCountsItsCounts() {
        #expect(FeeEstimation.estimateTransactionSize(inputCount: 252, outputCount: 1) == 10 + 252 * 148 + 34)
        #expect(FeeEstimation.estimateTransactionSize(inputCount: 253, outputCount: 1) == 12 + 253 * 148 + 34)
        #expect(FeeEstimation.estimateTransactionSize(inputCount: 1, outputCount: 253) == 12 + 148 + 253 * 34)
    }

    // MARK: - Fees

    @Test("A one-input, two-output send at each priority", arguments: [
        (priority: FeeEstimation.Priority.low, koinu: UInt64(226_000)),
        (priority: .standard, koinu: 226_000),
        (priority: .high, koinu: 1_130_000)
    ])
    func feeByPriority(priority: FeeEstimation.Priority, koinu: UInt64) {
        #expect(FeeEstimation.estimateFee(inputCount: 1, outputCount: 2, priority: priority) == DogecoinAmount(koinu: koinu))
    }

    @Test("Fees are proportional to size, rounded down, with no flat minimum")
    func feeIsProportional() {
        #expect(FeeEstimation.calculateFee(sizeBytes: 1, feePerKB: DogecoinAmount(koinu: 1000)) == DogecoinAmount(koinu: 1))
        #expect(FeeEstimation.calculateFee(sizeBytes: 1, feePerKB: DogecoinAmount(koinu: 999)) == .zero)
        #expect(FeeEstimation.calculateFee(sizeBytes: 1999, feePerKB: DogecoinAmount(koinu: 1000)) == DogecoinAmount(koinu: 1999))
        #expect(FeeEstimation.calculateFee(sizeBytes: 0, feePerKB: FeeEstimation.standardFeePerKB) == .zero)
    }

    @Test("Convenience estimates agree with the general one")
    func conveniences() {
        #expect(FeeEstimation.typicalFee == FeeEstimation.estimateFee(inputCount: 1, outputCount: 2, priority: .standard))
        #expect(FeeEstimation.estimateSendFee(inputCount: 2) == FeeEstimation.estimateFee(inputCount: 2, outputCount: 2, priority: .standard))
        #expect(FeeEstimation.estimateSendFee(inputCount: 2, priority: .high) == FeeEstimation.estimateFee(inputCount: 2, outputCount: 2, priority: .high))
    }

    // MARK: - Dust

    @Test("Every output below the soft dust limit adds the limit to the fee")
    func dustSurcharge() {
        let limit = FeeEstimation.softDustLimit
        #expect(FeeEstimation.dustSurcharge(forOutputs: []) == .zero)
        #expect(FeeEstimation.dustSurcharge(forOutputs: [limit, DogecoinAmount(koinu: 5_000_000_000)]) == .zero)
        #expect(FeeEstimation.dustSurcharge(forOutputs: [DogecoinAmount(koinu: limit.koinu - 1)]) == limit)
        #expect(FeeEstimation.dustSurcharge(forOutputs: [
            DogecoinAmount(koinu: 500_000), limit, DogecoinAmount(koinu: 100_000)
        ]) == DogecoinAmount(koinu: 2_000_000))
    }

    @Test("The minimum relay fee is the relay rate by size plus the dust surcharge")
    func minimumRelayFee() {
        let whole = DogecoinAmount(koinu: 100_000_000)
        let dusty = DogecoinAmount(koinu: 500_000)

        #expect(FeeEstimation.minimumRelayFee(sizeBytes: 226, outputs: [whole, whole]) == DogecoinAmount(koinu: 22_600))
        #expect(FeeEstimation.minimumRelayFee(sizeBytes: 226, outputs: [whole, dusty]) == DogecoinAmount(koinu: 1_022_600))
        // A flat hundredth of a DOGE stopped covering a transaction of
        // about seventy inputs.
        #expect(FeeEstimation.minimumRelayFee(sizeBytes: 14_878, outputs: [whole, whole]) == DogecoinAmount(koinu: 1_487_800))
    }

    // MARK: - Maximum

    @Test("The most a wallet can send is everything less the fee for one output")
    func maxSendable() {
        let utxos = [
            UTXO(txid: String(repeating: "a", count: 64), vout: 0, address: "D1", amount: DogecoinAmount(koinu: 10_000_000_000), confirmations: 10)
        ]

        #expect(FeeEstimation.maxSendableAmount(utxos: utxos) == DogecoinAmount(koinu: 10_000_000_000 - 192_000))
        #expect(FeeEstimation.maxSendableAmount(utxos: utxos, priority: .high) == DogecoinAmount(koinu: 10_000_000_000 - 960_000))
        #expect(FeeEstimation.maxSendableAmount(utxos: []) == .zero)
    }
}
