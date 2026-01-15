import Foundation
import Testing
@testable import DogecoinKit

@Suite("HeaderChain Tests")
struct HeaderChainTests {
    init() {
        Dogecoin.initialize()
    }

    @Test("Median time past validation rejects stale timestamps")
    func testMedianTimePast() throws {
        let storageURL = temporaryStorageURL()
        let chain = HeaderChain(network: .testnet, storageDirectory: storageURL)

        #expect(chain.getHeader(height: 0) != nil)
        guard let genesis = chain.getHeader(height: 0) else { return }

        let header1 = makeHeader(
            prevHash: genesis.header.hash,
            timestamp: genesis.header.timestamp + 1,
            bits: 0x1e0ffff0,
            nonce: 1,
            merkleSeed: 1
        )
        try chain.addHeaderValidated(header1)

        let header2 = makeHeader(
            prevHash: header1.hash,
            timestamp: header1.timestamp,
            bits: 0x1e0ffff0,
            nonce: 2,
            merkleSeed: 2
        )

        #expect(throws: HeaderChain.ValidationError.self) {
            try chain.addHeaderValidated(header2)
        }
    }

    @Test("Reorg chooses higher chainwork over height")
    func testReorgByChainwork() throws {
        let storageURL = temporaryStorageURL()
        let chain = HeaderChain(network: .testnet, storageDirectory: storageURL)

        #expect(chain.getHeader(height: 0) != nil)
        guard let genesis = chain.getHeader(height: 0) else { return }

        let chainATime = genesis.header.timestamp + 100
        let a1 = makeHeader(
            prevHash: genesis.header.hash,
            timestamp: chainATime,
            bits: 0x1e0ffff0,
            nonce: 10,
            merkleSeed: 10
        )
        try chain.addHeaderValidated(a1)

        let a2 = makeHeader(
            prevHash: a1.hash,
            timestamp: chainATime + 1,
            bits: 0x1e0ffff0,
            nonce: 11,
            merkleSeed: 11
        )
        try chain.addHeaderValidated(a2)

        #expect(chain.tip?.header.hash == a2.hash)

        let chainBTime = genesis.header.timestamp + 10
        let b1 = makeHeader(
            prevHash: genesis.header.hash,
            timestamp: chainBTime,
            bits: 0x1e0ffff0,
            nonce: 20,
            merkleSeed: 20
        )
        try chain.addHeaderValidated(b1)

        let b2 = makeHeader(
            prevHash: b1.hash,
            timestamp: chainBTime + 1,
            bits: 0x1e0ffff0,
            nonce: 21,
            merkleSeed: 21
        )
        try chain.addHeaderValidated(b2)

        let b3 = makeHeader(
            prevHash: b2.hash,
            timestamp: chainBTime + 2,
            bits: 0x1e0ffff0,
            nonce: 22,
            merkleSeed: 22
        )
        try chain.addHeaderValidated(b3)

        #expect(chain.tip?.header.hash == b3.hash)
        #expect(chain.getHeader(height: 1)?.header.hash == b1.hash)
        #expect(chain.getHeader(height: 2)?.header.hash == b2.hash)
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
