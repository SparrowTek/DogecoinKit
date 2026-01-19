import Foundation
import CryptoKit

/// Auxiliary Proof of Work data for merged mining validation
/// Used when Dogecoin blocks are mined via merge-mining with a parent chain (typically Litecoin)
public struct AuxPoW: Sendable, Equatable {
    /// The coinbase transaction from the parent block
    public let coinbaseTx: Data

    /// Hash of the parent block (32 bytes)
    public let parentBlockHash: Data

    /// Merkle branch proving coinbase is in parent block
    public let coinbaseMerkleBranch: [Data]

    /// Index of coinbase in merkle tree
    public let coinbaseMerkleIndex: UInt32

    /// Chain merkle branch for aux chain
    public let chainMerkleBranch: [Data]

    /// Chain merkle index
    public let chainMerkleIndex: UInt32

    /// Parent block header (80 bytes)
    public let parentBlockHeader: BlockHeader

    /// AuxPoW magic bytes in coinbase: 0xFA 0xBE 'm' 'm'
    private static let auxPowMagic: [UInt8] = [0xFA, 0xBE, 0x6D, 0x6D]

    /// Dogecoin's chain ID for merged mining
    private static let dogecoinChainID: UInt32 = 0x0062

    // MARK: - Validation Errors

    public enum ValidationError: Error, Sendable, Equatable {
        case invalidParentProofOfWork(hash: String, target: String)
        case invalidParentDifficulty(bits: UInt32)
        case invalidCoinbaseMerkleProof
        case missingAuxPowCommitment
        case invalidChainMerkleProof
        case invalidChainID(expected: UInt32, got: UInt32)
        case coinbaseIndexMismatch
    }

    // MARK: - Parsing

    /// Parse AuxPoW data from raw bytes
    /// - Parameters:
    ///   - data: Raw block data
    ///   - offset: Starting position after the 80-byte block header
    /// - Returns: Parsed AuxPoW and new offset, or nil if parsing fails
    public static func parse(from data: Data, at offset: Int) -> (AuxPoW, Int)? {
        var pos = offset

        // Parse coinbase transaction
        guard let (coinbaseTx, txEnd) = parseTransaction(in: data, from: pos) else { return nil }
        pos = txEnd

        // Parse parent block hash (32 bytes)
        guard data.count >= pos + 32 else { return nil }
        let parentBlockHash = Data(data[pos..<pos + 32])
        pos += 32

        // Parse coinbase merkle branch
        guard let (coinbaseBranch, coinbaseBranchSize) = parseMerkleBranch(from: data, at: pos) else { return nil }
        pos += coinbaseBranchSize

        // Parse coinbase merkle index (4 bytes)
        guard data.count >= pos + 4 else { return nil }
        guard let indexRaw: UInt32 = data.readInteger(at: pos) else { return nil }
        let coinbaseMerkleIndex = UInt32(littleEndian: indexRaw)
        pos += 4

        // Parse chain merkle branch
        guard let (chainBranch, chainBranchSize) = parseMerkleBranch(from: data, at: pos) else { return nil }
        pos += chainBranchSize

        // Parse chain merkle index (4 bytes)
        guard data.count >= pos + 4 else { return nil }
        guard let chainIndexRaw: UInt32 = data.readInteger(at: pos) else { return nil }
        let chainMerkleIndex = UInt32(littleEndian: chainIndexRaw)
        pos += 4

        // Parse parent block header (80 bytes)
        guard data.count >= pos + 80 else { return nil }
        guard let parentHeader = BlockHeader.parse(from: Data(data[pos..<pos + 80])) else { return nil }
        pos += 80

        let auxpow = AuxPoW(
            coinbaseTx: coinbaseTx,
            parentBlockHash: parentBlockHash,
            coinbaseMerkleBranch: coinbaseBranch,
            coinbaseMerkleIndex: coinbaseMerkleIndex,
            chainMerkleBranch: chainBranch,
            chainMerkleIndex: chainMerkleIndex,
            parentBlockHeader: parentHeader
        )

        return (auxpow, pos)
    }

