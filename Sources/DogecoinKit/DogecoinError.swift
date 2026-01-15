import Foundation

/// Errors that can occur when using the Dogecoin library
public enum DogecoinError: Error, LocalizedError, Sendable {
    /// The library failed to initialize the ECC context
    case initializationFailed

    /// Key generation failed
    case keyGenerationFailed

    /// The provided address is invalid
    case invalidAddress(String)

    /// The provided mnemonic phrase is invalid
    case invalidMnemonic

    /// The mnemonic word count is invalid (must be 12, 15, 18, 21, or 24)
    case invalidMnemonicWordCount(Int)

    /// The entropy size is invalid (must be 128, 160, 192, 224, or 256)
    case invalidEntropySize(Int)

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

    /// Invalid transaction index
    case invalidTransactionIndex(Int)

    /// Invalid private key format
    case invalidPrivateKey

    /// Invalid public key format
    case invalidPublicKey

    /// Amount conversion failed
    case amountConversionFailed

    /// Memory allocation failed
    case memoryAllocationFailed

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

    /// Secure storage is not available on this device
    case secureStorageUnavailable

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
        case .invalidMnemonicWordCount(let count):
            return "Invalid mnemonic word count: \(count). Must be 12, 15, 18, 21, or 24"
        case .invalidEntropySize(let size):
            return "Invalid entropy size: \(size). Must be 128, 160, 192, 224, or 256"
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
        case .invalidTransactionIndex(let index):
            return "Invalid transaction index: \(index)"
        case .invalidPrivateKey:
            return "Invalid private key format"
        case .invalidPublicKey:
            return "Invalid public key format"
        case .amountConversionFailed:
            return "Amount conversion failed"
        case .memoryAllocationFailed:
            return "Memory allocation failed"
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
        case .secureStorageUnavailable:
            return "Secure storage is not available on this device"
        }
    }
}
