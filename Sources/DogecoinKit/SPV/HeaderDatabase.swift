import Foundation
import GRDB
#if canImport(os)
import os.log
#endif

/// Errors from header database operations
public enum HeaderDatabaseError: Error, Sendable {
    case databaseNotOpen
    case migrationFailed(Error)
    case queryFailed(Error)
    case insertFailed(Error)
    /// A pre-built header cache failed verification and was not installed
    case invalidCache(String)
}

extension HeaderDatabaseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .databaseNotOpen:
            return "The header database is not open"
        case .migrationFailed(let error):
            return "Header database migration failed: \(error.localizedDescription)"
        case .queryFailed(let error):
            return "Header database query failed: \(error.localizedDescription)"
        case .insertFailed(let error):
            return "Header database insert failed: \(error.localizedDescription)"
        case .invalidCache(let reason):
            return "The header cache is not usable: \(reason)"
        }
    }
}

/// SQLite database for block header storage
public final class HeaderDatabase: Sendable {
    /// The database queue for thread-safe access
    private let dbQueue: DatabaseQueue

    /// Logger
    private let logger = Logger(subsystem: "DogecoinKit", category: "HeaderDatabase")

    /// Initialize with a database file path
    /// - Parameter path: Path to the SQLite database file
    public init(path: String) throws {
        var config = Configuration()
        // Another connection to the same file (a second sync manager, a
        // cache check) makes a write wait briefly instead of failing.
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            // WAL keeps commits cheap: one append instead of a journal
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            // Optimize for our read-heavy workload
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            // 64MB cache
            try db.execute(sql: "PRAGMA cache_size = -64000")
        }

        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        try migrate()
        logger.info("Opened header database at \(path)")
    }

    /// Whether `error` says the file itself is damaged, or is not a
    /// database at all — as opposed to a failure that may not repeat.
    static func indicatesUnreadableFile(_ error: Error) -> Bool {
        guard let error = error as? DatabaseError else { return false }
        return error.resultCode == .SQLITE_NOTADB || error.resultCode == .SQLITE_CORRUPT
    }

    /// Opens an existing database for reading only.
    ///
    /// Nothing is written: no journal mode change, no migration. Use it to
    /// inspect or verify a header database without altering it — opening
    /// one with ``init(path:)`` rewrites its header and can migrate it.
    ///
    /// SQLite can only read a database left in write-ahead-log mode this
    /// way while its `-wal` and `-shm` files are still beside it, as they
    /// are after ``init(path:)`` has opened it on Apple platforms.
    /// - Parameter path: Path to the SQLite database file
    public init(readOnlyPath path: String) throws {
        var config = Configuration()
        config.readonly = true
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
    }

    /// Initialize with an in-memory database (for testing)
    public init() throws {
        self.dbQueue = try DatabaseQueue()
        try migrate()
    }

    // MARK: - Migration

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_headers") { db in
            try db.create(table: "headers") { t in
                t.column("hash", .blob).primaryKey()
                t.column("prevBlockHash", .blob).notNull().indexed()
                t.column("height", .integer).notNull().indexed()
                t.column("chainWork", .blob).notNull()
                t.column("version", .integer).notNull()
                t.column("merkleRoot", .blob).notNull()
                t.column("timestamp", .integer).notNull()
                t.column("bits", .integer).notNull()
                t.column("nonce", .integer).notNull()
                t.column("isInBestChain", .boolean).notNull().defaults(to: false)
            }

            // Index for finding best chain tip
            try db.create(
                index: "idx_headers_best_chain_height",
                on: "headers",
                columns: ["isInBestChain", "height"]
            )

            // Index for merkle proof lookups
            try db.create(
                index: "idx_headers_merkle_root",
                on: "headers",
                columns: ["merkleRoot"]
            )
        }

        // No query ever filtered on the previous-block hash or the merkle
        // root, yet their indexes were a quarter of the database — about
        // 525 MB of a full mainnet chain — and more than doubled the pages
        // every insert touches. Dropping them frees those pages for reuse;
        // the file itself only shrinks when the database is next exported
        // or vacuumed.
        migrator.registerMigration("v2_drop_unused_indexes") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS headers_on_prevBlockHash")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_headers_merkle_root")
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Read Operations

    /// Get header by hash
    public func getHeader(hash: Data) throws -> HeaderRecord? {
        try dbQueue.read { db in
            try HeaderRecord.fetchOne(db, key: hash)
        }
    }

    /// Get header by height (from best chain)
    public func getHeader(height: Int32) throws -> HeaderRecord? {
        try dbQueue.read { db in
            try HeaderRecord
                .filter(HeaderRecord.Columns.height == height)
                .filter(HeaderRecord.Columns.isInBestChain == true)
                .fetchOne(db)
        }
    }

    /// Get the chain tip (highest header in best chain)
    public func getTip() throws -> HeaderRecord? {
        try dbQueue.read { db in
            try HeaderRecord
                .filter(HeaderRecord.Columns.isInBestChain == true)
                .order(HeaderRecord.Columns.height.desc)
                .fetchOne(db)
        }
    }

    /// Get total header count
    public func getHeaderCount() throws -> Int {
        try dbQueue.read { db in
            try HeaderRecord.fetchCount(db)
        }
    }

    /// Get headers in best chain within height range
    public func getHeaders(fromHeight: Int32, toHeight: Int32) throws -> [HeaderRecord] {
        try dbQueue.read { db in
            try HeaderRecord
                .filter(HeaderRecord.Columns.isInBestChain == true)
                .filter(HeaderRecord.Columns.height >= fromHeight)
                .filter(HeaderRecord.Columns.height <= toHeight)
                .order(HeaderRecord.Columns.height)
                .fetchAll(db)
        }
    }

    /// Check if header exists
    public func headerExists(hash: Data) throws -> Bool {
        try dbQueue.read { db in
            try HeaderRecord.exists(db, key: hash)
        }
    }

    // MARK: - Write Operations

    /// Insert a single header
    public func insertHeader(_ record: HeaderRecord) throws {
        try dbQueue.write { db in
            try record.insert(db)
        }
    }

    /// Insert or update a single header
    public func upsertHeader(_ record: HeaderRecord) throws {
        try dbQueue.write { db in
            try record.save(db)
        }
    }

    /// Insert multiple headers in a transaction (for bulk loading)
    public func insertHeaders(_ records: [HeaderRecord]) throws {
        try dbQueue.write { db in
            for record in records {
                try record.insert(db)
            }
        }
    }

    /// Insert headers in batches with progress callback
    public func insertHeadersBatched(
        _ records: [HeaderRecord],
        batchSize: Int = 10000,
        progress: ((Int, Int) -> Void)? = nil
    ) throws {
        let total = records.count
        var inserted = 0

        for batch in records.chunks(ofCount: max(1, batchSize)) {
            try dbQueue.write { db in
                for record in batch {
                    try record.insert(db)
                }
            }
            inserted += batch.count
            progress?(inserted, total)
        }
    }

    /// Update header's best chain status
    public func updateBestChainStatus(hash: Data, isInBestChain: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE headers SET isInBestChain = ? WHERE hash = ?",
                arguments: [isInBestChain, hash]
            )
        }
    }

    /// Mark range of heights as best chain
    public func markBestChain(fromHeight: Int32, toHeight: Int32, hashes: [Data]) throws {
        try dbQueue.write { db in
            // Clear old best chain markers in range
            try db.execute(
                sql: """
                    UPDATE headers
                    SET isInBestChain = 0
                    WHERE height >= ? AND height <= ?
                    """,
                arguments: [fromHeight, toHeight]
            )

            // Set new best chain markers
            for hash in hashes {
                try db.execute(
                    sql: "UPDATE headers SET isInBestChain = 1 WHERE hash = ?",
                    arguments: [hash]
                )
            }
        }
    }

    /// Makes `hashes` the best chain above `height`, atomically: a crash
    /// part-way can never leave the database with no best-chain tip.
    public func replaceBestChain(above height: Int32, with hashes: [Data]) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE headers SET isInBestChain = 0 WHERE height > ?",
                arguments: [height]
            )
            for hash in hashes {
                try db.execute(
                    sql: "UPDATE headers SET isInBestChain = 1 WHERE hash = ?",
                    arguments: [hash]
                )
            }
        }
    }

    /// Clear all best chain markers (used during reorganization)
    public func clearBestChainMarkers(aboveHeight: Int32) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE headers SET isInBestChain = 0 WHERE height > ?",
                arguments: [aboveHeight]
            )
        }
    }

    // MARK: - Block Locator

    /// Get block locator hashes for getheaders message
    public func getBlockLocator() throws -> [Data] {
        try dbQueue.read { db in
            var locator: [Data] = []
            var step: Int32 = 1

            guard let tip = try HeaderRecord
                .filter(HeaderRecord.Columns.isInBestChain == true)
                .order(HeaderRecord.Columns.height.desc)
                .fetchOne(db) else {
                return []
            }

            var height = tip.height

            while height >= 0 {
                if let record = try HeaderRecord
                    .filter(HeaderRecord.Columns.height == height)
                    .filter(HeaderRecord.Columns.isInBestChain == true)
                    .fetchOne(db) {
                    locator.append(record.hash)
                }

                if locator.count >= 10 {
                    step = step <= 536_870_912 ? step * 2 : step
                }

                height -= step
            }

            // Always include genesis
            if let genesis = try HeaderRecord
                .filter(HeaderRecord.Columns.height == 0)
                .fetchOne(db) {
                if locator.last != genesis.hash {
                    locator.append(genesis.hash)
                }
            }

            return locator
        }
    }

    // MARK: - Utility

    /// Names of the indexes on the headers table
    func indexNames() throws -> Set<String> {
        try dbQueue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'headers'"))
        }
    }

    /// Access database for raw queries (use sparingly)
    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    /// Access database for raw writes (use sparingly)
    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }

    /// Execute raw SQL without a transaction wrapper (needed for VACUUM)
    public func executeWithoutTransaction(_ sql: String) throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: sql)
        }
    }

    /// Get the underlying database queue (for observation)
    public var databaseQueue: DatabaseQueue {
        dbQueue
    }
}

// MARK: - Array Chunking Helper

private extension Array {
    func chunks(ofCount count: Int) -> [[Element]] {
        stride(from: 0, to: self.count, by: count).map {
            Array(self[$0..<Swift.min($0 + count, self.count)])
        }
    }
}
