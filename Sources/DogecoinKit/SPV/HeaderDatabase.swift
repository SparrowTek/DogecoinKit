import Foundation
import GRDB
#if canImport(os)
import os.log
#endif

/// Errors from header database operations
public enum HeaderDatabaseError: Error, Sendable, Equatable {
    case databaseNotOpen
    /// A pre-built header cache failed verification and was not installed
    case invalidCache(String)
    /// Another connection extended or replaced the best chain since this
    /// one last looked. Nothing was written.
    case chainChanged
}

extension HeaderDatabaseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .databaseNotOpen:
            return "The header database is not open"
        case .invalidCache(let reason):
            return "The header cache is not usable: \(reason)"
        case .chainChanged:
            return "The header database was changed by another connection"
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
            // A sync writes a batch of headers every second or two. Without
            // a limit the write-ahead log keeps whatever size its largest
            // burst reached, for as long as the file is open.
            try db.execute(sql: "PRAGMA journal_size_limit = 67108864")
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
    init() throws {
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

        // Every query that names a height also asks for the best chain, and
        // `idx_headers_best_chain_height` answers those on its own. The
        // index on height alone — another 76 MB of a full mainnet chain —
        // served nothing else.
        migrator.registerMigration("v3_drop_height_index") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS headers_on_height")
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
            try Self.bestChainHeader(at: height, db)
        }
    }

    /// Get the chain tip (highest header in best chain)
    public func getTip() throws -> HeaderRecord? {
        try dbQueue.read { db in
            try Self.tip(db)
        }
    }

    /// Counts every stored header, side branches included.
    ///
    /// This reads the whole table. The best chain's length is its tip's
    /// height plus one, which ``getTip()`` gives at once.
    public func getHeaderCount() throws -> Int {
        try dbQueue.read { db in
            try HeaderRecord.fetchCount(db)
        }
    }

    /// Get headers in best chain within height range
    public func getHeaders(fromHeight: Int32, toHeight: Int32) throws -> [HeaderRecord] {
        try dbQueue.read { db in
            try HeaderRecord.fetchAll(db, sql: Query.bestChainRange, arguments: [fromHeight, toHeight])
        }
    }

    /// Check if header exists
    public func headerExists(hash: Data) throws -> Bool {
        try dbQueue.read { db in
            try HeaderRecord.exists(db, key: hash)
        }
    }

    /// The statements that find blocks by height. Each names the best
    /// chain, so each is answered by `idx_headers_best_chain_height` — the
    /// only index on height there is. One that did not would read all six
    /// million rows.
    enum Query {
        static let tip = "SELECT * FROM headers WHERE isInBestChain = 1 ORDER BY height DESC LIMIT 1"
        static let bestChainAtHeight = "SELECT * FROM headers WHERE isInBestChain = 1 AND height = ?"
        static let bestChainRange = "SELECT * FROM headers WHERE isInBestChain = 1 AND height >= ? AND height <= ? ORDER BY height"
        static let unflagAbove = "UPDATE headers SET isInBestChain = 0 WHERE isInBestChain = 1 AND height > ?"
        static let unflagOthersAtHeight = "UPDATE headers SET isInBestChain = 0 WHERE isInBestChain = 1 AND height = ? AND hash <> ?"
    }

    private static func tip(_ db: Database) throws -> HeaderRecord? {
        try HeaderRecord.fetchOne(db, sql: Query.tip)
    }

    private static func bestChainHeader(at height: Int32, _ db: Database) throws -> HeaderRecord? {
        try HeaderRecord.fetchOne(db, sql: Query.bestChainAtHeight, arguments: [height])
    }

    // MARK: - Write Operations

    /// Insert a single header
    public func insertHeader(_ record: HeaderRecord) throws {
        try dbQueue.write { db in
            try record.insert(db)
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

    /// Appends `records` to the best chain in one transaction — provided
    /// the chain still ends where the caller believes it does.
    ///
    /// Two connections to one file each keep their own idea of the tip. The
    /// check runs inside the write transaction, so the one that is out of
    /// date finds out here instead of flagging a second block at a height
    /// the other has already filled.
    /// - Parameters:
    ///   - records: Headers extending the best chain, in order
    ///   - expectedTip: The hash of the tip they build on
    /// - Throws: ``HeaderDatabaseError/chainChanged`` when the stored tip is
    ///   another block; nothing is written then
    func appendToBestChain(_ records: [HeaderRecord], after expectedTip: Data) throws {
        guard !records.isEmpty else { return }
        try dbQueue.write { db in
            guard try Self.tip(db)?.hash == expectedTip else {
                throw HeaderDatabaseError.chainChanged
            }
            for record in records {
                try record.insert(db)
            }
        }
    }

    /// Makes `hashes` the best chain above `height`, atomically: a crash
    /// part-way can never leave the database with no best-chain tip.
    /// - Parameter expectedTip: The tip being replaced, when the caller's
    ///   view of it must still hold; a different stored tip then throws
    ///   ``HeaderDatabaseError/chainChanged`` and changes nothing
    func replaceBestChain(above height: Int32, with hashes: [Data], expectedTip: Data? = nil) throws {
        try dbQueue.write { db in
            if let expectedTip {
                guard try Self.tip(db)?.hash == expectedTip else {
                    throw HeaderDatabaseError.chainChanged
                }
            }
            try db.execute(sql: Query.unflagAbove, arguments: [height])
            for hash in hashes {
                try db.execute(
                    sql: "UPDATE headers SET isInBestChain = 1 WHERE hash = ?",
                    arguments: [hash]
                )
            }
        }
    }

    /// Follows parent links down from the tip and makes the best-chain
    /// flags agree with them.
    ///
    /// The flags are what answers "which block is at this height". A file
    /// written by an interrupted or older build can carry a flag on a block
    /// the tip does not descend from, or miss one on a block it does —
    /// and a sync onto that would request and verify against the wrong
    /// block.
    ///
    /// The walk ends early where a block's parent is not stored — a
    /// database need not reach back to the genesis block — and what lies
    /// beyond is left as it is.
    /// - Parameter depth: How many blocks below the tip to check
    /// - Returns: The number of flags corrected
    @discardableResult
    func repairBestChain(depth: Int) throws -> Int {
        try dbQueue.write { db in
            guard var cursor = try Self.tip(db) else { return 0 }

            /// Leaves `record` as the only best-chain block at its height.
            func flagOnly(_ record: HeaderRecord) throws -> Int {
                try db.execute(sql: Query.unflagOthersAtHeight, arguments: [record.height, record.hash])
                var changes = db.changesCount
                if !record.isInBestChain {
                    try db.execute(sql: "UPDATE headers SET isInBestChain = 1 WHERE hash = ?", arguments: [record.hash])
                    changes += 1
                }
                return changes
            }

            var repaired = try flagOnly(cursor)
            var remaining = depth
            while remaining > 0, cursor.height > 0 {
                guard let parent = try HeaderRecord.fetchOne(db, key: cursor.prevBlockHash),
                      parent.height == cursor.height - 1 else {
                    break
                }
                repaired += try flagOnly(parent)
                cursor = parent
                remaining -= 1
            }
            return repaired
        }
    }

    // MARK: - Block Locator

    /// Get block locator hashes for getheaders message
    public func getBlockLocator() throws -> [Data] {
        try dbQueue.read { db in
            var locator: [Data] = []
            var step: Int32 = 1

            guard let tip = try Self.tip(db) else {
                return []
            }

            var height = tip.height

            while height >= 0 {
                if let record = try Self.bestChainHeader(at: height, db) {
                    locator.append(record.hash)
                }

                if locator.count >= 10 {
                    step = step <= 536_870_912 ? step * 2 : step
                }

                height -= step
            }

            // Always include genesis
            if let genesis = try Self.bestChainHeader(at: 0, db), locator.last != genesis.hash {
                locator.append(genesis.hash)
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

    /// How SQLite would run `sql`: one line per step of its plan
    func queryPlan(for sql: String) throws -> [String] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).compactMap { $0["detail"] as String? }
        }
    }

    /// Execute raw SQL without a transaction wrapper (needed for VACUUM)
    public func executeWithoutTransaction(_ sql: String) throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: sql)
        }
    }
}
