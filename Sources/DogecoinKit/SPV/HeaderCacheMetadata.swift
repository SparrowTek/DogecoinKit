import Foundation

public struct HeaderCacheMetadata: Codable, Sendable, Equatable {
    public let version: Int
    public let network: String
    public let headerCount: Int
    public let tipHeight: Int
    public let tipHash: String
    public let generatedAt: Date
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let checksumSHA256: String

    public init(
        version: Int,
        network: String,
        headerCount: Int,
        tipHeight: Int,
        tipHash: String,
        generatedAt: Date,
        compressedSize: Int,
        uncompressedSize: Int,
        checksumSHA256: String
    ) {
        self.version = version
        self.network = network
        self.headerCount = headerCount
        self.tipHeight = tipHeight
        self.tipHash = tipHash
        self.generatedAt = generatedAt
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.checksumSHA256 = checksumSHA256
    }
}