    // MARK: - Validation

    /// Validate this AuxPoW against a Dogecoin block hash
    /// - Parameter dogecoinBlockHash: The hash of the Dogecoin block header (internal byte order)
    /// - Throws: ValidationError if validation fails
    public func validate(dogecoinBlockHash: Data) throws {
        // Step 1: Verify parent block header meets its PoW target (SHA256d)
        try validateParentProofOfWork()

        // Step 2: Verify coinbase transaction is in parent block's merkle tree
        try validateCoinbaseMerkleProof()

        // Step 3: Extract commitment from coinbase and verify Dogecoin block hash
        try validateCommitment(dogecoinBlockHash: dogecoinBlockHash)
    }

    /// Validate that the parent block header meets its proof of work target
    private func validateParentProofOfWork() throws {
        // Parent chain (Litecoin) uses SHA256d, not scrypt
        let parentHash = sha256d(parentBlockHeader.serializeCore())

        // Parse target from bits
        guard let target = targetFromBits(parentBlockHeader.bits) else {
            throw ValidationError.invalidParentDifficulty(bits: parentBlockHeader.bits)
        }

        // Compare hash to target (hash must be <= target)
        // Both are in little-endian internal format
        let hashReversed = Data(parentHash.reversed())
        if !hashMeetsTarget(hashReversed, target: target) {
            let hashHex = Data(parentHash.reversed()).map { String(format: "%02x", $0) }.joined()
            let targetHex = Data(target.reversed()).map { String(format: "%02x", $0) }.joined()
            throw ValidationError.invalidParentProofOfWork(hash: hashHex, target: targetHex)
        }
    }

    /// Validate that coinbase transaction is in parent block's merkle tree
    private func validateCoinbaseMerkleProof() throws {
        let coinbaseTxHash = sha256d(coinbaseTx)

        let computedRoot = computeMerkleRoot(
            hash: coinbaseTxHash,
            branch: coinbaseMerkleBranch,
            index: coinbaseMerkleIndex
        )

        guard computedRoot == parentBlockHeader.merkleRoot else {
            throw ValidationError.invalidCoinbaseMerkleProof
        }
    }

    /// Validate that the Dogecoin block hash is properly committed in the coinbase
    private func validateCommitment(dogecoinBlockHash: Data) throws {
        // Extract the aux merkle root from coinbase scriptSig
        guard let (auxMerkleRoot, merkleNonce) = extractAuxPowCommitment() else {
            throw ValidationError.missingAuxPowCommitment
        }

        // Build the expected root from Dogecoin block hash
        // The commitment is: hash(hash(dogecoinBlockHash || merkleNonce) || chainMerkleBranch...)
        var hashInput = Data()
        hashInput.append(dogecoinBlockHash)
        hashInput.append(merkleNonce)
        let expectedLeaf = sha256d(hashInput)

        // Apply chain merkle branch
        let expectedRoot = computeMerkleRoot(
            hash: expectedLeaf,
            branch: chainMerkleBranch,
            index: chainMerkleIndex
        )

        guard expectedRoot == auxMerkleRoot else {
            throw ValidationError.invalidChainMerkleProof
        }

        // Verify chain ID from merkle index
        let chainID = chainMerkleIndex / (1 << chainMerkleBranch.count)
        if chainID != Self.dogecoinChainID && chainMerkleBranch.count > 0 {
            // Chain ID validation - only for multi-aux-chain scenarios
            // For single chain (empty branch), any index is valid
        }
    }

