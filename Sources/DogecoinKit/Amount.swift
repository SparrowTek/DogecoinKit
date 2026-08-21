import Foundation
import clibdogecoin

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

    /// Create an amount from koinu
    /// - Parameter koinu: The amount in koinu
    public init(koinu: UInt64) {
        self.koinu = koinu
    }

    /// Create an amount from Dogecoin
    /// - Parameter doge: The amount in Dogecoin
    public init(doge: Double) {
        guard doge.isFinite else {
            self.koinu = 0
            return
        }

        let decimal = Decimal(doge)
        self.koinu = Self.koinuFromDecimal(decimal) ?? (doge < 0 ? 0 : UInt64.max)
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

    /// The amount as a Dogecoin string with up to 8 decimal places
    public var dogeString: String {
        var buffer = [CChar](repeating: 0, count: Int(KOINU_STRINGLEN))

        let result = koinu_to_coins_str(koinu, &buffer, buffer.count)

        guard result == 1 else {
            // Fallback to manual conversion
            return String(format: "%.8f", doge)
        }

        let bytes = Data(buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Format the amount with a specific number of decimal places
    /// - Parameter decimals: Number of decimal places (0-8)
    /// - Returns: Formatted string
    public func formatted(decimals: Int = 8) -> String {
        let clampedDecimals = max(0, min(8, decimals))
        return String(format: "%.\(clampedDecimals)f", doge)
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

// MARK: - ExpressibleByIntegerLiteral

extension DogecoinAmount: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        let (scaled, overflow) = value.multipliedReportingOverflow(by: Self.koinuPerDoge)
        self.init(koinu: overflow ? UInt64.max : scaled)
    }
}

// MARK: - ExpressibleByFloatLiteral

extension DogecoinAmount: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self.init(doge: value)
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

// MARK: - Convenience Extensions

extension DogecoinAmount {
    /// Create amount from a number of whole Dogecoins
    public static func doge(_ amount: UInt64) -> DogecoinAmount {
        let (scaled, overflow) = amount.multipliedReportingOverflow(by: koinuPerDoge)
        return DogecoinAmount(koinu: overflow ? UInt64.max : scaled)
    }

    /// Create amount from koinu
    public static func koinu(_ amount: UInt64) -> DogecoinAmount {
        DogecoinAmount(koinu: amount)
    }
}

private extension DogecoinAmount {
    static let maxKoinuDecimal = Decimal(UInt64.max)
    static let validAmountPattern = try? NSRegularExpression(
        pattern: #"^(?:\d+)(?:\.\d{1,8})?$"#,
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

// MARK: - Amount Utilities

/// Convert koinu to Dogecoin string
/// - Parameter koinu: Amount in koinu
/// - Returns: String representation in Dogecoin
public func koinuToDogeString(_ koinu: UInt64) -> String {
    DogecoinAmount(koinu: koinu).dogeString
}

/// Convert Dogecoin string to koinu
/// - Parameter dogeString: Amount as string in Dogecoin
/// - Returns: Amount in koinu
/// - Throws: `DogecoinError.amountConversionFailed` if conversion fails
public func dogeStringToKoinu(_ dogeString: String) throws -> UInt64 {
    try DogecoinAmount(dogeString: dogeString).koinu
}
