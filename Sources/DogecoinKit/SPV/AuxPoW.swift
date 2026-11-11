import Foundation

/// Auxiliary Proof of Work data for merged mining validation
/// Used when Dogecoin blocks are mined via merge-mining with a parent chain (typically Litecoin)
public struct AuxPoW: Sendable, Equatable {
    /// The coinbase transaction from the parent block
    public let coinbaseTx: Data

    /// The `hashBlock` field of the proof. Serialized for compatibility,
    /// not used by validation (Dogecoin Core ignores it as well).
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

    /// Merged-mining header in the parent coinbase: 0xFA 0xBE 'm' 'm'
    private static let mergedMiningHeader = Data([0xFA, 0xBE, 0x6D, 0x6D])

    /// Longest chain merkle branch Core accepts.
    private static let maximumChainMerkleBranchLength = 30

    // MARK: - Validation Errors

    public enum ValidationError: Error, Sendable, Equatable {
        /// The parent block's scrypt hash does not meet the Dogecoin block's target
        case invalidParentProofOfWork(hash: String, target: String)
        /// The Dogecoin block's `nBits` do not encode an acceptable target
        case invalidParentDifficulty(bits: UInt32)
        /// The coinbase is not in the parent block's merkle tree
        case invalidCoinbaseMerkleProof
        /// The parent coinbase does not commit to the chain merkle root
        case missingAuxPowCommitment
        /// The chain merkle branch, its size, or its commitment layout is invalid
        case invalidChainMerkleProof
        /// The block or its parent carries the wrong merged-mining chain ID
        case invalidChainID(expected: UInt32, got: UInt32)
        /// The coinbase is not the parent block's first transaction, or the
        /// chain merkle index is not the slot the nonce selects
        case coinbaseIndexMismatch
        /// The block's version does not flag AuxPoW, or the parent's does
        case invalidVersion
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
        guard let parentBlockHash = data.bytes(at: pos, count: 32) else { return nil }
        pos += 32

        // Parse coinbase merkle branch
        guard let (coinbaseBranch, coinbaseBranchSize) = parseMerkleBranch(from: data, at: pos) else { return nil }
        pos += coinbaseBranchSize

        // Parse coinbase merkle index (4 bytes)
        guard let indexRaw: UInt32 = data.readInteger(at: pos) else { return nil }
        let coinbaseMerkleIndex = UInt32(littleEndian: indexRaw)
        pos += 4

        // Parse chain merkle branch
        guard let (chainBranch, chainBranchSize) = parseMerkleBranch(from: data, at: pos) else { return nil }
        pos += chainBranchSize

        // Parse chain merkle index (4 bytes)
        guard let chainIndexRaw: UInt32 = data.readInteger(at: pos) else { return nil }
        let chainMerkleIndex = UInt32(littleEndian: chainIndexRaw)
        pos += 4

        // Parse parent block header (80 bytes)
        guard let parentHeaderBytes = data.bytes(at: pos, count: BlockHeader.size),
              let parentHeader = BlockHeader.parse(from: parentHeaderBytes) else { return nil }
        pos += BlockHeader.size

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

    /// Serializes the proof in wire format (as it follows a header)
    public func serialize() -> Data {
        var data = Data()
        data.append(coinbaseTx)
        data.append(parentBlockHash)
        data.append(VarInt(UInt64(coinbaseMerkleBranch.count)).serialize())
        coinbaseMerkleBranch.forEach { data.append($0) }
        withUnsafeBytes(of: coinbaseMerkleIndex.littleEndian) { data.append(contentsOf: $0) }
        data.append(VarInt(UInt64(chainMerkleBranch.count)).serialize())
        chainMerkleBranch.forEach { data.append($0) }
        withUnsafeBytes(of: chainMerkleIndex.littleEndian) { data.append(contentsOf: $0) }
        data.append(parentBlockHeader.serializeCore())
        return data
    }

    // MARK: - Validation

