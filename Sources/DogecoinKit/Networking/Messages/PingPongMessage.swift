import Foundation

/// Ping message for keepalive
public struct PingMessage: Sendable {
    /// Random nonce
    public let nonce: UInt64

    /// Create a ping message with random nonce
    public init(nonce: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        self.nonce = nonce
    }

    /// Serialize to Data
    public func serialize() -> Data {
        var data = Data()
        var nonce = self.nonce.littleEndian
        data.append(Data(bytes: &nonce, count: 8))
        return data
    }

    /// Parse from Data
    public static func parse(from data: Data) -> PingMessage? {
        guard data.count >= 8 else { return nil }
        let nonce = data.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        return PingMessage(nonce: nonce)
    }
}

/// Pong message for keepalive response
public struct PongMessage: Sendable {
    /// Nonce from ping
    public let nonce: UInt64

    /// Create a pong message responding to a ping
    public init(nonce: UInt64) {
        self.nonce = nonce
    }

    /// Create from a ping message
    public init(ping: PingMessage) {
        self.nonce = ping.nonce
    }

    /// Serialize to Data
    public func serialize() -> Data {
        var data = Data()
        var nonce = self.nonce.littleEndian
        data.append(Data(bytes: &nonce, count: 8))
        return data
    }

    /// Parse from Data
    public static func parse(from data: Data) -> PongMessage? {
        guard data.count >= 8 else { return nil }
        let nonce = data.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        return PongMessage(nonce: nonce)
    }
}

/// Verack message (acknowledgement of version)
public struct VerackMessage: Sendable {
    public init() {}

    /// Serialize to Data (empty payload)
    public func serialize() -> Data {
        Data()
    }

    /// Parse from Data
    public static func parse(from data: Data) -> VerackMessage? {
        VerackMessage()
    }
}
