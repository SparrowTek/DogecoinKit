import Compression
import Foundation
import Testing
@testable import DogecoinKit

@Suite("HeaderCacheManager Tests")
struct HeaderCacheManagerTests {
    @Test("shouldUseBundledCache returns true when no local cache exists")
    func testShouldUseBundledCacheNoLocal() async {
        let manager = HeaderCacheManager()
        let bundledMetadata = makeMetadata(headerCount: 1000)

        let result = await manager.shouldUseBundledCache(localMetadata: nil, bundledMetadata: bundledMetadata)
        #expect(result == true)
    }

    @Test("shouldUseBundledCache returns true when bundled has more headers")
    func testShouldUseBundledCacheMoreHeaders() async {
        let manager = HeaderCacheManager()
        let localMetadata = makeMetadata(headerCount: 500)
        let bundledMetadata = makeMetadata(headerCount: 1000)

        let result = await manager.shouldUseBundledCache(localMetadata: localMetadata, bundledMetadata: bundledMetadata)
        #expect(result == true)
    }

    @Test("shouldUseBundledCache returns false when local has more headers")
    func testShouldUseBundledCacheFewerHeaders() async {
        let manager = HeaderCacheManager()
        let localMetadata = makeMetadata(headerCount: 1000)
        let bundledMetadata = makeMetadata(headerCount: 500)

        let result = await manager.shouldUseBundledCache(localMetadata: localMetadata, bundledMetadata: bundledMetadata)
        #expect(result == false)
    }

    @Test("shouldUseBundledCache returns false when header counts are equal")
    func testShouldUseBundledCacheEqualHeaders() async {
        let manager = HeaderCacheManager()
        let localMetadata = makeMetadata(headerCount: 1000)
        let bundledMetadata = makeMetadata(headerCount: 1000)

        let result = await manager.shouldUseBundledCache(localMetadata: localMetadata, bundledMetadata: bundledMetadata)
        #expect(result == false)
    }

    @Test("loadMetadata returns nil for non-existent directory")
    func testLoadMetadataNonExistent() async {
        let manager = HeaderCacheManager()
        let nonExistentURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let result = await manager.loadMetadata(from: nonExistentURL)
        #expect(result == nil)
    }

    @Test("loadMetadata successfully loads valid metadata")
    func testLoadMetadataValid() async throws {
        let manager = HeaderCacheManager()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let metadata = makeMetadata(headerCount: 5000)
        let metadataURL = tempDir.appendingPathComponent("metadata.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL)

        let loaded = await manager.loadMetadata(from: tempDir)
        #expect(loaded != nil)
        #expect(loaded?.headerCount == 5000)
        #expect(loaded?.network == "mainnet")
    }

    @Test("verifyInstalledCache returns false for missing headers file")
    func testVerifyInstalledCacheMissing() async {
        let manager = HeaderCacheManager()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let metadata = makeMetadata(headerCount: 100)

        let result = await manager.verifyInstalledCache(at: tempDir, metadata: metadata)
        #expect(result == false)
    }

    @Test("Block work is derived from difficulty bits")
    func testBlockWorkDependsOnBits() {
        let harderBits: UInt32 = 0x1e0ffff0
        let easierBits: UInt32 = 0x1f00ffff

        let harderWork = HeaderCacheManager.blockWork(bits: harderBits)
        let easierWork = HeaderCacheManager.blockWork(bits: easierBits)

        #expect(harderWork != nil)
        #expect(easierWork != nil)
        #expect(harderWork != easierWork)

        var placeholder = Data(repeating: 0, count: 32)
        placeholder[0] = 1
        #expect(harderWork != placeholder)
    }

    @Test("Invalid bits fail block work calculation")
    func testBlockWorkRejectsInvalidBits() {
        #expect(HeaderCacheManager.blockWork(bits: 0) == nil)
        #expect(HeaderCacheManager.blockWork(bits: 0x1e800001) == nil)
    }

    private func makeMetadata(headerCount: Int) -> HeaderCacheMetadata {
        HeaderCacheMetadata(
            version: 1,
            network: "mainnet",
            headerCount: headerCount,
            tipHeight: headerCount - 1,
            tipHash: "0000000000000000000000000000000000000000000000000000000000000000",
            generatedAt: Date(),
            compressedSize: headerCount * 40,
            uncompressedSize: headerCount * 80,
            checksumSHA256: "abc123"
        )
    }
}

@Suite("LZFSEDecompressor Tests")
struct LZFSEDecompressorTests {
    @Test("Decompression of valid LZFSE data succeeds")
    func testDecompressValidData() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let originalData = Data(repeating: 0xAB, count: 1000)
        let compressedURL = tempDir.appendingPathComponent("test.lzfse")

        try compressLZFSE(data: originalData, to: compressedURL)

        let decompressed = try LZFSEDecompressor.decompress(from: compressedURL)
        #expect(decompressed == originalData)
    }

    @Test("Decompression with chunk handler processes all data")
    func testDecompressWithChunkHandler() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let originalData = Data(repeating: 0xCD, count: 5000)
        let compressedURL = tempDir.appendingPathComponent("test.lzfse")

        try compressLZFSE(data: originalData, to: compressedURL)

        var chunks: [Data] = []
        try LZFSEDecompressor.decompress(from: compressedURL) { chunk in
            chunks.append(chunk)
        }

        let reassembled = chunks.reduce(Data()) { $0 + $1 }
        #expect(reassembled == originalData)
    }

    @Test("Decompression of non-existent file throws appropriate error")
    func testDecompressNonExistentFile() {
        let nonExistentURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        #expect(throws: LZFSEError.self) {
            _ = try LZFSEDecompressor.decompress(from: nonExistentURL)
        }
    }

    private func compressLZFSE(data: Data, to url: URL) throws {
        let compressed = try data.withUnsafeBytes { srcBuffer -> Data in
            guard let srcPtr = srcBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw LZFSEError.decompressionFailed
            }
            var dstBuffer = [UInt8](repeating: 0, count: data.count + 1024)

            let compressedSize = dstBuffer.withUnsafeMutableBufferPointer { dstPtr -> Int in
                guard let dstBase = dstPtr.baseAddress else { return 0 }
                return compression_encode_buffer(
                    dstBase,
                    dstPtr.count,
                    srcPtr,
                    srcBuffer.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }

            guard compressedSize > 0 else {
                throw LZFSEError.decompressionFailed
            }

            return Data(dstBuffer.prefix(compressedSize))
        }

        try compressed.write(to: url)
    }
}
