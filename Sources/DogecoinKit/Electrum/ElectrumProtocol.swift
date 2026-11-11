import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(os)
import os.log
#endif

private let electrumProtocolLogger = Logger(subsystem: "DogecoinKit", category: "electrum")

// MARK: - JSON-RPC Request

public struct ElectrumRequest: Encodable, Sendable {
    public let jsonrpc: String = "2.0"
    public let id: Int
    public let method: String
    public let params: [ElectrumParam]

    public init(id: Int, method: String, params: [ElectrumParam] = []) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public enum ElectrumParam: Encodable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        }
    }
}

// MARK: - JSON-RPC Response

/// What a reply carries. The id that pairs it with its request is read
/// before this is decoded, by the envelope that routes replies.
public struct ElectrumResponse<T: Decodable>: Decodable, Sendable where T: Sendable {
    public let result: T?
    public let error: ElectrumRPCError?

    private enum CodingKeys: String, CodingKey {
        case result
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decodeIfPresent(T.self, forKey: .result)
        error = try container.decodeIfPresent(ElectrumRPCError.self, forKey: .error)
    }
}

public struct ElectrumRPCError: Decodable, Sendable {
    public let code: Int
    public let message: String
}

/// Marker type for JSON-RPC methods that return `null` (e.g. server.ping)
public struct ElectrumNull: Decodable, Sendable {
    public init() {}
}

// MARK: - Electrum Data Types

public struct ElectrumScriptHash: Sendable {
    public let scriptHash: String

    public init(address: String, network: DogecoinNetwork) throws {
        // Convert address to scriptPubKey, then SHA256, then reverse bytes
        self.scriptHash = try Self.computeScriptHash(for: address, network: network)
    }

    /// Electrum indexes outputs by `sha256(scriptPubKey)`, byte-reversed.
    private static func computeScriptHash(for address: String, network: DogecoinNetwork) throws -> String {
        guard Address.detectNetwork(address) == network,
              let scriptPubKey = Address.scriptPubKey(for: address) else {
            electrumProtocolLogger.error("Address network mismatch: \(address, privacy: .private)")
            throw ElectrumError.invalidAddress(address)
        }

        return Data(SHA256.hash(data: scriptPubKey).reversed()).hexString
    }
}

public struct ElectrumBalance: Decodable, Sendable {
    public let confirmed: Int64
    /// Can be negative while an outgoing spend is in the mempool
    public let unconfirmed: Int64

    /// Confirmed plus unconfirmed, saturating instead of trapping when a
    /// misbehaving server reports values whose sum overflows `Int64`.
    public var total: Int64 {
        let (sum, overflow) = confirmed.addingReportingOverflow(unconfirmed)
        guard overflow else { return sum }
        return unconfirmed < 0 ? .min : .max
    }

    private enum CodingKeys: String, CodingKey {
        case confirmed
        case unconfirmed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let confirmed = try container.decode(Int64.self, forKey: .confirmed)
        guard confirmed >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .confirmed, in: container, debugDescription: "Negative confirmed balance")
        }
        self.confirmed = confirmed
        self.unconfirmed = try container.decode(Int64.self, forKey: .unconfirmed)
    }
}

public struct ElectrumHistoryItem: Decodable, Sendable {
    public let txHash: String
    /// The height of the block that holds the transaction; zero or less
    /// while it is unconfirmed
    public let height: Int

    private enum CodingKeys: String, CodingKey {
        case txHash = "tx_hash"
        case height
    }
}

public struct ElectrumUTXO: Decodable, Sendable {
    public let txHash: String
    public let txPos: Int
    public let height: Int
    public let value: Int64

    private enum CodingKeys: String, CodingKey {
        case txHash = "tx_hash"
        case txPos = "tx_pos"
        case height
        case value
    }

    public var outpoint: String {
        "\(txHash):\(txPos)"
    }

    /// Rejects outputs no honest server reports — negative values or indexes,
    /// malformed txids — so callers can convert them to unsigned types and
    /// hand them to the transaction builder without trapping.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let txHash = try container.decode(String.self, forKey: .txHash)
        guard txHash.utf8.count == 64, Data(hexString: txHash) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .txHash, in: container, debugDescription: "Malformed txid")
        }
        let txPos = try container.decode(Int.self, forKey: .txPos)
        guard UInt32(exactly: txPos) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .txPos, in: container, debugDescription: "Output index out of range")
        }
        let value = try container.decode(Int64.self, forKey: .value)
        guard value >= 0, UInt64(value) <= DogecoinAmount.maxMoney.koinu else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "Output value out of range")
        }

        self.txHash = txHash
        self.txPos = txPos
        self.height = try container.decode(Int.self, forKey: .height)
        self.value = value
    }
}

public struct ElectrumHeader: Decodable, Sendable {
    public let height: Int

    private enum CodingKeys: String, CodingKey {
        case height
    }

    /// Heights outside `Int32` are rejected here so they can never trap a
    /// later conversion to the chain-height type used everywhere else.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let height = try container.decode(Int.self, forKey: .height)
        guard Int32(exactly: height).map({ $0 >= 0 }) == true else {
            throw DecodingError.dataCorruptedError(forKey: .height, in: container, debugDescription: "Block height out of range")
        }
        self.height = height
    }
}

/// What a server says about itself — of which only the chain it serves
/// matters here.
struct ElectrumServerFeatures: Decodable, Sendable {
    /// The hash of the first block of the chain the server indexes, in
    /// display byte order
    let genesisHash: String

    private enum CodingKeys: String, CodingKey {
        case genesisHash = "genesis_hash"
    }
}

// MARK: - Electrum Methods

public enum ElectrumMethod: String, Sendable {
    // Server methods
    case serverVersion = "server.version"
    case serverFeatures = "server.features"
    case serverPing = "server.ping"

    // Blockchain methods
    case blockchainHeadersSubscribe = "blockchain.headers.subscribe"
    case blockchainBlockHeader = "blockchain.block.header"

    // Script hash methods (address queries)
    case blockchainScripthashGetBalance = "blockchain.scripthash.get_balance"
    case blockchainScripthashGetHistory = "blockchain.scripthash.get_history"
    case blockchainScripthashListUnspent = "blockchain.scripthash.listunspent"
    case blockchainScripthashSubscribe = "blockchain.scripthash.subscribe"

    // Transaction methods
    case blockchainTransactionGet = "blockchain.transaction.get"
    case blockchainTransactionBroadcast = "blockchain.transaction.broadcast"
}
