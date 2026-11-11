import Foundation

public enum ElectrumError: Error, Sendable, Equatable {
    case connectionFailed(String)
    case connectionTimeout
    case serverDisconnected
    case invalidResponse(String)
    case requestFailed(code: Int, message: String)
    case noServersAvailable
    case invalidAddress(String)

    /// The connection was lost after a transaction was sent for broadcast
    /// and before the server said what it made of it. The transaction may
    /// have been accepted. Nothing that spends the same coins should be
    /// sent until ``ElectrumSyncManager/isTransactionKnown(txid:)`` has
    /// settled the question.
    case broadcastOutcomeUnknown(txid: String)
}

extension ElectrumError {
    /// Whether this error means the connection it happened on is gone: it
    /// closed, or it was dropped because the server stopped answering.
    var endedConnection: Bool {
        switch self {
        case .serverDisconnected, .connectionTimeout:
            true
        default:
            false
        }
    }
}

extension ElectrumError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .connectionTimeout:
            return "Connection timed out"
        case .serverDisconnected:
            return "Server disconnected"
        case .invalidResponse(let reason):
            return "Invalid response: \(reason)"
        case .requestFailed(let code, let message):
            return "Request failed (\(code)): \(message)"
        case .noServersAvailable:
            return "No Electrum servers available"
        case .invalidAddress(let address):
            return "Invalid address: \(address)"
        case .broadcastOutcomeUnknown:
            return "The connection was lost before the server confirmed the transaction"
        }
    }
}
