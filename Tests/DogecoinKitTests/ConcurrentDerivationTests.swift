import Foundation
import Testing
@testable import DogecoinKit

/// Concurrency regression coverage for key derivation.
///
/// Two historical hazards this guards:
/// 1. Pre-0.1.5 libdogecoin computed HMAC-SHA256 through `static` scratch
///    buffers (and overflowed one of them), so concurrent derivations could
///    corrupt memory or produce wrong keys. The 0.1.5 stateless refactor
///    fixed it — this test fails loudly if that class of bug returns.
/// 2. 0.1.5 keeps its secp256k1 context in thread-local storage; a thread
///    that never armed it crashes on first ECC call. `ECC.armCurrentThread()`
///    must cover every path — concurrent tasks land on many pool threads.
@Suite("Concurrent Derivation")
struct ConcurrentDerivationTests {

    private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    init() async {
        await Dogecoin.initialize()
    }

    @Test("Parallel derivations agree with serial derivations")
    func parallelMatchesSerial() async throws {
        let wallet = try await HDWallet(mnemonic: testMnemonic, network: .mainnet)

        // Serial reference addresses
        var expected: [UInt32: String] = [:]
        for index: UInt32 in 0..<8 {
            expected[index] = try await wallet.deriveAddress(account: 0, index: index, change: false)
        }

        // Many concurrent derivations of the same indices across pool threads
        try await withThrowingTaskGroup(of: (UInt32, String).self) { group in
            for round in 0..<6 {
                for index: UInt32 in 0..<8 {
                    _ = round
                    group.addTask {
                        let address = try await wallet.deriveAddress(account: 0, index: index, change: false)
                        return (index, address)
                    }
                }
            }

            for try await (index, address) in group {
                #expect(address == expected[index], "concurrent derivation diverged at index \(index)")
            }
        }
    }

    @Test("Parallel signing and derivation do not interfere")
    func parallelSigningAndDerivation() async throws {
        let wallet = try await HDWallet(mnemonic: testMnemonic, network: .mainnet)
        let address = try await wallet.deriveAddress(account: 0, index: 0, change: false)
        let privateKey = try await wallet.derivePrivateKey(account: 0, index: 0, change: false)
        let scriptPubKey = try Address.toPubkeyHash(address)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for lane in 0..<8 {
                group.addTask {
                    if lane.isMultiple(of: 2) {
                        let derived = try await wallet.deriveAddress(account: 0, index: 0, change: false)
                        #expect(derived == address)
                    } else {
                        let utxo = UTXO(
                            txid: String(repeating: "ab", count: 32),
                            vout: lane,
                            address: address,
                            amount: DogecoinAmount(koinu: 10_000_000_000),
                            scriptPubKey: scriptPubKey,
                            confirmations: 12
                        )
                        let signed = try await createTransaction(
                            inputs: [utxo],
                            outputs: [(address: "DD8sGWjLS7KodzdhWFA63G2Ryn1Ku1qjQ5", amount: DogecoinAmount(koinu: 5_000_000_000))],
                            signingKeysByAddress: [address: privateKey],
                            changeAddress: address,
                            fee: DogecoinAmount(koinu: 100_000_000)
                        )
                        #expect(!signed.rawHex.isEmpty)
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}
