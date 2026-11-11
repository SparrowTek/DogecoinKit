import Foundation
import GRDB

/// Database record for a stored block header
public struct HeaderRecord: Codable, Sendable {
    /// Block hash (primary key) - 32 bytes stored as BLOB
    public var hash: Data

    /// Previous block hash - 32 bytes stored as BLOB
    public var prevBlockHash: Data

    /// Block height
    public var height: Int32

    /// Cumulative chain work - 32 bytes stored as BLOB
    public var chainWork: Data

    /// Header version
    public var version: Int32

    /// Merkle root - 32 bytes stored as BLOB
    public var merkleRoot: Data

    /// Block timestamp
    public var timestamp: UInt32

    /// Difficulty bits
    public var bits: UInt32

    /// Nonce
    public var nonce: UInt32

    /// Whether this header is part of the best chain
    public var isInBestChain: Bool

    public init(
        hash: Data,
        prevBlockHash: Data,
        height: Int32,
        chainWork: Data,
        version: Int32,
        merkleRoot: Data,
        timestamp: UInt32,
        bits: UInt32,
        nonce: UInt32,
        isInBestChain: Bool
    ) {
        self.hash = hash
        self.prevBlockHash = prevBlockHash
        self.height = height
        self.chainWork = chainWork
        self.version = version
        self.merkleRoot = merkleRoot
        self.timestamp = timestamp
        self.bits = bits
        self.nonce = nonce
        self.isInBestChain = isInBestChain
    }
}

// MARK: - GRDB Conformance

extension HeaderRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "headers"

    public enum Columns {
        public static let hash = Column(CodingKeys.hash)
        public static let prevBlockHash = Column(CodingKeys.prevBlockHash)
        public static let height = Column(CodingKeys.height)
        public static let chainWork = Column(CodingKeys.chainWork)
        public static let version = Column(CodingKeys.version)
        public static let merkleRoot = Column(CodingKeys.merkleRoot)
        public static let timestamp = Column(CodingKeys.timestamp)
        public static let bits = Column(CodingKeys.bits)
        public static let nonce = Column(CodingKeys.nonce)
        public static let isInBestChain = Column(CodingKeys.isInBestChain)
    }
}

// MARK: - Conversion

extension HeaderRecord {
    /// Create from StoredHeader
    ///
    /// The chain work is stored without the zero bytes that pad it to 32:
    /// a mainnet total fits in ten or so, and the padding was a tenth of
    /// the whole database.
    public init(storedHeader: StoredHeader, isInBestChain: Bool = true) {
        self.hash = storedHeader.header.hash
        self.prevBlockHash = storedHeader.header.prevBlock
        self.height = storedHeader.height
        self.chainWork = Self.trimmed(storedHeader.chainWork)
        self.version = storedHeader.header.version
        self.merkleRoot = storedHeader.header.merkleRoot
        self.timestamp = storedHeader.header.timestamp
        self.bits = storedHeader.header.bits
        self.nonce = storedHeader.header.nonce
        self.isInBestChain = isInBestChain
    }

    /// Convert to StoredHeader
    public func toStoredHeader() -> StoredHeader {
        let header = BlockHeader(
            version: version,
            prevBlock: prevBlockHash,
            merkleRoot: merkleRoot,
            timestamp: timestamp,
            bits: bits,
            nonce: nonce
        )
        return StoredHeader(header: header, height: height, chainWork: Self.padded(chainWork))
    }

    /// A little-endian number without its high-order zero bytes.
    static func trimmed(_ littleEndian: Data) -> Data {
        guard let lastNonZero = littleEndian.lastIndex(where: { $0 != 0 }) else { return Data() }
        return Data(littleEndian[littleEndian.startIndex...lastNonZero])
    }

    /// A little-endian number at its full 32 bytes.
    static func padded(_ littleEndian: Data) -> Data {
        littleEndian.count >= 32 ? Data(littleEndian.prefix(32)) : littleEndian + Data(count: 32 - littleEndian.count)
    }
}
