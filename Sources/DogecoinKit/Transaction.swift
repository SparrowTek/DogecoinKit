import Foundation
import clibdogecoin

/// A Dogecoin transaction builder
public final class TransactionBuilder: @unchecked Sendable {

    /// The internal transaction index
    private let txIndex: Int32

    /// Lock for thread safety
    private let lock = NSLock()

    /// Track if transaction has been finalized
    private var isFinalized = false

    /// Create a new transaction builder
    /// - Throws: `DogecoinError.transactionCreationFailed` if creation fails
    public init() throws {
        try Dogecoin.ensureInitialized()

        let index = start_transaction()
        guard index >= 0 else {
            throw DogecoinError.transactionCreationFailed
        }

        self.txIndex = index
    }

    deinit {
        clear_transaction(txIndex)
    }

    /// Add an input (UTXO) to the transaction
    /// - Parameters:
    ///   - txid: The transaction ID containing the UTXO
    ///   - vout: The output index within the transaction
    /// - Throws: `DogecoinError.addInputFailed` if adding the input fails
    public func addInput(txid: String, vout: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinalized else {
            throw DogecoinError.internalError("Transaction already finalized")
        }

        var txidBuffer = Array(txid.utf8CString)

        let result = add_utxo(txIndex, &txidBuffer, Int32(vout))

        guard result == 1 else {
            throw DogecoinError.addInputFailed
        }
    }

    /// Add an output to the transaction
    /// - Parameters:
    ///   - address: The recipient address
    ///   - amount: The amount to send
    /// - Throws: `DogecoinError.addOutputFailed` if adding the output fails
    public func addOutput(address: String, amount: DogecoinAmount) throws {
        try addOutput(address: address, amountString: amount.dogeString)
    }

    /// Add an output to the transaction using a string amount
    /// - Parameters:
    ///   - address: The recipient address
    ///   - amountString: The amount as a string (e.g., "1.5")
    /// - Throws: `DogecoinError.addOutputFailed` if adding the output fails
    public func addOutput(address: String, amountString: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinalized else {
            throw DogecoinError.internalError("Transaction already finalized")
        }

        var addressBuffer = Array(address.utf8CString)
        var amountBuffer = Array(amountString.utf8CString)

        let result = add_output(txIndex, &addressBuffer, &amountBuffer)

        guard result == 1 else {
            throw DogecoinError.addOutputFailed
        }
    }

    /// Finalize the transaction with change address and fee
    /// - Parameters:
    ///   - destinationAddress: The primary recipient address
    ///   - fee: The transaction fee
    ///   - totalAmount: The total amount being sent (for verification)
    ///   - changeAddress: The address to receive change (optional)
    /// - Returns: The raw transaction hex
    /// - Throws: `DogecoinError.finalizationFailed` if finalization fails
    public func finalize(
        destinationAddress: String,
        fee: DogecoinAmount,
        totalAmount: DogecoinAmount,
        changeAddress: String? = nil
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinalized else {
            throw DogecoinError.internalError("Transaction already finalized")
        }

        var destBuffer = Array(destinationAddress.utf8CString)
        var feeBuffer = Array(fee.dogeString.utf8CString)
        var amountBuffer = Array(totalAmount.dogeString.utf8CString)

        let rawTx: UnsafeMutablePointer<CChar>?

        if let changeAddr = changeAddress {
            var changeBuffer = Array(changeAddr.utf8CString)
            rawTx = finalize_transaction(txIndex, &destBuffer, &feeBuffer, &amountBuffer, &changeBuffer)
        } else {
            rawTx = finalize_transaction(txIndex, &destBuffer, &feeBuffer, &amountBuffer, nil)
        }

        guard let tx = rawTx else {
            throw DogecoinError.finalizationFailed
        }

        isFinalized = true
        return String(cString: tx)
    }

    /// Sign the transaction with a private key
    /// - Parameter privateKeyWIF: The private key in WIF format
    /// - Throws: `DogecoinError.transactionSigningFailed` if signing fails
    public func sign(privateKeyWIF: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var privKeyBuffer = Array(privateKeyWIF.utf8CString)

        // Use the simplified signing function
        let result = sign_transaction_w_privkey(txIndex, 0, &privKeyBuffer)

        guard result == 1 else {
            throw DogecoinError.transactionSigningFailed
        }
    }

