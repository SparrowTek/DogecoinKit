import Foundation
import GRDB
import os.log
import clibdogecoin

@_silgen_name("scrypt_1024_1_1_256")
private func scrypt_1024_1_1_256(_ input: UnsafePointer<UInt8>?, _ output: UnsafeMutablePointer<UInt8>?)

/// Stored block header with additional metadata
public struct StoredHeader: Sendable, Codable {
    /// The block header
    public let header: BlockHeader

    /// The block height
    public let height: Int32

    /// Cumulative chain work
    public let chainWork: Data

    /// Create a stored header
    public init(header: BlockHeader, height: Int32, chainWork: Data = Data(repeating: 0, count: 32)) {
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

// MARK: - Binary Serialization (kept for migration compatibility)

extension StoredHeader {
    /// Serialize to binary format: 80 bytes header + 4 bytes height + 32 bytes chainWork = 116 bytes
    func serializeBinary() -> Data {
        var data = Data()
        data.reserveCapacity(116)
        data.append(header.serializeCore())
        withUnsafeBytes(of: height.littleEndian) { data.append(contentsOf: $0) }
        let paddedChainWork = chainWork.count == 32 ? chainWork : chainWork.prefix(32) + Data(repeating: 0, count: max(0, 32 - chainWork.count))
        data.append(paddedChainWork.prefix(32))
        return data
    }

    /// Deserialize from binary format
    static func deserializeBinary(from data: Data) -> StoredHeader? {
        guard data.count >= 116 else { return nil }

        let headerData = data.prefix(80)
        guard let header = BlockHeader.parse(from: Data(headerData)) else { return nil }

        let heightData = data.subdata(in: 80..<84)
        let height = heightData.withUnsafeBytes { $0.load(as: Int32.self).littleEndian }

        let chainWork = data.subdata(in: 84..<116)

        return StoredHeader(header: header, height: height, chainWork: chainWork)
    }
}

/// Manages the chain of block headers for SPV verification
public final class HeaderChain: @unchecked Sendable {
    /// The network
    public let network: DogecoinNetwork

    /// Storage directory URL
    private let storageURL: URL

    /// SQLite database for header storage
    private var database: HeaderDatabase?

    /// LRU cache for recently accessed headers (by hash)
    private let recentHeaders = LRUCache<Data, StoredHeader>(capacity: 1000)

    /// Cached tip header
    private var tipCache: StoredHeader?

    /// Lock for thread safety
    private let lock = NSLock()

    /// Logger
    private let logger = Logger(subsystem: "DogecoinKit", category: "HeaderChain")

    /// Cached warning state for auxpow handling
    private var didLogAuxpowWarning = false

    /// Cached state for SPV trust logging
    private var didLogAuxpowSPVTrust = false

    /// Binary record size for migration: 80 (header) + 4 (height) + 32 (chainWork) = 116 bytes
    private static let binaryRecordSize = 116

    // MARK: - Checkpoints

    /// Checkpoints from libdogecoin chainparams (height -> block hash)
    private static let mainnetCheckpoints: [Int32: String] = [
        0: "1a91e3dace36e2be3bf030a65679fe821aa1d6ef92e7c9902eb318182c355691",
        104679: "35eb87ae90d44b98898fec8c39577b76cb1eb08e1261cfc10706c8ce9a1d01cf",
        145000: "cc47cae70d7c5c92828d3214a266331dde59087d4a39071fa76ddfff9b7bde72",
        371337: "60323982f9c5ff1b5a954eac9dc1269352835f47c2c5222691d80f0d50dcf053",
        450000: "d279277f8f846a224d776450aa04da3cf978991a182c6f3075db4c48b173bbd7",
        771275: "1b7d789ed82cbdc640952e7e7a54966c6488a32eaad54fc39dff83f310dbaaed",
        1000000: "6aae55bea74235f0c80bd066349d4440c31f2d0f27d54265ecd484d8c1d11b47",
        1250000: "00c7a442055c1a990e11eea5371ca5c1c02a0677b33cc88ec728c45edc4ec060",
        1500000: "f1d32d6920de7b617d51e74bdf4e58adccaa582ffdc8657464454f16a952fca6",
        1750000: "5c8e7327984f0d6f59447d89d143e5f6eafc524c82ad95d176c5cec082ae2001",
        2000000: "9914f0e82e39bbf21950792e8816620d71b9965bdbbc14e72a95e3ab9618fea8",
        2031142: "893297d89afb7599a3c571ca31a3b80e8353f4cf39872400ad0f57d26c4c5d42",
        2250000: "0a87a8d4e40dca52763f93812a288741806380cd569537039ee927045c6bc338",
        2510150: "77e3f4a4bcb4a2c15e8015525e3d15b466f6c022f6ca82698f329edef7d9777e",
        2750000: "d4f8abb835930d3c4f92ca718aaa09bef545076bd872354e0b2b85deefacf2e3",
        3000000: "195a83b091fb3ee7ecb56f2e63d01709293f57f971ccf373d93890c8dc1033db",
        3250000: "7f3e28bf9e309c4b57a4b70aa64d3b2ea5250ae797af84976ddc420d49684034",
        3500000: "eaa303b93c1c64d2b3a2cdcf6ccf21b10cc36626965cc2619661e8e1879abdfb",
        3606083: "954c7c66dee51f0a3fb1edb26200b735f5275fe54d9505c76ebd2bcabac36f1e",
        3854173: "e4b4ecda4c022406c502a247c0525480268ce7abbbef632796e8ca1646425e75",
        3963597: "2b6927cfaa5e82353d45f02be8aadd3bfd165ece5ce24b9bfa4db20432befb5d",
        4303965: "ed7d266dcbd8bb8af80f9ccb8deb3e18f9cc3f6972912680feeb37b090f8cee0",
        5050000: "e7d4577405223918491477db725a393bcfc349d8ee63b0a4fde23cbfbfd81dea",
        5400000: "cbb1f4ae807da83e13bdf9c28188982938c9ee6bf560c1023f51adac229eef87"
    ]

    /// Checkpoints from libdogecoin chainparams (height -> block hash)
    private static let testnetCheckpoints: [Int32: String] = [
        0: "bb0a78264637406b6360aad926284d544d7049f45189db5664f3c4d07350559e",
        483173: "a804201ca0aceb7e937ef7a3c613a9b7589245b10cc095148c4ce4965b0b73b5",
        591117: "5f6b93b2c28cedf32467d900369b8be6700f0649388a7dbfd3ebd4a01b1ffad8",
        658924: "ed6c8324d9a77195ee080f225a0fca6346495e08ded99bcda47a8eea5a8a620b",
        703635: "839fa54617adcd582d53030a37455c14a87a806f6615aa8213f13e196230ff7f",
        1000000: "1fe4d44ea4d1edb031f52f0d7c635db8190dc871a190654c41d2450086b8ef0e",
        1202214: "a2179767a87ee4e95944703976fee63578ec04fa3ac2fc1c9c2c83587d096977",
        1250000: "b46affb421872ca8efa30366b09694e2f9bf077f7258213be14adb05a9f41883",
        1500000: "0caa041b47b4d18a4f44bdc05cef1a96d5196ce7b2e32ad3e4eb9ba505144917",
        1750000: "8042462366d854ad39b8b95ed2ca12e89a526ceee5a90042d55ebb24d5aab7e9",
        2000000: "d6acde73e1b42fc17f29dcc76f63946d378ae1bd4eafab44d801a25be784103c",
        2250000: "c4342ae6d9a522a02e5607411df1b00e9329563ef844a758d762d601d42c86dc",
        2500000: "3a66ec4933fbb348c9b1889aaf2f732fe429fd9a8f74fee6895eae061ac897e2",
        2750000: "473ea9f625d59f534ffcc9738ffc58f7b7b1e0e993078614f5484a9505885563",
        3062910: "113c41c00934f940a41f99d18b2ad9aefd183a4b7fe80527e1e6c12779bd0246",
        3286675: "07fef07a255d510297c9189dc96da5f4e41a8184bc979df8294487f07fee1cf3",
        3445426: "70574db7856bd685abe7b0a8a3e79b29882620645bd763b01459176bceb58cd1",
        3976284: "af23c3e750bb4f2ce091235f006e7e4e2af453d4c866282e7870471dcfeb4382",
        5900000: "199bea6a442310589cbb50a193a30b097c228bd5a0f21af21e4e53dd57c382d3"
    ]

    /// Maximum allowed time drift for block timestamps (2 hours)
    private static let maxTimeDrift: UInt32 = 7200

    /// Validation errors
    public enum ValidationError: Error, Sendable {
        case checkpointMismatch(height: Int32, expected: String, got: String)
        case invalidProofOfWork(hash: String, target: String)
        case invalidDifficulty(bits: UInt32)
        case invalidTimestamp(timestamp: UInt32)
        case invalidPreviousBlock
        case futureTooFar(timestamp: UInt32)
        case auxPowRequired(height: Int32)
        case auxPowValidationFailed(AuxPoW.ValidationError)
        case databaseError(Error)
    }

    /// Highest checkpoint heights for each network
    /// AuxPoW validation is required for blocks above these heights
    private static let mainnetHighestCheckpoint: Int32 = 5_400_000
    private static let testnetHighestCheckpoint: Int32 = 5_900_000

    /// The tip (highest) header
    public var tip: StoredHeader? {
        lock.lock()
        defer { lock.unlock() }
        return tipCache
    }

    /// Current chain height
    public var height: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return tipCache?.height ?? -1
    }

    /// Create a header chain
    /// - Parameters:
    ///   - network: The Dogecoin network (mainnet or testnet)
    ///   - storageDirectory: Optional custom storage directory for header cache
    ///   - bundledCacheDirectory: Optional directory containing pre-bundled headers.sqlite
    public init(network: DogecoinNetwork = .mainnet, storageDirectory: URL? = nil, bundledCacheDirectory: URL? = nil) {
        self.network = network

        if let url = storageDirectory {
            self.storageURL = url
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.storageURL = caches.appendingPathComponent("DogecoinKit/headers/\(network == .mainnet ? "mainnet" : "testnet")")
        }

        createStorageDirectory()
        openOrCreateDatabase()
        migrateFromBinaryIfNeeded()
        installBundledCacheIfNeeded(from: bundledCacheDirectory)
        loadTipFromDatabase()
        initializeGenesisIfNeeded()
    }

    // MARK: - Database Setup

    private func createStorageDirectory() {
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
    }

    private func openOrCreateDatabase() {
        let dbPath = storageURL.appendingPathComponent("headers.sqlite").path
        do {
            database = try HeaderDatabase(path: dbPath)
            logger.info("Opened header database at \(dbPath)")
        } catch {
            logger.error("Failed to open header database: \(error.localizedDescription)")
        }
    }

    private func loadTipFromDatabase() {
        guard let db = database else { return }
        do {
            if let tipRecord = try db.getTip() {
                tipCache = tipRecord.toStoredHeader()
                logger.info("Loaded tip from database at height \(self.tipCache?.height ?? -1)")
            }
        } catch {
            logger.error("Failed to load tip from database: \(error.localizedDescription)")
        }
    }

    /// Migrate from legacy binary format to SQLite
    private func migrateFromBinaryIfNeeded() {
        let binaryURL = storageURL.appendingPathComponent("headers.bin")
        guard FileManager.default.fileExists(atPath: binaryURL.path),
              let db = database else {
            return
        }

        do {
            let existingCount = try db.getHeaderCount()
            if existingCount > 0 {
                logger.info("Database already has \(existingCount) headers, skipping migration")
                return
            }
        } catch {
            logger.error("Failed to check database: \(error.localizedDescription)")
            return
        }

        logger.info("Migrating from binary format to SQLite...")

        do {
            let data = try Data(contentsOf: binaryURL)
            let recordCount = data.count / Self.binaryRecordSize

            var records: [HeaderRecord] = []
            records.reserveCapacity(min(recordCount, 10000))

            for i in 0..<recordCount {
                let offset = i * Self.binaryRecordSize
                let recordData = data.subdata(in: offset..<(offset + Self.binaryRecordSize))
                guard let stored = StoredHeader.deserializeBinary(from: recordData) else {
                    logger.warning("Failed to parse binary record at offset \(offset)")
                    continue
                }

                let record = HeaderRecord(storedHeader: stored, isInBestChain: true)
                records.append(record)

                if records.count >= 10000 {
                    try db.insertHeaders(records)
                    records.removeAll(keepingCapacity: true)
                    logger.debug("Migrated \(i + 1) / \(recordCount) headers")
                }
            }

            if !records.isEmpty {
                try db.insertHeaders(records)
            }

            // Backup and remove old binary file
            let backupURL = binaryURL.appendingPathExtension("migrated")
            try? FileManager.default.moveItem(at: binaryURL, to: backupURL)

            logger.info("Successfully migrated \(recordCount) headers to SQLite")
        } catch {
            logger.error("Migration from binary failed: \(error.localizedDescription)")
        }
    }

    /// Attempt to install bundled cache if it's newer than local cache
    private func installBundledCacheIfNeeded(from bundledDirectory: URL?) {
        guard let bundledDirectory else { return }

        let bundledDBPath = bundledDirectory.appendingPathComponent("headers.sqlite")
        guard FileManager.default.fileExists(atPath: bundledDBPath.path) else {
            logger.info("No bundled SQLite database found at \(bundledDBPath.path)")
            return
        }

        guard let localDB = database else { return }

        do {
            let localCount = try localDB.getHeaderCount()

            // Open bundled database to check its count
            let bundledDB = try HeaderDatabase(path: bundledDBPath.path)
            let bundledCount = try bundledDB.getHeaderCount()

            guard bundledCount > localCount else {
                logger.info("Local database has \(localCount) headers, bundled has \(bundledCount). Skipping install.")
                return
            }

            logger.info("Installing bundled cache: \(bundledCount) headers (local has \(localCount))")

            // Copy bundled database over local
            let localDBPath = storageURL.appendingPathComponent("headers.sqlite")
            try? FileManager.default.removeItem(at: localDBPath)
            try FileManager.default.copyItem(at: bundledDBPath, to: localDBPath)

            // Reopen database
            database = try HeaderDatabase(path: localDBPath.path)
            loadTipFromDatabase()

            logger.info("Successfully installed bundled header cache")
        } catch {
            logger.error("Failed to install bundled cache: \(error.localizedDescription)")
        }
    }

    // MARK: - Public API

    /// Add a header to the chain with full validation
    /// - Parameter header: The block header to add
    /// - Returns: true if the header was added successfully
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

    /// Add a header with AuxPoW data for merged-mining validation
    @discardableResult
    public func addHeader(_ header: BlockHeader, auxpow: AuxPoW?) -> Bool {
        do {
            try addHeaderValidated(header, auxpow: auxpow)
            return true
        } catch {
            logger.warning("Header validation failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Add a header with validation, throwing on errors
    public func addHeaderValidated(_ header: BlockHeader) throws {
        try addHeaderValidated(header, auxpow: nil)
    }

    /// Add a header with validation and optional AuxPoW data
    public func addHeaderValidated(_ header: BlockHeader, auxpow: AuxPoW?) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let db = database else {
            throw ValidationError.databaseError(HeaderDatabaseError.databaseNotOpen)
        }

        let hash = header.hash

        // Check if we already have this header
        if recentHeaders.contains(hash) {
            return
        }
        if let _ = try? db.getHeader(hash: hash) {
            return
        }

        // Find the parent
        let parent: StoredHeader
        if let cached = recentHeaders.get(header.prevBlock) {
            parent = cached
        } else if let record = try? db.getHeader(hash: header.prevBlock) {
            parent = record.toStoredHeader()
        } else {
            logger.warning("Parent not found for header \(header.hashHex)")
            throw ValidationError.invalidPreviousBlock
        }

        let newHeight = parent.height + 1

        // Validate checkpoint if one exists at this height
        try validateCheckpoint(header: header, height: newHeight)

        // Determine validation strategy based on height and AuxPoW status
        let isAuxPowBlock = AuxPoW.isAuxPow(version: header.version)
        let highestCheckpoint = network == .mainnet ? Self.mainnetHighestCheckpoint : Self.testnetHighestCheckpoint

        let blockWork: Data
        if isAuxPowBlock {
            if newHeight <= highestCheckpoint {
                logAuxpowTrustCheckpointIfNeeded(height: newHeight)
            } else if let auxpowData = auxpow {
                do {
                    try auxpowData.validate(dogecoinBlockHash: hash)
                    logger.debug("AuxPoW validated for block at height \(newHeight)")
                } catch let error as AuxPoW.ValidationError {
                    throw ValidationError.auxPowValidationFailed(error)
                }
            } else {
                logAuxpowSPVTrustIfNeeded(height: newHeight)
            }
            blockWork = try calculateBlockWork(for: header, validatePoW: false)
        } else {
            blockWork = try calculateBlockWork(for: header, validatePoW: true)
        }

        // Validate timestamp
        try validateTimestamp(header: header, parent: parent)

        // Create stored header
        let chainWork = addChainWork(normalizedChainWork(parent.chainWork), blockWork)
        let stored = StoredHeader(
            header: header,
            height: newHeight,
            chainWork: chainWork
        )

        // Determine if this extends the best chain
        let isNewTip = tipCache == nil || stored.header.prevBlock == tipCache?.header.hash
        let shouldReorg = !isNewTip && tipCache != nil && shouldReorganize(currentTip: tipCache!, candidateTip: stored)

        // Insert into database
        let record = HeaderRecord(storedHeader: stored, isInBestChain: isNewTip || shouldReorg)
        do {
            try db.insertHeader(record)
        } catch {
            throw ValidationError.databaseError(error)
        }

        // Update cache
        recentHeaders.set(hash, stored)

        // Update tip
        if isNewTip {
            tipCache = stored
        } else if shouldReorg {
            try reorganize(from: tipCache!, to: stored, db: db)
        }
    }

    /// Add multiple headers
    public func addHeaders(_ headers: [BlockHeader]) -> Int {
        var added = 0
        for header in headers {
            if addHeader(header) {
                added += 1
            }
        }
        return added
    }

    /// Flush is a no-op with SQLite (writes are immediate)
    public func flush() {
        // SQLite writes are immediate, no pending buffer
    }

    /// Get a header by hash
    public func getHeader(hash: Data) -> StoredHeader? {
        lock.lock()
        defer { lock.unlock() }

        // Check cache first
        if let cached = recentHeaders.get(hash) {
            return cached
        }

        // Query database
        guard let db = database,
              let record = try? db.getHeader(hash: hash) else {
            return nil
        }

        let stored = record.toStoredHeader()
        recentHeaders.set(hash, stored)
        return stored
    }

    /// Get a header by height (from best chain)
    public func getHeader(height: Int32) -> StoredHeader? {
        lock.lock()
        defer { lock.unlock() }

        guard let db = database,
              let record = try? db.getHeader(height: height) else {
            return nil
        }

        let stored = record.toStoredHeader()
        recentHeaders.set(stored.header.hash, stored)
        return stored
    }

    /// Check if a header is part of the current best chain
    public func isHeaderInBestChain(_ hash: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let db = database,
              let record = try? db.getHeader(hash: hash) else {
            return false
        }

        return record.isInBestChain
    }

    /// Get block locator hashes for getheaders message
    public func getBlockLocator() -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        guard let db = database else { return [] }

        do {
            return try db.getBlockLocator()
        } catch {
            logger.error("Failed to get block locator: \(error.localizedDescription)")
            return []
        }
    }

    /// Get the underlying database (for advanced queries)
    public var headerDatabase: HeaderDatabase? {
        database
    }

    // MARK: - Validation Methods

    private func validateCheckpoint(header: BlockHeader, height: Int32) throws {
        let checkpoints = network == .mainnet ? Self.mainnetCheckpoints : Self.testnetCheckpoints

        guard let expectedHash = checkpoints[height] else {
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

    private func validateTimestamp(header: BlockHeader, parent: StoredHeader) throws {
        let medianTime = medianTimePast(from: parent)

        guard header.timestamp > medianTime else {
            throw ValidationError.invalidTimestamp(timestamp: header.timestamp)
        }

        let currentTime = UInt32(Date().timeIntervalSince1970)
        let maxFutureTime = currentTime + Self.maxTimeDrift

        guard header.timestamp <= maxFutureTime else {
            throw ValidationError.futureTooFar(timestamp: header.timestamp)
        }
    }

    // MARK: - Chain Reorganization

    private func shouldReorganize(currentTip: StoredHeader, candidateTip: StoredHeader) -> Bool {
        let comparison = compareChainWork(candidateTip.chainWork, currentTip.chainWork)
        if comparison == .orderedDescending {
            return true
        }
        if comparison == .orderedSame {
            return candidateTip.header.timestamp > currentTip.header.timestamp
        }
        return false
    }

    private func reorganize(from currentTip: StoredHeader, to newTip: StoredHeader, db: HeaderDatabase) throws {
        guard let commonAncestor = findCommonAncestor(between: currentTip, and: newTip) else {
            logger.error("Unable to find common ancestor for reorg")
            return
        }

        // Clear best chain markers above common ancestor
        try db.clearBestChainMarkers(aboveHeight: commonAncestor.height)

        // Mark new chain as best
        var cursor: StoredHeader? = newTip
        var newChainHashes: [Data] = []
        while let header = cursor, header.height > commonAncestor.height {
            newChainHashes.append(header.header.hash)
            cursor = getHeaderUnlocked(hash: header.header.prevBlock)
        }

        for hash in newChainHashes {
            try db.updateBestChainStatus(hash: hash, isInBestChain: true)
        }

        tipCache = newTip
        logger.info("Chain reorganized at height \(commonAncestor.height), new tip at \(newTip.height)")
    }

    private func findCommonAncestor(between first: StoredHeader, and second: StoredHeader) -> StoredHeader? {
        var a: StoredHeader? = first
        var b: StoredHeader? = second

        while let aHeader = a, let bHeader = b, aHeader.height != bHeader.height {
            if aHeader.height > bHeader.height {
                a = getHeaderUnlocked(hash: aHeader.header.prevBlock)
            } else {
                b = getHeaderUnlocked(hash: bHeader.header.prevBlock)
            }
        }

        while let aHeader = a, let bHeader = b {
            if aHeader.header.hash == bHeader.header.hash {
                return aHeader
            }
            a = getHeaderUnlocked(hash: aHeader.header.prevBlock)
            b = getHeaderUnlocked(hash: bHeader.header.prevBlock)
        }

        return nil
    }

    /// Get header without acquiring lock (for internal use when lock is already held)
    private func getHeaderUnlocked(hash: Data) -> StoredHeader? {
        if let cached = recentHeaders.get(hash) {
            return cached
        }
        guard let db = database,
              let record = try? db.getHeader(hash: hash) else {
            return nil
        }
        let stored = record.toStoredHeader()
        recentHeaders.set(hash, stored)
        return stored
    }

    // MARK: - Genesis Block

    private func initializeGenesisIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        guard let db = database else { return }

        // Check if genesis exists
        do {
            if let _ = try db.getHeader(height: 0) {
                return
            }
        } catch {
            // Continue to create genesis
        }

        let merkleRootInternal = Data(Data(hexString: "5b2a3f53f605d62c53e62932dac6925e3d74afa5a4b459745c36d42d0ed26a69")!.reversed())

        let genesis: BlockHeader
        if network == .mainnet {
            genesis = BlockHeader(
                version: 1,
                prevBlock: Data(count: 32),
                merkleRoot: merkleRootInternal,
                timestamp: 1386325540,
                bits: 0x1e0ffff0,
                nonce: 99943
            )
        } else {
            genesis = BlockHeader(
                version: 1,
                prevBlock: Data(count: 32),
                merkleRoot: merkleRootInternal,
                timestamp: 1391503289,
                bits: 0x1e0ffff0,
                nonce: 997879
            )
        }

        let genesisWork = (try? calculateBlockWork(for: genesis, validatePoW: true)) ?? Data(repeating: 0, count: 32)
        let stored = StoredHeader(header: genesis, height: 0, chainWork: genesisWork)

        // Verify genesis hash matches expected checkpoint
        let checkpoints = network == .mainnet ? Self.mainnetCheckpoints : Self.testnetCheckpoints
        if let expectedHash = checkpoints[0] {
            let actualHash = genesis.hashHex
            if actualHash != expectedHash {
                logger.error("Genesis hash mismatch: expected \(expectedHash), got \(actualHash)")
            }
        }

        let record = HeaderRecord(storedHeader: stored, isInBestChain: true)
        do {
            try db.insertHeader(record)
            recentHeaders.set(genesis.hash, stored)

            if tipCache == nil {
                tipCache = stored
                logger.info("Initialized genesis block as tip with hash \(genesis.hashHex)")
            } else {
                logger.info("Added missing genesis block with hash \(genesis.hashHex)")
            }
        } catch {
            logger.error("Failed to insert genesis: \(error.localizedDescription)")
        }
    }

    // MARK: - Chainwork + PoW

    private func calculateBlockWork(for header: BlockHeader, validatePoW: Bool) throws -> Data {
        guard let target = targetFromBits(header.bits) else {
            throw ValidationError.invalidDifficulty(bits: header.bits)
        }

        if validatePoW {
            let hash = scryptHash(for: header)
            let powHash = Data(hash.reversed())

            guard compareChainWork(powHash, target) != .orderedDescending else {
                let targetHex = targetHexString(bits: header.bits)
                logger.error("PoW validation failed: hash \(header.hashHex) does not meet target")
                throw ValidationError.invalidProofOfWork(hash: header.hashHex, target: targetHex)
            }
        }

        let targetValue = UInt256(data: target)
        let targetPlusOne = targetValue.adding(UInt256.one)
        let negTarget = targetValue.bitwiseNot()
        let hashes = negTarget.divided(by: targetPlusOne)
        let work = hashes.adding(UInt256.one)

        return work.data
    }

    private func scryptHash(for header: BlockHeader) -> Data {
        let headerData = header.serializeCore()
        var hash = Data(repeating: 0, count: 32)

        headerData.withUnsafeBytes { headerBytes in
            hash.withUnsafeMutableBytes { hashBytes in
                guard let headerPtr = headerBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let hashPtr = hashBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                scrypt_1024_1_1_256(headerPtr, hashPtr)
            }
        }

        return hash
    }

    private func medianTimePast(from header: StoredHeader) -> UInt32 {
        var timestamps: [UInt32] = []
        var cursor: StoredHeader? = header

        for _ in 0..<11 {
            guard let current = cursor else { break }
            timestamps.append(current.header.timestamp)
            cursor = getHeaderUnlocked(hash: current.header.prevBlock)
        }

        timestamps.sort()
        return timestamps[timestamps.count / 2]
    }

    private func normalizedChainWork(_ work: Data) -> Data {
        guard work.count == 32 else {
            var padded = Data(repeating: 0, count: 32)
            let copyCount = min(work.count, 32)
            padded.replaceSubrange(0..<copyCount, with: work.prefix(copyCount))
            return padded
        }
        return work
    }

    private func addChainWork(_ lhs: Data, _ rhs: Data) -> Data {
        let left = normalizedChainWork(lhs)
        let right = normalizedChainWork(rhs)
        var result = Data(repeating: 0, count: 32)
        var carry: UInt16 = 0

        for index in 0..<32 {
            let sum = UInt16(left[index]) + UInt16(right[index]) + carry
            result[index] = UInt8(sum & 0xff)
            carry = sum >> 8
        }

        return result
    }

    private func compareChainWork(_ lhs: Data, _ rhs: Data) -> ComparisonResult {
        let left = normalizedChainWork(lhs)
        let right = normalizedChainWork(rhs)

        for index in stride(from: 31, through: 0, by: -1) {
            let leftByte = left[index]
            let rightByte = right[index]
            if leftByte == rightByte { continue }
            return leftByte < rightByte ? .orderedAscending : .orderedDescending
        }

        return .orderedSame
    }

    private func targetHexString(bits: UInt32) -> String {
        guard let target = targetFromBits(bits) else { return "invalid" }
        return Data(target.reversed()).hexString
    }

    private func targetFromBits(_ bits: UInt32) -> Data? {
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

    private func logAuxpowTrustCheckpointIfNeeded(height: Int32) {
        guard !didLogAuxpowWarning else { return }
        didLogAuxpowWarning = true
        let highestCheckpoint = network == .mainnet ? Self.mainnetHighestCheckpoint : Self.testnetHighestCheckpoint
        logger.notice("AuxPoW block at height \(height) <= checkpoint \(highestCheckpoint): trusting checkpoint validation")
    }

    private func logAuxpowSPVTrustIfNeeded(height: Int32) {
        guard !didLogAuxpowSPVTrust else { return }
        didLogAuxpowSPVTrust = true
        logger.notice("AuxPoW block at height \(height): SPV mode - trusting cumulative difficulty (AuxPoW proof not validated)")
    }
}

// MARK: - UInt256

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
