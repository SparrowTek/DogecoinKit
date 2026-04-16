import Testing
@testable import DogecoinKit

@Suite("BIP39 Mnemonic Validation")
struct BIP39ValidationTests {
    init() async {
        await Dogecoin.initialize()
    }

    // MARK: - Happy path

    @Test("Valid 12-word mnemonic returns .isValid")
    func testValidTwelveWords() async throws {
        let mnemonic = try await generateMnemonic(strength: .words12)
        let result = validateMnemonicDetailed(mnemonic)

        #expect(result.isValid)
        #expect(result.error == nil)
        #expect(result.invalidWordIndices.isEmpty)
        #expect(result.allWordsValid)
        #expect(result.hasValidWordCount)
    }

    @Test("Known-good 24-word vector validates")
    func testValidTwentyFourWordVector() {
        // Fixed valid 24-word mnemonic (the BIP39 test-vector canonical
        // all-zero-entropy phrase). Uses a hardcoded vector rather than
        // round-tripping `generateMnemonic(.words24)` so we're testing the
        // validator, not the generator.
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
        let result = validateMnemonicDetailed(mnemonic)

        #expect(result.isValid)
        #expect(result.error == nil)
    }

    @Test("Leading and trailing whitespace is tolerated")
    func testWhitespaceTolerance() async throws {
        let mnemonic = try await generateMnemonic(strength: .words12)
        let padded = "   \(mnemonic)\n"
        let result = validateMnemonicDetailed(padded)

        #expect(result.isValid)
    }

    // MARK: - Structural errors

    @Test("Empty mnemonic returns .emptyMnemonic")
    func testEmptyMnemonic() {
        let result = validateMnemonicDetailed("")

        #expect(!result.isValid)
        #expect(result.error == .emptyMnemonic)
    }

    @Test("Whitespace-only mnemonic returns .emptyMnemonic")
    func testWhitespaceOnlyMnemonic() {
        let result = validateMnemonicDetailed("   \n\t  ")

        #expect(!result.isValid)
        #expect(result.error == .emptyMnemonic)
    }

    @Test("11-word input returns .invalidWordCount")
    func testTooFewWords() {
        // Take an 11-word span from a real wordlist so individual words are valid.
        let words = Array(repeating: "abandon", count: 11)
        let result = validateMnemonicDetailed(words.joined(separator: " "))

        #expect(!result.isValid)
        #expect(result.error == .invalidWordCount)
    }

    @Test("13-word input returns .invalidWordCount")
    func testOffByOneWords() {
        let words = Array(repeating: "abandon", count: 13)
        let result = validateMnemonicDetailed(words.joined(separator: " "))

        #expect(!result.isValid)
        #expect(result.error == .invalidWordCount)
    }

    // MARK: - Word-level errors

    @Test("Non-BIP39 words are reported with their indices")
    func testInvalidWordsAreIndexed() async throws {
        var words = (try await generateMnemonic(strength: .words12))
            .split(separator: " ")
            .map(String.init)
        #expect(words.count == 12)

        // Inject two non-wordlist tokens at known positions.
        words[2] = "notaword"
        words[7] = "alsonot"
        let mnemonic = words.joined(separator: " ")

        let result = validateMnemonicDetailed(mnemonic)

        #expect(!result.isValid)
        #expect(result.error == .invalidWords([2, 7]))
        #expect(result.invalidWordIndices == [2, 7])
        #expect(!result.allWordsValid)
    }

    @Test("All-valid words with bad checksum returns .invalidChecksum")
    func testChecksumFailureSurfacesDistinctly() {
        // Canonical known-bad mnemonic: twelve "abandon" words. Every word is a
        // real BIP39 entry (so no `.invalidWords`), but the checksum bits do
        // not match — the actual all-zero-entropy mnemonic ends in "about".
        let mnemonic = Array(repeating: "abandon", count: 12).joined(separator: " ")
        let result = validateMnemonicDetailed(mnemonic)

        #expect(!result.isValid)
        #expect(result.error == .invalidChecksum)
        #expect(result.allWordsValid)
    }
}
