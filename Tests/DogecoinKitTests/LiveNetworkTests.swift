import Foundation
import Testing
@testable import DogecoinKit

/// Waits for a peer's handshake and its first `headers` reply.
private final class LivePeerObserver: PeerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var closed = false
    private var headersPayload: Data?

    var isReady: Bool { lock.withLock { ready } }
    var isClosed: Bool { lock.withLock { closed } }
    var headers: Data? { lock.withLock { headersPayload } }

    func peer(_ peer: Peer, didChangeState state: Peer.State) async {
        lock.withLock {
            if state == .ready { ready = true }
            if state == .disconnected { closed = true }
        }
    }

    func peer(_ peer: Peer, didReceiveMessage message: ProtocolMessage) async {
        guard message.command == ProtocolMessage.Command.headers else { return }
        lock.withLock { headersPayload = message.payload }
    }

    func peer(_ peer: Peer, didFailWithError error: Error) async {
        lock.withLock { closed = true }
    }
}

/// Talks to the real Dogecoin network. Opt-in: `DOGECOINKIT_LIVE_P2P=1`.
@Suite("Live P2P Network", .timeLimit(.minutes(5)))
struct LiveNetworkTests {

    @Test(
        "Headers from a live node pass full validation, AuxPoW and DigiShield included",
        .enabled(if: TestEnvironment.runsLiveP2PTests)
    )
    func liveHeadersValidate() async throws {
        let directory = TestDirectories.unique()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try HeaderDatabase(path: directory.appendingPathComponent("headers.sqlite").path)
        try database.insertHeaders(RealChainFixtures.storedAncestors().map { HeaderRecord(storedHeader: $0, isInBestChain: true) })
        let chain = HeaderChain(network: .mainnet, storageDirectory: directory)
        try await chain.setup()
        let tip = try #require(await chain.tip)

        let hosts = ["184.160.37.131"] + NetworkConstants.mainnetFallbackNodes.map(\.host)
        for host in hosts {
            let observer = LivePeerObserver()
            let peer = Peer(host: host, network: .mainnet)
            await peer.setDelegate(observer)
            await peer.configureTimeouts(connection: 8, handshake: 15)
            await peer.connect()

            guard await eventually(timeout: .seconds(20), { observer.isReady || observer.isClosed }), observer.isReady else {
                await peer.disconnect()
                continue
            }

            await peer.sendGetHeaders(locatorHashes: [tip.header.hash])
            guard await eventually(timeout: .seconds(60), { observer.headers != nil || observer.isClosed }),
                  let payload = observer.headers else {
                await peer.disconnect()
                continue
            }
            await peer.disconnect()

            let message = try #require(HeadersMessage.parse(from: payload))
            #expect(message.entries.count == 2000)
            #expect(message.entries.allSatisfy { !$0.header.isAuxPoW || $0.auxpow != nil })

            let result = await chain.addHeaders(message.entries)
            #expect(result.failure == nil, "live header rejected: \(String(describing: result.failure))")
            #expect(result.added == message.entries.count)
            #expect(await chain.height == tip.height + Int32(message.entries.count))
            print("Validated \(result.added) live headers from \(host); tip now \(await chain.height)")
            return
        }

        Issue.record("No live Dogecoin node answered")
    }
}
