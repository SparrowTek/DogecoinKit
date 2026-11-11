import Testing
@testable import DogecoinKit

@Suite("BIP39 Mnemonic Validation")
struct BIP39ValidationTests {
    // MARK: - Happy path

    @Test("Valid 12-word mnemonic returns .isValid")
    func validTwelveWords() async throws {
        let mnemonic = try await generateMnemonic(strength: .words12)
        let result = validateMnemonicDetailed(mnemonic)

        #expect(result.isValid)
        #expect(result.error == nil)
        #expect(result.invalidWordIndices.isEmpty)
        #expect(result.allWordsValid)
        #expect(result.hasValidWordCount)
    }

    @Test("Known-good 24-word vector validates")
    func validTwentyFourWordVector() {
        // Fixed valid 24-word mnemonic (the BIP39 test-vector canonical
        // all-zero-entropy phrase). Uses a hardcoded vector rather than
        // round-tripping `generateMnemonic(.words24)` so we're testing the
        // validator, not the generator.
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
        let result = validateMnemonicDetailed(mnemonic)

        #expect(result.isValid)
        #expect(result.error == nil)
    }

    private static let vector = testPhrase

    @Test("Capitals, repeated spaces, and line breaks are not errors", arguments: [
        "   \(vector)\n",
        "Abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        "ABANDON ABANDON ABANDON ABANDON ABANDON ABANDON ABANDON ABANDON ABANDON ABANDON ABANDON ABOUT",
        "abandon  abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon   about",
        "abandon\nabandon\nabandon\nabandon\nabandon\nabandon\nabandon\nabandon\nabandon\nabandon\nabandon\nabout",
        "abandon\tabandon abandon abandon abandon abandon abandon abandon abandon abandon abandon\r\nabout"
    ])
    func spellingsOfOnePhrase(typed: String) async throws {
        let result = validateMnemonicDetailed(typed)
        #expect(result.isValid)
        #expect(result.error == nil)
        #expect(normalizedMnemonic(typed) == Self.vector)

        // What validates here is what a wallet accepts, and it is the same
        // wallet however the phrase was typed.
        let wallet = try await HDWallet(mnemonic: typed)
        #expect(wallet.masterKey == (try await HDWallet(mnemonic: Self.vector)).masterKey)
    }

    @Test("A wrong word is found by position however the phrase is spaced")
    func invalidWordInUntidyPhrase() {
        let result = validateMnemonicDetailed("Abandon  abandon\nNOTAWORD abandon abandon abandon abandon abandon abandon abandon abandon about")

        #expect(!result.isValid)
        #expect(result.error == .invalidWords([2]))
    }

    @Test("Phrases of every length validate and open a wallet", arguments: MnemonicStrength.allCases)
    func everyStrength(strength: MnemonicStrength) async throws {
        let mnemonic = try await generateMnemonic(strength: strength)

        #expect(mnemonic.split(separator: " ").count == strength.wordCount)
        #expect(validateMnemonicDetailed(mnemonic).isValid)
        #expect(verifyMnemonic(mnemonic))

        let wallet = try await HDWallet(mnemonic: mnemonic, network: .testnet)
        #expect(wallet.mnemonic == mnemonic)
        #expect(try await wallet.deriveAddress().hasPrefix("n"))
    }

    @Test("A passphrase is part of the seed: the same one reopens the wallet, any other opens a different one")
    func passphrase() async throws {
        let plain = try await HDWallet(mnemonic: Self.vector)
        let guarded = try await HDWallet(mnemonic: Self.vector, passphrase: "TREZOR")
        let guardedAgain = try await HDWallet(mnemonic: Self.vector, passphrase: "TREZOR")
        let other = try await HDWallet(mnemonic: Self.vector, passphrase: "trezor")

        #expect(guarded.masterKey == guardedAgain.masterKey)
        #expect(guarded.masterKey != plain.masterKey)
        #expect(guarded.masterKey != other.masterKey)
        #expect(try await guarded.deriveAddress() != plain.deriveAddress())
    }

    // MARK: - Structural errors

    @Test("Empty mnemonic returns .emptyMnemonic")
    func emptyMnemonic() {
        let result = validateMnemonicDetailed("")

        #expect(!result.isValid)
        #expect(result.error == .emptyMnemonic)
    }

    @Test("Whitespace-only mnemonic returns .emptyMnemonic")
    func whitespaceOnlyMnemonic() {
        let result = validateMnemonicDetailed("   \n\t  ")

        #expect(!result.isValid)
        #expect(result.error == .emptyMnemonic)
    }

    @Test("11-word input returns .invalidWordCount")
    func tooFewWords() {
        // Take an 11-word span from a real wordlist so individual words are valid.
        let words = Array(repeating: "abandon", count: 11)
        let result = validateMnemonicDetailed(words.joined(separator: " "))

        #expect(!result.isValid)
        #expect(result.error == .invalidWordCount)
    }

    @Test("13-word input returns .invalidWordCount")
    func offByOneWords() {
        let words = Array(repeating: "abandon", count: 13)
        let result = validateMnemonicDetailed(words.joined(separator: " "))

        #expect(!result.isValid)
        #expect(result.error == .invalidWordCount)
    }

    // MARK: - Word-level errors

    @Test("Non-BIP39 words are reported with their indices")
    func invalidWordsAreIndexed() async throws {
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
    func checksumFailureSurfacesDistinctly() {
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
