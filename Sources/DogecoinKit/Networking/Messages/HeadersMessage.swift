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

        guard let versionRaw: Int32 = data.readInteger(at: 0) else { return nil }
        let version = Int32(littleEndian: versionRaw)
        let prevBlock = Data(data[4..<36])
        let merkleRoot = Data(data[36..<68])
        guard let timestampRaw: UInt32 = data.readInteger(at: 68) else { return nil }
        guard let bitsRaw: UInt32 = data.readInteger(at: 72) else { return nil }
        guard let nonceRaw: UInt32 = data.readInteger(at: 76) else { return nil }
        let timestamp = UInt32(littleEndian: timestampRaw)
        let bits = UInt32(littleEndian: bitsRaw)
        let nonce = UInt32(littleEndian: nonceRaw)

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

    /// Check if a block version indicates AuxPoW (merged mining)
    private static func isAuxPow(version: Int32) -> Bool {
        (version & 0x100) == 0x100
    }

    /// Skip AuxPoW data in the buffer, returning the new offset
    private static func skipAuxPow(in data: Data, from offset: Int) -> Int? {
        var pos = offset

        // AuxPoW structure:
        // - coinbase tx (variable)
        // - block hash (32 bytes)
        // - coinbase branch (merkle branch)
        // - blockchain branch (merkle branch)
        // - parent block header (80 bytes)

        // Skip coinbase transaction
        guard let txEnd = skipTransaction(in: data, from: pos) else { return nil }
        pos = txEnd

        // Skip block hash (32 bytes)
        guard data.count >= pos + 32 else { return nil }
        pos += 32

        // Skip coinbase merkle branch
        guard let branchEnd1 = skipMerkleBranch(in: data, from: pos) else { return nil }
        pos = branchEnd1

        // Skip blockchain merkle branch
        guard let branchEnd2 = skipMerkleBranch(in: data, from: pos) else { return nil }
        pos = branchEnd2

        // Skip parent block header (80 bytes)
        guard data.count >= pos + 80 else { return nil }
        pos += 80

        return pos
    }

    /// Skip a transaction in the buffer
    private static func skipTransaction(in data: Data, from offset: Int) -> Int? {
        var pos = offset

        // Version (4 bytes)
        guard data.count >= pos + 4 else { return nil }
        pos += 4

        // Input count
        guard let (inputCount, inputCountSize) = VarInt.parse(from: Data(data[pos...])) else { return nil }
        pos += inputCountSize

        // Skip inputs
        for _ in 0..<inputCount {
            // Previous output (36 bytes: 32 hash + 4 index)
            guard data.count >= pos + 36 else { return nil }
            pos += 36

            // Script length and script
            guard let (scriptLen, scriptLenSize) = VarInt.parse(from: Data(data[pos...])) else { return nil }
            pos += scriptLenSize
            guard data.count >= pos + Int(scriptLen) else { return nil }
            pos += Int(scriptLen)

            // Sequence (4 bytes)
            guard data.count >= pos + 4 else { return nil }
            pos += 4
        }

        // Output count
        guard let (outputCount, outputCountSize) = VarInt.parse(from: Data(data[pos...])) else { return nil }
        pos += outputCountSize

        // Skip outputs
        for _ in 0..<outputCount {
            // Value (8 bytes)
            guard data.count >= pos + 8 else { return nil }
            pos += 8

            // Script length and script
            guard let (scriptLen, scriptLenSize) = VarInt.parse(from: Data(data[pos...])) else { return nil }
            pos += scriptLenSize
            guard data.count >= pos + Int(scriptLen) else { return nil }
            pos += Int(scriptLen)
        }

        // Lock time (4 bytes)
        guard data.count >= pos + 4 else { return nil }
        pos += 4

        return pos
    }

    /// Skip a merkle branch in the buffer
    private static func skipMerkleBranch(in data: Data, from offset: Int) -> Int? {
        var pos = offset

        // Branch length
        guard let (branchLen, branchLenSize) = VarInt.parse(from: Data(data[pos...])) else { return nil }
        pos += branchLenSize

        // Skip hashes (32 bytes each)
        let hashesSize = Int(branchLen) * 32
        guard data.count >= pos + hashesSize else { return nil }
        pos += hashesSize

        // Branch side mask (4 bytes)
        guard data.count >= pos + 4 else { return nil }
        pos += 4

        return pos
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

            // If this is an AuxPoW block, skip the auxpow data
            if isAuxPow(version: header.version) {
                guard let newOffset = skipAuxPow(in: data, from: offset) else { return nil }
                offset = newOffset
            }

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
