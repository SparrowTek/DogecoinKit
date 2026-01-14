import Foundation
import clibdogecoin

// MARK: - BIP39 Mnemonic Validation

/// Validates a mnemonic phrase using full BIP39 checksum validation via libdogecoin
/// - Parameters:
///   - mnemonic: The mnemonic phrase to validate
///   - language: ISO 639-2 language code (default: "eng" for English)
/// - Returns: true if valid BIP39 mnemonic with correct checksum
public func verifyMnemonic(_ mnemonic: String, language: String = "eng") -> Bool {
    Dogecoin.initialize()

    let result = mnemonic.withCString { mnemonicPtr in
        language.withCString { langPtr in
            " ".withCString { spacePtr in
                dogecoin_verify_mnemonic(mnemonicPtr, langPtr, spacePtr, nil)
            }
        }
    }

    return result == 0
}

// MARK: - BIP39 Wordlist Access

/// The number of words in the BIP39 English wordlist
public let bip39WordCount = 2048

/// Returns the BIP39 English wordlist (2048 words)
/// Useful for autocomplete and word-by-word validation
/// - Returns: Array of all 2048 BIP39 English words
public func getBIP39Wordlist() -> [String] {
    var words: [String] = []
    words.reserveCapacity(bip39WordCount)

    for i in 0..<bip39WordCount {
        if let wordPtr = wordlist_eng[i] {
            words.append(String(cString: wordPtr))
        }
    }

    return words
}

/// Checks if a single word is a valid BIP39 English word
/// - Parameter word: The word to validate
/// - Returns: true if the word is in the BIP39 English wordlist
public func isValidBIP39Word(_ word: String) -> Bool {
    let lowercased = word.lowercased().trimmingCharacters(in: .whitespaces)
    guard !lowercased.isEmpty else { return false }

    for i in 0..<bip39WordCount {
        if let wordPtr = wordlist_eng[i] {
            if String(cString: wordPtr) == lowercased {
                return true
            }
        }
    }

    return false
}

/// Returns BIP39 words matching a prefix (for autocomplete)
/// - Parameters:
///   - prefix: The prefix to match
///   - limit: Maximum number of suggestions to return (default: 5)
/// - Returns: Array of matching words, sorted alphabetically
public func bip39WordsMatching(prefix: String, limit: Int = 5) -> [String] {
    let lowercased = prefix.lowercased().trimmingCharacters(in: .whitespaces)
    guard !lowercased.isEmpty else { return [] }

    var matches: [String] = []

    for i in 0..<bip39WordCount {
        if let wordPtr = wordlist_eng[i] {
            let word = String(cString: wordPtr)
            if word.hasPrefix(lowercased) {
                matches.append(word)
                if matches.count >= limit {
                    break
                }
            }
        }
    }

    return matches
}

/// Returns the index of a BIP39 word in the wordlist
/// - Parameter word: The word to find
/// - Returns: The index (0-2047) or nil if not found
public func bip39WordIndex(_ word: String) -> Int? {
    let lowercased = word.lowercased().trimmingCharacters(in: .whitespaces)
    guard !lowercased.isEmpty else { return nil }

    for i in 0..<bip39WordCount {
        if let wordPtr = wordlist_eng[i] {
            if String(cString: wordPtr) == lowercased {
                return i
            }
        }
    }

    return nil
}

/// Returns the BIP39 word at a specific index
/// - Parameter index: The index (0-2047)
/// - Returns: The word at that index, or nil if index is out of range
public func bip39Word(at index: Int) -> String? {
    guard index >= 0, index < bip39WordCount else { return nil }

    if let wordPtr = wordlist_eng[index] {
        return String(cString: wordPtr)
    }

    return nil
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
public enum MnemonicValidationError: Error, Sendable {
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

    // Check each word
    var invalidIndices: [Int] = []
    for (index, word) in words.enumerated() {
        if !isValidBIP39Word(word) {
            invalidIndices.append(index)
        }
    }

    if !invalidIndices.isEmpty {
        return MnemonicValidationResult(
            isValid: false,
            invalidWordIndices: invalidIndices,
            error: .invalidWords(invalidIndices)
        )
    }

    // All words valid, now check checksum using libdogecoin
    let isChecksumValid = verifyMnemonic(trimmed)

    if !isChecksumValid {
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