    /// Validates this proof as the proof of work for a merge-mined Dogecoin
    /// block, following Dogecoin Core's `CheckAuxPowProofOfWork` and
    /// `CAuxPow::check`:
    ///
    /// 1. The block flags AuxPoW and carries Dogecoin's chain ID; the parent
    ///    block does neither.
    /// 2. The coinbase is the first transaction of the parent block.
    /// 3. The parent coinbase commits — once, and in the right place — to a
    ///    chain merkle root containing the block's hash at the slot its nonce
    ///    selects.
    /// 4. The parent block's **scrypt** hash meets the **Dogecoin block's**
    ///    target. The parent's own `nBits` are irrelevant.
    /// - Parameters:
    ///   - header: The Dogecoin block header this proof belongs to
    ///   - network: The network whose consensus rules apply
    /// - Throws: `ValidationError` describing the first failed rule
    public func validate(for header: BlockHeader, network: DogecoinNetwork = .mainnet) throws {
        try validate(for: header, rules: .rules(for: network))
    }

    func validate(for header: BlockHeader, rules: ProofOfWorkRules) throws {
        guard header.isAuxPoW, !parentBlockHeader.isAuxPoW else {
            throw ValidationError.invalidVersion
        }

        if rules.requiresStrictChainID {
            guard header.chainID == ProofOfWorkRules.auxPowChainID else {
                throw ValidationError.invalidChainID(expected: ProofOfWorkRules.auxPowChainID, got: header.chainID)
            }
            guard parentBlockHeader.chainID != header.chainID else {
                throw ValidationError.invalidChainID(expected: ProofOfWorkRules.auxPowChainID, got: parentBlockHeader.chainID)
            }
        }

        try validateCommitment(blockHash: header.hash, chainID: header.chainID)
        try validateParentProofOfWork(bits: header.bits, rules: rules)
    }

    /// Core's `CAuxPow::check`.
    private func validateCommitment(blockHash: Data, chainID: UInt32) throws {
        // The coinbase must be the parent block's first transaction.
        guard coinbaseMerkleIndex == 0 else {
            throw ValidationError.coinbaseIndexMismatch
        }

        guard chainMerkleBranch.count <= Self.maximumChainMerkleBranchLength else {
            throw ValidationError.invalidChainMerkleProof
        }

        // The parent block commits to the coinbase's txid, which excludes
        // witness data — a parent chain with segregated witness may send it.
        guard let coinbase = RawTransaction(data: coinbaseTx),
              Self.merkleRoot(leaf: coinbase.txid, branch: coinbaseMerkleBranch, index: coinbaseMerkleIndex) == parentBlockHeader.merkleRoot else {
            throw ValidationError.invalidCoinbaseMerkleProof
        }

        // The coinbase commits to the chain merkle root in display order.
        let chainRoot = Data(Self.merkleRoot(leaf: blockHash, branch: chainMerkleBranch, index: chainMerkleIndex).reversed())

        guard let script = coinbase.inputs.first?.script,
              let rootRange = script.firstRange(of: chainRoot) else {
            throw ValidationError.missingAuxPowCommitment
        }

        if let headerRange = script.firstRange(of: Self.mergedMiningHeader) {
            // Exactly one merged-mining header, immediately before the root.
            guard script[headerRange.upperBound...].firstRange(of: Self.mergedMiningHeader) == nil,
                  headerRange.upperBound == rootRange.lowerBound else {
                throw ValidationError.invalidChainMerkleProof
            }
        } else {
            // Legacy commitments without the header must start early in the
            // coinbase, so only one root can be committed.
            guard rootRange.lowerBound - script.startIndex <= 20 else {
                throw ValidationError.invalidChainMerkleProof
            }
        }

        // The root is followed by the merkle tree size and nonce.
        let sizeOffset = rootRange.upperBound - script.startIndex
        guard let sizeRaw: UInt32 = script.readInteger(at: sizeOffset),
              let nonceRaw: UInt32 = script.readInteger(at: sizeOffset + 4) else {
            throw ValidationError.invalidChainMerkleProof
        }

        let merkleHeight = chainMerkleBranch.count
        guard UInt32(littleEndian: sizeRaw) == UInt32(1) << UInt32(merkleHeight) else {
            throw ValidationError.invalidChainMerkleProof
        }

        guard chainMerkleIndex == Self.expectedChainIndex(nonce: UInt32(littleEndian: nonceRaw), chainID: chainID, merkleHeight: merkleHeight) else {
            throw ValidationError.coinbaseIndexMismatch
        }
    }

