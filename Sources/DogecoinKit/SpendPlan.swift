import Foundation

/// Which outputs a payment spends, the fee it pays, and the change it returns.
///
/// One plan serves every step of a send — the fee shown while an amount is
/// entered, the most that can be sent, and the transaction that is finally
/// built — so the three cannot disagree. Hand ``inputs`` and ``fee`` to
/// ``createTransaction(inputs:outputs:signingKeysByAddress:changeAddress:fee:)``
/// together with the payments the plan was made for.
///
/// Inputs are chosen largest first, which keeps transactions small. Outputs
/// that cost more to spend than they are worth are left alone.
public struct SpendPlan: Sendable, Equatable {
    /// The outputs to spend, largest first
    public let inputs: [UTXO]

    /// The network fee. When the inputs leave less than
    /// ``FeeEstimation/softDustLimit`` over, that remainder is part of the
    /// fee instead of becoming a change output.
    public let fee: DogecoinAmount

    /// What returns to the wallet, or zero when the transaction has no
    /// change output
    public let change: DogecoinAmount

    /// Why a payment cannot be planned
    public enum Failure: Error, Sendable, Equatable {
        /// There is no payment, or one is below
        /// ``FeeEstimation/hardDustLimit`` — the network would not relay
        /// it — or above ``DogecoinAmount/maxMoney``
        case paymentOutOfRange

        /// The spendable outputs do not cover the payments and the fee
        case insufficientFunds

        /// The funds are there, but spread over more outputs than one
        /// standard transaction can spend. A smaller payment first, with
        /// its change, gathers them.
        case tooManyInputs
    }
}

extension SpendPlan {
    /// Plans a transaction that makes `payments`.
    /// - Parameters:
    ///   - payments: The value of every output to pay, change excluded
    ///   - utxos: The outputs available to spend, in any order
    ///   - feePerKB: The fee rate; rates below
    ///     ``FeeEstimation/minimumRelayFeePerKB`` are raised to it
    ///   - minimumConfirmations: Outputs with fewer confirmations are not
    ///     spent
    /// - Throws: ``Failure``
    public init(
        paying payments: [DogecoinAmount],
        from utxos: [UTXO],
        feePerKB: DogecoinAmount = FeeEstimation.standardFeePerKB,
        minimumConfirmations: Int = 1
    ) throws(Failure) {
        guard !payments.isEmpty,
              payments.allSatisfy({ $0 >= FeeEstimation.hardDustLimit && $0 <= .maxMoney }),
              let target = Self.checkedSum(payments) else {
            throw .paymentOutOfRange
        }

        let rate = max(feePerKB, FeeEstimation.minimumRelayFeePerKB)
        let surcharge = FeeEstimation.dustSurcharge(forOutputs: payments)
        let coins = Self.coinsWorthSpending(utxos, at: rate, minimumConfirmations: minimumConfirmations)

        var selected: [UTXO] = []
        var total = DogecoinAmount.zero

        for coin in coins {
            let inputCount = selected.count + 1
            guard Self.isStandardSize(inputCount: inputCount, outputCount: payments.count) else { break }
            guard let sum = Self.checkedSum([total, coin.amount]) else { throw .paymentOutOfRange }
            selected.append(coin)
            total = sum

            // With a change output, if what is left over is worth one.
            let feeWithChange = FeeEstimation.estimateFee(
                inputCount: inputCount,
                outputCount: payments.count + 1,
                feePerKB: rate
            ) + surcharge
            if Self.isStandardSize(inputCount: inputCount, outputCount: payments.count + 1),
               total >= target + feeWithChange + FeeEstimation.softDustLimit {
                self.init(inputs: selected, fee: feeWithChange, change: total - target - feeWithChange)
                return
            }

            // Without one: whatever is left over goes to the fee.
            let feeWithoutChange = FeeEstimation.estimateFee(
                inputCount: inputCount,
                outputCount: payments.count,
                feePerKB: rate
            ) + surcharge
            if total >= target + feeWithoutChange {
                self.init(inputs: selected, fee: total - target, change: .zero)
                return
            }
        }

        // Out of coins, or out of room for them?
        let everything = coins.reduce(DogecoinAmount.zero) { $0 + $1.amount }
        throw selected.count < coins.count && everything >= target ? .tooManyInputs : .insufficientFunds
    }

