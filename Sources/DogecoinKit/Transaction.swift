import Foundation
import os.log
import clibdogecoin

private let signLogger = Logger(subsystem: "DogecoinKit", category: "sign")

/// A Dogecoin transaction builder
public actor TransactionBuilder {

    /// The internal transaction index
    private let txIndex: Int32

    /// Track if transaction has been finalized
    private var isFinalized = false

    private var inputCount: Int = 0

    /// Create a new transaction builder
    /// - Throws: `DogecoinError.transactionCreationFailed` if creation fails
    public init() async throws {
        try await Dogecoin.ensureInitialized()
        ECC.armCurrentThread()

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
        guard !isFinalized else {
            throw DogecoinError.internalError("Transaction already finalized")
        }

        var txidBuffer = Array(txid.utf8CString)

        let result = add_utxo(txIndex, &txidBuffer, Int32(vout))

        guard result == 1 else {
            throw DogecoinError.addInputFailed
        }

        inputCount += 1
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
        guard inputCount > 0 else {
            throw DogecoinError.transactionSigningFailed
        }

        for index in 0..<inputCount {
            try signInput(index: index, privateKeyWIF: privateKeyWIF)
        }
    }

    /// Sign a specific input using a private key
    /// - Parameters:
    ///   - index: The input index to sign
    ///   - privateKeyWIF: The private key in WIF format
    /// - Throws: `DogecoinError.transactionSigningFailed` if signing fails
    public func signInput(index: Int, privateKeyWIF: String) throws {
        guard index >= 0, index < inputCount else {
            throw DogecoinError.transactionSigningFailed
        }

        ECC.armCurrentThread()
        var privKeyBuffer = Array(privateKeyWIF.utf8CString)
        let result = sign_transaction_w_privkey(txIndex, Int32(index), &privKeyBuffer)

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
        ECC.armCurrentThread()
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

    /// The effective fee used when building the transaction, if known
    public let fee: DogecoinAmount?

    /// The transaction ID (computed from the raw hex)
    public var txid: String {
        // Transaction ID is the double SHA256 of the raw tx, reversed
        guard let data = Data(hexString: rawHex) else { return rawHex }
        let hash = MerkleTree.doubleSHA256(data)
        return Data(hash.reversed()).hexString
    }

    /// Create from raw hex
    public init(rawHex: String, fee: DogecoinAmount? = nil) {
        self.rawHex = rawHex
        self.fee = fee
    }
}

// MARK: - Internal Planning

struct TransactionPlan: Sendable, Equatable {
    let fee: DogecoinAmount
    let change: DogecoinAmount
    let changeAddress: String?
    let outputCount: Int
    let estimatedSize: Int
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
) async throws -> SignedTransaction {
    let uniqueAddresses = Set(inputs.map { $0.address })
    guard uniqueAddresses.count <= 1 else {
        throw DogecoinError.transactionValidationFailed("Multiple input addresses require per-input signing keys")
    }

    return try await createTransaction(
        inputs: inputs,
        outputs: outputs,
        signingKeysByAddress: [inputs.first?.address ?? "": privateKey],
        changeAddress: changeAddress,
        fee: fee
    )
}

/// Create and sign a transaction with per-input signing keys
/// - Parameters:
///   - inputs: The UTXOs to spend
///   - outputs: The recipient addresses and amounts
///   - signingKeysByAddress: Map of address -> private key (WIF)
///   - changeAddress: The address for change
///   - fee: The transaction fee
/// - Returns: The signed transaction
/// - Throws: `DogecoinError` if any step fails
public func createTransaction(
    inputs: [UTXO],
    outputs: [(address: String, amount: DogecoinAmount)],
    signingKeysByAddress: [String: String],
    changeAddress: String? = nil,
    fee: DogecoinAmount
) async throws -> SignedTransaction {
    let plan = try planTransaction(
        inputs: inputs,
        outputs: outputs,
        fee: fee,
        changeAddress: changeAddress
    )

    let builder = try await TransactionBuilder()

    for input in inputs {
        try await builder.addInput(txid: input.txid, vout: input.vout)
    }

    for output in outputs {
        try await builder.addOutput(address: output.address, amount: output.amount)
    }

    let totalInput = inputs.reduce(DogecoinAmount.zero) { $0 + $1.amount }

    guard let firstOutput = outputs.first else {
        throw DogecoinError.transactionCreationFailed
    }

    _ = try await builder.finalize(
        destinationAddress: firstOutput.address,
        fee: plan.fee,
        totalAmount: totalInput,
        changeAddress: plan.changeAddress
    )

    for (index, input) in inputs.enumerated() {
        guard let privateKey = signingKeysByAddress[input.address] else {
            signLogger.error("Missing signing key for input \(index, privacy: .public) address=\(input.address, privacy: .private)")
            throw DogecoinError.transactionValidationFailed("Missing signing key for address \(input.address)")
        }
        do {
            try await builder.signInput(index: index, privateKeyWIF: privateKey)
        } catch {
            signLogger.error("Sign failed for input \(index, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    let rawHex = try await builder.getRawTransaction()
    let signed = SignedTransaction(rawHex: rawHex, fee: plan.fee)
    signLogger.info("Signed tx \(signed.txid, privacy: .public) — \(inputs.count, privacy: .public) in, \(outputs.count, privacy: .public) out, fee \(plan.fee.koinu, privacy: .public) koinu")
    return signed
}

func planTransaction(
    inputs: [UTXO],
    outputs: [(address: String, amount: DogecoinAmount)],
    fee: DogecoinAmount,
    changeAddress: String?
) throws -> TransactionPlan {
    guard !inputs.isEmpty else {
        throw DogecoinError.transactionValidationFailed("Transaction requires at least one input")
    }
    guard !outputs.isEmpty else {
        throw DogecoinError.transactionValidationFailed("Transaction requires at least one output")
    }

    for input in inputs where input.address.isEmpty {
        throw DogecoinError.transactionValidationFailed("Input address is missing")
    }

    for output in outputs where output.amount.koinu == 0 {
        throw DogecoinError.transactionValidationFailed("Output amount must be greater than zero")
    }

    var feeToUse = fee
    if feeToUse < FeeEstimation.minimumFee {
        feeToUse = FeeEstimation.minimumFee
    }

    let totalInput = inputs.reduce(DogecoinAmount.zero) { $0 + $1.amount }
    let totalOutput = outputs.reduce(DogecoinAmount.zero) { $0 + $1.amount }
    let required = totalOutput + feeToUse

    guard totalInput >= required else {
        throw DogecoinError.transactionValidationFailed("Inputs do not cover outputs and fee")
    }

    var change = totalInput - required

    if change.koinu > 0 && change < FeeEstimation.dustThreshold {
        feeToUse += change
        change = .zero
    }

    let shouldIncludeChange = change.koinu > 0
    let outputCount = outputs.count + (shouldIncludeChange ? 1 : 0)
    let estimatedSize = FeeEstimation.estimateTransactionSize(
        inputCount: inputs.count,
        outputCount: outputCount
    )

    guard estimatedSize <= FeeEstimation.maxStandardTxSize else {
        throw DogecoinError.transactionValidationFailed("Transaction exceeds standard size limit")
    }

    let effectiveChangeAddress: String?
    if shouldIncludeChange {
        effectiveChangeAddress = changeAddress ?? inputs.first?.address
        guard effectiveChangeAddress != nil else {
            throw DogecoinError.transactionValidationFailed("Missing change address")
        }
    } else {
        effectiveChangeAddress = nil
    }

    return TransactionPlan(
        fee: feeToUse,
        change: change,
        changeAddress: effectiveChangeAddress,
        outputCount: outputCount,
        estimatedSize: estimatedSize
    )
}