    /// The parent block's scrypt hash must meet the Dogecoin block's target.
    private func validateParentProofOfWork(bits: UInt32, rules: ProofOfWorkRules) throws {
        guard let target = rules.target(forBits: bits) else {
            throw ValidationError.invalidParentDifficulty(bits: bits)
        }

        guard let hash = parentBlockHeader.scryptHashValue, hash <= target else {
            let hashDescription = parentBlockHeader.scryptHashValue?.description ?? "malformed parent header"
            throw ValidationError.invalidParentProofOfWork(hash: hashDescription, target: target.description)
        }
    }

    /// Core's `CAuxPow::CheckMerkleBranch`.
    private static func merkleRoot(leaf: Data, branch: [Data], index: UInt32) -> Data {
        var hash = leaf
        var position = index
        for sibling in branch {
            hash = position & 1 == 1 ? MerkleTree.hashPair(sibling, hash) : MerkleTree.hashPair(hash, sibling)
            position >>= 1
        }
        return hash
    }

    /// Core's `CAuxPow::getExpectedIndex`: a pseudo-random slot in the chain
    /// merkle tree, fixed for a given nonce, chain, and tree height.
    static func expectedChainIndex(nonce: UInt32, chainID: UInt32, merkleHeight: Int) -> UInt32 {
        var random = nonce
        random = random &* 1_103_515_245 &+ 12_345
        random = random &+ chainID
        random = random &* 1_103_515_245 &+ 12_345
        return random % (UInt32(1) << UInt32(merkleHeight))
    }

    // MARK: - Transaction Parsing

    /// Parse a transaction and return (txData, endOffset)
    private static func parseTransaction(in data: Data, from offset: Int) -> (Data, Int)? {
        guard let (_, end) = RawTransaction.decode(in: data, at: offset),
              let transaction = data.bytes(at: offset, count: end - offset) else { return nil }
        return (transaction, end)
    }

    /// The offset just past the proof that starts at `offset`, for readers
    /// that only need what follows it — a merkle block's tree, say, whose
    /// header is already proven. Nothing is copied but the coinbase.
    static func endOffset(in data: Data, at offset: Int) -> Int? {
        guard let (_, coinbaseEnd) = RawTransaction.decode(in: data, at: offset) else { return nil }
        // Parent block hash, then two branches, each followed by its index.
        var position = coinbaseEnd + 32
        for _ in 0..<2 {
            guard let (count, countSize) = data.readBoundedCount(at: position, minItemSize: 32) else { return nil }
            position += countSize + count * 32 + 4
        }
        position += BlockHeader.size
        return position <= data.count ? position : nil
    }

    /// Parse merkle branch from data.
    /// The count is peer-supplied — bound it by the remaining bytes before
    /// reserving capacity so a fabricated count cannot force a huge allocation.
    private static func parseMerkleBranch(from data: Data, at offset: Int) -> ([Data], Int)? {
        guard let (count, countSize) = data.readBoundedCount(at: offset, minItemSize: 32) else { return nil }
        var pos = offset + countSize

        var branch: [Data] = []
        branch.reserveCapacity(count)

        for _ in 0..<count {
            guard let hash = data.bytes(at: pos, count: 32) else { return nil }
            branch.append(hash)
            pos += 32
        }

        return (branch, pos - offset)
    }
}

// MARK: - Check if block version indicates AuxPoW

extension AuxPoW {
    /// Check if a block version indicates AuxPoW (merged mining)
    public static func isAuxPow(version: Int32) -> Bool {
        (version & 0x100) == 0x100
    }
}
