import Foundation
import CryptoKit

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
    case array([ElectrumParam])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        }
    }
}

// MARK: - JSON-RPC Response

public struct ElectrumResponse<T: Decodable>: Decodable, Sendable where T: Sendable {
    public let jsonrpc: String
    public let id: Int?
    public let result: T?
    public let error: ElectrumRPCError?
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
    public let address: String
    public let scriptHash: String

    public init(address: String, network: DogecoinNetwork) throws {
        self.address = address
        // Convert address to scriptPubKey, then SHA256, then reverse bytes
        self.scriptHash = try Self.computeScriptHash(for: address, network: network)
    }

    private static func computeScriptHash(for address: String, network: DogecoinNetwork) throws -> String {
        guard let detectedNetwork = Address.detectNetwork(address),
              detectedNetwork == network else {
            print("[ElectrumScriptHash] Address network mismatch: \(address)")
            throw ElectrumError.invalidAddress(address)
        }

        let pubkeyHashHex: String
        do {
            pubkeyHashHex = try Address.toPubkeyHash(address)
        } catch {
            print("[ElectrumScriptHash] Failed to get scriptPubKey for \(address): \(error)")
            throw ElectrumError.invalidAddress(address)
        }
        let scriptPubKeyHex = pubkeyHashHex
        guard let scriptPubKey = Data(hexString: scriptPubKeyHex) else {
            print("[ElectrumScriptHash] Invalid scriptPubKey hex: \(scriptPubKeyHex)")
            throw ElectrumError.serializationError("Invalid scriptPubKey")
        }

        let hash = SHA256.hash(data: scriptPubKey)
        let result = Data(hash.reversed()).hexString
        return result
    }
}

public struct ElectrumBalance: Decodable, Sendable {
    public let confirmed: Int64
    public let unconfirmed: Int64

    public var total: Int64 {
        confirmed + unconfirmed
    }
}

public struct ElectrumHistoryItem: Decodable, Sendable {
    public let txHash: String
    public let height: Int
    public let fee: Int?

    private enum CodingKeys: String, CodingKey {
        case txHash = "tx_hash"
        case height
        case fee
    }

    public var isConfirmed: Bool {
        height > 0
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

    public var isConfirmed: Bool {
        height > 0
    }
}

public struct ElectrumTransaction: Sendable {
    public let txid: String
    public let rawHex: String
    public let blockHeight: Int?
    public let blockHash: String?
    public let timestamp: Date?
    public let fee: Int64?

    public var isConfirmed: Bool {
        guard let height = blockHeight else { return false }
        return height > 0
    }
}

public struct ElectrumHeader: Decodable, Sendable {
    public let height: Int
    public let hex: String
}

public struct ElectrumServerInfo: Decodable, Sendable {
    public let genesisHash: String
    public let serverVersion: String
    public let protocolMin: String
    public let protocolMax: String
    public let hashFunction: String

    private enum CodingKeys: String, CodingKey {
        case genesisHash = "genesis_hash"
        case serverVersion = "server_version"
        case protocolMin = "protocol_min"
        case protocolMax = "protocol_max"
        case hashFunction = "hash_function"
    }
}

// MARK: - Electrum Methods

public enum ElectrumMethod: String, Sendable {
    // Server methods
    case serverVersion = "server.version"
    case serverBanner = "server.banner"
    case serverFeatures = "server.features"
    case serverPing = "server.ping"

    // Blockchain methods
    case blockchainHeadersSubscribe = "blockchain.headers.subscribe"
    case blockchainBlockHeader = "blockchain.block.header"
    case blockchainEstimateFee = "blockchain.estimatefee"
    case blockchainRelayFee = "blockchain.relayfee"

    // Script hash methods (address queries)
    case blockchainScripthashGetBalance = "blockchain.scripthash.get_balance"
    case blockchainScripthashGetHistory = "blockchain.scripthash.get_history"
    case blockchainScripthashGetMempool = "blockchain.scripthash.get_mempool"
    case blockchainScripthashListUnspent = "blockchain.scripthash.listunspent"
    case blockchainScripthashSubscribe = "blockchain.scripthash.subscribe"
    case blockchainScripthashUnsubscribe = "blockchain.scripthash.unsubscribe"

    // Transaction methods
    case blockchainTransactionGet = "blockchain.transaction.get"
    case blockchainTransactionGetMerkle = "blockchain.transaction.get_merkle"
    case blockchainTransactionBroadcast = "blockchain.transaction.broadcast"
}
