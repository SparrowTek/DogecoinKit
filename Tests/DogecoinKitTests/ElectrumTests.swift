import Testing
@testable import DogecoinKit

@Suite("Electrum Client Tests")
struct ElectrumClientTests {

    init() {
        Dogecoin.initialize()
    }

    private func requireIntegrationTests() -> Bool {
        let enabled = ProcessInfo.processInfo.environment["ELECTRUM_INTEGRATION_TESTS"] == "1"
        if !enabled {
            Issue.record("Skipping Electrum integration test. Set ELECTRUM_INTEGRATION_TESTS=1 to enable.")
        }
        return enabled
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
}

@Suite("Electrum Sync Manager Tests")
struct ElectrumSyncManagerTests {

    private func requireIntegrationTests() -> Bool {
        let enabled = ProcessInfo.processInfo.environment["ELECTRUM_INTEGRATION_TESTS"] == "1"
        if !enabled {
            Issue.record("Skipping Electrum integration test. Set ELECTRUM_INTEGRATION_TESTS=1 to enable.")
        }
        return enabled
    }

    @Test("Start and stop sync")
    func testStartStop() async throws {
        guard requireIntegrationTests() else { return }

        let manager = ElectrumSyncManager(network: .mainnet)

        try await manager.start()
        #expect(manager.state.isConnected)
        #expect(manager.currentHeight > 0)

        manager.stop()
        #expect(!manager.state.isConnected)
    }
}
