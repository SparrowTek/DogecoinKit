import Testing
@testable import DogecoinKit

@Suite("Version Message Parsing")
struct VersionMessageTests {
    @Test("Parse version message with extended user agent")
    func testParseWithExtendedUserAgent() {
        let userAgent = String(repeating: "a", count: 253)
        let addrRecv = NetworkAddress.ipv4("127.0.0.1", port: 22556, services: 1)
        let addrFrom = NetworkAddress.ipv4("10.0.0.2", port: 22556, services: 9)

        let message = VersionMessage(
            version: 70_015,
            services: 1,
            timestamp: 1_700_000_000,
            addrRecv: addrRecv,
            addrFrom: addrFrom,
            nonce: 0x1122334455667788,
            userAgent: userAgent,
            startHeight: 12_345,
            relay: false
        )

        let parsed = VersionMessage.parse(from: message.serialize())

        #expect(parsed != nil)
        #expect(parsed?.version == message.version)
        #expect(parsed?.services == message.services)
        #expect(parsed?.timestamp == message.timestamp)
        #expect(parsed?.addrRecv.services == addrRecv.services)
        #expect(parsed?.addrRecv.address == addrRecv.address)
        #expect(parsed?.addrRecv.port == addrRecv.port)
        #expect(parsed?.addrFrom.services == addrFrom.services)
        #expect(parsed?.addrFrom.address == addrFrom.address)
        #expect(parsed?.addrFrom.port == addrFrom.port)
        #expect(parsed?.nonce == message.nonce)
        #expect(parsed?.userAgent == userAgent)
        #expect(parsed?.startHeight == message.startHeight)
        #expect(parsed?.relay == message.relay)
    }
}
