import Foundation

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

    /// Transaction ID in internal byte order (double SHA256, no reversal)
    public var txidInternal: Data {
        MerkleTree.doubleSHA256(rawData)
    }

    /// Transaction ID in display byte order (reversed)
    public var txid: Data {
        Data(txidInternal.reversed())
    }

    /// Transaction ID as hex string (suitable for display and APIs)
    public var txidHex: String {
        txid.hexString
    }
}
