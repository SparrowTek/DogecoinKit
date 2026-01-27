import Testing
@testable import DogecoinKit

@Suite("Wallet Mode Tests")
struct WalletModeTests {

    @Test("Default mode is Electrum")
    func testDefaultMode() {
        #expect(WalletMode.electrum.isRecommended == true)
        #expect(WalletMode.spv.isRecommended == false)
    }

    @Test("Display names are user-friendly")
    func testDisplayNames() {
        #expect(WalletMode.electrum.displayName == "Standard")
        #expect(WalletMode.spv.displayName == "Enhanced Privacy")
    }

    @Test("Estimated storage values")
    func testStorageEstimates() {
        #expect(WalletMode.electrum.estimatedStorage.contains("50"))
        #expect(WalletMode.spv.estimatedStorage.contains("2"))
    }
}
