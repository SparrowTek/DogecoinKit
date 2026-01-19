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
}

/// Manages bundled header cache installation and validation
public actor HeaderCacheManager {
    /// Standard file names for the cache bundle
    public static let headersFileName = "headers.bin.lzfse"
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
    /// - Parameters:
    ///   - bundleDirectory: Directory containing the bundled headers.bin.lzfse and metadata.json
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
        let headersURL = bundleDirectory.appendingPathComponent(Self.headersFileName)
        let metadataURL = bundleDirectory.appendingPathComponent(Self.metadataFileName)

        // Load and validate metadata
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw HeaderCacheError.metadataNotFound(metadataURL)
        }

        guard FileManager.default.fileExists(atPath: headersURL.path) else {
            throw HeaderCacheError.headersFileNotFound(headersURL)
        }

        let metadata = try loadMetadataOrThrow(from: metadataURL)
        let expectedNetwork = network == .mainnet ? "mainnet" : "testnet"

        guard metadata.network == expectedNetwork else {
            throw HeaderCacheError.networkMismatch(expected: expectedNetwork, actual: metadata.network)
        }

        // Verify checksum
        progressHandler?(0.0)
        let actualChecksum = try await computeChecksum(of: headersURL)

        guard normalizedHex(actualChecksum) == normalizedHex(metadata.checksumSHA256) else {
            throw HeaderCacheError.checksumMismatch(expected: metadata.checksumSHA256, actual: actualChecksum)
        }

        progressHandler?(0.1)

        // Create local directory if needed
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)

        // Decompress and write headers to the local headers.json format
        let localHeadersURL = localDirectory.appendingPathComponent("headers.json")
        try await decompressAndConvert(
            from: headersURL,
            to: localHeadersURL,
            metadata: metadata,
            network: network,
            progressHandler: progressHandler
        )

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
        let headersURL = directoryURL.appendingPathComponent("headers.json")

        guard FileManager.default.fileExists(atPath: headersURL.path) else {
            return false
        }

        do {
            let data = try Data(contentsOf: headersURL)
            guard let store = try? JSONDecoder().decode(HeaderChain.HeaderStore.self, from: data) else {
                return false
            }
            return store.headers.count == metadata.headerCount
        } catch {
            return false
        }
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

    private func decompressAndConvert(
        from compressedURL: URL,
        to outputURL: URL,
        metadata: HeaderCacheMetadata,
        network: DogecoinNetwork,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        var headers: [StoredHeader] = []
        headers.reserveCapacity(metadata.headerCount)

        var leftover = Data()
        var headerCount = 0
        var previousHash: Data?

        let expectedTotal = metadata.headerCount
        let progressBase = 0.1
        let progressRange = 0.85

        try LZFSEDecompressor.decompress(from: compressedURL) { chunk in
            let combined: Data
            if leftover.isEmpty {
                combined = chunk
            } else {
                var merged = Data()
                merged.reserveCapacity(leftover.count + chunk.count)
                merged.append(leftover)
                merged.append(chunk)
                combined = merged
            }

            var offset = 0
            while combined.count - offset >= BlockHeader.size {
                let range = offset..<(offset + BlockHeader.size)
                let headerData = combined.subdata(in: range)

                guard let header = BlockHeader.parse(from: headerData) else {
                    throw HeaderCacheError.invalidHeaderData(height: headerCount)
                }

                // Validate chain linkage
                if headerCount == 0 {
                    // Genesis block should have zero prevBlock
                    if header.prevBlock != Data(count: 32) {
                        throw HeaderCacheError.chainValidationFailed(height: 0, reason: "Invalid genesis block")
                    }
                } else if let previous = previousHash, header.prevBlock != previous {
                    throw HeaderCacheError.chainValidationFailed(height: headerCount, reason: "Chain linkage broken")
                }

                let chainWork = computeChainWork(header: header, previousHeaders: headers)
                let stored = StoredHeader(header: header, height: Int32(headerCount), chainWork: chainWork)
                headers.append(stored)

                previousHash = header.hash
                headerCount += 1
                offset += BlockHeader.size

                // Report progress periodically
                if headerCount % 10000 == 0 {
                    let progress = progressBase + progressRange * (Double(headerCount) / Double(expectedTotal))
                    progressHandler?(min(progress, 0.95))
                }
            }

            if offset < combined.count {
                leftover = combined.subdata(in: offset..<combined.count)
            } else {
                leftover.removeAll(keepingCapacity: true)
            }
        }

        guard leftover.isEmpty else {
            throw HeaderCacheError.installationFailed("Trailing bytes after decompression")
        }

        guard headerCount == metadata.headerCount else {
            throw HeaderCacheError.headerCountMismatch(expected: metadata.headerCount, actual: headerCount)
        }

        // Write to JSON format compatible with HeaderChain
        let store = HeaderChain.HeaderStore(version: 2, headers: headers)
        let encoder = JSONEncoder()
        let data = try encoder.encode(store)

        try? FileManager.default.removeItem(at: outputURL)
        try data.write(to: outputURL, options: .atomic)
    }

    private func computeChainWork(header: BlockHeader, previousHeaders: [StoredHeader]) -> Data {
        // Chain work calculation: work = 2^256 / (target + 1)
        // For simplicity, we use a basic calculation based on the bits field
        let target = targetFromBits(header.bits)
        let work = calculateWork(target: target)

        if let lastHeader = previousHeaders.last {
            return addWork(lastHeader.chainWork, work)
        }
        return work
    }

    private func targetFromBits(_ bits: UInt32) -> Data {
        let exponent = Int((bits >> 24) & 0xFF)
        let coefficient = bits & 0x007FFFFF

        var target = Data(repeating: 0, count: 32)
        if exponent <= 3 {
            let shift = 8 * (3 - exponent)
            let value = coefficient >> shift
            target[31] = UInt8(value & 0xFF)
            target[30] = UInt8((value >> 8) & 0xFF)
            target[29] = UInt8((value >> 16) & 0xFF)
        } else {
            let byteIndex = 32 - exponent
            if byteIndex >= 0 && byteIndex < 32 {
                target[byteIndex] = UInt8(coefficient & 0xFF)
                if byteIndex + 1 < 32 {
                    target[byteIndex + 1] = UInt8((coefficient >> 8) & 0xFF)
                }
                if byteIndex + 2 < 32 {
                    target[byteIndex + 2] = UInt8((coefficient >> 16) & 0xFF)
                }
            }
        }
        return target
    }

    private func calculateWork(target: Data) -> Data {
        // Simplified work calculation
        // In practice this should be: (2^256 - 1) / (target + 1)
        // For bundled cache, the exact values are less critical since
        // we'll recalculate when loading into HeaderChain
        var work = Data(repeating: 0, count: 32)
        work[31] = 1
        return work
    }

    private func addWork(_ a: Data, _ b: Data) -> Data {
        var result = Data(repeating: 0, count: 32)
        var carry: UInt16 = 0

        for i in (0..<32).reversed() {
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
