import Foundation
#if canImport(os)
import os.log
#endif

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

/// Manages the chain of block headers for SPV verification
///
/// Every header is checked the way Dogecoin Core checks it before it can
/// extend or replace the best chain:
///
/// - **Checkpoints** — headers at checkpoint heights must match, and no
///   branch may fork below the last checkpoint the chain has passed.
/// - **Version** — merge-mined versions carry Dogecoin's chain ID; legacy
///   versions are rejected once merged mining began.
/// - **Proof of work** — a merge-mined header's AuxPoW proof must validate
///   (parent scrypt hash against the header's target); any other header's
///   own scrypt hash must meet its target. Headers without a proof are only
///   trusted at or below the highest checkpoint.
/// - **Difficulty** — `nBits` must be exactly what `GetNextWorkRequired`
///   (DigiShield) demands, so nobody can claim easy targets or invent work.
/// - **Time** — later than the median of the previous 11 blocks, and no more
///   than two hours in the future.
///
/// On testnet only the checkpoint, proof-of-work, and time rules apply.
public actor HeaderChain {
    /// The network
    public nonisolated let network: DogecoinNetwork

    /// Storage directory URL
    private let storageURL: URL

    /// SQLite database for header storage
    private var database: HeaderDatabase?

    /// LRU cache for recently accessed headers (by hash)
    private let recentHeaders = LRUCache<Data, StoredHeader>(capacity: 1000)

    /// Cached tip header
    private var tipCache: StoredHeader?

    /// Consensus rules for `network`
    private let rules: ProofOfWorkRules

    /// Logger
    private let logger = Logger(subsystem: "DogecoinKit", category: "HeaderChain")

    /// Cached warning state for auxpow handling
    private var didLogAuxpowWarning = false

    private static let databaseFileName = "headers.sqlite"
    private static let metadataFileName = "metadata.json"

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
        /// The header branches off below a checkpoint the chain already passed
        case forkBelowCheckpoint(height: Int32)
        /// `nBits` differ from what the difficulty adjustment requires
        case incorrectDifficulty(height: Int32, bits: UInt32, expected: UInt32)
        /// The version breaks the chain-ID or merge-mining rules for its height
        case invalidVersion(height: Int32, version: Int32)
        /// The version predates a soft fork active at its height (BIP 66 or 65)
        case obsoleteVersion(height: Int32, version: Int32)
    }

    /// The tip (highest) header
    public var tip: StoredHeader? {
        tipCache
    }

    /// Current chain height
    public var height: Int32 {
        tipCache?.height ?? -1
    }

    /// Create a header chain
    /// - Parameters:
    ///   - network: The Dogecoin network (mainnet or testnet)
    ///   - storageDirectory: Optional custom storage directory for header cache
    ///   - bundledCacheDirectory: Optional directory containing a pre-built
    ///     `headers.sqlite` and its `metadata.json`
    public init(network: DogecoinNetwork = .mainnet, storageDirectory: URL? = nil, bundledCacheDirectory: URL? = nil) {
        self.network = network
        self.rules = .rules(for: network)
        self.storageURL = storageDirectory ?? Self.defaultStorageDirectory(for: network)
        self.bundledCacheDirectory = bundledCacheDirectory
    }

    /// `Caches/DogecoinKit/headers/<network>`, falling back to the temporary
    /// directory on platforms without a user caches directory.
    private static func defaultStorageDirectory(for network: DogecoinNetwork) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("DogecoinKit/headers/\(network == .mainnet ? "mainnet" : "testnet")")
    }

    /// The bundled cache directory passed at init (used by setup)
    private let bundledCacheDirectory: URL?

    /// Whether setup has been performed
    private var isSetUp = false

    /// Perform post-init setup: create storage, open database, load state.
    /// Must be called after init before using the chain. Safe to call multiple times.
    public func setup() {
        guard !isSetUp else { return }
        isSetUp = true
        createStorageDirectory()
        installBundledCacheIfNeeded(from: bundledCacheDirectory)
        openOrCreateDatabase()
        loadTipFromDatabase()
        initializeGenesisIfNeeded()
    }

    /// Whether the header database opened. When it did not — a full disk,
    /// an unwritable directory — the chain can neither read nor store
    /// headers, and a sync built on it could only stall.
    public var isOpen: Bool {
        database != nil
    }

    // MARK: - Database Setup

    private func createStorageDirectory() {
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
    }

    private func openOrCreateDatabase() {
        let dbPath = storageURL.appendingPathComponent(Self.databaseFileName).path
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

    // MARK: - Bundled Cache

    /// What stands where the local database should be
    private enum LocalDatabase {
        /// Nothing worth keeping: no file, no headers, or a file SQLite
        /// cannot read (which has been deleted)
        case none
        /// A working database whose best chain reaches this height
        case tip(Int32)
        /// A file that could not be inspected but is not provably damaged
        case indeterminate
    }

    /// Installs the bundled header cache when it reaches further than the
    /// local database, or when there is no usable local database.
    ///
    /// Runs before the database is opened. The bundled file is copied next
    /// to the live one and checked there first, so a failed or interrupted
    /// install leaves the previous database in place, and a cache for the
    /// wrong network — or one that does not hold the checkpointed chain — is
    /// never installed.
    private func installBundledCacheIfNeeded(from bundledDirectory: URL?) {
        let localURL = storageURL.appendingPathComponent(Self.databaseFileName)
        let local = inspectLocalDatabase(at: localURL)

        guard let bundledDirectory else { return }

        let bundledURL = bundledDirectory.appendingPathComponent(Self.databaseFileName)
        let metadataURL = bundledDirectory.appendingPathComponent(Self.metadataFileName)

        guard FileManager.default.fileExists(atPath: bundledURL.path) else {
            logger.info("No bundled SQLite database found at \(bundledURL.path)")
            return
        }

        let metadata: HeaderCacheMetadata
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            metadata = try decoder.decode(HeaderCacheMetadata.self, from: Data(contentsOf: metadataURL))
        } catch {
            logger.error("Bundled cache has no readable metadata at \(metadataURL.path): \(error.localizedDescription)")
            return
        }

        let networkName = network == .mainnet ? "mainnet" : "testnet"
        guard metadata.network == networkName else {
            logger.error("Bundled cache is for \(metadata.network), not \(networkName). Skipping install.")
            return
        }

        switch local {
        case .none:
            break
        case .tip(let height) where metadata.tipHeight > Int(height):
            break
        case .tip(let height):
            logger.info("Local database is at height \(height), bundled cache at \(metadata.tipHeight). Skipping install.")
            return
        case .indeterminate:
            logger.error("Local database could not be inspected; leaving it in place and skipping the bundled cache.")
            return
        }

        logger.info("Installing bundled cache up to height \(metadata.tipHeight)")

        let stagingURL = storageURL.appendingPathComponent(Self.databaseFileName + ".installing")
        removeDatabaseFiles(at: stagingURL)

        do {
            try FileManager.default.copyItem(at: bundledURL, to: stagingURL)
            try verifyStagedCache(at: stagingURL, expectedTipHeight: metadata.tipHeight)

            // Verification folded everything into the staged file itself,
            // so what is left beside it is empty scaffolding.
            guard writeAheadLogIsEmpty(for: stagingURL) else {
                throw HeaderDatabaseError.invalidCache("its staged copy could not be finalized")
            }
            removeSidecarFiles(of: stagingURL)
            removeDatabaseFiles(at: localURL)
            try FileManager.default.moveItem(at: stagingURL, to: localURL)

            logger.info("Successfully installed bundled header cache")
        } catch {
            logger.error("Failed to install bundled cache: \(error.localizedDescription)")
            removeDatabaseFiles(at: stagingURL)
        }
    }

    /// Looks at the local database before anything is installed over it.
    ///
    /// A file SQLite cannot read is deleted: left in place it would fail to
    /// open on every launch, and nothing would ever replace it.
    private func inspectLocalDatabase(at url: URL) -> LocalDatabase {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }

        do {
            guard let tip = try HeaderDatabase(path: url.path).getTip() else { return .none }
            return .tip(tip.height)
        } catch where HeaderDatabase.indicatesUnreadableFile(error) {
            logger.error("Local header database is unreadable and will be replaced: \(error.localizedDescription)")
            removeDatabaseFiles(at: url)
            return .none
        } catch {
            logger.error("Could not inspect the local header database: \(error.localizedDescription)")
            return .indeterminate
        }
    }

    /// Checks a staged copy of a bundled cache before it replaces anything:
    /// it must open, reach the height its metadata claims, and hold this
    /// network's genesis block and the highest checkpoint it reaches.
    private func verifyStagedCache(at url: URL, expectedTipHeight: Int) throws {
        let staged = try HeaderDatabase(path: url.path)

        guard let tip = try staged.getTip(), Int(tip.height) >= expectedTipHeight else {
            throw HeaderDatabaseError.invalidCache("it does not reach height \(expectedTipHeight)")
        }

        let highestCheckpoint = checkpoints.keys.filter { $0 <= tip.height }.max()
        for height in Set([0, highestCheckpoint].compactMap { $0 }) {
            guard let expectedHash = checkpoints[height],
                  let record = try staged.getHeader(height: height),
                  Data(record.hash.reversed()).hexString == expectedHash else {
                throw HeaderDatabaseError.invalidCache("its block at height \(height) is not on this chain")
            }
        }

        // Opening the copy may have migrated its schema. Fold that back
        // into the file, so that the file alone is the whole database.
        try staged.executeWithoutTransaction("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func writeAheadLogIsEmpty(for url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0 == 0
    }

    /// Removes a database file together with its write-ahead log and index.
    private func removeDatabaseFiles(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        removeSidecarFiles(of: url)
    }

    private func removeSidecarFiles(of url: URL) {
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    // MARK: - Public API

    /// Outcome of adding a batch of headers
    public struct BatchResult: Sendable {
        /// Headers newly stored (headers already known are not counted)
        public let added: Int

        /// Why the batch stopped early, if a header failed validation.
        /// Everything after it was skipped — it would have built on a
        /// rejected header anyway.
        public let failure: ValidationError?

        /// Set when these headers made another branch the best chain: the
        /// height of the last block both branches share. Every block above
        /// it on the best chain is new, even at heights seen before.
        public let forkHeight: Int32?
    }

    /// Add a header to the chain with full validation
    /// - Parameter header: The block header to add
    /// - Returns: true if the header was added successfully
    @discardableResult
    public func addHeader(_ header: BlockHeader) -> Bool {
        addHeader(header, auxpow: nil)
    }

    /// Add a header with AuxPoW data for merged-mining validation
    @discardableResult
    public func addHeader(_ header: BlockHeader, auxpow: AuxPoW?) -> Bool {
        do {
            try addHeaderValidated(header, auxpow: auxpow)
            return true
        } catch {
            logger.warning("Header validation failed: \(String(describing: error))")
            return false
        }
    }

    /// Add a header with validation, throwing on errors
    public func addHeaderValidated(_ header: BlockHeader) throws {
        try addHeaderValidated(header, auxpow: nil)
    }

    /// Add a header with validation and optional AuxPoW data
    public func addHeaderValidated(_ header: BlockHeader, auxpow: AuxPoW?) throws {
        _ = try store(header, auxpow: auxpow)
    }

    private enum StoreOutcome {
        case alreadyKnown
        /// Stored, extending the best chain or a side branch
        case stored
        /// Stored, and its branch replaced the best chain above `forkHeight`
        case reorganized(forkHeight: Int32)
    }

    /// Add multiple headers
    public func addHeaders(_ headers: [BlockHeader]) -> Int {
        addHeaders(headers.map { HeadersMessage.Entry(header: $0) }).added
    }

    /// Add headers received from a peer, stopping at the first invalid one
    public func addHeaders(_ entries: [HeadersMessage.Entry]) -> BatchResult {
        var added = 0
        var forkHeight: Int32?
        for entry in entries {
            do {
                switch try store(entry.header, auxpow: entry.auxpow) {
                case .alreadyKnown:
                    break
                case .stored:
                    added += 1
                case .reorganized(let height):
                    added += 1
                    forkHeight = min(forkHeight ?? height, height)
                }
            } catch let error as ValidationError {
                logger.warning("Header validation failed: \(String(describing: error))")
                return BatchResult(added: added, failure: error, forkHeight: forkHeight)
            } catch {
                return BatchResult(added: added, failure: .databaseError(error), forkHeight: forkHeight)
            }
        }
        return BatchResult(added: added, failure: nil, forkHeight: forkHeight)
    }

    /// Flush is a no-op with SQLite (writes are immediate)
    public func flush() {
        // SQLite writes are immediate, no pending buffer
    }

    /// Get a header by hash
    public func getHeader(hash: Data) -> StoredHeader? {
        getCachedHeader(hash: hash)
    }

    /// Get a header by height (from best chain)
    public func getHeader(height: Int32) -> StoredHeader? {
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
        guard let db = database,
              let record = try? db.getHeader(hash: hash) else {
            return false
        }

        return record.isInBestChain
    }

    /// Get block locator hashes for getheaders message
    public func getBlockLocator() -> [Data] {
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

    // MARK: - Storing

    /// Validates and stores one header.
    private func store(_ header: BlockHeader, auxpow: AuxPoW?) throws -> StoreOutcome {
        guard let db = database else {
            throw ValidationError.databaseError(HeaderDatabaseError.databaseNotOpen)
        }

        let hash = header.hash

        // Check if we already have this header
        if recentHeaders.contains(hash) {
            return .alreadyKnown
        }
        do {
            if try db.headerExists(hash: hash) {
                return .alreadyKnown
            }
        } catch {
            throw ValidationError.databaseError(error)
        }

        guard let parent = getCachedHeader(hash: header.prevBlock) else {
            logger.warning("Parent not found for header \(header.hashHex)")
            throw ValidationError.invalidPreviousBlock
        }

        let newHeight = parent.height + 1

        try validateCheckpoint(header: header, height: newHeight)
        try rejectForkBelowCheckpoint(height: newHeight)
        try validateVersion(header, height: newHeight)
        let target = try validateProofOfWork(header, auxpow: auxpow, height: newHeight)
        try validateDifficulty(header, parent: parent, height: newHeight)
        try validateTimestamp(header: header, parent: parent)
        try validateSoftForkVersion(header, height: newHeight)

        let chainWork = UInt256(littleEndian: parent.chainWork) &+ ProofOfWorkRules.work(forTarget: target)
        let stored = StoredHeader(header: header, height: newHeight, chainWork: chainWork.littleEndianData)

        // Extends the best chain, or overtakes it with strictly more work.
        // Equal work keeps the current tip (first seen wins, as in Core).
        let currentTip = tipCache
        let isNewTip = currentTip.map { stored.header.prevBlock == $0.header.hash } ?? true
        let shouldReorg = !isNewTip && currentTip.map { chainWork > UInt256(littleEndian: $0.chainWork) } == true

        // A header that overtakes the best chain is stored unflagged; the
        // reorganization then flags its whole branch in one transaction. If
        // that fails, the old chain is still the one, consistently, marked
        // best — and the next header on the new branch tries again.
        let record = HeaderRecord(storedHeader: stored, isInBestChain: isNewTip)
        do {
            try db.insertHeader(record)
        } catch {
            throw ValidationError.databaseError(error)
        }

        recentHeaders.set(hash, stored)

        if isNewTip {
            tipCache = stored
        } else if shouldReorg, let currentTip {
            return .reorganized(forkHeight: try reorganize(from: currentTip, to: stored, db: db))
        }

        return .stored
    }

    // MARK: - Validation Methods

    private var checkpoints: [Int32: String] {
        network == .mainnet ? Self.mainnetCheckpoints : Self.testnetCheckpoints
    }

    private var highestCheckpoint: Int32 {
        checkpoints.keys.max() ?? 0
    }

    private func validateCheckpoint(header: BlockHeader, height: Int32) throws {
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

    /// Core's "bad-fork-prior-to-checkpoint": once the chain has passed a
    /// checkpoint, nothing may branch off below it. Without this, a branch
    /// that never reaches the next checkpoint could rewrite history.
    private func rejectForkBelowCheckpoint(height: Int32) throws {
        guard let tipHeight = tipCache?.height,
              let lastPassed = checkpoints.keys.filter({ $0 <= tipHeight }).max(),
              height < lastPassed else {
            return
        }
        throw ValidationError.forkBelowCheckpoint(height: height)
    }

    /// Core's chain-ID and merge-mining activation rules. These decide which
    /// proof of work applies, so they run before it is checked.
    private func validateVersion(_ header: BlockHeader, height: Int32) throws {
        guard rules.enforcesContextualRules,
              !rules.allowsVersion(of: header, atHeight: height) else {
            return
        }
        throw ValidationError.invalidVersion(height: height, version: header.version)
    }

    /// Core's minimum versions for active soft forks — checked last, as in
    /// `ContextualCheckBlockHeader`.
    private func validateSoftForkVersion(_ header: BlockHeader, height: Int32) throws {
        guard rules.enforcesContextualRules,
              !rules.meetsSoftForkVersion(of: header, atHeight: height) else {
            return
        }
        throw ValidationError.obsoleteVersion(height: height, version: header.version)
    }

    /// Checks the header's proof of work against the target its `nBits` claim.
    /// - Returns: The decoded target
    private func validateProofOfWork(_ header: BlockHeader, auxpow: AuxPoW?, height: Int32) throws -> UInt256 {
        guard let target = rules.target(forBits: header.bits) else {
            throw ValidationError.invalidDifficulty(bits: header.bits)
        }

        if header.isAuxPoW {
            if let auxpow {
                do {
                    try auxpow.validate(for: header, rules: rules)
                } catch let error as AuxPoW.ValidationError {
                    throw ValidationError.auxPowValidationFailed(error)
                }
            } else if height <= highestCheckpoint {
                // Headers that arrive without their proof (a bundled cache,
                // say) are trusted only where checkpoints pin the chain.
                logAuxpowTrustCheckpointIfNeeded(height: height)
            } else {
                throw ValidationError.auxPowRequired(height: height)
            }
        } else {
            guard let powHash = header.scryptHashValue, powHash <= target else {
                logger.error("PoW validation failed: hash \(header.hashHex) does not meet target")
                throw ValidationError.invalidProofOfWork(hash: header.hashHex, target: target.description)
            }
        }

        return target
    }

    /// `nBits` must be exactly what the difficulty adjustment demands.
    private func validateDifficulty(_ header: BlockHeader, parent: StoredHeader, height: Int32) throws {
        guard rules.enforcesContextualRules else { return }

        guard let expected = rules.requiredBits(after: parent, ancestor: { ancestor(of: parent, atHeight: $0) }) else {
            throw ValidationError.invalidPreviousBlock
        }

        guard header.bits == expected else {
            throw ValidationError.incorrectDifficulty(height: height, bits: header.bits, expected: expected)
        }
    }

    private func validateTimestamp(header: BlockHeader, parent: StoredHeader) throws {
        let medianTime = medianTimePast(from: parent)

        guard header.timestamp > medianTime else {
            throw ValidationError.invalidTimestamp(timestamp: header.timestamp)
        }

        let currentTime = UInt32(clamping: Int64(Date().timeIntervalSince1970))
        let (maxFutureTime, overflow) = currentTime.addingReportingOverflow(Self.maxTimeDrift)

        guard overflow || header.timestamp <= maxFutureTime else {
            throw ValidationError.futureTooFar(timestamp: header.timestamp)
        }
    }

    // MARK: - Chain Reorganization

    /// Makes `newTip`'s branch the best chain.
    /// - Returns: The height of the last block the two branches share
    private func reorganize(from currentTip: StoredHeader, to newTip: StoredHeader, db: HeaderDatabase) throws -> Int32 {
        guard let commonAncestor = findCommonAncestor(between: currentTip, and: newTip) else {
            logger.error("Unable to find common ancestor for reorg")
            throw ValidationError.invalidPreviousBlock
        }

        var cursor: StoredHeader? = newTip
        var newChainHashes: [Data] = []
        while let header = cursor, header.height > commonAncestor.height {
            newChainHashes.append(header.header.hash)
            cursor = getCachedHeader(hash: header.header.prevBlock)
        }

        // Flagging a branch with a hole in it would leave heights where no
        // block is on the best chain.
        guard cursor?.header.hash == commonAncestor.header.hash else {
            logger.error("New branch does not lead back to the common ancestor")
            throw ValidationError.invalidPreviousBlock
        }

        do {
            try db.replaceBestChain(above: commonAncestor.height, with: newChainHashes)
        } catch {
            throw ValidationError.databaseError(error)
        }

        tipCache = newTip
        logger.info("Chain reorganized at height \(commonAncestor.height), new tip at \(newTip.height)")
        return commonAncestor.height
    }

    private func findCommonAncestor(between first: StoredHeader, and second: StoredHeader) -> StoredHeader? {
        var a: StoredHeader? = first
        var b: StoredHeader? = second

        while let aHeader = a, let bHeader = b, aHeader.height != bHeader.height {
            if aHeader.height > bHeader.height {
                a = getCachedHeader(hash: aHeader.header.prevBlock)
            } else {
                b = getCachedHeader(hash: bHeader.header.prevBlock)
            }
        }

        while let aHeader = a, let bHeader = b {
            if aHeader.header.hash == bHeader.header.hash {
                return aHeader
            }
            a = getCachedHeader(hash: aHeader.header.prevBlock)
            b = getCachedHeader(hash: bHeader.header.prevBlock)
        }

        return nil
    }

    private func getCachedHeader(hash: Data) -> StoredHeader? {
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

    /// The ancestor of `header` at `height`, following parent links so it
    /// works on any branch, not only the best chain.
    private func ancestor(of header: StoredHeader, atHeight height: Int32) -> StoredHeader? {
        guard height >= 0, height <= header.height else { return nil }
        var cursor = header
        while cursor.height > height {
            guard let previous = getCachedHeader(hash: cursor.header.prevBlock) else { return nil }
            cursor = previous
        }
        return cursor
    }

    // MARK: - Genesis Block

    private func initializeGenesisIfNeeded() {
        guard let db = database else { return }

        // Check if genesis exists
        do {
            if let _ = try db.getHeader(height: 0) {
                return
            }
        } catch {
            // Continue to create genesis
        }

        let genesisMerkleRootHex = "5b2a3f53f605d62c53e62932dac6925e3d74afa5a4b459745c36d42d0ed26a69"
        guard let merkleRootBigEndian = Data(hexString: genesisMerkleRootHex) else {
            logger.error("Failed to decode genesis merkle root hex — skipping genesis insert")
            return
        }
        let merkleRootInternal = Data(merkleRootBigEndian.reversed())

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

        // Verify genesis hash matches expected checkpoint
        if let expectedHash = checkpoints[0], genesis.hashHex != expectedHash {
            logger.error("Genesis hash mismatch: expected \(expectedHash), got \(genesis.hashHex)")
            return
        }

        let genesisWork = rules.target(forBits: genesis.bits).map(ProofOfWorkRules.work(forTarget:)) ?? .zero
        let stored = StoredHeader(header: genesis, height: 0, chainWork: genesisWork.littleEndianData)

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

    // MARK: - Helpers

    private func medianTimePast(from header: StoredHeader) -> UInt32 {
        var timestamps: [UInt32] = []
        var cursor: StoredHeader? = header

        for _ in 0..<11 {
            guard let current = cursor else { break }
            timestamps.append(current.header.timestamp)
            cursor = getCachedHeader(hash: current.header.prevBlock)
        }

        timestamps.sort()
        return timestamps[timestamps.count / 2]
    }

    private func logAuxpowTrustCheckpointIfNeeded(height: Int32) {
        guard !didLogAuxpowWarning else { return }
        didLogAuxpowWarning = true
        logger.notice("AuxPoW block at height \(height) <= checkpoint \(self.highestCheckpoint): trusting checkpoint validation")
    }
}
