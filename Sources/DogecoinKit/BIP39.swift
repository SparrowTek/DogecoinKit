import Foundation
import clibdogecoin

// MARK: - BIP39 Mnemonic Validation

/// Validates a mnemonic phrase using full BIP39 checksum validation via libdogecoin
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

// MARK: - BIP39 Wordlist

/// The number of words in the BIP39 English wordlist
public let bip39WordCount = 2048

private enum BIP39Wordlist {
    static let english: [String] = loadWordlist()
    static let englishIndex: [String: Int] = {
        var index: [String: Int] = [:]
        index.reserveCapacity(english.count)
        for (offset, word) in english.enumerated() {
            index[word] = offset
        }
        return index
    }()

    private static func loadWordlist() -> [String] {
        guard let url = Bundle.module.url(forResource: "bip39_english", withExtension: "txt"),
              let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let words = content.split(whereSeparator: { $0.isNewline }).map(String.init)
        return words.count == bip39WordCount ? words : []
    }
}

/// Checks if a word is in the BIP39 wordlist (falls back to basic criteria if unavailable)
/// For full validation, use verifyMnemonic() on the complete phrase
/// - Parameter word: The word to validate
/// - Returns: true if the word meets basic BIP39 criteria
public func isValidBIP39Word(_ word: String) -> Bool {
    let normalized = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return false }

    if !BIP39Wordlist.englishIndex.isEmpty {
        return BIP39Wordlist.englishIndex[normalized] != nil
    }

    // BIP39 words are 3-8 characters, lowercase letters only
    guard normalized.count >= 3, normalized.count <= 8 else { return false }

    // Must be all lowercase letters
    let letters = CharacterSet.lowercaseLetters
    return normalized.unicodeScalars.allSatisfy { letters.contains($0) }
}

/// Returns the BIP39 English wordlist
/// - Returns: The bundled wordlist in alphabetical order
public func getBIP39Wordlist() -> [String] {
    BIP39Wordlist.english
}

/// Returns BIP39 words matching a prefix (for autocomplete)
/// - Returns: Words starting with the prefix, up to the limit
public func bip39WordsMatching(prefix: String, limit: Int = 5) -> [String] {
    let normalized = prefix.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, limit > 0 else { return [] }

    let words = BIP39Wordlist.english
    guard !words.isEmpty else { return [] }

    var matches: [String] = []
    matches.reserveCapacity(min(limit, words.count))
    for word in words where word.hasPrefix(normalized) {
        matches.append(word)
        if matches.count >= limit {
            break
        }
    }
    return matches
}

/// Returns the index of a BIP39 word in the wordlist
/// - Returns: The word's index, or nil if not found
public func bip39WordIndex(_ word: String) -> Int? {
    let normalized = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }

    let index = BIP39Wordlist.englishIndex
    guard !index.isEmpty else { return nil }
    return index[normalized]
}

/// Returns the BIP39 word at a specific index
/// - Returns: The word at the index, or nil if out of range
public func bip39Word(at index: Int) -> String? {
    let words = BIP39Wordlist.english
    guard index >= 0, index < words.count else { return nil }
    return words[index]
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
        error != .invalidWordCount
    }

    /// Returns true if all words are valid BIP39 words
    public var allWordsValid: Bool {
        invalidWordIndices.isEmpty
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
/// - Parameter mnemonic: The mnemonic phrase to validate
/// - Returns: A detailed validation result
public func validateMnemonicDetailed(_ mnemonic: String) -> MnemonicValidationResult {
    let trimmed = mnemonic.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty else {
        return MnemonicValidationResult(
            isValid: false,
            invalidWordIndices: [],
            error: .emptyMnemonic
        )
    }

    let words = trimmed.split(separator: " ").map(String.init)
    let validCounts = [12, 15, 18, 21, 24]

    guard validCounts.contains(words.count) else {
        return MnemonicValidationResult(
            isValid: false,
            invalidWordIndices: [],
            error: .invalidWordCount
        )
    }

    // Use libdogecoin's full validation (includes word and checksum validation)
    let isValid = verifyMnemonic(trimmed)

    if !isValid {
        // Cannot determine specific invalid words without wordlist access
        // Return generic checksum error
        return MnemonicValidationResult(
            isValid: false,
            invalidWordIndices: [],
            error: .invalidChecksum
        )
    }

    return MnemonicValidationResult(
        isValid: true,
        invalidWordIndices: [],
        error: nil
    )
}
