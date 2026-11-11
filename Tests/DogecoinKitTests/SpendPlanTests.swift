import Testing
@testable import DogecoinKit

@Suite("Spend Planning")
struct SpendPlanTests {

    private static let doge: UInt64 = 100_000_000

    /// An output of `koinu`, told apart from the others by `number`.
    private static func coin(_ koinu: UInt64, _ number: Int, confirmations: Int = 6) -> UTXO {
        let hex = String(number, radix: 16)
        return UTXO(
            txid: String(repeating: "0", count: 64 - hex.count) + hex,
            vout: 0,
            address: "DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5",
            amount: DogecoinAmount(koinu: koinu),
            confirmations: confirmations
        )
    }

    private static func amount(_ koinu: UInt64) -> DogecoinAmount {
        DogecoinAmount(koinu: koinu)
    }

    // MARK: - Selection

    @Test("The largest output pays, and the rest comes back as change")
    func largestFirstWithChange() throws {
        let hundred = Self.coin(100 * Self.doge, 1)
        let fifty = Self.coin(50 * Self.doge, 2)

        let plan = try SpendPlan(paying: [Self.amount(30 * Self.doge)], from: [fifty, hundred])

        // One input, two outputs: 226 bytes at 0.01 DOGE per 1000.
        #expect(plan.inputs == [hundred])
        #expect(plan.fee == Self.amount(226_000))
        #expect(plan.change == Self.amount(70 * Self.doge - 226_000))
    }

    @Test("Inputs are added, largest first, until they cover the payment and its fee")
    func addsInputsUntilCovered() throws {
        let thirty = Self.coin(30 * Self.doge, 1)
        let forty = Self.coin(40 * Self.doge, 2)
        let twenty = Self.coin(20 * Self.doge, 3)

        let plan = try SpendPlan(paying: [Self.amount(60 * Self.doge)], from: [thirty, forty, twenty])

        // Two inputs, two outputs: 374 bytes.
        #expect(plan.inputs == [forty, thirty])
        #expect(plan.fee == Self.amount(374_000))
        #expect(plan.change == Self.amount(10 * Self.doge - 374_000))
    }

    @Test("Change below the soft dust limit goes to the fee instead of an output")
    func dustChangeJoinsTheFee() throws {
        let plan = try SpendPlan(paying: [Self.amount(99_500_000)], from: [Self.coin(Self.doge, 1)])

        #expect(plan.change == .zero)
        #expect(plan.fee == Self.amount(500_000))
    }

    @Test("Change of exactly the soft dust limit gets its output")
    func changeAtTheLimitIsKept() throws {
        // 226,000 fee + 1,000,000 change on top of the payment.
        let plan = try SpendPlan(paying: [Self.amount(Self.doge - 1_226_000)], from: [Self.coin(Self.doge, 1)])

        #expect(plan.fee == Self.amount(226_000))
        #expect(plan.change == FeeEstimation.softDustLimit)

        // One koinu less change and it is dust.
        let dusty = try SpendPlan(paying: [Self.amount(Self.doge - 1_225_999)], from: [Self.coin(Self.doge, 1)])
        #expect(dusty.change == .zero)
        #expect(dusty.fee == Self.amount(1_225_999))
    }

    @Test("Outputs that cost more to spend than they hold are left alone")
    func uneconomicOutputsAreSkipped() throws {
        // Spending an input costs 148,000 koinu at the standard rate.
        let whole = Self.coin(Self.doge, 1)
        let worthless = Self.coin(100_000, 2)
        let barelyWorthIt = Self.coin(148_001, 3)

        // Counting it would lower the maximum by more than it adds.
        let maximum = SpendPlan.maximumPayment(from: [whole, worthless])
        #expect(maximum == Self.amount(Self.doge - 192_000))
        #expect(try SpendPlan(paying: [maximum], from: [whole, worthless]).inputs == [whole])

        #expect(SpendPlan.maximumPayment(from: [whole, barelyWorthIt]) == Self.amount(Self.doge + 148_001 - 340_000))
        #expect(SpendPlan.maximumPayment(from: [worthless]) == .zero)
    }

