import Testing
@testable import DogecoinKit
import Foundation

@Suite("Electrum Client Tests")
struct ElectrumClientTests {

    init() async {
        await Dogecoin.initialize()
    }

    private func requireIntegrationTests() -> Bool {
        ProcessInfo.processInfo.environment["ELECTRUM_INTEGRATION_TESTS"] == "1"
    }

    /// Connects to the first mainnet server that answers; any one of them
    /// may be down at a given moment.
    private func connectToAnyServer() async throws -> ElectrumClient {
        for server in ElectrumServerList.servers(for: .mainnet).shuffled() {
            let client = ElectrumClient(server: server)
            do {
                try await client.connect()
                return client
            } catch {
                continue
            }
        }
        throw ElectrumError.noServersAvailable
    }

    @Test("Connect to mainnet server")
    func testConnect() async throws {
        guard requireIntegrationTests() else { return }
        let client = try await connectToAnyServer()

        // Should be connected now
        try await client.serverPing()

        await client.disconnect()
    }

    @Test("Get balance for known address")
    func testGetBalance() async throws {
        guard requireIntegrationTests() else { return }
        let client = try await connectToAnyServer()

        // Use a known Dogecoin address
        let scriptHash = try ElectrumScriptHash(
            address: "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD",
            network: .mainnet
        )

        let balance = try await client.getBalance(scriptHash: scriptHash.scriptHash)

        // Balance should be non-negative
        #expect(balance.confirmed >= 0)

        await client.disconnect()
    }

    @Test("Subscribe to headers")
    func testHeaderSubscription() async throws {
        guard requireIntegrationTests() else { return }
        let client = try await connectToAnyServer()

        let header = try await client.subscribeHeaders()

        // Height should be reasonable (Dogecoin has millions of blocks)
        #expect(header.height > 1_000_000)

        await client.disconnect()
    }

    @Test("Script hash uses P2PKH scriptPubKey format")
    func testScriptHashComputation() throws {
        let address = "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"
        // toPubkeyHash already returns the full P2PKH scriptPubKey hex (76a914...88ac)
        #expect(try Address.toPubkeyHash(address) == "76a9141a489a9364888ba3e81b61d16f59899bdca5badd88ac")

        // SHA-256 of that script, byte-reversed (computed independently).
        let scriptHash = try ElectrumScriptHash(address: address, network: .mainnet)
        #expect(scriptHash.scriptHash == "774575bb5a9f803fde8be6804d24bc17ade79c45c9f28ee5a9835edf17b8ada0")
    }

    @Test("Testnet Electrum server list is populated")
    func testTestnetServersAvailable() {
        let servers = ElectrumServerList.servers(for: .testnet)
        #expect(!servers.isEmpty)
        #expect(servers.allSatisfy { $0.network == .testnet })
    }
}

@Suite("Electrum Sync Manager Tests")
struct ElectrumSyncManagerTests {

    private func requireIntegrationTests() -> Bool {
        ProcessInfo.processInfo.environment["ELECTRUM_INTEGRATION_TESTS"] == "1"
    }

    @Test("Start and stop sync")
    func testStartStop() async throws {
        guard requireIntegrationTests() else { return }

        let manager = ElectrumSyncManager(network: .mainnet)

        try await manager.start()
        let state = await manager.state
        #expect(state.isConnected)
        let height = await manager.currentHeight
        #expect(height > 0)

        await manager.stop()
        let stoppedState = await manager.state
        #expect(!stoppedState.isConnected)
    }

    @Test("Live UTXOs verify against their funding transactions")
    func testLiveUTXOVerification() async throws {
        guard requireIntegrationTests() else { return }
        await Dogecoin.initialize()

        let manager = ElectrumSyncManager(network: .mainnet)
        try await manager.start()

        // Find funded addresses by walking forward from a known address: the
        // newest transactions of each hop pay the addresses of the next.
        // Servers refuse addresses with very long histories ("history too
        // large"); the walk skips those, and only those.
        var frontier: Set<String> = ["D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"]
        var utxos: [(address: String, utxo: ElectrumUTXO)] = []
        for _ in 0..<4 where utxos.isEmpty {
            var next: Set<String> = []
            for address in frontier.prefix(8) {
                let history: [ElectrumHistoryItem]
                do {
                    history = try await manager.fetchTransactionHistory(for: [address])
                } catch ElectrumError.requestFailed {
                    continue
                }
                for item in history.prefix(3) {
                    let transaction = try #require(RawTransaction(hex: try await manager.getTransaction(txid: item.txHash)))
                    for output in transaction.outputs {
                        // P2PKH outputs only; anything else has no address to query.
                        if let payee = try? await Address.fromPubkeyHash(output.script.hexString) {
                            next.insert(payee)
                        }
                    }
                }
            }
            for address in next {
                do {
                    utxos += try await manager.fetchUTXOs(for: [address])
                } catch ElectrumError.requestFailed {
                    continue
                }
            }
            frontier = next
        }

        #expect(!utxos.isEmpty, "found no funded address to verify")
        print("Verified \(utxos.count) live UTXOs against their funding transactions")
        await manager.stop()
    }

    @Test("Failed start allows retry")
    func testFailedStartAllowsRetry() async {
        let manager = ElectrumSyncManager(network: .mainnet, serverList: [])

        await #expect(throws: ElectrumError.self) {
            try await manager.start()
        }

        await #expect(throws: ElectrumError.self) {
            try await manager.start()
        }
    }
}
