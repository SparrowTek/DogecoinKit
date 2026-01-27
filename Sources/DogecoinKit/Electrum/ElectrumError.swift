import Foundation

public enum ElectrumError: Error, Sendable {
    case connectionFailed(String)
    case connectionTimeout
    case serverDisconnected
    case invalidResponse(String)
    case requestFailed(code: Int, message: String)
    case serializationError(String)
    case sslError(String)
    case noServersAvailable
    case subscriptionFailed(String)
    case transactionBroadcastFailed(String)
    case invalidAddress(String)
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
        case .serializationError(let reason):
            return "Serialization error: \(reason)"
        case .sslError(let reason):
            return "SSL error: \(reason)"
        case .noServersAvailable:
            return "No Electrum servers available"
        case .subscriptionFailed(let reason):
            return "Subscription failed: \(reason)"
        case .transactionBroadcastFailed(let reason):
            return "Transaction broadcast failed: \(reason)"
        case .invalidAddress(let address):
            return "Invalid address: \(address)"
        }
    }
}
