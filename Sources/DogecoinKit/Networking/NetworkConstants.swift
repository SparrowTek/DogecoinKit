import Foundation

/// Network-related constants for Dogecoin P2P protocol
public enum NetworkConstants {
    /// Protocol version (based on Dogecoin Core)
    public static let protocolVersion: UInt32 = 70015

    /// Magic bytes for mainnet
    public static let mainnetMagic: UInt32 = 0xC0C0C0C0

    /// Magic bytes for testnet
    public static let testnetMagic: UInt32 = 0xFCC1B7DC

    /// Default mainnet port
    public static let mainnetPort: UInt16 = 22556

    /// Default testnet port
    public static let testnetPort: UInt16 = 44556

    /// User agent string
    public static let userAgent = "/DogecoinKit:0.1.0/"

    /// Services supported (NODE_NETWORK)
    public static let services: UInt64 = 1

    /// Maximum message payload size (32 MB)
    public static let maxPayloadSize: UInt32 = 32 * 1024 * 1024

    /// Command name length in message header
    public static let commandLength = 12

    /// Message header size (4 magic + 12 command + 4 length + 4 checksum)
    public static let headerSize = 24

    /// DNS seeds for mainnet
    public static let mainnetSeeds = [
        "seed.multidoge.org",
        "seed2.multidoge.org",
        "seed.dogecoin.com",
        "seed.dogechain.info"
    ]

    /// DNS seeds for testnet
    public static let testnetSeeds = [
        "testnetseed.jrn.me.uk"
    ]

    /// Get magic bytes for network
    public static func magic(for network: DogecoinNetwork) -> UInt32 {
        switch network {
        case .mainnet: return mainnetMagic
        case .testnet: return testnetMagic
        }
    }

    /// Get default port for network
    public static func port(for network: DogecoinNetwork) -> UInt16 {
        switch network {
        case .mainnet: return mainnetPort
        case .testnet: return testnetPort
        }
    }

    /// Get DNS seeds for network
    public static func seeds(for network: DogecoinNetwork) -> [String] {
        switch network {
        case .mainnet: return mainnetSeeds
        case .testnet: return testnetSeeds
        }
    }
}
