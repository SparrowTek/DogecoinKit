import Testing
@testable import DogecoinKit
import CryptoKit
import Foundation

@Suite("Electrum Client Tests")
struct ElectrumClientTests {

    init() async {
        await Dogecoin.initialize()
    }

    private func requireIntegrationTests() -> Bool {
        ProcessInfo.processInfo.environment["ELECTRUM_INTEGRATION_TESTS"] == "1"
    }

    @Test("Connect to mainnet server")
    func testConnect() async throws {
        guard requireIntegrationTests() else { return }
        guard let server = ElectrumServerList.randomServer(for: .mainnet) else {
            Issue.record("No servers available")
            return
        }

        let client = ElectrumClient(server: server)
        try await client.connect()

        // Should be connected now
        try await client.serverPing()

        await client.disconnect()
    }

    @Test("Get balance for known address")
    func testGetBalance() async throws {
        guard requireIntegrationTests() else { return }
        guard let server = ElectrumServerList.randomServer(for: .mainnet) else {
            Issue.record("No servers available")
            return
        }

        let client = ElectrumClient(server: server)
        try await client.connect()

        // Use a known Dogecoin address
        let scriptHash = try ElectrumScriptHash(
            address: "D7Y55gKBKsQrXmgbVRH9bEP7BWCN3zwhSr",
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
        guard let server = ElectrumServerList.randomServer(for: .mainnet) else {
            Issue.record("No servers available")
            return
        }

        let client = ElectrumClient(server: server)
        try await client.connect()

        let header = try await client.subscribeHeaders()

        // Height should be reasonable (Dogecoin has millions of blocks)
        #expect(header.height > 1_000_000)

        await client.disconnect()
    }

    @Test("Script hash uses P2PKH scriptPubKey format")
    func testScriptHashComputation() throws {
        let address = "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"
        let pubkeyHash = try Address.toPubkeyHash(address)
        let scriptPubKeyHex = "76a914\(pubkeyHash)88ac"
        let scriptPubKey = try #require(Data(hexString: scriptPubKeyHex))
        let expected = Data(SHA256.hash(data: scriptPubKey).reversed()).hexString

        let scriptHash = try ElectrumScriptHash(address: address, network: .mainnet)
        #expect(scriptHash.scriptHash == expected)
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
