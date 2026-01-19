import Testing
@testable import DogecoinKit

@Suite("BIP39 Wordlist Tests")
struct BIP39WordlistTests {
    @Test("Bundled wordlist has expected count and bounds")
    func testWordlistCountAndBounds() {
        let words = getBIP39Wordlist()

        #expect(words.count == bip39WordCount)
        #expect(words.first == "abandon")
        #expect(words.last == "zoo")
    }

    @Test("Word lookup by index")
    func testWordAtIndex() {
        #expect(bip39Word(at: 0) == "abandon")
        #expect(bip39Word(at: bip39WordCount - 1) == "zoo")
        #expect(bip39Word(at: bip39WordCount) == nil)
    }

    @Test("Word index lookup")
    func testWordIndex() {
        #expect(bip39WordIndex("abandon") == 0)
        #expect(bip39WordIndex("zoo") == bip39WordCount - 1)
        #expect(bip39WordIndex("notaword") == nil)
    }

    @Test("Autocomplete suggestions match prefix")
    func testWordsMatchingPrefix() {
        let matches = bip39WordsMatching(prefix: "zoo", limit: 5)

        #expect(matches == ["zoo"])
    }

    @Test("Word validation uses wordlist")
    func testWordValidation() {
        #expect(isValidBIP39Word("abandon"))
        #expect(isValidBIP39Word("Abandon"))
        #expect(!isValidBIP39Word("notaword"))
    }
}
