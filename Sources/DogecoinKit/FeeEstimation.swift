import Foundation

/// Dogecoin's fee and dust policy, and fee estimates built on it.
///
/// The policy constants are Dogecoin Core's defaults since 1.14.6 — what
/// nodes relay and miners include unless their operators changed them.
public enum FeeEstimation {

    // MARK: - Network Policy

    /// The fee rate Dogecoin Core recommends and its own wallet pays:
    /// 0.01 DOGE per 1000 bytes. It is also the lowest rate miners include
    /// by default — a transaction paying less is relayed but may never
    /// confirm.
    public static let recommendedFeePerKB = DogecoinAmount(koinu: 1_000_000)

    /// The lowest fee rate nodes relay: 0.001 DOGE per 1000 bytes.
    public static let minimumRelayFeePerKB = DogecoinAmount(koinu: 100_000)

    /// The soft dust limit: 0.01 DOGE. A transaction owes this much extra
    /// fee for every output below it, and change this small is added to the
    /// fee rather than given an output of its own.
    public static let softDustLimit = DogecoinAmount(koinu: 1_000_000)

    /// The hard dust limit: 0.001 DOGE. Nodes do not relay a transaction
    /// with an output below it.
    public static let hardDustLimit = DogecoinAmount(koinu: 100_000)

    /// Maximum standard transaction size in bytes
    public static let maxStandardTxSize = 100_000

    // MARK: - Fee Rates

    /// Standard rate: the recommended 0.01 DOGE per 1000 bytes
    public static let standardFeePerKB = recommendedFeePerKB

    /// Economy rate. Nothing below the recommended rate confirms reliably,
    /// so this is the recommended rate as well.
    public static let lowFeePerKB = recommendedFeePerKB

    /// Priority rate: five times the recommended rate, 0.05 DOGE per 1000
    /// bytes, for the rare times blocks are full
    public static let highFeePerKB = DogecoinAmount(koinu: 5_000_000)

    // MARK: - Size Constants

    /// Version (4 bytes) and lock time (4 bytes)
    private static let fixedTxSize = 8

    /// Size of a signed P2PKH input in bytes, at its largest:
    /// txid (32) + vout (4) + scriptSig length (1) + scriptSig (107) + sequence (4)
    static let p2pkhInputSize = 148

    /// Size of a P2PKH output in bytes:
    /// value (8) + scriptPubKey length (1) + scriptPubKey (25).
    /// A P2SH output is two bytes smaller, so this never underestimates.
    static let p2pkhOutputSize = 34

    // MARK: - Fee Priority

    /// Fee priority level
    public enum Priority: String, Sendable, CaseIterable {
        /// The lowest rate that confirms reliably
        case low
        /// The rate Dogecoin Core recommends
        case standard
        /// A higher rate for when blocks are full
        case high

        /// Fee rate per kilobyte for this priority
        public var feePerKB: DogecoinAmount {
            switch self {
            case .low: return FeeEstimation.lowFeePerKB
            case .standard: return FeeEstimation.standardFeePerKB
            case .high: return FeeEstimation.highFeePerKB
            }
        }
    }

    // MARK: - Size Estimation

    /// Estimate transaction size in bytes
    ///
    /// An upper bound for a transaction spending P2PKH outputs: signatures
    /// vary by a byte or two and are counted at their longest.
    /// - Parameters:
    ///   - inputCount: Number of P2PKH inputs
    ///   - outputCount: Number of outputs
    /// - Returns: Estimated transaction size in bytes
    public static func estimateTransactionSize(inputCount: Int, outputCount: Int) -> Int {
        // Negative counts are meaningless; huge ones saturate instead of trapping.
        let inputs = max(0, inputCount)
        let outputs = max(0, outputCount)
        let (inputSize, inputOverflow) = p2pkhInputSize.multipliedReportingOverflow(by: inputs)
        let (outputSize, outputOverflow) = p2pkhOutputSize.multipliedReportingOverflow(by: outputs)
        guard !inputOverflow, !outputOverflow else { return .max }

        let overhead = fixedTxSize + compactSizeLength(of: inputs) + compactSizeLength(of: outputs)
        let (size, overflow) = (overhead + inputSize).addingReportingOverflow(outputSize)
        return overflow ? .max : size
    }

