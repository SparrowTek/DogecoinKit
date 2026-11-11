import Foundation
import clibdogecoin
import DogecoinKitShims

// MARK: - BIP39 Mnemonic Validation

/// Validates a mnemonic phrase using full BIP39 checksum validation via libdogecoin
///
/// Exact: the words must be lowercase and separated by single spaces, the
/// form ``normalizedMnemonic(_:)`` produces.
/// - Parameters:
///   - mnemonic: The mnemonic phrase to validate
///   - language: ISO 639-2 language code (default: "eng" for English)
/// - Returns: true if valid BIP39 mnemonic with correct checksum
public func verifyMnemonic(_ mnemonic: String, language: String = "eng") -> Bool {
    let result = mnemonic.withCString { mnemonicPtr in
        language.withCString { langPtr in
            " ".withCString { spacePtr in
                dogecoin_verify_mnemonic(mnemonicPtr, langPtr, spacePtr, nil)
            }
        }
    }

    return result == 0
}

/// A mnemonic phrase the way BIP39 writes it: lowercase words separated by
/// single spaces.
///
/// A phrase typed with capitals, extra spaces, or line breaks is the same
/// phrase; a wallet seed, though, is derived from the exact text. Normalizing
/// first makes every spelling of a phrase open the same wallet.
public func normalizedMnemonic(_ mnemonic: String) -> String {
    mnemonicWords(mnemonic).joined(separator: " ")
}

private func mnemonicWords(_ mnemonic: String) -> [String] {
    mnemonic.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
}

// MARK: - BIP39 Wordlist

/// The number of words in the BIP39 English wordlist
public let bip39WordCount = 2048

private enum BIP39Wordlist {
    /// libdogecoin's compiled-in list — the same one `verifyMnemonic` checks
    /// against — so no resource bundle is needed on any platform.
    static let english: [String] = (0..<Int32(bip39WordCount)).compactMap { index in
        dogecoinkit_bip39_english_word(index).map { String(cString: $0) }
    }

    static let englishIndex: [String: Int] = Dictionary(
        english.enumerated().map { ($0.element, $0.offset) },
        uniquingKeysWith: { first, _ in first }
    )
}

/// Checks if a word is in the BIP39 wordlist
///
/// For full validation, use ``verifyMnemonic(_:language:)`` or
/// ``validateMnemonicDetailed(_:)`` on the complete phrase.
/// - Parameter word: The word to validate; case and surrounding whitespace
///   are ignored
/// - Returns: true if the word is one of the 2048
public func isValidBIP39Word(_ word: String) -> Bool {
    BIP39Wordlist.englishIndex[word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)] != nil
}

/// Returns the BIP39 English wordlist
/// - Returns: The wordlist in alphabetical order
public func getBIP39Wordlist() -> [String] {
    BIP39Wordlist.english
}

/// Returns BIP39 words matching a prefix (for autocomplete)
/// - Returns: Words starting with the prefix, up to the limit
public func bip39WordsMatching(prefix: String, limit: Int = 5) -> [String] {
    let normalized = prefix.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, limit > 0 else { return [] }

    return Array(BIP39Wordlist.english.lazy.filter { $0.hasPrefix(normalized) }.prefix(limit))
}

// MARK: - Mnemonic Validation Result

/// Detailed validation result for a mnemonic phrase
public struct MnemonicValidationResult: Sendable {
    /// Whether the mnemonic is valid
    public let isValid: Bool

    /// Indices of invalid words (empty if all words are valid BIP39 words)
    public let invalidWordIndices: [Int]

    /// The validation error, if any
    public let error: MnemonicValidationError?

    /// Returns true if the mnemonic has the correct word count
    public var hasValidWordCount: Bool {
        error != .invalidWordCount && error != .emptyMnemonic
    }

    /// Returns true if all words are valid BIP39 words
    public var allWordsValid: Bool {
        invalidWordIndices.isEmpty
    }

    fileprivate static func invalid(_ error: MnemonicValidationError, words: [Int] = []) -> MnemonicValidationResult {
        MnemonicValidationResult(isValid: false, invalidWordIndices: words, error: error)
    }
}

/// Errors that can occur during mnemonic validation
public enum MnemonicValidationError: Error, Sendable, Equatable {
    case emptyMnemonic
    case invalidWordCount
    case invalidWords([Int])
    case invalidChecksum
}

/// Validates a mnemonic phrase and returns detailed results
///
/// The phrase is judged as ``normalizedMnemonic(_:)`` writes it, so capitals,
/// repeated spaces, and line breaks are not errors: a phrase that is valid
/// here is one ``HDWallet/init(mnemonic:passphrase:network:)`` accepts.
/// - Parameter mnemonic: The mnemonic phrase to validate
/// - Returns: A detailed validation result
public func validateMnemonicDetailed(_ mnemonic: String) -> MnemonicValidationResult {
    let words = mnemonicWords(mnemonic)

    guard !words.isEmpty else {
        return .invalid(.emptyMnemonic)
    }

    guard MnemonicStrength.allCases.contains(where: { $0.wordCount == words.count }) else {
        return .invalid(.invalidWordCount)
    }

    // Naming the words that are not in the list tells the user exactly what
    // to retype; a checksum failure only says that something is wrong.
    let invalidIndices = words.indices.filter { BIP39Wordlist.englishIndex[words[$0]] == nil }
    guard invalidIndices.isEmpty else {
        return .invalid(.invalidWords(invalidIndices), words: invalidIndices)
    }

    guard verifyMnemonic(words.joined(separator: " ")) else {
        return .invalid(.invalidChecksum)
    }

    return MnemonicValidationResult(isValid: true, invalidWordIndices: [], error: nil)
}
