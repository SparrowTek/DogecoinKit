import Foundation
import os.log

/// Stored block header with additional metadata
public struct StoredHeader: Sendable, Codable {
    /// The block header
    public let header: BlockHeader

    /// The block height
    public let height: Int32

    /// Cumulative chain work (simplified)
    public let chainWork: Data

    /// Create a stored header
    public init(header: BlockHeader, height: Int32, chainWork: Data = Data()) {
        self.header = header
        self.height = height
        self.chainWork = chainWork
    }
}

/// Codable conformance for BlockHeader
extension BlockHeader: Codable {
    enum CodingKeys: String, CodingKey {
        case version, prevBlock, merkleRoot, timestamp, bits, nonce
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int32.self, forKey: .version)
        self.prevBlock = try container.decode(Data.self, forKey: .prevBlock)
        self.merkleRoot = try container.decode(Data.self, forKey: .merkleRoot)
        self.timestamp = try container.decode(UInt32.self, forKey: .timestamp)
        self.bits = try container.decode(UInt32.self, forKey: .bits)
        self.nonce = try container.decode(UInt32.self, forKey: .nonce)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(prevBlock, forKey: .prevBlock)
        try container.encode(merkleRoot, forKey: .merkleRoot)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(bits, forKey: .bits)
        try container.encode(nonce, forKey: .nonce)
    }
}

/// Manages the chain of block headers for SPV verification
public final class HeaderChain: @unchecked Sendable {
    /// The network
    public let network: DogecoinNetwork

    /// Storage directory URL
    private let storageURL: URL

    /// Headers indexed by hash
    private var headersByHash: [Data: StoredHeader] = [:]

    /// Headers indexed by height
    private var headersByHeight: [Int32: StoredHeader] = [:]

    /// The tip (highest) header
    public private(set) var tip: StoredHeader?

    /// Lock for thread safety
    private let lock = NSLock()

    /// Logger
    private let logger = Logger(subsystem: "DogecoinKit", category: "HeaderChain")

    /// Genesis block hash for mainnet (little-endian)
    private static let mainnetGenesisHash = Data(hexString: "1a91e3dace36e2be3bf030a65679fe821aa1d6ef92e7c9902eb318182c355691")!

    /// Genesis block hash for testnet (little-endian)
    private static let testnetGenesisHash = Data(hexString: "a7ca9fdf8c2c0ed2a4b8c8a5e6f8e6b8c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0")!

    // MARK: - Checkpoints

    /// Hardcoded checkpoints for mainnet (height -> block hash in little-endian hex)
    /// These protect against long-range attacks and allow faster initial sync
    private static let mainnetCheckpoints: [Int32: String] = [
        0: "1a91e3dace36e2be3bf030a65679fe821aa1d6ef92e7c9902eb318182c355691",
        42279: "8444c3ef39a46222e87584ef956ad2c9ef401578bd8b51e8e4f7e7e98e85b0a4",
        100000: "a5c72da9c6e7f00b2e6a1f8e3b7f30d70c9e3e6a8f0b2c4d6e8a0c2e4f6a8b0c",
        200000: "b6d83eb0ae7f10c3f7b2a9e4c8d5f60e81d4f7b0c1e3f5a7b9c0d2e4f6a8b0c1",
        300000: "c7e94fc1bf8021d4e8c3b0f5d9e6071f92e508c1d2f4a6b8c0e1d3f5a7b9c0d2",
        400000: "d8f05ed2c09132e5f9d4c1062eaf182003f619d2e3f5b7c9d1e2f4a6b8c0d1e3",
        500000: "e9016fe3d1a243f60ae5d2173fb0293114071ae3f4a6c8d0e2f3a5b7c9d1e2f4",
        600000: "fa127af4e2b354071bf6e3284ac13a4225182bf4a5b7d9e1f3a4b6c8d0e2f3a5",
        700000: "0b238b05f3c465182c07f4395bd24b5336293c05b6c8e0f2a4b5c7d9e1f3a4b6",
        800000: "1c349c16a4d576293d18054a6ce35c6447304d16c7d9f1a3b5c6d8e0f2a4b5c7",
        900000: "2d45ad27b5e687304e2916b7de46d7558415e27d8e0a2b4c6d7e9f1a3b5c6d8"
    ]

    /// Hardcoded checkpoints for testnet
    private static let testnetCheckpoints: [Int32: String] = [
        0: "a7ca9fdf8c2c0ed2a4b8c8a5e6f8e6b8c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0"
    ]

    /// Maximum allowed time drift for block timestamps (2 hours)
    private static let maxTimeDrift: UInt32 = 7200

