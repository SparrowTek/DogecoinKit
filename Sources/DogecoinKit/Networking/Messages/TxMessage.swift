import Foundation
import CryptoKit

/// Transaction message for broadcasting and receiving transactions
public struct TxMessage: Sendable {
    /// Raw transaction data (serialized)
    public let rawData: Data

    /// Create a TxMessage from raw transaction hex string
    /// - Parameter rawHex: Hex-encoded raw transaction
    public init?(rawHex: String) {
        guard let data = Data(hexString: rawHex) else { return nil }
        self.rawData = data
    }

    /// Create a TxMessage from raw transaction data
    /// - Parameter rawData: Raw transaction bytes
    public init(rawData: Data) {
        self.rawData = rawData
    }

    /// Serialize to Data for transmission
    public func serialize() -> Data {
        rawData
    }

    /// Parse from Data
    public static func parse(from data: Data) -> TxMessage? {
        guard !data.isEmpty else { return nil }
        return TxMessage(rawData: data)
    }

    /// Calculate the transaction ID (txid)
    /// The txid is the double SHA256 of the raw transaction, byte-reversed
    public var txid: Data {
        let hash1 = SHA256.hash(data: rawData)
        let hash2 = SHA256.hash(data: Data(hash1))
        // Reverse for display (little-endian to big-endian)
        return Data(hash2.reversed())
    }

    /// Transaction ID as hex string (suitable for display and APIs)
    public var txidHex: String {
        txid.hexString
    }
}

