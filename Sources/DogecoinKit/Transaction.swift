import Foundation
#if canImport(os)
import os.log
#endif
import clibdogecoin

private let signLogger = Logger(subsystem: "DogecoinKit", category: "sign")

/// A Dogecoin transaction builder
///
/// libdogecoin keeps its working transactions — and the secp256k1 context
/// used to sign them — in thread-local storage, while an actor can resume on
/// a different thread after every `await`. The builder therefore keeps its
/// inputs and outputs in Swift and only reaches into libdogecoin from
/// synchronous stretches that begin and end on one thread: serialization
/// creates, fills, serializes, and clears a libdogecoin transaction in a
/// single call, and signing operates on the serialized hex through
/// `sign_raw_transaction_ex`, which needs no working transaction — only the
/// calling thread's ECC context, armed right before.
public actor TransactionBuilder {

    private struct Outpoint: Sendable, Hashable {
        /// Display-order hex, as block explorers and Electrum servers show it
        let txid: String
        let vout: UInt32
    }

    private struct Output: Sendable {
        let address: String
        let amount: DogecoinAmount
    }

    private static let sighashAll: Int32 = 1

    private var inputs: [Outpoint] = []
    private var outputs: [Output] = []

    /// The serialized transaction once finalized, replaced as inputs are
    /// signed. Non-nil freezes the input and output sets.
    private var sealedHex: String?

    /// Create a new transaction builder
    public init() {}

    /// Add an input (UTXO) to the transaction
    /// - Parameters:
    ///   - txid: The transaction ID containing the UTXO (64 hex characters, display order)
    ///   - vout: The output index within the transaction
    /// - Throws: `DogecoinError.addInputFailed` if the outpoint is malformed
    public func addInput(txid: String, vout: Int) throws {
        try ensureMutable()

        guard txid.utf8.count == 64,
              Data(hexString: txid) != nil,
              let index = UInt32(exactly: vout) else {
            throw DogecoinError.addInputFailed
        }

        inputs.append(Outpoint(txid: txid, vout: index))
    }

    /// Add an output to the transaction
    /// - Parameters:
    ///   - address: The recipient address (P2PKH or P2SH)
    ///   - amount: The amount to send — more than zero and at most ``DogecoinAmount/maxMoney``
    /// - Throws: `DogecoinError.addOutputFailed` if the address or amount is invalid
    public func addOutput(address: String, amount: DogecoinAmount) throws {
        try ensureMutable()

        guard let network = Address.detectNetwork(address),
              amount.koinu > 0,
              amount <= .maxMoney else {
            throw DogecoinError.addOutputFailed
        }

        if let first = outputs.first, Address.detectNetwork(first.address) != network {
            throw DogecoinError.transactionValidationFailed("Outputs must all belong to the same network")
        }

        outputs.append(Output(address: address, amount: amount))
    }

    /// Finalize the transaction with change address and fee
    ///
    /// Whatever `totalAmount` leaves over after the outputs and `fee` goes to
    /// `changeAddress`. Once finalized, inputs and outputs can no longer change.
    /// - Parameters:
    ///   - fee: The transaction fee
    ///   - totalAmount: The total value of the inputs being spent
    ///   - changeAddress: The address to receive change; required when there is change
    /// - Returns: The unsigned raw transaction hex
    /// - Throws: `DogecoinError.finalizationFailed` if there are no inputs
    ///   or outputs or the amounts do not balance, or
    ///   `DogecoinError.transactionValidationFailed` if the builder was
    ///   already finalized
    public func finalize(
        fee: DogecoinAmount,
        totalAmount: DogecoinAmount,
        changeAddress: String? = nil
    ) throws -> String {
        try ensureMutable()

        guard !inputs.isEmpty,
              let network = outputs.first.flatMap({ Address.detectNetwork($0.address) }),
              let spent = checkedSum(outputs.map(\.amount) + [fee]),
              spent <= totalAmount else {
            throw DogecoinError.finalizationFailed
        }

        var finalOutputs = outputs
        let change = totalAmount - spent
        if change.koinu > 0 {
            guard let changeAddress, Address.detectNetwork(changeAddress) == network else {
                throw DogecoinError.finalizationFailed
            }
            finalOutputs.append(Output(address: changeAddress, amount: change))
        }

        let rawHex = try Self.serialize(inputs: inputs, outputs: finalOutputs)
        sealedHex = rawHex
        return rawHex
    }

    /// Sign every input with one private key
    ///
    /// Each input is signed as P2PKH for the key's own (compressed) address.
    /// - Parameter privateKeyWIF: The private key in WIF format
    /// - Throws: `DogecoinError.transactionValidationFailed` if the builder is
    ///   not finalized or an input is already signed,
    ///   `DogecoinError.invalidPrivateKey` for an unusable key, and
    ///   `DogecoinError.transactionSigningFailed` if signing fails
    func sign(privateKeyWIF: String) throws {
        var signed = try finalizedTransaction()
        for index in inputs.indices {
            signed = try Self.sign(input: index, of: signed, privateKeyWIF: privateKeyWIF)
        }
        sealedHex = signed
    }

    /// Sign a specific input using a private key
    /// - Parameters:
    ///   - index: The input index to sign
    ///   - privateKeyWIF: The private key in WIF format
    /// - Throws: `DogecoinError.transactionValidationFailed` if the builder is
    ///   not finalized or the input is already signed,
    ///   `DogecoinError.invalidPrivateKey` for an unusable key, and
    ///   `DogecoinError.transactionSigningFailed` if signing fails
    public func signInput(index: Int, privateKeyWIF: String) throws {
        guard inputs.indices.contains(index) else {
            throw DogecoinError.transactionSigningFailed
        }

        sealedHex = try Self.sign(input: index, of: try finalizedTransaction(), privateKeyWIF: privateKeyWIF)
    }

    /// Get the raw transaction hex
    ///
    /// Returns the finalized (and possibly signed) transaction, or a fresh
    /// serialization of the current inputs and outputs if not yet finalized.
    /// - Returns: The raw transaction as hex string
    /// - Throws: `DogecoinError.transactionValidationFailed` if there are no
    ///   inputs yet — a transaction without any cannot be written down — or
    ///   `DogecoinError.transactionCreationFailed` if serialization fails
    public func getRawTransaction() throws -> String {
        if let sealedHex {
            return sealedHex
        }
        guard !inputs.isEmpty else {
            throw DogecoinError.transactionValidationFailed("Transaction has no inputs")
        }
        return try Self.serialize(inputs: inputs, outputs: outputs)
    }

    // MARK: - Private

    private func ensureMutable() throws {
        guard sealedHex == nil else {
            throw DogecoinError.transactionValidationFailed("Transaction already finalized")
        }
    }

    /// The finalized transaction. Signing anything else is refused: without
    /// `finalize` there is no change output, and whatever the outputs leave
    /// over would go to miners as fee.
    private func finalizedTransaction() throws -> String {
        guard let sealedHex else {
            throw DogecoinError.transactionValidationFailed("Finalize the transaction before signing it")
        }
        return sealedHex
    }

    /// Serializes an unsigned transaction.
    ///
    /// Runs start to finish on the calling thread — libdogecoin's
    /// working-transaction table is thread-local — and then decodes the
    /// result to confirm libdogecoin wrote exactly the requested outpoints,
    /// values, and output scripts before anything gets signed.
    private static func serialize(inputs: [Outpoint], outputs: [Output]) throws -> String {
        let rawHex = try withWorkingTransaction { index in
            for input in inputs {
                var txid = Array(input.txid.utf8CString)
                guard add_utxo(index, &txid, Int32(bitPattern: input.vout)) == 1 else {
                    throw DogecoinError.addInputFailed
                }
            }

            for output in outputs {
                var address = Array(output.address.utf8CString)
                var amount = Array(output.amount.dogeString.utf8CString)
                guard add_output(index, &address, &amount) == 1 else {
                    throw DogecoinError.addOutputFailed
                }
            }

            guard let raw = get_raw_transaction(index) else {
                throw DogecoinError.transactionCreationFailed
            }
            return String(cString: raw)
        }

        guard let decoded = RawTransaction(hex: rawHex),
              !decoded.hasWitness,
              decoded.inputs.count == inputs.count,
              decoded.outputs.count == outputs.count else {
            throw DogecoinError.transactionValidationFailed("Serialized transaction does not match the requested inputs and outputs")
        }

        for (decodedInput, input) in zip(decoded.inputs, inputs) {
            guard let txid = Data(hexString: input.txid),
                  decodedInput.previousTxid == Data(txid.reversed()),
                  decodedInput.previousIndex == input.vout else {
                throw DogecoinError.transactionValidationFailed("Serialized transaction spends an unexpected outpoint")
            }
        }

        for (decodedOutput, output) in zip(decoded.outputs, outputs) {
            guard decodedOutput.value == output.amount.koinu,
                  decodedOutput.script == Address.scriptPubKey(for: output.address) else {
                throw DogecoinError.transactionValidationFailed("Serialized transaction pays an unexpected amount or script")
            }
        }

        return rawHex
    }

    /// Hands `body` a fresh libdogecoin working transaction and clears it
    /// afterwards, all within one synchronous call.
    private static func withWorkingTransaction<T>(_ body: (Int32) throws -> T) throws -> T {
        let index = start_transaction()
        guard index > 0 else {
            throw DogecoinError.transactionCreationFailed
        }
        defer { clear_transaction(index) }
        return try body(index)
    }

    /// Hex characters signing adds to an input at most — a script-length
    /// byte that grows by none, a 73-byte signature push, and a 34-byte
    /// public-key push — plus the terminating NUL.
    private static let signedInputGrowth = 2 * (1 + 73 + 1 + 33) + 1

    /// Signs one input of a serialized transaction — as P2PKH for the key's
    /// own (compressed) address — and returns the new hex, after confirming
    /// libdogecoin changed nothing but that input's script.
    private static func sign(input index: Int, of rawHex: String, privateKeyWIF: String) throws -> String {
        guard let inputIndex = Int32(exactly: index),
              let unsigned = RawTransaction(hex: rawHex),
              unsigned.inputs.indices.contains(index) else {
            throw DogecoinError.transactionSigningFailed
        }

        // libdogecoin would append a second signature to the first, leaving a
        // script that nodes refuse to relay.
        guard unsigned.inputs[index].script.isEmpty else {
            throw DogecoinError.transactionValidationFailed("Input \(index) is already signed")
        }

        guard KeyPair.network(ofPrivateKey: privateKeyWIF) != nil else {
            throw DogecoinError.invalidPrivateKey
        }

        try ECC.armCurrentThread()
        let script = try p2pkhScript(forPrivateKeyWIF: privateKeyWIF)

        // One call: the buffer is sized for the longest signature there is,
        // so libdogecoin never has to be asked first how much it will write.
        var size = rawHex.utf8.count + signedInputGrowth
        var buffer = [CChar](repeating: 0, count: size)
        guard sign_raw_transaction_ex(inputIndex, rawHex, &buffer, &size, script, sighashAll, privateKeyWIF) == 1 else {
            throw DogecoinError.transactionSigningFailed
        }

        let signedHex = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard let signed = RawTransaction(hex: signedHex),
              signed.isSigned(input: index, from: unsigned) else {
            throw DogecoinError.transactionSigningFailed
        }
        return signedHex
    }

    /// The P2PKH output script hex for the address of a WIF private key.
    /// Needs the calling thread's ECC context to be armed.
    private static func p2pkhScript(forPrivateKeyWIF privateKeyWIF: String) throws -> String {
        var wif = Array(privateKeyWIF.utf8CString)
        while wif.count < Int(PRIVKEYWIFLEN) { wif.append(0) }
        defer { wif.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }

        guard let script = dogecoin_private_key_wif_to_pubkey_hash(&wif) else {
            throw DogecoinError.invalidPrivateKey
        }
        defer { dogecoin_free(script) }

        return String(cString: script)
    }
}

