import Foundation
import os.log

/// Fetches UTXOs for addresses from blockchain APIs
/// This is a temporary MVP solution - full SPV implementation would use bloom filters
public actor UTXOFetcher {

    /// The network to query
    public let network: DogecoinNetwork

    /// Logger
    private let logger = Logger(subsystem: "DogecoinKit", category: "UTXOFetcher")

    /// Rate limiting: minimum interval between requests
    private let requestInterval: TimeInterval = 0.5

    /// Last request timestamp
    private var lastRequestTime: Date?

    /// Create a UTXO fetcher for a network
    public init(network: DogecoinNetwork = .mainnet) {
        self.network = network
    }

    // MARK: - Public API

    /// Fetch UTXOs for a single address
    /// - Parameter address: The Dogecoin address
    /// - Returns: Array of UTXOs for the address
    public func fetchUTXOs(for address: String) async throws -> [UTXO] {
        await rateLimit()

        // Use Blockcypher API for both mainnet and testnet
        let baseURL: String
        switch network {
        case .mainnet:
            baseURL = "https://api.blockcypher.com/v1/doge/main"
        case .testnet:
            baseURL = "https://api.blockcypher.com/v1/doge/test3"
        }

        let urlString = "\(baseURL)/addrs/\(address)?unspentOnly=true"
        guard let url = URL(string: urlString) else {
            throw DogecoinError.internalError("Invalid URL for address: \(address)")
        }

        logger.info("Fetching UTXOs for \(address)")

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DogecoinError.internalError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            // Handle rate limiting
            if httpResponse.statusCode == 429 {
                logger.warning("Rate limited, waiting...")
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                return try await fetchUTXOs(for: address)
            }

            // Handle no transactions case (returns 404)
            if httpResponse.statusCode == 404 {
                return []
            }

            throw DogecoinError.internalError("API error: HTTP \(httpResponse.statusCode)")
        }

        return try parseBlockcypherResponse(data, address: address)
    }

    /// Fetch UTXOs for multiple addresses
    /// - Parameter addresses: Array of Dogecoin addresses
    /// - Returns: Dictionary mapping addresses to their UTXOs
    public func fetchUTXOs(for addresses: [String]) async throws -> [String: [UTXO]] {
        var result: [String: [UTXO]] = [:]

        for address in addresses {
            do {
                let utxos = try await fetchUTXOs(for: address)
                result[address] = utxos
            } catch {
                logger.error("Failed to fetch UTXOs for \(address): \(error.localizedDescription)")
                result[address] = []
            }
        }

        return result
    }

    /// Fetch total balance for an address
    /// - Parameter address: The Dogecoin address
    /// - Returns: Total balance in koinu
    public func fetchBalance(for address: String) async throws -> UInt64 {
        let utxos = try await fetchUTXOs(for: address)
        return utxos.reduce(0) { $0 + $1.amount.koinu }
    }

    // MARK: - Private Methods

    /// Rate limiting
    private func rateLimit() async {
        if let lastRequest = lastRequestTime {
            let elapsed = Date().timeIntervalSince(lastRequest)
            if elapsed < requestInterval {
                let delay = UInt64((requestInterval - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        lastRequestTime = Date()
    }

    /// Parse Blockcypher API response
    private func parseBlockcypherResponse(_ data: Data, address: String) throws -> [UTXO] {
        let decoder = JSONDecoder()
        let response = try decoder.decode(BlockcypherAddressResponse.self, from: data)

        var utxos: [UTXO] = []

        for txref in response.txrefs ?? [] {
            // Only include unspent outputs
            guard txref.spent == false else { continue }

            let utxo = UTXO(
                txid: txref.txHash,
                vout: txref.txOutputN,
                address: address,
                amount: DogecoinAmount(koinu: UInt64(txref.value)),
                scriptPubKey: txref.script,
                confirmations: txref.confirmations
            )
            utxos.append(utxo)
        }

        // Also check unconfirmed outputs
        for txref in response.unconfirmedTxrefs ?? [] {
            guard txref.spent == false else { continue }

            let utxo = UTXO(
                txid: txref.txHash,
                vout: txref.txOutputN,
                address: address,
                amount: DogecoinAmount(koinu: UInt64(txref.value)),
                scriptPubKey: txref.script,
                confirmations: 0
            )
            utxos.append(utxo)
        }

        logger.info("Found \(utxos.count) UTXOs for \(address)")
        return utxos
    }
}

// MARK: - Blockcypher API Response Models

private struct BlockcypherAddressResponse: Decodable {
    let address: String
    let totalReceived: Int?
    let totalSent: Int?
    let balance: Int?
    let unconfirmedBalance: Int?
    let finalBalance: Int?
    let nTx: Int?
    let unconfirmedNTx: Int?
    let finalNTx: Int?
    let txrefs: [BlockcypherTxRef]?
    let unconfirmedTxrefs: [BlockcypherTxRef]?

    enum CodingKeys: String, CodingKey {
        case address
        case totalReceived = "total_received"
        case totalSent = "total_sent"
        case balance
        case unconfirmedBalance = "unconfirmed_balance"
        case finalBalance = "final_balance"
        case nTx = "n_tx"
        case unconfirmedNTx = "unconfirmed_n_tx"
        case finalNTx = "final_n_tx"
        case txrefs
        case unconfirmedTxrefs = "unconfirmed_txrefs"
    }
}

private struct BlockcypherTxRef: Decodable {
    let txHash: String
    let blockHeight: Int?
    let txInputN: Int
    let txOutputN: Int
    let value: Int
    let refBalance: Int?
    let spent: Bool
    let confirmations: Int
    let confirmed: String?
    let doubleSpend: Bool?
    let script: String?

    enum CodingKeys: String, CodingKey {
        case txHash = "tx_hash"
        case blockHeight = "block_height"
        case txInputN = "tx_input_n"
        case txOutputN = "tx_output_n"
        case value
        case refBalance = "ref_balance"
        case spent
        case confirmations
        case confirmed
        case doubleSpend = "double_spend"
        case script
    }
}
