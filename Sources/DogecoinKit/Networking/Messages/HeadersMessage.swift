import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

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
        guard let versionRaw: Int32 = data.readInteger(at: 0),
              let prevBlock = data.bytes(at: 4, count: 32),
              let merkleRoot = data.bytes(at: 36, count: 32),
              let timestampRaw: UInt32 = data.readInteger(at: 68),
              let bitsRaw: UInt32 = data.readInteger(at: 72),
              let nonceRaw: UInt32 = data.readInteger(at: 76) else { return nil }
        let version = Int32(littleEndian: versionRaw)
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
///
/// After merged mining began, every Dogecoin header on the wire carries an
/// AuxPoW proof. The parser keeps it: without it a merge-mined header has no
/// verifiable proof of work at all.
public struct HeadersMessage: Sendable {
    /// One header and, for merge-mined blocks, its AuxPoW proof
    public struct Entry: Sendable, Equatable {
        public let header: BlockHeader
        public let auxpow: AuxPoW?

        public init(header: BlockHeader, auxpow: AuxPoW? = nil) {
            self.header = header
            self.auxpow = auxpow
        }
    }

    /// The headers in the order received, with their proofs
    public let entries: [Entry]

    /// The headers in the order received
    public var headers: [BlockHeader] {
        entries.map(\.header)
    }

    /// Create a headers message
    public init(headers: [BlockHeader]) {
        self.entries = headers.map { Entry(header: $0) }
    }

    /// Create a headers message with AuxPoW proofs
    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// Serialize to Data
    public func serialize() -> Data {
        var data = Data()

        data.append(VarInt(UInt64(entries.count)).serialize())
        for entry in entries {
            data.append(entry.header.serializeCore())
            if let auxpow = entry.auxpow {
                data.append(auxpow.serialize())
            }
            data.append(0) // Transaction count is always 0 in headers message
        }

        return data
    }

    /// Parse from Data
    public static func parse(from data: Data) -> HeadersMessage? {
        // Bound the peer-supplied header count by the remaining bytes
        // (each entry is at least an 80-byte header).
        guard let (count, varIntSize) = data.readBoundedCount(at: 0, minItemSize: BlockHeader.size) else { return nil }

        var offset = varIntSize
        var entries: [Entry] = []
        entries.reserveCapacity(count)

        for _ in 0..<count {
            guard let headerBytes = data.bytes(at: offset, count: BlockHeader.size),
                  let header = BlockHeader.parse(from: headerBytes) else { return nil }
            offset += BlockHeader.size

            var auxpow: AuxPoW?
            if header.isAuxPoW {
                guard let (parsed, newOffset) = AuxPoW.parse(from: data, at: offset) else { return nil }
                auxpow = parsed
                offset = newOffset
            }

            // Transaction count (varint, always 0 in a headers message)
            if data.count > offset {
                guard let (_, txCountSize) = data.readVarInt(at: offset) else { return nil }
                offset += txCountSize
            }

            entries.append(Entry(header: header, auxpow: auxpow))
        }

        return HeadersMessage(entries: entries)
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
