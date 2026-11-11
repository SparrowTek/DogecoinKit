import Foundation

/// Represents an amount of Dogecoin
/// Internally stored as koinu (1 DOGE = 100,000,000 koinu)
public struct DogecoinAmount: Sendable, Equatable, Hashable, Comparable {

    /// The amount in koinu (satoshis)
    /// 1 DOGE = 100,000,000 koinu
    public let koinu: UInt64

    /// Number of koinu per Dogecoin
    public static let koinuPerDoge: UInt64 = 100_000_000

    /// Zero amount
    public static let zero = DogecoinAmount(koinu: 0)

    /// The largest value a single transaction output may carry — Dogecoin
    /// Core's `MAX_MONEY` of 10 billion DOGE. Nodes reject anything above it.
    public static let maxMoney = DogecoinAmount(koinu: 10_000_000_000 * koinuPerDoge)

    /// Create an amount from koinu
    /// - Parameter koinu: The amount in koinu
    public init(koinu: UInt64) {
        self.koinu = koinu
    }

    /// Create an amount from Dogecoin
    /// - Parameter doge: The amount in Dogecoin
    ///
    /// Rounds to the nearest koinu. Negative and non-finite amounts become
    /// zero; amounts too large to represent saturate at `UInt64.max`. A
    /// `Double` holds an amount exactly to the koinu only up to about
    /// 90 million DOGE — use ``init(dogeString:)`` or ``init(koinu:)`` where
    /// every koinu matters.
    public init(doge: Double) {
        guard doge.isFinite, doge > 0 else {
            self.koinu = 0
            return
        }

        // Scaling in binary and rounding once is as exact as a Double
        // allows. (Converting through `Decimal(Double)` was already off by a
        // few koinu from about a million DOGE up.)
        let scaled = (doge * Double(Self.koinuPerDoge)).rounded()
        self.koinu = scaled < 0x1p64 ? UInt64(scaled) : .max
    }

    /// Create an amount from a Dogecoin string
    /// - Parameter dogeString: The amount as a string (e.g., "1.5", "100")
    /// - Throws: `DogecoinError.amountConversionFailed` if conversion fails
    public init(dogeString: String) throws {
        let normalized = dogeString.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let pattern = Self.validAmountPattern,
              pattern.firstMatch(in: normalized, options: [], range: fullRange) != nil else {
            throw DogecoinError.amountConversionFailed
        }

        guard let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              let koinu = Self.koinuFromDecimal(decimal) else {
            throw DogecoinError.amountConversionFailed
        }

        self.koinu = koinu
    }

    /// The amount in Dogecoin
    public var doge: Double {
        Double(koinu) / Double(Self.koinuPerDoge)
    }

    /// The amount as a Dogecoin string with exactly 8 decimal places
    /// (e.g. "1.50000000"), computed with integer arithmetic so every koinu
    /// value converts exactly — the same format libdogecoin parses.
    public var dogeString: String {
        let whole = koinu / Self.koinuPerDoge
        let fraction = String(koinu % Self.koinuPerDoge)
        return "\(whole)." + String(repeating: "0", count: 8 - fraction.count) + fraction
    }

    // MARK: - Comparable

    public static func < (lhs: DogecoinAmount, rhs: DogecoinAmount) -> Bool {
        lhs.koinu < rhs.koinu
    }

    // MARK: - Arithmetic

    public static func + (lhs: DogecoinAmount, rhs: DogecoinAmount) -> DogecoinAmount {
        let (sum, overflow) = lhs.koinu.addingReportingOverflow(rhs.koinu)
        return DogecoinAmount(koinu: overflow ? UInt64.max : sum)
    }

    public static func - (lhs: DogecoinAmount, rhs: DogecoinAmount) -> DogecoinAmount {
        let (difference, overflow) = lhs.koinu.subtractingReportingOverflow(rhs.koinu)
        return DogecoinAmount(koinu: overflow ? 0 : difference)
    }

    public static func * (lhs: DogecoinAmount, rhs: UInt64) -> DogecoinAmount {
        let (product, overflow) = lhs.koinu.multipliedReportingOverflow(by: rhs)
        return DogecoinAmount(koinu: overflow ? UInt64.max : product)
    }

    public static func / (lhs: DogecoinAmount, rhs: UInt64) -> DogecoinAmount {
        guard rhs > 0 else { return .zero }
        return DogecoinAmount(koinu: lhs.koinu / rhs)
    }

    public static func += (lhs: inout DogecoinAmount, rhs: DogecoinAmount) {
        lhs = lhs + rhs
    }

    public static func -= (lhs: inout DogecoinAmount, rhs: DogecoinAmount) {
        lhs = lhs - rhs
    }
}

// MARK: - CustomStringConvertible

extension DogecoinAmount: CustomStringConvertible {
    public var description: String {
        "\(dogeString) DOGE"
    }
}

// MARK: - Codable

extension DogecoinAmount: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.koinu = try container.decode(UInt64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(koinu)
    }
}

private extension DogecoinAmount {
    static let maxKoinuDecimal = Decimal(UInt64.max)
    /// ASCII digits only: `\d` also matches other scripts' digits, which
    /// `Decimal(string:)` then stops at, silently truncating the amount.
    static let validAmountPattern = try? NSRegularExpression(
        pattern: #"^(?:[0-9]+)(?:\.[0-9]{1,8})?$"#,
        options: []
    )

    static func koinuFromDecimal(_ value: Decimal) -> UInt64? {
        guard value >= 0 else { return nil }

        var scaled = value * Decimal(koinuPerDoge)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)

        guard rounded <= maxKoinuDecimal else { return nil }

        let number = NSDecimalNumber(decimal: rounded)
        guard number != NSDecimalNumber.notANumber else { return nil }
        return number.uint64Value
    }
}