    /// The largest payment one transaction can make from `utxos` on top of
    /// `payments`: everything worth spending, less the fee, with no change.
    ///
    /// Planning that payment — `SpendPlan(paying: payments + [maximum], …)`
    /// with the same outputs, rate, and confirmations — always succeeds and
    /// spends exactly the same outputs.
    /// - Parameters:
    ///   - utxos: The outputs available to spend, in any order
    ///   - payments: Other payments the same transaction makes
    ///   - feePerKB: The fee rate; rates below
    ///     ``FeeEstimation/minimumRelayFeePerKB`` are raised to it
    ///   - minimumConfirmations: Outputs with fewer confirmations are not
    ///     spent
    /// - Returns: The amount, or zero when nothing can be sent — including
    ///   when what would be left is below ``FeeEstimation/softDustLimit``,
    ///   which costs more in fees to send than it is worth
    public static func maximumPayment(
        from utxos: [UTXO],
        alongside payments: [DogecoinAmount] = [],
        feePerKB: DogecoinAmount = FeeEstimation.standardFeePerKB,
        minimumConfirmations: Int = 1
    ) -> DogecoinAmount {
        let rate = max(feePerKB, FeeEstimation.minimumRelayFeePerKB)
        let outputCount = payments.count + 1
        let coins = coinsWorthSpending(utxos, at: rate, minimumConfirmations: minimumConfirmations)
            .enumerated()
            .prefix { isStandardSize(inputCount: $0.offset + 1, outputCount: outputCount) }
            .map(\.element)

        guard !coins.isEmpty,
              let total = checkedSum(coins.map(\.amount)),
              let owed = checkedSum(payments + [
                  FeeEstimation.estimateFee(inputCount: coins.count, outputCount: outputCount, feePerKB: rate),
                  FeeEstimation.dustSurcharge(forOutputs: payments)
              ]),
              total >= owed else {
            return .zero
        }

        let remainder = total - owed
        return remainder >= FeeEstimation.softDustLimit ? min(remainder, .maxMoney) : .zero
    }
}

private extension SpendPlan {
    /// The outputs that add more to a transaction than spending them costs,
    /// largest first. Ties are ordered by outpoint, so the same wallet
    /// always yields the same plan.
    static func coinsWorthSpending(_ utxos: [UTXO], at rate: DogecoinAmount, minimumConfirmations: Int) -> [UTXO] {
        let costOfAnInput = FeeEstimation.calculateFee(sizeBytes: FeeEstimation.p2pkhInputSize, feePerKB: rate)
        return utxos
            .filter { $0.confirmations >= minimumConfirmations && $0.amount > costOfAnInput && $0.amount <= .maxMoney }
            .sorted { lhs, rhs in
                lhs.amount == rhs.amount ? (lhs.txid, lhs.vout) < (rhs.txid, rhs.vout) : lhs.amount > rhs.amount
            }
    }

    static func isStandardSize(inputCount: Int, outputCount: Int) -> Bool {
        FeeEstimation.estimateTransactionSize(inputCount: inputCount, outputCount: outputCount) <= FeeEstimation.maxStandardTxSize
    }

    /// Sums amounts, returning `nil` instead of saturating on overflow.
    static func checkedSum(_ amounts: [DogecoinAmount]) -> DogecoinAmount? {
        var total: UInt64 = 0
        for amount in amounts {
            let (next, overflow) = total.addingReportingOverflow(amount.koinu)
            guard !overflow else { return nil }
            total = next
        }
        return DogecoinAmount(koinu: total)
    }
}
