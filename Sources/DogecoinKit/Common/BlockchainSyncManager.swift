import Foundation

/// Unified sync state enum used by both SPV and Electrum
public enum SyncState: Sendable {
    case idle
    case syncing
    case completed
    case failed
}

/// Protocol that both SPVSyncManager and ElectrumSyncManager conform to
public protocol BlockchainSyncManager: Actor {
    nonisolated var network: DogecoinNetwork { get }
    var syncState: SyncState { get }
    var currentHeight: Int32 { get }
    var progress: Double { get }
    var delegate: (any BlockchainSyncDelegate)? { get set }
}

/// Delegate protocol for sync events
public protocol BlockchainSyncDelegate: AnyObject, Sendable {
    func syncManager(_ manager: any BlockchainSyncManager, progressUpdated progress: Double, height: Int32) async
    func syncManagerDidComplete(_ manager: any BlockchainSyncManager) async
    func syncManager(_ manager: any BlockchainSyncManager, didEncounterError error: Error) async
    func syncManager(_ manager: any BlockchainSyncManager, didUpdateTransaction txid: String, confirmations: Int) async
}

/// Optional delegate methods with default implementations
public extension BlockchainSyncDelegate {
    func syncManager(_ manager: any BlockchainSyncManager, progressUpdated progress: Double, height: Int32) async {}
    func syncManager(_ manager: any BlockchainSyncManager, didUpdateTransaction txid: String, confirmations: Int) async {}
}
