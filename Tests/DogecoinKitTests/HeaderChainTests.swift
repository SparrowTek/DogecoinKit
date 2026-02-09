import Foundation
import Testing
@testable import DogecoinKit

@Suite("HeaderChain Tests")
struct HeaderChainTests {
    init() async {
        await Dogecoin.initialize()
    }

    @Test("Mainnet genesis hash matches expected checkpoint")
    func testMainnetGenesisHash() async {
        let storageURL = temporaryStorageURL()
        let chain = HeaderChain(network: .mainnet, storageDirectory: storageURL)
        await chain.setup()

        let genesis = await chain.getHeader(height: 0)
        #expect(genesis != nil)
        #expect(genesis?.header.hashHex == "1a91e3dace36e2be3bf030a65679fe821aa1d6ef92e7c9902eb318182c355691")
    }

    @Test("Testnet genesis hash matches expected checkpoint")
    func testTestnetGenesisHash() async {
        let storageURL = temporaryStorageURL()
        let chain = HeaderChain(network: .testnet, storageDirectory: storageURL)
        await chain.setup()

        let genesis = await chain.getHeader(height: 0)
        #expect(genesis != nil)
        #expect(genesis?.header.hashHex == "bb0a78264637406b6360aad926284d544d7049f45189db5664f3c4d07350559e")
    }

    @Test("Median time past validation rejects stale timestamps")
    func testMedianTimePast() async throws {
        let storageURL = temporaryStorageURL()
        let chain = HeaderChain(network: .testnet, storageDirectory: storageURL)
        await chain.setup()

        let genesisResult = await chain.getHeader(height: 0)
        #expect(genesisResult != nil)
        guard let genesis = genesisResult else { return }

        let header1 = makeHeader(
            prevHash: genesis.header.hash,
            timestamp: genesis.header.timestamp + 1,
            bits: 0x1e0ffff0,
            nonce: 1,
            merkleSeed: 1
        )
        try await chain.addHeaderValidated(header1)

        let header2 = makeHeader(
            prevHash: header1.hash,
            timestamp: header1.timestamp,
            bits: 0x1e0ffff0,
            nonce: 2,
            merkleSeed: 2
        )

        await #expect(throws: HeaderChain.ValidationError.self) {
            try await chain.addHeaderValidated(header2)
        }
    }

    @Test("Reorg chooses higher chainwork over height")
    func testReorgByChainwork() async throws {
        let storageURL = temporaryStorageURL()
        let chain = HeaderChain(network: .testnet, storageDirectory: storageURL)
        await chain.setup()

        let genesisResult = await chain.getHeader(height: 0)
        #expect(genesisResult != nil)
        guard let genesis = genesisResult else { return }

        let chainATime = genesis.header.timestamp + 100
        let a1 = makeHeader(
            prevHash: genesis.header.hash,
            timestamp: chainATime,
            bits: 0x1e0ffff0,
            nonce: 10,
            merkleSeed: 10
        )
        try await chain.addHeaderValidated(a1)

        let a2 = makeHeader(
            prevHash: a1.hash,
            timestamp: chainATime + 1,
            bits: 0x1e0ffff0,
            nonce: 11,
            merkleSeed: 11
        )
        try await chain.addHeaderValidated(a2)

        let tip = await chain.tip
        #expect(tip?.header.hash == a2.hash)

        let chainBTime = genesis.header.timestamp + 10
        let b1 = makeHeader(
            prevHash: genesis.header.hash,
            timestamp: chainBTime,
            bits: 0x1e0ffff0,
            nonce: 20,
            merkleSeed: 20
        )
        try await chain.addHeaderValidated(b1)

        let b2 = makeHeader(
            prevHash: b1.hash,
            timestamp: chainBTime + 1,
            bits: 0x1e0ffff0,
            nonce: 21,
            merkleSeed: 21
        )
        try await chain.addHeaderValidated(b2)

        let b3 = makeHeader(
            prevHash: b2.hash,
            timestamp: chainBTime + 2,
            bits: 0x1e0ffff0,
            nonce: 22,
            merkleSeed: 22
        )
        try await chain.addHeaderValidated(b3)

        let finalTip = await chain.tip
        #expect(finalTip?.header.hash == b3.hash)

        let header1 = await chain.getHeader(height: 1)
        #expect(header1?.header.hash == b1.hash)

        let header2 = await chain.getHeader(height: 2)
        #expect(header2?.header.hash == b2.hash)
    }

    private func temporaryStorageURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeHeader(
        prevHash: Data,
        timestamp: UInt32,
        bits: UInt32,
        nonce: UInt32,
        merkleSeed: UInt8
    ) -> BlockHeader {
        BlockHeader(
            version: 0x100,
            prevBlock: prevHash,
            merkleRoot: Data(repeating: merkleSeed, count: 32),
            timestamp: timestamp,
            bits: bits,
            nonce: nonce
        )
    }
}
