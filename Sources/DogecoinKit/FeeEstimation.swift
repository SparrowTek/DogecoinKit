import Foundation

/// Dogecoin fee estimation utilities
/// Fee calculation is blockchain-related logic and belongs in DogecoinKit
public enum FeeEstimation {

    // MARK: - Fee Rate Constants

    /// Standard Dogecoin fee rate: 1 DOGE per KB (recommended)
    public static let standardFeePerKB = DogecoinAmount(doge: 1.0)

    /// Low fee rate: 0.1 DOGE per KB (may take longer to confirm)
    public static let lowFeePerKB = DogecoinAmount(doge: 0.1)

    /// High fee rate: 2 DOGE per KB (faster confirmation)
    public static let highFeePerKB = DogecoinAmount(doge: 2.0)

    /// Minimum recommended fee: 0.01 DOGE (dust threshold)
    public static let minimumFee = DogecoinAmount(koinu: 1_000_000)

    /// Dust threshold for change outputs
    public static let dustThreshold = minimumFee

    /// Maximum standard transaction size in bytes
    public static let maxStandardTxSize = 100_000

    // MARK: - Size Constants

    /// Base transaction size in bytes (version 4 + locktime 4 + varint overhead ~2)
    private static let baseTxSize = 10

    /// Size of a P2PKH input in bytes
    /// txid (32) + vout (4) + scriptSig length (1) + scriptSig (~107) + sequence (4) = ~148
    private static let p2pkhInputSize = 148

    /// Size of a P2PKH output in bytes
    /// value (8) + scriptPubKey length (1) + scriptPubKey (25) = 34
    private static let p2pkhOutputSize = 34

    // MARK: - Fee Priority

    /// Fee priority level
    public enum Priority: String, Sendable, CaseIterable {
        /// Low priority - may take longer to confirm
        case low
        /// Standard priority - normal confirmation time
        case standard
        /// High priority - faster confirmation
        case high

        /// Fee rate per kilobyte for this priority
        public var feePerKB: DogecoinAmount {
            switch self {
            case .low: return FeeEstimation.lowFeePerKB
            case .standard: return FeeEstimation.standardFeePerKB
            case .high: return FeeEstimation.highFeePerKB
            }
        }

        /// Display name for UI
        public var displayName: String {
            switch self {
            case .low: return "Economy"
            case .standard: return "Standard"
            case .high: return "Priority"
            }
        }

        /// Estimated confirmation time description
        public var estimatedTime: String {
            switch self {
            case .low: return "~30+ minutes"
            case .standard: return "~10 minutes"
            case .high: return "~1-2 minutes"
            }
        }
    }

    // MARK: - Size Estimation

    /// Estimate transaction size in bytes
    /// - Parameters:
    ///   - inputCount: Number of P2PKH inputs
    ///   - outputCount: Number of P2PKH outputs
    /// - Returns: Estimated transaction size in bytes
    public static func estimateTransactionSize(inputCount: Int, outputCount: Int) -> Int {
        let inputSize = p2pkhInputSize * inputCount
        let outputSize = p2pkhOutputSize * outputCount
        return baseTxSize + inputSize + outputSize
    }

    /// Estimate virtual size for a typical send transaction (1 recipient + 1 change)
    /// - Parameter inputCount: Number of inputs needed
    /// - Returns: Estimated size in bytes
    public static func estimateSendSize(inputCount: Int) -> Int {
        estimateTransactionSize(inputCount: inputCount, outputCount: 2)
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
    /// - Parameters:
    ///   - sizeBytes: Transaction size in bytes
    ///   - feePerKB: Fee rate per kilobyte
    /// - Returns: Calculated fee amount (minimum fee enforced)
    public static func calculateFee(sizeBytes: Int, feePerKB: DogecoinAmount) -> DogecoinAmount {
        // Calculate fee: (size * feePerKB) / 1000
        let feeKoinu = (UInt64(sizeBytes) * feePerKB.koinu) / 1000

        // Enforce minimum fee
        let finalFee = max(feeKoinu, minimumFee.koinu)

        return DogecoinAmount(koinu: finalFee)
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

    /// Estimate fee with all priority options
    /// - Parameters:
    ///   - inputCount: Number of inputs
    ///   - outputCount: Number of outputs
    /// - Returns: Dictionary of priority to fee amount
    public static func estimateAllPriorities(
        inputCount: Int,
        outputCount: Int
    ) -> [Priority: DogecoinAmount] {
        var fees: [Priority: DogecoinAmount] = [:]
        for priority in Priority.allCases {
            fees[priority] = estimateFee(inputCount: inputCount, outputCount: outputCount, priority: priority)
        }
        return fees
    }

    // MARK: - UTXO Selection Helpers

    /// Estimate the number of inputs needed to cover an amount plus fee
    /// - Parameters:
    ///   - targetAmount: The amount to send
    ///   - utxos: Available UTXOs sorted by amount (largest first)
    ///   - priority: Fee priority level
    /// - Returns: Tuple of (selected UTXOs, total fee) or nil if insufficient funds
    public static func selectUTXOsWithFee(
        targetAmount: DogecoinAmount,
        utxos: [UTXO],
        priority: Priority = .standard
    ) -> (utxos: [UTXO], fee: DogecoinAmount)? {
        // Sort UTXOs by amount (largest first)
        let sorted = utxos.sorted { (lhs: UTXO, rhs: UTXO) -> Bool in
            lhs.amount > rhs.amount
        }

        var selected: [UTXO] = []
        var totalInput = DogecoinAmount.zero

        // Initial fee estimate with 1 input
        var estimatedFee = estimateSendFee(inputCount: 1, priority: priority)
        var targetWithFee = targetAmount + estimatedFee

        for utxo in sorted {
            selected.append(utxo)
            totalInput = totalInput + utxo.amount

            // Recalculate fee with updated input count
            estimatedFee = estimateSendFee(inputCount: selected.count, priority: priority)
            targetWithFee = targetAmount + estimatedFee

            if totalInput >= targetWithFee {
                return (selected, estimatedFee)
            }
        }

        return nil // Insufficient funds
    }

    /// Calculate the maximum sendable amount given available UTXOs
    /// - Parameters:
    ///   - utxos: Available UTXOs
    ///   - priority: Fee priority level
    /// - Returns: Maximum sendable amount after fees
    public static func maxSendableAmount(
        utxos: [UTXO],
        priority: Priority = .standard
    ) -> DogecoinAmount {
        guard !utxos.isEmpty else { return .zero }

        let totalInput = utxos.reduce(DogecoinAmount.zero) { $0 + $1.amount }

        // Max sendable is total - fee, output count is 1 (no change needed when sending max)
        let sendAllFee = estimateFee(inputCount: utxos.count, outputCount: 1, priority: priority)

        if totalInput > sendAllFee {
            return totalInput - sendAllFee
        }
        return .zero
    }
}
