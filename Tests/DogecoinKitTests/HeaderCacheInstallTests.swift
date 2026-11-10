import Foundation
import Testing
@testable import DogecoinKit

/// A pre-built header cache — the app ships one so an SPV wallet does not
/// have to download six million headers — is installed only after it has
/// been checked, and never at the cost of a working local database.
@Suite("Header Cache Install")
struct HeaderCacheInstallTests {
    init() async {
        await Dogecoin.initialize()
    }

    // MARK: - Fixtures

    private func makeDirectory() throws -> URL {
        let directory = TestDirectories.unique()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A header that only has to be *stored*: caches are checked against
    /// genesis and checkpoints, not revalidated block by block.
    private func record(height: Int32, seed: UInt8) -> HeaderRecord {
        HeaderRecord(
            hash: Data(repeating: seed, count: 32),
            prevBlockHash: Data(repeating: seed &- 1, count: 32),
            height: height,
            chainWork: Data(repeating: seed, count: 32),
            version: 0x100,
            merkleRoot: Data(repeating: seed, count: 32),
            timestamp: 1_400_000_000 + UInt32(height),
            bits: 0x1e0ffff0,
            nonce: 0,
            isInBestChain: true
        )
    }

    /// Writes a cache directory: `network`'s genesis block plus `extraHeaders`
    /// more, with metadata claiming `network` (or `claimedNetwork`).
    private func makeCache(
        network: DogecoinNetwork,
        extraHeaders: Int32,
        claimedNetwork: String? = nil,
        claimedTipHeight: Int? = nil
    ) async throws -> URL {
        let directory = try makeDirectory()

        do {
            let chain = HeaderChain(network: network, storageDirectory: directory)
            await chain.setup()
            #expect(await chain.height == 0)
        }

        if extraHeaders > 0 {
            let database = try HeaderDatabase(path: directory.appendingPathComponent("headers.sqlite").path)
            try database.insertHeaders((1...extraHeaders).map { record(height: $0, seed: UInt8($0)) })
        }

        try writeMetadata(
            to: directory,
            network: claimedNetwork ?? (network == .mainnet ? "mainnet" : "testnet"),
            tipHeight: claimedTipHeight ?? Int(extraHeaders)
        )
        return directory
    }

    private func writeMetadata(to directory: URL, network: String, tipHeight: Int) throws {
        let metadata = HeaderCacheMetadata(
            version: 2,
            network: network,
            headerCount: tipHeight + 1,
            tipHeight: tipHeight,
            tipHash: "",
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            compressedSize: 0,
            uncompressedSize: 0,
            checksumSHA256: ""
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
    }

    private func chain(_ network: DogecoinNetwork, storage: URL, cache: URL?) async -> HeaderChain {
        let chain = HeaderChain(network: network, storageDirectory: storage, bundledCacheDirectory: cache)
        await chain.setup()
        return chain
    }

    private func leftovers(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.contains(".installing") }
    }

    // MARK: - Installing

    @Test("A cache is installed when there is no local database")
    func installsIntoEmptyStorage() async throws {
        let cache = try await makeCache(network: .mainnet, extraHeaders: 3)
        let storage = TestDirectories.unique()

        let chain = await chain(.mainnet, storage: storage, cache: cache)

        #expect(await chain.isOpen)
        #expect(await chain.height == 3)
        #expect(await chain.getHeader(height: 0)?.header.hashHex == "1a91e3dace36e2be3bf030a65679fe821aa1d6ef92e7c9902eb318182c355691")
        #expect(leftovers(in: storage).isEmpty)
    }

    @Test("A cache that reaches further replaces the local database")
    func replacesShorterLocalDatabase() async throws {
        let storage = try await makeCache(network: .mainnet, extraHeaders: 1)
        let cache = try await makeCache(network: .mainnet, extraHeaders: 3)

        let chain = await chain(.mainnet, storage: storage, cache: cache)

        #expect(await chain.height == 3)
        #expect(leftovers(in: storage).isEmpty)
    }

    @Test("A local database that is at least as far along is kept")
    func keepsLongerLocalDatabase() async throws {
        let storage = try await makeCache(network: .mainnet, extraHeaders: 5)
        let cache = try await makeCache(network: .mainnet, extraHeaders: 3)

        let chain = await chain(.mainnet, storage: storage, cache: cache)

        #expect(await chain.height == 5)
    }

    // MARK: - Refusing

    @Test("A cache for another network is not installed")
    func refusesOtherNetworkByMetadata() async throws {
        let cache = try await makeCache(network: .mainnet, extraHeaders: 3)
        let storage = TestDirectories.unique()

        let chain = await chain(.testnet, storage: storage, cache: cache)

        // Only testnet's own genesis block, created fresh.
        #expect(await chain.height == 0)
        #expect(await chain.getHeader(height: 0)?.header.hashHex == "bb0a78264637406b6360aad926284d544d7049f45189db5664f3c4d07350559e")
    }

    @Test("A cache whose blocks are not this chain's is not installed, whatever its metadata says")
    func refusesOtherNetworkByContents() async throws {
        let cache = try await makeCache(network: .testnet, extraHeaders: 3, claimedNetwork: "mainnet")
        let storage = try await makeCache(network: .mainnet, extraHeaders: 1)

        let chain = await chain(.mainnet, storage: storage, cache: cache)

        #expect(await chain.height == 1)
        #expect(await chain.getHeader(height: 0)?.header.hashHex == "1a91e3dace36e2be3bf030a65679fe821aa1d6ef92e7c9902eb318182c355691")
        #expect(leftovers(in: storage).isEmpty)
    }

    @Test("A cache that falls short of its own metadata is not installed")
    func refusesShortCache() async throws {
        let cache = try await makeCache(network: .mainnet, extraHeaders: 3, claimedTipHeight: 9)
        let storage = try await makeCache(network: .mainnet, extraHeaders: 1)

        let chain = await chain(.mainnet, storage: storage, cache: cache)

        #expect(await chain.height == 1)
        #expect(leftovers(in: storage).isEmpty)
    }

    @Test("A cache file that is not a database leaves the local database alone")
    func refusesGarbageCache() async throws {
        let cache = try makeDirectory()
        // What a checkout without Git LFS puts where the database should be.
        try Data("version https://git-lfs.github.com/spec/v1\noid sha256:4f18\nsize 1988976640\n".utf8)
            .write(to: cache.appendingPathComponent("headers.sqlite"))
        try writeMetadata(to: cache, network: "mainnet", tipHeight: 6_341_590)
        let storage = try await makeCache(network: .mainnet, extraHeaders: 2)

        let chain = await chain(.mainnet, storage: storage, cache: cache)

        #expect(await chain.height == 2)
        #expect(leftovers(in: storage).isEmpty)
    }

    // MARK: - The real thing

    @Test(
        "A real mainnet cache installs, passes its checkpoint, and sheds the unused indexes",
        .enabled(if: TestEnvironment.headerCacheDirectory != nil)
    )
    func installsRealCache() async throws {
        let cache = URL(fileURLWithPath: try #require(TestEnvironment.headerCacheDirectory), isDirectory: true)
        let storage = TestDirectories.unique()

        let clock = ContinuousClock()
        let start = clock.now
        let chain = await chain(.mainnet, storage: storage, cache: cache)
        print("Installed and opened the cache in \(clock.now - start)")

        #expect(await chain.isOpen)
        #expect(await chain.height > 6_000_000)
        #expect(await chain.getHeader(height: 5_400_000)?.header.hashHex == "cbb1f4ae807da83e13bdf9c28188982938c9ee6bf560c1023f51adac229eef87")
        #expect(leftovers(in: storage).isEmpty)

        let indexes = try #require(await chain.headerDatabase).indexNames()
        #expect(!indexes.contains("headers_on_prevBlockHash"))
        #expect(!indexes.contains("idx_headers_merkle_root"))
    }

    // MARK: - Recovering

    @Test("An unreadable local database is replaced by the cache")
    func recoversFromUnreadableLocalDatabase() async throws {
        let cache = try await makeCache(network: .mainnet, extraHeaders: 3)
        let storage = try makeDirectory()
        try Data(repeating: 0x5A, count: 4096).write(to: storage.appendingPathComponent("headers.sqlite"))

        let chain = await chain(.mainnet, storage: storage, cache: cache)

        #expect(await chain.isOpen)
        #expect(await chain.height == 3)
    }

    @Test("An unreadable local database does not stay in the way without a cache")
    func recoversFromUnreadableLocalDatabaseWithoutCache() async throws {
        let storage = try makeDirectory()
        try Data(repeating: 0x5A, count: 4096).write(to: storage.appendingPathComponent("headers.sqlite"))

        let chain = await chain(.mainnet, storage: storage, cache: nil)

        #expect(await chain.isOpen)
        #expect(await chain.height == 0)
    }
}