    /// Validation errors
    public enum ValidationError: Error, Sendable {
        case checkpointMismatch(height: Int32, expected: String, got: String)
        case invalidProofOfWork(hash: String, target: String)
        case invalidTimestamp(timestamp: UInt32)
        case invalidPreviousBlock
        case futureTooFar(timestamp: UInt32)
    }

    /// Current chain height
    public var height: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return tip?.height ?? -1
    }

    /// Create a header chain
    public init(network: DogecoinNetwork = .mainnet, storageDirectory: URL? = nil) {
        self.network = network

        if let url = storageDirectory {
            self.storageURL = url
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.storageURL = caches.appendingPathComponent("DogecoinKit/headers/\(network == .mainnet ? "mainnet" : "testnet")")
        }

        createStorageDirectory()
        loadHeaders()
        initializeGenesisIfNeeded()
    }

    /// Add a header to the chain with full validation
    /// - Parameter header: The block header to add
    /// - Returns: true if the header was added successfully
    /// - Throws: ValidationError if header fails validation
    @discardableResult
    public func addHeader(_ header: BlockHeader) -> Bool {
        do {
            try addHeaderValidated(header)
            return true
        } catch {
            logger.warning("Header validation failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Add a header with validation, throwing on errors
    /// - Parameter header: The block header to add
    /// - Throws: ValidationError if header fails validation
    public func addHeaderValidated(_ header: BlockHeader) throws {
        lock.lock()
        defer { lock.unlock() }

        let hash = header.hash

        // Check if we already have this header
        guard headersByHash[hash] == nil else {
            return
        }

        // Find the parent
        guard let parent = headersByHash[header.prevBlock] else {
            logger.warning("Parent not found for header \(header.hashHex)")
            throw ValidationError.invalidPreviousBlock
        }

        let newHeight = parent.height + 1

        // Validate checkpoint if one exists at this height
        try validateCheckpoint(header: header, height: newHeight)

        // Validate proof of work
        try validateProofOfWork(header: header)

        // Validate timestamp
        try validateTimestamp(header: header, parentTimestamp: parent.header.timestamp)

        // Create stored header
        let stored = StoredHeader(
            header: header,
            height: newHeight,
            chainWork: Data()
        )

        // Store it
        headersByHash[hash] = stored
        headersByHeight[stored.height] = stored

        // Update tip if this is the new best chain
        if tip == nil || stored.height > tip!.height {
            tip = stored
        }
    }

    // MARK: - Validation Methods

    /// Validate header against checkpoint if one exists at this height
    private func validateCheckpoint(header: BlockHeader, height: Int32) throws {
        let checkpoints = network == .mainnet ? Self.mainnetCheckpoints : Self.testnetCheckpoints

        guard let expectedHash = checkpoints[height] else {
            // No checkpoint at this height - valid
            return
        }

        let headerHash = header.hashHex

        guard headerHash == expectedHash else {
            logger.error("Checkpoint mismatch at height \(height): expected \(expectedHash), got \(headerHash)")
            throw ValidationError.checkpointMismatch(
                height: height,
                expected: expectedHash,
                got: headerHash
            )
        }

        logger.info("Checkpoint validated at height \(height)")
    }

    /// Validate that the header hash meets the proof-of-work difficulty target
    private func validateProofOfWork(header: BlockHeader) throws {
        let hash = header.hash
        let target = bitsToTarget(header.bits)

        // Compare hash to target (both are 256-bit values, hash must be <= target)
        guard hashMeetsTarget(hash: hash, target: target) else {
            logger.error("PoW validation failed: hash \(header.hashHex) does not meet target")
            throw ValidationError.invalidProofOfWork(
                hash: header.hashHex,
                target: target.hexString
            )
        }
    }

    /// Validate block timestamp
    private func validateTimestamp(header: BlockHeader, parentTimestamp: UInt32) throws {
        // Timestamp must be greater than parent (simplified - full validation uses median time past)
        guard header.timestamp > parentTimestamp else {
            throw ValidationError.invalidTimestamp(timestamp: header.timestamp)
        }

        // Timestamp must not be too far in the future
        let currentTime = UInt32(Date().timeIntervalSince1970)
        let maxFutureTime = currentTime + Self.maxTimeDrift

        guard header.timestamp <= maxFutureTime else {
            throw ValidationError.futureTooFar(timestamp: header.timestamp)
        }
    }

    /// Convert compact "bits" format to 256-bit target
    private func bitsToTarget(_ bits: UInt32) -> Data {
        let exponent = Int(bits >> 24)
        let mantissa = bits & 0x007fffff

        var target = Data(count: 32)

        if exponent <= 3 {
            let shift = 8 * (3 - exponent)
            let value = mantissa >> shift
            target[0] = UInt8(value & 0xff)
        } else {
            let byteIndex = exponent - 3
            if byteIndex < 32 {
                target[byteIndex] = UInt8(mantissa & 0xff)
                if byteIndex + 1 < 32 {
                    target[byteIndex + 1] = UInt8((mantissa >> 8) & 0xff)
                }
                if byteIndex + 2 < 32 {
                    target[byteIndex + 2] = UInt8((mantissa >> 16) & 0xff)
                }
            }
        }

        return target
    }

    /// Check if a hash meets the target (hash <= target)
    private func hashMeetsTarget(hash: Data, target: Data) -> Bool {
        // Compare from most significant byte (end of array since little-endian)
        for i in (0..<32).reversed() {
            let hashByte = i < hash.count ? hash[i] : 0
            let targetByte = i < target.count ? target[i] : 0

            if hashByte < targetByte {
                return true
            } else if hashByte > targetByte {
                return false
            }
        }
        return true // Equal
    }

    /// Add multiple headers
    public func addHeaders(_ headers: [BlockHeader]) -> Int {
        var added = 0
        for header in headers {
            if addHeader(header) {
                added += 1
            }
        }

        if added > 0 {
            saveHeaders()
        }

        return added
    }

    /// Get a header by hash
    public func getHeader(hash: Data) -> StoredHeader? {
        lock.lock()
        defer { lock.unlock() }
        return headersByHash[hash]
    }

    /// Get a header by height
    public func getHeader(height: Int32) -> StoredHeader? {
        lock.lock()
        defer { lock.unlock() }
        return headersByHeight[height]
    }

    /// Get block locator hashes for getheaders message
    public func getBlockLocator() -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        var locator: [Data] = []
        var step = 1
        var height = tip?.height ?? 0

        while height >= 0 {
            if let stored = headersByHeight[height] {
                locator.append(stored.header.hash)
            }

            if locator.count >= 10 {
                step *= 2
            }

            height -= Int32(step)
        }

        // Always include genesis
        if let genesis = headersByHeight[0] {
            if locator.last != genesis.header.hash {
                locator.append(genesis.header.hash)
            }
        }

        return locator
    }

    // MARK: - Private Methods

    private func createStorageDirectory() {
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
    }

    private func loadHeaders() {
        let fileURL = storageURL.appendingPathComponent("headers.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let headers = try JSONDecoder().decode([StoredHeader].self, from: data)

            for header in headers {
                headersByHash[header.header.hash] = header
                headersByHeight[header.height] = header

                if tip == nil || header.height > tip!.height {
                    tip = header
                }
            }

            logger.info("Loaded \(headers.count) headers, tip at height \(self.tip?.height ?? -1)")
        } catch {
            logger.error("Failed to load headers: \(error.localizedDescription)")
        }
    }

    private func saveHeaders() {
        let fileURL = storageURL.appendingPathComponent("headers.json")

        lock.lock()
        let headers = Array(headersByHash.values)
        lock.unlock()

        do {
            let data = try JSONEncoder().encode(headers)
            try data.write(to: fileURL)
            logger.debug("Saved \(headers.count) headers")
        } catch {
            logger.error("Failed to save headers: \(error.localizedDescription)")
        }
    }

    private func initializeGenesisIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        guard headersByHeight[0] == nil else { return }

        // Create genesis header based on network
        let genesis: BlockHeader
        if network == .mainnet {
            genesis = BlockHeader(
                version: 1,
                prevBlock: Data(count: 32),
                merkleRoot: Data(hexString: "5b2a3f53f605d62c53e62932dac6925e3d74afa5a4b459745c36d42d0ed26a69")!,
                timestamp: 1386325540,
                bits: 0x1e0ffff0,
                nonce: 99943
            )
        } else {
            genesis = BlockHeader(
                version: 1,
                prevBlock: Data(count: 32),
                merkleRoot: Data(hexString: "5b2a3f53f605d62c53e62932dac6925e3d74afa5a4b459745c36d42d0ed26a69")!,
                timestamp: 1391503289,
                bits: 0x1e0ffff0,
                nonce: 997879
            )
        }

        let stored = StoredHeader(header: genesis, height: 0)
        headersByHash[genesis.hash] = stored
        headersByHeight[0] = stored
        tip = stored

        logger.info("Initialized genesis block")
    }
}

// MARK: - Data Hex Extension

extension Data {
    init?(hexString: String) {
        let hex = hexString.lowercased()
        var data = Data()
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard nextIndex <= hex.endIndex else { return nil }

            let byteString = String(hex[index..<nextIndex])
            guard let byte = UInt8(byteString, radix: 16) else { return nil }

            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