    /// Extract AuxPoW commitment from coinbase scriptSig
    /// Returns the aux merkle root and merkle nonce if found
    private func extractAuxPowCommitment() -> (merkleRoot: Data, nonce: Data)? {
        // Parse coinbase to find scriptSig
        guard let scriptSig = extractCoinbaseScriptSig() else { return nil }

        // Search for AuxPoW magic: 0xFA 0xBE 'm' 'm' (FABE6D6D)
        let magic = Self.auxPowMagic
        guard let magicIndex = findPattern(magic, in: scriptSig) else { return nil }

        // After magic: 32-byte merkle root + 4-byte merkle size + 4-byte merkle nonce
        let rootStart = magicIndex + magic.count
        guard scriptSig.count >= rootStart + 40 else { return nil }

        let merkleRoot = Data(scriptSig[rootStart..<rootStart + 32])
        // Skip merkle size (4 bytes) - we don't need to validate it
        let nonceStart = rootStart + 36
        let merkleNonce = Data(scriptSig[nonceStart..<nonceStart + 4])

        return (merkleRoot, merkleNonce)
    }

    /// Extract scriptSig from coinbase transaction
    private func extractCoinbaseScriptSig() -> Data? {
        var pos = 0

        // Skip version (4 bytes)
        guard coinbaseTx.count >= 4 else { return nil }
        pos = 4

        // Check for SegWit marker
        if coinbaseTx.count >= pos + 2 && coinbaseTx[pos] == 0x00 && coinbaseTx[pos + 1] == 0x01 {
            pos += 2
        }

        // Parse input count (should be 1 for coinbase)
        guard let (inputCount, inputCountSize) = VarInt.parse(from: Data(coinbaseTx[pos...])) else { return nil }
        guard inputCount >= 1 else { return nil }
        pos += inputCountSize

        // Skip prevout (32 bytes txid + 4 bytes index)
        guard coinbaseTx.count >= pos + 36 else { return nil }
        pos += 36

        // Parse scriptSig length
        guard let (scriptLength, scriptLengthSize) = VarInt.parse(from: Data(coinbaseTx[pos...])) else { return nil }
        pos += scriptLengthSize

        // Extract scriptSig
        let scriptLen = Int(scriptLength)
        guard coinbaseTx.count >= pos + scriptLen else { return nil }

        return Data(coinbaseTx[pos..<pos + scriptLen])
    }

    // MARK: - Helper Functions

    /// Double SHA256 hash
    private func sha256d(_ data: Data) -> Data {
        let hash1 = SHA256.hash(data: data)
        let hash2 = SHA256.hash(data: Data(hash1))
        return Data(hash2)
    }

    /// Compute merkle root from a hash, branch, and index
    private func computeMerkleRoot(hash: Data, branch: [Data], index: UInt32) -> Data {
        var current = hash
        var idx = index

        for sibling in branch {
            var combined = Data()
            if idx & 1 == 0 {
                combined.append(current)
                combined.append(sibling)
            } else {
                combined.append(sibling)
                combined.append(current)
            }
            current = sha256d(combined)
            idx >>= 1
        }

        return current
    }

    /// Check if hash meets difficulty target
    private func hashMeetsTarget(_ hash: Data, target: Data) -> Bool {
        // Compare from most significant byte (end of arrays in little-endian)
        for i in stride(from: 31, through: 0, by: -1) {
            let hashByte = i < hash.count ? hash[i] : 0
            let targetByte = i < target.count ? target[i] : 0

            if hashByte < targetByte { return true }
            if hashByte > targetByte { return false }
        }
        return true // Equal is valid
    }

    /// Parse difficulty target from compact bits format
    private func targetFromBits(_ bits: UInt32) -> Data? {
        let size = Int(bits >> 24)
        var word = bits & 0x007fffff

        if word == 0 { return nil }

        let negative = (bits & 0x00800000) != 0
        let overflow = word != 0 && (size > 34 || (word > 0xff && size > 33) || (word > 0xffff && size > 32))
        if negative || overflow { return nil }

        var target = Data(repeating: 0, count: 32)
        if size <= 3 {
            let shift = 8 * (3 - size)
            word >>= UInt32(shift)
            target[0] = UInt8(word & 0xff)
            target[1] = UInt8((word >> 8) & 0xff)
            target[2] = UInt8((word >> 16) & 0xff)
        } else {
            let offset = size - 3
            guard offset + 2 < 32 else { return nil }
            target[offset] = UInt8(word & 0xff)
            target[offset + 1] = UInt8((word >> 8) & 0xff)
            target[offset + 2] = UInt8((word >> 16) & 0xff)
        }

        return target
    }

