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
    public init(storedHeader: StoredHeader, isInBestChain: Bool = true) {
        self.hash = storedHeader.header.hash
        self.prevBlockHash = storedHeader.header.prevBlock
        self.height = storedHeader.height
        self.chainWork = storedHeader.chainWork
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
        return StoredHeader(header: header, height: height, chainWork: chainWork)
    }
}
