import Foundation

/// Errors that can occur when using the Dogecoin library
public enum DogecoinError: Error, LocalizedError, Sendable, Equatable {
    /// The secp256k1 context libdogecoin needs could not be created
    case initializationFailed

    /// Key generation failed
    case keyGenerationFailed

    /// The provided address is invalid
    case invalidAddress(String)

    /// The provided mnemonic phrase is invalid
    case invalidMnemonic

    /// HD key derivation failed
    case derivationFailed

    /// Transaction creation failed
    case transactionCreationFailed

    /// Transaction validation failed
    case transactionValidationFailed(String)

    /// Transaction signing failed
    case transactionSigningFailed

    /// Adding input to transaction failed
    case addInputFailed

    /// Adding output to transaction failed
    case addOutputFailed

    /// Transaction finalization failed
    case finalizationFailed

    /// Invalid private key format
    case invalidPrivateKey

    /// Invalid public key format
    case invalidPublicKey

    /// Amount conversion failed
    case amountConversionFailed

    /// An internal error occurred
    case internalError(String)

    // MARK: - Networking Errors

    /// No peers available for the operation
    case noPeersAvailable

    /// Transaction broadcast failed
    case broadcastFailed(String)

    /// Connection to peers failed
    case connectionFailed(String)

    /// Sync operation failed
    case syncFailed(String)

    // MARK: - Secure Storage Errors

    /// Keychain storage operation failed
    case keychainStorageFailed(String)

    /// Keychain retrieval operation failed
    case keychainRetrievalFailed(String)

    /// Keychain deletion operation failed
    case keychainDeletionFailed(String)

    /// The requested key was not found in secure storage
    case keyNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .initializationFailed:
            return "Failed to initialize the Dogecoin ECC context"
        case .keyGenerationFailed:
            return "Failed to generate key pair"
        case .invalidAddress(let address):
            return "Invalid Dogecoin address: \(address)"
        case .invalidMnemonic:
            return "Invalid mnemonic phrase"
        case .derivationFailed:
            return "HD key derivation failed"
        case .transactionCreationFailed:
            return "Failed to create transaction"
        case .transactionValidationFailed(let reason):
            return "Transaction validation failed: \(reason)"
        case .transactionSigningFailed:
            return "Failed to sign transaction"
        case .addInputFailed:
            return "Failed to add input to transaction"
        case .addOutputFailed:
            return "Failed to add output to transaction"
        case .finalizationFailed:
            return "Failed to finalize transaction"
        case .invalidPrivateKey:
            return "Invalid private key format"
        case .invalidPublicKey:
            return "Invalid public key format"
        case .amountConversionFailed:
            return "Amount conversion failed"
        case .internalError(let message):
            return "Internal error: \(message)"
        case .noPeersAvailable:
            return "No peers available for the operation"
        case .broadcastFailed(let reason):
            return "Transaction broadcast failed: \(reason)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .syncFailed(let reason):
            return "Sync operation failed: \(reason)"
        case .keychainStorageFailed(let reason):
            return "Failed to store key in Keychain: \(reason)"
        case .keychainRetrievalFailed(let reason):
            return "Failed to retrieve key from Keychain: \(reason)"
        case .keychainDeletionFailed(let reason):
            return "Failed to delete key from Keychain: \(reason)"
        case .keyNotFound(let identifier):
            return "Key not found in secure storage: \(identifier)"
        }
    }
}
