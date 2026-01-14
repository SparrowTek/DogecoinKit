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

    /// Add a header to the chain
    /// - Returns: true if the header was added successfully
    @discardableResult
    public func addHeader(_ header: BlockHeader) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let hash = header.hash

        // Check if we already have this header
        guard headersByHash[hash] == nil else {
            return true
        }

        // Find the parent
        guard let parent = headersByHash[header.prevBlock] else {
            logger.warning("Parent not found for header \(header.hashHex)")
            return false
        }

        // Create stored header
        let stored = StoredHeader(
            header: header,
            height: parent.height + 1,
            chainWork: Data()
        )

        // Store it
        headersByHash[hash] = stored
        headersByHeight[stored.height] = stored

        // Update tip if this is the new best chain
        if tip == nil || stored.height > tip!.height {
            tip = stored
        }

        return true
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
