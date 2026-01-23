import CryptoKit
import Foundation
import os.log

/// Errors that can occur during header cache management
public enum HeaderCacheError: Error, Sendable {
    case metadataNotFound(URL)
    case headersFileNotFound(URL)
    case invalidMetadata
    case checksumMismatch(expected: String, actual: String)
    case networkMismatch(expected: String, actual: String)
    case headerCountMismatch(expected: Int, actual: Int)
    case invalidHeaderData(height: Int)
    case chainValidationFailed(height: Int, reason: String)
    case installationFailed(String)
    case databaseError(Error)
}

/// Manages bundled header cache installation and validation
public actor HeaderCacheManager {
    /// Standard file names for the cache bundle
    public static let headersFileName = "headers.sqlite"
    public static let legacyHeadersFileName = "headers.bin.lzfse"
    public static let metadataFileName = "metadata.json"

    private let logger = Logger(subsystem: "DogecoinKit", category: "HeaderCacheManager")

    public init() {}

    // MARK: - Public API

    /// Check if a bundled cache should be used over local cache
    /// - Parameters:
    ///   - localMetadata: Existing local cache metadata, if any
    ///   - bundledMetadata: Bundled cache metadata
    /// - Returns: true if bundled cache is newer and should be installed
    public func shouldUseBundledCache(
        localMetadata: HeaderCacheMetadata?,
        bundledMetadata: HeaderCacheMetadata
    ) -> Bool {
        guard let localMetadata else {
            // No local cache exists, use bundled
            return true
        }

        // Use bundled if it has more headers
        return bundledMetadata.headerCount > localMetadata.headerCount
    }

    /// Load metadata from a cache directory
    /// - Parameter directoryURL: Directory containing metadata.json
    /// - Returns: The parsed metadata, or nil if not found
    public func loadMetadata(from directoryURL: URL) -> HeaderCacheMetadata? {
        let metadataURL = directoryURL.appendingPathComponent(Self.metadataFileName)

        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(HeaderCacheMetadata.self, from: data)
        } catch {
            logger.error("Failed to load metadata from \(directoryURL.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Install a bundled header cache to the local storage directory
    /// This method handles both SQLite and legacy LZFSE formats
    /// - Parameters:
    ///   - bundleDirectory: Directory containing the bundled headers.sqlite (or headers.bin.lzfse) and metadata.json
    ///   - localDirectory: Target directory for the installed cache
    ///   - network: Expected network (mainnet/testnet) for validation
    ///   - progressHandler: Optional closure called with progress (0.0 to 1.0)
    /// - Returns: The installed metadata
    @discardableResult
    public func installBundledCache(
        from bundleDirectory: URL,
        to localDirectory: URL,
        network: DogecoinNetwork,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> HeaderCacheMetadata {
        let sqliteURL = bundleDirectory.appendingPathComponent(Self.headersFileName)
        let lzfseURL = bundleDirectory.appendingPathComponent(Self.legacyHeadersFileName)
        let metadataURL = bundleDirectory.appendingPathComponent(Self.metadataFileName)

        // Load and validate metadata
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw HeaderCacheError.metadataNotFound(metadataURL)
        }

        let metadata = try loadMetadataOrThrow(from: metadataURL)
        let expectedNetwork = network == .mainnet ? "mainnet" : "testnet"

        guard metadata.network == expectedNetwork else {
            throw HeaderCacheError.networkMismatch(expected: expectedNetwork, actual: metadata.network)
        }

        progressHandler?(0.0)

        // Create local directory if needed
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)

        // Check for SQLite format first (preferred)
        if FileManager.default.fileExists(atPath: sqliteURL.path) {
            try installSQLiteCache(from: sqliteURL, to: localDirectory, metadata: metadata, progressHandler: progressHandler)
        } else if FileManager.default.fileExists(atPath: lzfseURL.path) {
            // Fall back to LZFSE format (legacy)
            try await installLZFSECache(from: lzfseURL, to: localDirectory, metadata: metadata, progressHandler: progressHandler)
        } else {
            throw HeaderCacheError.headersFileNotFound(sqliteURL)
        }

        // Copy metadata for reference
        let localMetadataURL = localDirectory.appendingPathComponent(Self.metadataFileName)
        try? FileManager.default.removeItem(at: localMetadataURL)
        try FileManager.default.copyItem(at: metadataURL, to: localMetadataURL)

        progressHandler?(1.0)
        logger.info("Installed header cache: \(metadata.headerCount) headers at height \(metadata.tipHeight)")

        return metadata
    }

    /// Verify the integrity of an installed header cache
    /// - Parameters:
    ///   - directoryURL: Directory containing the cache files
    ///   - metadata: Expected metadata to verify against
    /// - Returns: true if the cache is valid
    public func verifyInstalledCache(at directoryURL: URL, metadata: HeaderCacheMetadata) -> Bool {
        let sqliteURL = directoryURL.appendingPathComponent(Self.headersFileName)

        guard FileManager.default.fileExists(atPath: sqliteURL.path) else {
            return false
        }

        do {
            let db = try HeaderDatabase(path: sqliteURL.path)
            let count = try db.getHeaderCount()
            return count == metadata.headerCount
        } catch {
            logger.error("Failed to verify cache: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private Installation Methods

    private func installSQLiteCache(
        from sourceURL: URL,
        to localDirectory: URL,
        metadata: HeaderCacheMetadata,
        progressHandler: (@Sendable (Double) -> Void)?
    ) throws {
        progressHandler?(0.1)

        let localSQLiteURL = localDirectory.appendingPathComponent(Self.headersFileName)

        // Simply copy the SQLite file
        try? FileManager.default.removeItem(at: localSQLiteURL)
        try FileManager.default.copyItem(at: sourceURL, to: localSQLiteURL)

        progressHandler?(0.9)

        // Verify the copied database
        let db = try HeaderDatabase(path: localSQLiteURL.path)
        let count = try db.getHeaderCount()

        guard count == metadata.headerCount else {
            throw HeaderCacheError.headerCountMismatch(expected: metadata.headerCount, actual: count)
        }

        logger.info("Installed SQLite cache with \(count) headers")
    }

    private func installLZFSECache(
        from compressedURL: URL,
        to localDirectory: URL,
        metadata: HeaderCacheMetadata,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        // Verify checksum first
        let actualChecksum = try await computeChecksum(of: compressedURL)

        guard normalizedHex(actualChecksum) == normalizedHex(metadata.checksumSHA256) else {
            throw HeaderCacheError.checksumMismatch(expected: metadata.checksumSHA256, actual: actualChecksum)
        }

        progressHandler?(0.1)

        let localSQLiteURL = localDirectory.appendingPathComponent(Self.headersFileName)

        // Remove existing database
        try? FileManager.default.removeItem(at: localSQLiteURL)

        // Create new database
        let db = try HeaderDatabase(path: localSQLiteURL.path)

        // Stream from LZFSE directly to SQLite
        try await decompressToSQLite(
            from: compressedURL,
            database: db,
            metadata: metadata,
            progressHandler: progressHandler
        )
    }

    private func decompressToSQLite(
        from compressedURL: URL,
        database: HeaderDatabase,
        metadata: HeaderCacheMetadata,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        // Use a class to hold mutable state for safe capture in closure
        final class DecompressState: @unchecked Sendable {
            var leftover = Data()
            var headerCount = 0
            var previousHash: Data?
            var cumulativeChainWork = Data(repeating: 0, count: 32)
            var batch: [HeaderRecord] = []
        }
        let state = DecompressState()
        let batchSize = 10000

        let expectedTotal = metadata.headerCount
        let progressBase = 0.1
        let progressRange = 0.85

        try LZFSEDecompressor.decompress(from: compressedURL) { [self] chunk in
            let combined: Data
            if state.leftover.isEmpty {
                combined = chunk
            } else {
                var merged = Data()
                merged.reserveCapacity(state.leftover.count + chunk.count)
                merged.append(state.leftover)
                merged.append(chunk)
                combined = merged
            }

            var offset = 0
            while combined.count - offset >= BlockHeader.size {
                let range = offset..<(offset + BlockHeader.size)
                let headerData = combined.subdata(in: range)

                guard let header = BlockHeader.parse(from: headerData) else {
                    throw HeaderCacheError.invalidHeaderData(height: state.headerCount)
                }

                // Validate chain linkage
                if state.headerCount == 0 {
                    if header.prevBlock != Data(count: 32) {
                        throw HeaderCacheError.chainValidationFailed(height: 0, reason: "Invalid genesis block")
                    }
                } else if let previous = state.previousHash, header.prevBlock != previous {
                    throw HeaderCacheError.chainValidationFailed(height: state.headerCount, reason: "Chain linkage broken")
                }

                // Calculate chain work
                let blockWork = calculateBlockWork(bits: header.bits)
                state.cumulativeChainWork = addWork(state.cumulativeChainWork, blockWork)

                // Create record
                let record = HeaderRecord(
                    hash: header.hash,
                    prevBlockHash: header.prevBlock,
                    height: Int32(state.headerCount),
                    chainWork: state.cumulativeChainWork,
                    version: header.version,
                    merkleRoot: header.merkleRoot,
                    timestamp: header.timestamp,
                    bits: header.bits,
                    nonce: header.nonce,
                    isInBestChain: true
                )
                state.batch.append(record)

                state.previousHash = header.hash
                state.headerCount += 1
                offset += BlockHeader.size

                // Flush batch to database
                if state.batch.count >= batchSize {
                    try database.insertHeaders(state.batch)
                    state.batch.removeAll(keepingCapacity: true)

                    let progress = progressBase + progressRange * (Double(state.headerCount) / Double(expectedTotal))
                    progressHandler?(min(progress, 0.95))
                }
            }

            if offset < combined.count {
                state.leftover = combined.subdata(in: offset..<combined.count)
            } else {
                state.leftover.removeAll(keepingCapacity: true)
            }
        }

        // Flush remaining batch
        if !state.batch.isEmpty {
            try database.insertHeaders(state.batch)
        }

        guard state.leftover.isEmpty else {
            throw HeaderCacheError.installationFailed("Trailing bytes after decompression")
        }

        guard state.headerCount == metadata.headerCount else {
            throw HeaderCacheError.headerCountMismatch(expected: metadata.headerCount, actual: state.headerCount)
        }

        logger.info("Decompressed \(state.headerCount) headers to SQLite")
    }

    // MARK: - Private Helpers

    private func loadMetadataOrThrow(from url: URL) throws -> HeaderCacheMetadata {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HeaderCacheMetadata.self, from: data)
    }

    private func computeChecksum(of url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                continuation.resume(throwing: HeaderCacheError.headersFileNotFound(url))
                return
            }
            defer { try? handle.close() }

            var hasher = SHA256()
            while true {
                let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }

            let digest = hasher.finalize()
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            continuation.resume(returning: hex)
        }
    }

    private func calculateBlockWork(bits: UInt32) -> Data {
        // Simplified work calculation
        var work = Data(repeating: 0, count: 32)
        work[0] = 1
        return work
    }

    private func addWork(_ a: Data, _ b: Data) -> Data {
        var result = Data(repeating: 0, count: 32)
        var carry: UInt16 = 0

        for i in 0..<32 {
            let sum = UInt16(a[i]) + UInt16(b[i]) + carry
            result[i] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }

        return result
    }

    private func normalizedHex(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