private extension RawTransaction {
    /// Whether this is `unsigned` with a script added to input `index` and
    /// every other field — outpoints, sequences, other scripts, outputs —
    /// left exactly as it was.
    func isSigned(input index: Int, from unsigned: RawTransaction) -> Bool {
        guard !hasWitness,
              version == unsigned.version,
              lockTime == unsigned.lockTime,
              outputs == unsigned.outputs,
              inputs.count == unsigned.inputs.count,
              !inputs[index].script.isEmpty else {
            return false
        }

        return zip(inputs, unsigned.inputs).enumerated().allSatisfy { position, pair in
            let (after, before) = pair
            return after.previousTxid == before.previousTxid
                && after.previousIndex == before.previousIndex
                && after.sequence == before.sequence
                && (position == index || after.script == before.script)
        }
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

    /// The transaction ID, in the byte order block explorers show
    public let txid: String

    /// Create from raw hex
    /// - Returns: `nil` unless `rawHex` is one whole serialized transaction
    public init?(rawHex: String, fee: DogecoinAmount? = nil) {
        guard let transaction = RawTransaction(hex: rawHex) else { return nil }
        self.rawHex = rawHex
        self.fee = fee
        self.txid = Data(transaction.txid.reversed()).hexString
    }
}

// MARK: - Internal Planning

struct TransactionPlan: Sendable, Equatable {
    let fee: DogecoinAmount
    let change: DogecoinAmount
    let changeAddress: String?
    let outputCount: Int
}

// MARK: - Convenience Functions

/// Create and sign a transaction with per-input signing keys
///
/// Every input must be a P2PKH output of its `address`, and
/// `signingKeysByAddress` must hold the matching private key for each
/// distinct input address; a missing or mismatched key fails before
/// anything is built rather than producing an unspendable signature.
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

