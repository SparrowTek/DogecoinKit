import Foundation

/// Unified sync state enum used by both SPV and Electrum
public enum SyncState: Sendable {
    case idle
    case syncing
    case completed
    case failed
}

/// Protocol that both SPVSyncManager and ElectrumSyncManager conform to
public protocol BlockchainSyncManager: AnyObject, Sendable {
    var network: DogecoinNetwork { get }
    var syncState: SyncState { get }
    var currentHeight: Int32 { get }
    var progress: Double { get }
    var delegate: BlockchainSyncDelegate? { get set }
}

/// Delegate protocol for sync events
public protocol BlockchainSyncDelegate: AnyObject, Sendable {
    func syncManager(_ manager: any BlockchainSyncManager, progressUpdated progress: Double, height: Int32)
    func syncManagerDidComplete(_ manager: any BlockchainSyncManager)
    func syncManager(_ manager: any BlockchainSyncManager, didEncounterError error: Error)
    func syncManager(_ manager: any BlockchainSyncManager, didUpdateTransaction txid: String, confirmations: Int)
}

/// Optional delegate methods with default implementations
public extension BlockchainSyncDelegate {
    func syncManager(_ manager: any BlockchainSyncManager, progressUpdated progress: Double, height: Int32) {}
    func syncManager(_ manager: any BlockchainSyncManager, didUpdateTransaction txid: String, confirmations: Int) {}
}