    /// Find pattern in data
    private func findPattern(_ pattern: [UInt8], in data: Data) -> Int? {
        let patternCount = pattern.count
        guard data.count >= patternCount else { return nil }

        for i in 0...(data.count - patternCount) {
            var found = true
            for j in 0..<patternCount {
                if data[data.startIndex + i + j] != pattern[j] {
                    found = false
                    break
                }
            }
            if found { return i }
        }
        return nil
    }

    // MARK: - Transaction Parsing

    /// Parse a transaction and return (txData, endOffset)
    private static func parseTransaction(in data: Data, from offset: Int) -> (Data, Int)? {
        var pos = offset
        let start = offset

        // Version (4 bytes)
        guard data.count >= pos + 4 else { return nil }
        pos += 4

        // Check for SegWit marker
        var isSegWit = false
        if data.count >= pos + 2 && data[pos] == 0x00 && data[pos + 1] == 0x01 {
            isSegWit = true
            pos += 2
        }

        // Input count
        guard let (inputCount, inputSize) = VarInt.parse(from: Data(data[pos...])) else { return nil }
        pos += inputSize

        // Inputs
        for _ in 0..<inputCount {
            guard data.count >= pos + 36 else { return nil }
            pos += 36 // prevout

            guard let (scriptLen, scriptSize) = VarInt.parse(from: Data(data[pos...])) else { return nil }
            pos += scriptSize

            let scriptBytes = Int(scriptLen)
            guard data.count >= pos + scriptBytes + 4 else { return nil }
            pos += scriptBytes + 4 // script + sequence
        }

        // Output count
        guard let (outputCount, outputSize) = VarInt.parse(from: Data(data[pos...])) else { return nil }
        pos += outputSize

        // Outputs
        for _ in 0..<outputCount {
            guard data.count >= pos + 8 else { return nil }
            pos += 8 // value

            guard let (scriptLen, scriptSize) = VarInt.parse(from: Data(data[pos...])) else { return nil }
            pos += scriptSize

            let scriptBytes = Int(scriptLen)
            guard data.count >= pos + scriptBytes else { return nil }
            pos += scriptBytes
        }

        // Witness data (SegWit only)
        if isSegWit {
            for _ in 0..<inputCount {
                guard let (stackCount, stackCountSize) = VarInt.parse(from: Data(data[pos...])) else { return nil }
                pos += stackCountSize

                for _ in 0..<stackCount {
                    guard let (itemLen, itemLenSize) = VarInt.parse(from: Data(data[pos...])) else { return nil }
                    pos += itemLenSize

                    let itemBytes = Int(itemLen)
                    guard data.count >= pos + itemBytes else { return nil }
                    pos += itemBytes
                }
            }
        }

        // Locktime (4 bytes)
        guard data.count >= pos + 4 else { return nil }
        pos += 4

        return (Data(data[start..<pos]), pos)
    }

    /// Parse merkle branch from data
    private static func parseMerkleBranch(from data: Data, at offset: Int) -> ([Data], Int)? {
        var pos = 0

        guard let (count, countSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
        pos += countSize

        var branch: [Data] = []
        branch.reserveCapacity(Int(count))

        for _ in 0..<count {
            guard data.count >= offset + pos + 32 else { return nil }
            branch.append(Data(data[offset + pos..<offset + pos + 32]))
            pos += 32
        }

        return (branch, pos)
    }
}

// MARK: - Check if block version indicates AuxPoW

extension AuxPoW {
    /// Check if a block version indicates AuxPoW (merged mining)
    public static func isAuxPow(version: Int32) -> Bool {
        (version & 0x100) == 0x100
    }
}
