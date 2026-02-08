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

                // Calculate chain work from compact difficulty bits
                guard let blockWork = Self.blockWork(bits: header.bits) else {
                    throw HeaderCacheError.chainValidationFailed(
                        height: state.headerCount,
                        reason: "Invalid difficulty bits: \(header.bits)"
                    )
                }
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

    nonisolated static func blockWork(bits: UInt32) -> Data? {
        guard let target = targetFromBits(bits) else { return nil }

        let targetValue = UInt256(data: target)
        let targetPlusOne = targetValue.adding(.one)
        let negTarget = targetValue.bitwiseNot()
        let hashes = negTarget.divided(by: targetPlusOne)
        let work = hashes.adding(.one)
        return work.data
    }

    nonisolated private static func targetFromBits(_ bits: UInt32) -> Data? {
        let size = Int(bits >> 24)
        var word = bits & 0x007fffff

        if word == 0 {
            return nil
        }

        let negative = (bits & 0x00800000) != 0
        let overflow = word != 0 && (size > 34 || (word > 0xff && size > 33) || (word > 0xffff && size > 32))
        if negative || overflow {
            return nil
        }

        var target = Data(repeating: 0, count: 32)
        if size <= 3 {
            let shift = 8 * (3 - size)
            word >>= UInt32(shift)
            target[0] = UInt8(word & 0xff)
            target[1] = UInt8((word >> 8) & 0xff)
            target[2] = UInt8((word >> 16) & 0xff)
        } else {
            let offset = size - 3
            guard offset + 2 < 32 else { return nil }
            target[offset] = UInt8(word & 0xff)
            target[offset + 1] = UInt8((word >> 8) & 0xff)
            target[offset + 2] = UInt8((word >> 16) & 0xff)
        }

        return target
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

private struct UInt256: Sendable, Equatable {
    static let zero = UInt256(words: Array(repeating: 0, count: 8))
    static let one = UInt256(words: [1, 0, 0, 0, 0, 0, 0, 0])

    var words: [UInt32]

    init(words: [UInt32]) {
        var padded = words
        if padded.count < 8 {
            padded.append(contentsOf: Array(repeating: 0, count: 8 - padded.count))
        }
        self.words = Array(padded.prefix(8))
    }

    init(data: Data) {
        var values = Array(repeating: UInt32(0), count: 8)
        let bytes = [UInt8](data.prefix(32))
        for index in 0..<8 {
            let base = index * 4
            if base + 3 < bytes.count {
                let word = UInt32(bytes[base])
                    | (UInt32(bytes[base + 1]) << 8)
                    | (UInt32(bytes[base + 2]) << 16)
                    | (UInt32(bytes[base + 3]) << 24)
                values[index] = word
            }
        }
        self.words = values
    }

    var data: Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for word in words {
            bytes.append(UInt8(word & 0xff))
            bytes.append(UInt8((word >> 8) & 0xff))
            bytes.append(UInt8((word >> 16) & 0xff))
            bytes.append(UInt8((word >> 24) & 0xff))
        }
        return Data(bytes)
    }

    func bitwiseNot() -> UInt256 {
        UInt256(words: words.map { ~$0 })
    }

    func adding(_ other: UInt256) -> UInt256 {
        var result = Array(repeating: UInt32(0), count: 8)
        var carry: UInt64 = 0

        for index in 0..<8 {
            let sum = UInt64(words[index]) + UInt64(other.words[index]) + carry
            result[index] = UInt32(sum & 0xffffffff)
            carry = sum >> 32
        }

        return UInt256(words: result)
    }

    func subtracting(_ other: UInt256) -> UInt256 {
        var result = Array(repeating: UInt32(0), count: 8)
        var borrow: UInt64 = 0

        for index in 0..<8 {
            let lhs = UInt64(words[index])
            let rhs = UInt64(other.words[index]) + borrow
            if lhs >= rhs {
                result[index] = UInt32(lhs - rhs)
                borrow = 0
            } else {
                result[index] = UInt32((1 << 32) + lhs - rhs)
                borrow = 1
            }
        }

        return UInt256(words: result)
    }

    func divided(by divisor: UInt256) -> UInt256 {
        guard divisor != .zero else { return .zero }

        var quotient = UInt256.zero
        var remainder = UInt256.zero

        for bit in stride(from: 255, through: 0, by: -1) {
            remainder = remainder.shiftedLeftBy1()
            if bitValue(at: bit) == 1 {
                remainder.words[0] |= 1
            }

            if remainder.compare(to: divisor) != .orderedAscending {
                remainder = remainder.subtracting(divisor)
                quotient.setBit(bit)
            }
        }

        return quotient
    }

    private func compare(to other: UInt256) -> ComparisonResult {
        for index in stride(from: 7, through: 0, by: -1) {
            let left = words[index]
            let right = other.words[index]
            if left == right { continue }
            return left < right ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private func bitValue(at index: Int) -> UInt32 {
        let wordIndex = index / 32
        let bitIndex = index % 32
        guard wordIndex < words.count else { return 0 }
        return (words[wordIndex] >> bitIndex) & 1
    }

    private mutating func setBit(_ index: Int) {
        let wordIndex = index / 32
        let bitIndex = index % 32
        guard wordIndex < words.count else { return }
        words[wordIndex] |= (1 << bitIndex)
    }

    private func shiftedLeftBy1() -> UInt256 {
        var result = Array(repeating: UInt32(0), count: 8)
        var carry: UInt32 = 0
        for index in 0..<8 {
            let newCarry = (words[index] >> 31) & 1
            result[index] = (words[index] << 1) | carry
            carry = newCarry
        }
        return UInt256(words: result)
    }
}