    /// Sign a specific input with script and private key
    /// - Parameters:
    ///   - scriptPubKey: The script pubkey hex
    ///   - privateKeyWIF: The private key in WIF format
    /// - Throws: `DogecoinError.transactionSigningFailed` if signing fails
    public func sign(scriptPubKey: String, privateKeyWIF: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var scriptBuffer = Array(scriptPubKey.utf8CString)
        var privKeyBuffer = Array(privateKeyWIF.utf8CString)

        let result = sign_transaction(txIndex, &scriptBuffer, &privKeyBuffer)

        guard result == 1 else {
            throw DogecoinError.transactionSigningFailed
        }
    }

    /// Get the raw transaction hex
    /// - Returns: The raw transaction as hex string
    /// - Throws: `DogecoinError.transactionCreationFailed` if retrieval fails
    public func getRawTransaction() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        guard let rawTx = get_raw_transaction(txIndex) else {
            throw DogecoinError.transactionCreationFailed
        }

        return String(cString: rawTx)
    }
}

// MARK: - UTXO

/// Represents an Unspent Transaction Output
public struct UTXO: Sendable, Equatable, Hashable, Codable {
    /// The transaction ID containing this output
    public let txid: String

    /// The output index within the transaction
    public let vout: Int

    /// The address this UTXO belongs to
    public let address: String

    /// The amount of this UTXO
    public let amount: DogecoinAmount

    /// The script pubkey (optional, for signing)
    public let scriptPubKey: String?

    /// Number of confirmations
    public let confirmations: Int

    /// Create a UTXO
    public init(
        txid: String,
        vout: Int,
        address: String,
        amount: DogecoinAmount,
        scriptPubKey: String? = nil,
        confirmations: Int = 0
    ) {
        self.txid = txid
        self.vout = vout
        self.address = address
        self.amount = amount
        self.scriptPubKey = scriptPubKey
        self.confirmations = confirmations
    }
}

// MARK: - Transaction Helpers

/// Represents a signed transaction ready for broadcast
public struct SignedTransaction: Sendable, Equatable, Hashable {
    /// The raw transaction hex
    public let rawHex: String

    /// The transaction ID (computed from the raw hex)
    public var txid: String {
        // Transaction ID is the double SHA256 of the raw tx, reversed
        // For now, we don't compute it here - it would be done by the network
        rawHex
    }

    /// Create from raw hex
    public init(rawHex: String) {
        self.rawHex = rawHex
    }
}

// MARK: - Convenience Functions

/// Create and sign a simple transaction
/// - Parameters:
///   - inputs: The UTXOs to spend
///   - outputs: The recipient addresses and amounts
///   - privateKey: The private key to sign with
///   - changeAddress: The address for change
///   - fee: The transaction fee
/// - Returns: The signed transaction
/// - Throws: `DogecoinError` if any step fails
public func createTransaction(
    inputs: [UTXO],
    outputs: [(address: String, amount: DogecoinAmount)],
    privateKey: String,
    changeAddress: String? = nil,
    fee: DogecoinAmount
) throws -> SignedTransaction {
    let builder = try TransactionBuilder()

    // Add all inputs
    for input in inputs {
        try builder.addInput(txid: input.txid, vout: input.vout)
    }

    // Add all outputs
    for output in outputs {
        try builder.addOutput(address: output.address, amount: output.amount)
    }

    // Calculate total input
    let totalInput = inputs.reduce(DogecoinAmount.zero) { $0 + $1.amount }

    // Finalize (first output address is the primary destination)
    guard let firstOutput = outputs.first else {
        throw DogecoinError.transactionCreationFailed
    }

    _ = try builder.finalize(
        destinationAddress: firstOutput.address,
        fee: fee,
        totalAmount: totalInput,
        changeAddress: changeAddress ?? inputs.first?.address
    )

    // Sign
    try builder.sign(privateKeyWIF: privateKey)

    // Get the raw hex
    let rawHex = try builder.getRawTransaction()

    return SignedTransaction(rawHex: rawHex)
}
