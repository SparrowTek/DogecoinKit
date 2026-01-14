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
        self.koinu = UInt64(doge * Double(Self.koinuPerDoge))
    }

    /// Create an amount from a Dogecoin string
    /// - Parameter dogeString: The amount as a string (e.g., "1.5", "100")
    /// - Throws: `DogecoinError.amountConversionFailed` if conversion fails
    public init(dogeString: String) throws {
        let normalized = dogeString.trimmingCharacters(in: .whitespaces)

        var strBuffer = Array(normalized.utf8CString)

        let result = coins_to_koinu_str(&strBuffer)

        // coins_to_koinu_str returns 0 on error, but 0 is also a valid amount
        // Check if input was "0" or similar
        if result == 0 {
            if let doubleValue = Double(normalized), doubleValue == 0 {
                self.koinu = 0
            } else if normalized.isEmpty {
                throw DogecoinError.amountConversionFailed
            } else {
                self.koinu = 0
            }
        } else {
            self.koinu = result
        }
    }

    /// The amount in Dogecoin
    public var doge: Double {
        Double(koinu) / Double(Self.koinuPerDoge)
    }

    /// The amount as a Dogecoin string with up to 8 decimal places
    public var dogeString: String {
        var buffer = [CChar](repeating: 0, count: Int(KOINU_STRINGLEN))

        let result = koinu_to_coins_str(koinu, &buffer)

        guard result == 1 else {
            // Fallback to manual conversion
            return String(format: "%.8f", doge)
        }

        return String(cString: buffer)
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
        DogecoinAmount(koinu: lhs.koinu + rhs.koinu)
    }

    public static func - (lhs: DogecoinAmount, rhs: DogecoinAmount) -> DogecoinAmount {
        DogecoinAmount(koinu: lhs.koinu - rhs.koinu)
    }

    public static func * (lhs: DogecoinAmount, rhs: UInt64) -> DogecoinAmount {
        DogecoinAmount(koinu: lhs.koinu * rhs)
    }

    public static func / (lhs: DogecoinAmount, rhs: UInt64) -> DogecoinAmount {
        DogecoinAmount(koinu: lhs.koinu / rhs)
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
        self.init(koinu: value * Self.koinuPerDoge)
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
        DogecoinAmount(koinu: amount * koinuPerDoge)
    }

    /// Create amount from koinu
    public static func koinu(_ amount: UInt64) -> DogecoinAmount {
        DogecoinAmount(koinu: amount)
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
