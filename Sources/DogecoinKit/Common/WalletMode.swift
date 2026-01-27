import Foundation

/// Defines the synchronization method for the wallet
public enum WalletMode: Int, Codable, Sendable, CaseIterable {
    /// Electrum mode - Fast, lightweight, server-based (DEFAULT)
    case electrum = 0

    /// SPV mode - Full header verification, better privacy, larger storage
    case spv = 1

    /// User-friendly display name
    public var displayName: String {
        switch self {
        case .electrum:
            return "Standard"
        case .spv:
            return "Enhanced Privacy"
        }
    }

    /// Short technical name
    public var technicalName: String {
        switch self {
        case .electrum:
            return "Electrum"
        case .spv:
            return "SPV"
        }
    }

    /// Description for UI
    public var description: String {
        switch self {
        case .electrum:
            return "Fast sync, minimal storage (~50 MB). Recommended for most users."
        case .spv:
            return "Downloads all block headers locally for independent verification. Better privacy but requires ~2 GB storage."
        }
    }

    /// Detailed explanation
    public var detailedDescription: String {
        switch self {
        case .electrum:
            return """
            Standard mode connects to Dogecoin Electrum servers to fetch your balance and transaction history. \
            This is the fastest way to get started and uses minimal storage.

            Trade-off: Electrum servers can see which addresses you query. Your funds remain secure and under your control.
            """
        case .spv:
            return """
            Enhanced Privacy mode downloads and verifies all Dogecoin block headers locally (~6 million headers). \
            This provides cryptographic proof of your transactions without revealing your addresses to any server.

            Trade-off: Requires ~2 GB of storage and initial sync may take 10-30 minutes.
            """
        }
    }

    /// Estimated storage requirement
    public var estimatedStorage: String {
        switch self {
        case .electrum:
            return "~50 MB"
        case .spv:
            return "~2 GB"
        }
    }

    /// Icon name (SF Symbols)
    public var iconName: String {
        switch self {
        case .electrum:
            return "bolt.fill"
        case .spv:
            return "shield.checkered"
        }
    }

    /// Whether this mode is recommended for new users
    public var isRecommended: Bool {
        self == .electrum
    }
}
