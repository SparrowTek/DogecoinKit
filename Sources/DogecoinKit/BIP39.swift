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

// MARK: - BIP39 Wordlist

/// The number of words in the BIP39 English wordlist
public let bip39WordCount = 2048

/// NOTE: Direct wordlist access is temporarily disabled due to Swift 6 compiler crash
/// with the C array. Use verifyMnemonic() for full validation instead.
/// The wordlist functions below use a simple validation approach.

/// Checks if a word could be a valid BIP39 word based on basic criteria
/// For full validation, use verifyMnemonic() on the complete phrase
/// - Parameter word: The word to validate
/// - Returns: true if the word meets basic BIP39 criteria
public func isValidBIP39Word(_ word: String) -> Bool {
    let lowercased = word.lowercased().trimmingCharacters(in: .whitespaces)
    guard !lowercased.isEmpty else { return false }

    // BIP39 words are 3-8 characters, lowercase letters only
    guard lowercased.count >= 3, lowercased.count <= 8 else { return false }

    // Must be all lowercase letters
    let letters = CharacterSet.lowercaseLetters
    return lowercased.unicodeScalars.allSatisfy { letters.contains($0) }
}

/// Returns the BIP39 English wordlist
/// NOTE: Currently returns empty array due to Swift 6 compiler issue with C array access
/// - Returns: Empty array (wordlist access disabled)
public func getBIP39Wordlist() -> [String] {
    // Disabled due to Swift 6 compiler crash with wordlist_eng C array
    []
}

/// Returns BIP39 words matching a prefix (for autocomplete)
/// NOTE: Currently returns empty array due to Swift 6 compiler issue
/// - Returns: Empty array (wordlist access disabled)
public func bip39WordsMatching(prefix: String, limit: Int = 5) -> [String] {
    // Disabled due to Swift 6 compiler crash with wordlist_eng C array
    []
}

/// Returns the index of a BIP39 word in the wordlist
/// NOTE: Currently returns nil due to Swift 6 compiler issue
/// - Returns: nil (wordlist access disabled)
public func bip39WordIndex(_ word: String) -> Int? {
    // Disabled due to Swift 6 compiler crash with wordlist_eng C array
    nil
}

/// Returns the BIP39 word at a specific index
/// NOTE: Currently returns nil due to Swift 6 compiler issue
/// - Returns: nil (wordlist access disabled)
public func bip39Word(at index: Int) -> String? {
    // Disabled due to Swift 6 compiler crash with wordlist_eng C array
    nil
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
