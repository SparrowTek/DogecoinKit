import Testing
@testable import DogecoinKit

@Suite("BIP39 Wordlist Tests")
struct BIP39WordlistTests {
    @Test("Bundled wordlist has expected count and bounds")
    func wordlistCountAndBounds() {
        let words = getBIP39Wordlist()

        #expect(words.count == bip39WordCount)
        #expect(words.first == "abandon")
        #expect(words.last == "zoo")
        #expect(words == words.sorted())
        #expect(Set(words).count == bip39WordCount)
    }

    @Test("Autocomplete suggestions match prefix, in list order, up to the limit")
    func wordsMatchingPrefix() {
        #expect(bip39WordsMatching(prefix: "zoo", limit: 5) == ["zoo"])
        #expect(bip39WordsMatching(prefix: "aban") == ["abandon"])
        #expect(bip39WordsMatching(prefix: " AB ", limit: 3) == ["abandon", "ability", "able"])
        #expect(bip39WordsMatching(prefix: "ab", limit: 0).isEmpty)
        #expect(bip39WordsMatching(prefix: "").isEmpty)
        #expect(bip39WordsMatching(prefix: "zzz").isEmpty)
    }

    @Test("Word validation uses wordlist")
    func wordValidation() {
        #expect(isValidBIP39Word("abandon"))
        #expect(isValidBIP39Word("Abandon"))
        #expect(isValidBIP39Word(" zoo\n"))
        #expect(!isValidBIP39Word("notaword"))
        #expect(!isValidBIP39Word("abandonn"))
        #expect(!isValidBIP39Word(""))
    }
}