    // One key check per address, however many inputs it funds.
    var verifiedAddresses: Set<String> = []
    let signingKeys = try inputs.enumerated().map { index, input in
        try signingKey(for: input, at: index, in: signingKeysByAddress, verified: &verifiedAddresses)
    }

    let builder = TransactionBuilder()

    for input in inputs {
        try await builder.addInput(txid: input.txid, vout: input.vout)
    }

    for output in outputs {
        try await builder.addOutput(address: output.address, amount: output.amount)
    }

    guard let totalInput = checkedSum(inputs.map(\.amount)) else {
        throw DogecoinError.transactionValidationFailed("Transaction amounts overflow")
    }

    _ = try await builder.finalize(
        fee: plan.fee,
        totalAmount: totalInput,
        changeAddress: plan.changeAddress
    )

    for (index, privateKey) in signingKeys.enumerated() {
        do {
            try await builder.signInput(index: index, privateKeyWIF: privateKey)
        } catch {
            signLogger.error("Sign failed for input \(index, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    guard let signed = SignedTransaction(rawHex: try await builder.getRawTransaction(), fee: plan.fee) else {
        throw DogecoinError.transactionSigningFailed
    }
    signLogger.info("Signed tx \(signed.txid, privacy: .public) — \(inputs.count, privacy: .public) in, \(outputs.count, privacy: .public) out, fee \(plan.fee.koinu, privacy: .public) koinu")
    return signed
}

/// Resolves and checks the key that will sign `input`.
/// - Parameter verified: Addresses whose key has already been shown to
///   control them; added to here
private func signingKey(
    for input: UTXO,
    at index: Int,
    in keysByAddress: [String: String],
    verified: inout Set<String>
) throws -> String {
    guard let privateKey = keysByAddress[input.address] else {
        signLogger.error("Missing signing key for input \(index, privacy: .public) address=\(input.address, privacy: .private)")
        throw DogecoinError.transactionValidationFailed("Missing signing key for address \(input.address)")
    }

    guard Address.kind(input.address) == .p2pkh,
          let network = Address.detectNetwork(input.address),
          let expectedScript = Address.scriptPubKey(for: input.address) else {
        throw DogecoinError.transactionValidationFailed("Input \(index) is not a P2PKH address")
    }

    // A recorded script that decodes to anything else is not ours to sign.
    if let recorded = input.scriptPubKey.flatMap({ Data(hexString: $0) }),
       !recorded.isEmpty,
       recorded != expectedScript {
        throw DogecoinError.transactionValidationFailed("Input \(index) script does not pay to \(input.address)")
    }

    guard verified.contains(input.address)
            || KeyPair.verify(privateKeyWIF: privateKey, address: input.address, network: network) else {
        signLogger.error("Signing key does not match input \(index, privacy: .public)")
        throw DogecoinError.transactionValidationFailed("Signing key does not match address \(input.address)")
    }
    verified.insert(input.address)

    return privateKey
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

    let outpoints = Set(inputs.map { "\($0.txid.lowercased()):\($0.vout)" })
    guard outpoints.count == inputs.count else {
        throw DogecoinError.transactionValidationFailed("Transaction spends the same output twice")
    }

    for output in outputs where output.amount.koinu == 0 {
        throw DogecoinError.transactionValidationFailed("Output amount must be greater than zero")
    }

    for output in outputs where output.amount > .maxMoney {
        throw DogecoinError.transactionValidationFailed("Output amount exceeds the network maximum")
    }

    // Nodes neither relay nor mine a transaction with an output this small.
    for output in outputs where output.amount < FeeEstimation.hardDustLimit {
        throw DogecoinError.transactionValidationFailed("Output amount is below the network's dust limit")
    }

    let addresses = inputs.map(\.address) + outputs.map(\.address) + [changeAddress].compactMap { $0 }
    guard Set(addresses.compactMap { Address.detectNetwork($0) }).count <= 1 else {
        throw DogecoinError.transactionValidationFailed("Inputs, outputs, and change must be on the same network")
    }

    guard let totalInput = checkedSum(inputs.map(\.amount)),
          let totalOutput = checkedSum(outputs.map(\.amount)) else {
        throw DogecoinError.transactionValidationFailed("Transaction amounts overflow")
    }

    guard FeeEstimation.estimateTransactionSize(inputCount: inputs.count, outputCount: outputs.count) <= FeeEstimation.maxStandardTxSize else {
        throw DogecoinError.transactionValidationFailed("Transaction exceeds standard size limit")
    }

    /// The fee to pay with `outputCount` outputs: the one asked for, or the
    /// least nodes relay for a transaction of that size if that is more.
    func feeToPay(outputCount: Int) -> DogecoinAmount {
        let size = FeeEstimation.estimateTransactionSize(inputCount: inputs.count, outputCount: outputCount)
        return max(fee, FeeEstimation.minimumRelayFee(sizeBytes: size, outputs: outputs.map(\.amount)))
    }

    // With a change output, when what the inputs leave over is worth one.
    let feeWithChange = feeToPay(outputCount: outputs.count + 1)
    if let spent = checkedSum([totalOutput, feeWithChange, FeeEstimation.softDustLimit]), totalInput >= spent {
        // No room for the output: fail rather than let the change fall
        // through to the fee below.
        guard FeeEstimation.estimateTransactionSize(inputCount: inputs.count, outputCount: outputs.count + 1) <= FeeEstimation.maxStandardTxSize else {
            throw DogecoinError.transactionValidationFailed("Transaction exceeds standard size limit")
        }

        // Without a change address, change returns to the first input's
        // address (there is always one: empty inputs were rejected above).
        return TransactionPlan(
            fee: feeWithChange,
            change: totalInput - totalOutput - feeWithChange,
            changeAddress: changeAddress ?? inputs.first?.address,
            outputCount: outputs.count + 1
        )
    }

    // Without one: what the inputs leave over — less than the soft dust
    // limit beyond the fee, or the branch above would have taken it — is
    // the fee.
    guard let required = checkedSum([totalOutput, feeToPay(outputCount: outputs.count)]),
          totalInput >= required else {
        throw DogecoinError.transactionValidationFailed("Inputs do not cover outputs and fee")
    }

    return TransactionPlan(
        fee: totalInput - totalOutput,
        change: .zero,
        changeAddress: nil,
        outputCount: outputs.count
    )
}

/// Sums amounts, returning `nil` instead of saturating on overflow.
private func checkedSum(_ amounts: [DogecoinAmount]) -> DogecoinAmount? {
    var total: UInt64 = 0
    for amount in amounts {
        let (next, overflow) = total.addingReportingOverflow(amount.koinu)
        guard !overflow else { return nil }
        total = next
    }
    return DogecoinAmount(koinu: total)
}
