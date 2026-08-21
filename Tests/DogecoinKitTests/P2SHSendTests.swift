import Foundation
import Testing
@testable import DogecoinKit

/// End-to-end coverage for sending to P2SH addresses.
///
/// Requires upstream libdogecoin's chain-detection fix (landed on
/// 0.1.5-dev in 710c18e): older revisions mapped mainnet P2SH addresses
/// ('9'/'A') to testnet chainparams and silently dropped the recipient
/// output while still reporting success — a funds-loss shape far worse
/// than a rejected send.
@Suite("P2SH Send Support")
struct P2SHSendTests {
    init() async {
        await Dogecoin.initialize()
    }

    /// Mainnet P2SH address for hash160(sha256("avocadoge-test")) — generated
    /// independently; its script hash in hex is fixed and known.
    private let mainnetP2SH = "A9rmPAxPNGTojaWevb571EYNmCiRLpXzcM"
    private let mainnetP2SHHash160 = "bf1c189252e8715c9ad06c005c65452992f6ff7b"

    @Test("Transaction to a mainnet P2SH address contains the P2SH output script")
    func p2shOutputIsBuilt() async throws {
        let builder = try await TransactionBuilder()
        try await builder.addInput(txid: String(repeating: "ab", count: 32), vout: 0)
        try await builder.addOutput(address: mainnetP2SH, amount: DogecoinAmount(doge: 5))

        let rawHex = try await builder.getRawTransaction()

        // P2SH scriptPubKey: OP_HASH160 (a9) PUSH20 (14) <hash160> OP_EQUAL (87)
        let expectedScript = "a914\(mainnetP2SHHash160)87"
        #expect(rawHex.contains(expectedScript),
                "raw tx must contain the P2SH output script — a missing script means libdogecoin silently dropped the recipient output")
    }

    @Test("Adding an output for an address from the wrong alphabet fails loudly")
    func invalidOutputAddressThrows() async throws {
        let builder = try await TransactionBuilder()
        try await builder.addInput(txid: String(repeating: "cd", count: 32), vout: 0)

        // Not valid base58check — with the honest return value this must
        // throw instead of silently building a transaction with no recipient.
        await #expect(throws: DogecoinError.self) {
            try await builder.addOutput(address: "notAnAddress0000", amount: DogecoinAmount(doge: 1))
        }
    }
}