    /// Bytes a count occupies in a transaction's variable-length encoding.
    private static func compactSizeLength(of count: Int) -> Int {
        switch count {
        case ..<0xfd: 1
        case ...0xffff: 3
        case ...0xffff_ffff: 5
        default: 9
        }
    }

    // MARK: - Fee Estimation

    /// Estimate fee for a transaction
    /// - Parameters:
    ///   - inputCount: Number of inputs
    ///   - outputCount: Number of outputs
    ///   - priority: Fee priority level (default: standard)
    /// - Returns: Estimated fee amount
    public static func estimateFee(
        inputCount: Int,
        outputCount: Int,
        priority: Priority = .standard
    ) -> DogecoinAmount {
        estimateFee(inputCount: inputCount, outputCount: outputCount, feePerKB: priority.feePerKB)
    }

    /// Estimate fee for a transaction with custom fee rate
    ///
    /// Leaves out the surcharge for outputs below the soft dust limit; see
    /// ``dustSurcharge(forOutputs:)``.
    /// - Parameters:
    ///   - inputCount: Number of inputs
    ///   - outputCount: Number of outputs
    ///   - feePerKB: Fee rate per kilobyte
    /// - Returns: Estimated fee amount
    public static func estimateFee(
        inputCount: Int,
        outputCount: Int,
        feePerKB: DogecoinAmount
    ) -> DogecoinAmount {
        let sizeBytes = estimateTransactionSize(inputCount: inputCount, outputCount: outputCount)
        return calculateFee(sizeBytes: sizeBytes, feePerKB: feePerKB)
    }

    /// Calculate fee for a given transaction size
    ///
    /// Proportional to the size and rounded down to the koinu, the way nodes
    /// work out what a transaction owes.
    /// - Parameters:
    ///   - sizeBytes: Transaction size in bytes
    ///   - feePerKB: Fee rate per kilobyte
    /// - Returns: Calculated fee amount
    public static func calculateFee(sizeBytes: Int, feePerKB: DogecoinAmount) -> DogecoinAmount {
        // (size * feePerKB) / 1000, saturating rather than trapping
        let (product, overflow) = UInt64(max(0, sizeBytes)).multipliedReportingOverflow(by: feePerKB.koinu)
        return DogecoinAmount(koinu: overflow ? UInt64.max : product / 1000)
    }

    /// The extra fee a transaction owes for outputs below the soft dust
    /// limit: the limit itself, once for each such output.
    /// - Parameter amounts: The value of every output
    public static func dustSurcharge(forOutputs amounts: [DogecoinAmount]) -> DogecoinAmount {
        softDustLimit * UInt64(amounts.count { $0 < softDustLimit })
    }

    /// The lowest fee nodes relay for a transaction: the minimum relay rate
    /// for its size, plus the surcharge for outputs below the soft dust limit.
    /// - Parameters:
    ///   - sizeBytes: Transaction size in bytes
    ///   - amounts: The value of every output
    public static func minimumRelayFee(sizeBytes: Int, outputs amounts: [DogecoinAmount]) -> DogecoinAmount {
        calculateFee(sizeBytes: sizeBytes, feePerKB: minimumRelayFeePerKB) + dustSurcharge(forOutputs: amounts)
    }

    // MARK: - Convenience Methods

    /// Quick estimate for typical 1-input, 2-output transaction at standard priority
    public static var typicalFee: DogecoinAmount {
        estimateFee(inputCount: 1, outputCount: 2, priority: .standard)
    }

    /// Estimate fee for a send transaction with automatic output count (recipient + change)
    /// - Parameters:
    ///   - inputCount: Number of inputs needed
    ///   - priority: Fee priority level
    /// - Returns: Estimated fee
    public static func estimateSendFee(inputCount: Int, priority: Priority = .standard) -> DogecoinAmount {
        estimateFee(inputCount: inputCount, outputCount: 2, priority: priority)
    }

    /// Calculate the maximum amount one transaction can send
    ///
    /// The same as ``SpendPlan/maximumPayment(from:alongside:feePerKB:minimumConfirmations:)``
    /// with no other payments.
    /// - Parameters:
    ///   - utxos: Available UTXOs
    ///   - priority: Fee priority level
    /// - Returns: Maximum sendable amount after fees, or zero when nothing
    ///   can be sent
    public static func maxSendableAmount(
        utxos: [UTXO],
        priority: Priority = .standard
    ) -> DogecoinAmount {
        SpendPlan.maximumPayment(from: utxos, feePerKB: priority.feePerKB)
    }
}
