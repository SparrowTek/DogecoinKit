import Foundation
import CryptoKit

/// Block header structure
public struct BlockHeader: Sendable, Equatable {
    /// Block version
    public let version: Int32

    /// Hash of the previous block header (32 bytes)
    public let prevBlock: Data

    /// Merkle root hash (32 bytes)
    public let merkleRoot: Data

    /// Block timestamp
    public let timestamp: UInt32

    /// Difficulty target (nBits)
    public let bits: UInt32

    /// Nonce used for mining
    public let nonce: UInt32

    /// Size of header in bytes (without auxpow)
    public static let size = 80

    /// Create a block header
    public init(
        version: Int32,
        prevBlock: Data,
        merkleRoot: Data,
        timestamp: UInt32,
        bits: UInt32,
        nonce: UInt32
    ) {
        self.version = version
        self.prevBlock = prevBlock
        self.merkleRoot = merkleRoot
        self.timestamp = timestamp
        self.bits = bits
        self.nonce = nonce
    }

    /// Compute the block hash (double SHA256)
    public var hash: Data {
        let headerData = serializeCore()
        let hash1 = SHA256.hash(data: headerData)
        let hash2 = SHA256.hash(data: Data(hash1))
        return Data(hash2)
    }

    /// Get the block hash as hex string (reversed, as displayed)
    public var hashHex: String {
        Data(hash.reversed()).map { String(format: "%02x", $0) }.joined()
    }

    /// Serialize core header (80 bytes, without auxpow)
    public func serializeCore() -> Data {
        var data = Data()

        var version = self.version.littleEndian
        data.append(Data(bytes: &version, count: 4))

        data.append(prevBlock)
        data.append(merkleRoot)

        var timestamp = self.timestamp.littleEndian
        data.append(Data(bytes: &timestamp, count: 4))

        var bits = self.bits.littleEndian
        data.append(Data(bytes: &bits, count: 4))

        var nonce = self.nonce.littleEndian
        data.append(Data(bytes: &nonce, count: 4))

        return data
    }

    /// Serialize for headers message (with transaction count = 0)
    public func serialize() -> Data {
        var data = serializeCore()
        data.append(0) // Transaction count is always 0 in headers message
        return data
    }

    /// Parse from Data
    public static func parse(from data: Data) -> BlockHeader? {
        guard data.count >= Self.size else { return nil }

        let version = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int32.self).littleEndian }
        let prevBlock = Data(data[4..<36])
        let merkleRoot = Data(data[36..<68])
        let timestamp = data.withUnsafeBytes { $0.load(fromByteOffset: 68, as: UInt32.self).littleEndian }
        let bits = data.withUnsafeBytes { $0.load(fromByteOffset: 72, as: UInt32.self).littleEndian }
        let nonce = data.withUnsafeBytes { $0.load(fromByteOffset: 76, as: UInt32.self).littleEndian }

        return BlockHeader(
            version: version,
            prevBlock: prevBlock,
            merkleRoot: merkleRoot,
            timestamp: timestamp,
            bits: bits,
            nonce: nonce
        )
    }
}

/// Get headers message
public struct GetHeadersMessage: Sendable {
    /// Protocol version
    public let version: UInt32

    /// Block locator hashes (newest to oldest)
    public let locatorHashes: [Data]

    /// Hash to stop at (zeros for no limit)
    public let hashStop: Data

    /// Create a getheaders message
    public init(
        version: UInt32 = NetworkConstants.protocolVersion,
        locatorHashes: [Data],
        hashStop: Data = Data(count: 32)
    ) {
        self.version = version
        self.locatorHashes = locatorHashes
        self.hashStop = hashStop
    }

    /// Serialize to Data
    public func serialize() -> Data {
        var data = Data()

        var version = self.version.littleEndian
        data.append(Data(bytes: &version, count: 4))

        data.append(VarInt(UInt64(locatorHashes.count)).serialize())
        for hash in locatorHashes {
            data.append(hash)
        }

        data.append(hashStop)

        return data
    }
}

/// Headers message response
public struct HeadersMessage: Sendable {
    /// List of block headers
    public let headers: [BlockHeader]

    /// Create a headers message
    public init(headers: [BlockHeader]) {
        self.headers = headers
    }

    /// Serialize to Data
    public func serialize() -> Data {
        var data = Data()

        data.append(VarInt(UInt64(headers.count)).serialize())
        for header in headers {
            data.append(header.serialize())
        }

        return data
    }

    /// Parse from Data
    public static func parse(from data: Data) -> HeadersMessage? {
        guard let (count, varIntSize) = VarInt.parse(from: data) else { return nil }

        var offset = varIntSize
        var headers: [BlockHeader] = []

        for _ in 0..<count {
            guard data.count >= offset + BlockHeader.size else { return nil }
            guard let header = BlockHeader.parse(from: Data(data[offset..<offset+BlockHeader.size])) else { return nil }
            headers.append(header)
            offset += BlockHeader.size

            // Skip transaction count (varint, should be 0)
            if data.count > offset {
                guard let (_, txCountSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
                offset += txCountSize
            }
        }

        return HeadersMessage(headers: headers)
    }
}

/// Get blocks message
public struct GetBlocksMessage: Sendable {
    /// Protocol version
    public let version: UInt32

    /// Block locator hashes (newest to oldest)
    public let locatorHashes: [Data]

    /// Hash to stop at (zeros for no limit)
    public let hashStop: Data

    /// Create a getblocks message
    public init(
        version: UInt32 = NetworkConstants.protocolVersion,
        locatorHashes: [Data],
        hashStop: Data = Data(count: 32)
    ) {
        self.version = version
        self.locatorHashes = locatorHashes
        self.hashStop = hashStop
    }

    /// Serialize to Data
    public func serialize() -> Data {
        var data = Data()

        var version = self.version.littleEndian
        data.append(Data(bytes: &version, count: 4))

        data.append(VarInt(UInt64(locatorHashes.count)).serialize())
        for hash in locatorHashes {
            data.append(hash)
        }

        data.append(hashStop)

        return data
    }
}