    @Test("Unconfirmed outputs are spent only when asked for")
    func confirmations() throws {
        let unconfirmed = Self.coin(100 * Self.doge, 1, confirmations: 0)
        let confirmed = Self.coin(Self.doge, 2, confirmations: 3)
        let payment = [Self.amount(50_000_000)]

        #expect(try SpendPlan(paying: payment, from: [unconfirmed, confirmed]).inputs == [confirmed])
        #expect(try SpendPlan(paying: payment, from: [unconfirmed, confirmed], minimumConfirmations: 0).inputs == [unconfirmed])
        #expect(throws: SpendPlan.Failure.insufficientFunds) {
            _ = try SpendPlan(paying: payment, from: [unconfirmed, confirmed], minimumConfirmations: 4)
        }
    }

    @Test("The same wallet yields the same plan, whatever order its outputs arrive in")
    func deterministic() throws {
        let coins = (1...6).map { Self.coin(10 * Self.doge, $0) }
        let payment = [Self.amount(25 * Self.doge)]

        let plan = try SpendPlan(paying: payment, from: coins)
        #expect(plan.inputs == Array(coins.prefix(3)))
        #expect(try SpendPlan(paying: payment, from: coins.reversed()) == plan)
    }

    // MARK: - Fee rate

    @Test("Priority pays five times the standard fee")
    func priorityRate() throws {
        let plan = try SpendPlan(
            paying: [Self.amount(30 * Self.doge)],
            from: [Self.coin(100 * Self.doge, 1)],
            feePerKB: FeeEstimation.Priority.high.feePerKB
        )
        #expect(plan.fee == Self.amount(1_130_000))
    }

    @Test("A rate below what nodes relay is raised to the relay minimum")
    func rateFloor() throws {
        let plan = try SpendPlan(paying: [Self.amount(30 * Self.doge)], from: [Self.coin(100 * Self.doge, 1)], feePerKB: .zero)
        #expect(plan.fee == Self.amount(22_600))
    }

    // MARK: - Dust

    @Test("A payment below the hard dust limit is refused")
    func hardDust() {
        let coins = [Self.coin(100 * Self.doge, 1)]

        #expect(throws: SpendPlan.Failure.paymentOutOfRange) {
            _ = try SpendPlan(paying: [Self.amount(99_999)], from: coins)
        }
        #expect(throws: SpendPlan.Failure.paymentOutOfRange) {
            _ = try SpendPlan(paying: [.zero], from: coins)
        }
        #expect(throws: SpendPlan.Failure.paymentOutOfRange) {
            _ = try SpendPlan(paying: [Self.amount(Self.doge), Self.amount(99_999)], from: coins)
        }
    }

    @Test("A payment below the soft dust limit pays the limit on top of the fee")
    func softDust() throws {
        let coins = [Self.coin(Self.doge, 1)]

        let atHardLimit = try SpendPlan(paying: [FeeEstimation.hardDustLimit], from: coins)
        #expect(atHardLimit.fee == Self.amount(1_226_000))
        #expect(atHardLimit.change == Self.amount(Self.doge - 100_000 - 1_226_000))

        let atSoftLimit = try SpendPlan(paying: [FeeEstimation.softDustLimit], from: coins)
        #expect(atSoftLimit.fee == Self.amount(226_000))
    }

    @Test("No payments, or one above max money, is refused")
    func outOfRange() {
        let coins = [Self.coin(100 * Self.doge, 1)]

        #expect(throws: SpendPlan.Failure.paymentOutOfRange) {
            _ = try SpendPlan(paying: [], from: coins)
        }
        #expect(throws: SpendPlan.Failure.paymentOutOfRange) {
            _ = try SpendPlan(paying: [Self.amount(DogecoinAmount.maxMoney.koinu + 1)], from: coins)
        }
        #expect(throws: SpendPlan.Failure.paymentOutOfRange) {
            _ = try SpendPlan(paying: [Self.amount(.max), Self.amount(.max)], from: coins)
        }
    }

    // MARK: - Shortfalls

    @Test("A payment the outputs cannot cover with its fee is refused")
    func insufficientFunds() {
        let coins = [Self.coin(10 * Self.doge, 1)]

        #expect(throws: SpendPlan.Failure.insufficientFunds) {
            _ = try SpendPlan(paying: [Self.amount(100 * Self.doge)], from: coins)
        }
        // The whole balance, leaving nothing for the fee.
        #expect(throws: SpendPlan.Failure.insufficientFunds) {
            _ = try SpendPlan(paying: [Self.amount(10 * Self.doge)], from: coins)
        }
        // One koinu more than the most that can be sent.
        #expect(throws: SpendPlan.Failure.insufficientFunds) {
            _ = try SpendPlan(paying: [Self.amount(10 * Self.doge - 192_000 + 1)], from: coins)
        }
        #expect(throws: SpendPlan.Failure.insufficientFunds) {
            _ = try SpendPlan(paying: [Self.amount(Self.doge)], from: [])
        }
    }

    @Test("Funds spread over more outputs than a transaction holds are reported as such")
    func tooManyInputs() throws {
        // 675 inputs and one output are 99,946 bytes; a 676th does not fit.
        let coins = (1...700).map { Self.coin(Self.doge, $0) }

        #expect(throws: SpendPlan.Failure.tooManyInputs) {
            _ = try SpendPlan(paying: [Self.amount(690 * Self.doge)], from: coins)
        }
        #expect(throws: SpendPlan.Failure.insufficientFunds) {
            _ = try SpendPlan(paying: [Self.amount(701 * Self.doge)], from: coins)
        }

        let maximum = SpendPlan.maximumPayment(from: coins)
        #expect(maximum == Self.amount(675 * Self.doge - 99_946_000))

        let plan = try SpendPlan(paying: [maximum], from: coins)
        #expect(plan.inputs.count == 675)
        #expect(plan.change == .zero)
        #expect(plan.fee == Self.amount(99_946_000))
    }

    // MARK: - Maximum

    @Test("The maximum is everything less the fee, and planning it spends exactly that")
    func maximumAndPlanAgree() throws {
        let coins = [Self.coin(5 * Self.doge, 1)]

        let maximum = SpendPlan.maximumPayment(from: coins)
        #expect(maximum == Self.amount(5 * Self.doge - 192_000))

        let plan = try SpendPlan(paying: [maximum], from: coins)
        #expect(plan.inputs == coins)
        #expect(plan.fee == Self.amount(192_000))
        #expect(plan.change == .zero)
    }

    @Test("Other payments in the transaction come out of the maximum")
    func maximumAlongsideOtherPayments() throws {
        let five = Self.coin(5 * Self.doge, 1)
        let three = Self.coin(3 * Self.doge, 2)
        let appFee = Self.amount(Self.doge)

        // Two inputs, two outputs: 374 bytes.
        let maximum = SpendPlan.maximumPayment(from: [three, five], alongside: [appFee])
        #expect(maximum == Self.amount(7 * Self.doge - 374_000))

        let plan = try SpendPlan(paying: [maximum, appFee], from: [three, five])
        #expect(plan.inputs == [five, three])
        #expect(plan.fee == Self.amount(374_000))
        #expect(plan.change == .zero)
    }

    @Test("Nothing can be sent when what is left would be dust")
    func maximumBelowDustIsZero() {
        // 192,000 fee leaves 999,999 koinu: under the soft dust limit, so
        // sending it would cost more than it is worth.
        #expect(SpendPlan.maximumPayment(from: [Self.coin(1_191_999, 1)]) == .zero)
        #expect(SpendPlan.maximumPayment(from: [Self.coin(1_192_000, 1)]) == FeeEstimation.softDustLimit)

        #expect(SpendPlan.maximumPayment(from: []) == .zero)
        #expect(SpendPlan.maximumPayment(from: [Self.coin(Self.doge, 1)], alongside: [Self.amount(Self.doge)]) == .zero)
        #expect(SpendPlan.maximumPayment(from: [Self.coin(Self.doge, 1, confirmations: 0)]) == .zero)
    }

    @Test("For any wallet, the maximum can be planned and one koinu more cannot")
    func maximumIsExactForRandomWallets() throws {
        var generator = SplitMix64(seed: 0x00D0_6EC0_1234_5678)

        for _ in 0..<300 {
            let coins = (0..<Int.random(in: 1...40, using: &generator)).map { number in
                Self.coin(UInt64.random(in: 1...(50 * Self.doge), using: &generator), number + 1)
            }
            let others = Bool.random(using: &generator) ? [Self.amount(Self.doge)] : []
            let rate = Bool.random(using: &generator) ? FeeEstimation.standardFeePerKB : FeeEstimation.highFeePerKB

            let maximum = SpendPlan.maximumPayment(from: coins, alongside: others, feePerKB: rate)
            guard maximum > .zero else {
                // Nothing to send must mean nothing can be planned either.
                #expect(throws: SpendPlan.Failure.insufficientFunds) {
                    _ = try SpendPlan(paying: others + [FeeEstimation.softDustLimit], from: coins, feePerKB: rate)
                }
                continue
            }

            let plan = try SpendPlan(paying: others + [maximum], from: coins, feePerKB: rate)
            let spent = plan.inputs.reduce(DogecoinAmount.zero) { $0 + $1.amount }
            let paid = others.reduce(maximum) { $0 + $1 }
            #expect(plan.change == .zero)
            #expect(spent == paid + plan.fee)
            #expect(plan.fee == FeeEstimation.estimateFee(inputCount: plan.inputs.count, outputCount: others.count + 1, feePerKB: rate))

            #expect(throws: SpendPlan.Failure.insufficientFunds) {
                _ = try SpendPlan(paying: others + [maximum + DogecoinAmount(koinu: 1)], from: coins, feePerKB: rate)
            }
        }
    }

    @Test("For any payment, the inputs cover the payment, the fee, and the change exactly")
    func plansBalanceForRandomPayments() throws {
        var generator = SplitMix64(seed: 0x0BAD_C0FF_EE15_600D)

        for _ in 0..<300 {
            let coins = (0..<Int.random(in: 1...30, using: &generator)).map { number in
                Self.coin(UInt64.random(in: 1...(20 * Self.doge), using: &generator), number + 1)
            }
            let payment = Self.amount(UInt64.random(in: 100_000...(100 * Self.doge), using: &generator))

            guard let plan = try? SpendPlan(paying: [payment], from: coins) else { continue }

            let spent = plan.inputs.reduce(DogecoinAmount.zero) { $0 + $1.amount }
            #expect(spent == payment + plan.fee + plan.change)
            #expect(plan.change == .zero || plan.change >= FeeEstimation.softDustLimit)

            let outputCount = plan.change == .zero ? 1 : 2
            let size = FeeEstimation.estimateTransactionSize(inputCount: plan.inputs.count, outputCount: outputCount)
            #expect(plan.fee >= FeeEstimation.calculateFee(sizeBytes: size, feePerKB: FeeEstimation.standardFeePerKB)
                + FeeEstimation.dustSurcharge(forOutputs: [payment]))
            // Never more than the fee with a change output plus the dust
            // that was not worth one.
            #expect(plan.fee < FeeEstimation.estimateFee(inputCount: plan.inputs.count, outputCount: 2)
                + FeeEstimation.dustSurcharge(forOutputs: [payment]) + FeeEstimation.softDustLimit)
        }
    }
}

/// A seeded generator, so the randomized tests check the same cases every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
