# Creating a Wallet

Generate new wallets and restore existing ones using mnemonic phrases.

@Metadata {
    @PageKind(article)
}

## Overview

DogecoinKit uses Hierarchical Deterministic (HD) wallets that generate all keys from a single seed. This seed is represented as a mnemonic phrase—a sequence of 12 to 24 words that users can write down and store safely.

## Creating a New Wallet

### Basic Wallet Creation

The simplest way to create a new wallet:

```swift
import DogecoinKit

func createWallet() async throws {
    // Create a wallet with a 12-word mnemonic
    let wallet = try await HDWallet.create(
        strength: .words12,
        network: .mainnet
    )

    // Access the recovery phrase
    print("Recovery phrase: \(wallet.mnemonic)")
}
```

### Mnemonic Strength Options

Choose the mnemonic length based on your security requirements:

```swift
// 12 words (128 bits of entropy) - Standard security
let wallet12 = try await HDWallet.create(strength: .words12)

// 15 words (160 bits)
let wallet15 = try await HDWallet.create(strength: .words15)

// 18 words (192 bits)
let wallet18 = try await HDWallet.create(strength: .words18)

// 21 words (224 bits)
let wallet21 = try await HDWallet.create(strength: .words21)

// 24 words (256 bits) - Maximum security
let wallet24 = try await HDWallet.create(strength: .words24)
```

| Strength | Words | Entropy | Security Level |
|----------|-------|---------|----------------|
| `.words12` | 12 | 128 bits | Standard |
| `.words15` | 15 | 160 bits | Enhanced |
| `.words18` | 18 | 192 bits | High |
| `.words21` | 21 | 224 bits | Very High |
| `.words24` | 24 | 256 bits | Maximum |

> Tip: 12 words is the default. More words mean more entropy, and more for the user to write down.

### Adding a Passphrase

You can add an optional passphrase for additional security. This creates a completely different wallet even with the same mnemonic:

```swift
// Wallet with passphrase
let wallet = try await HDWallet.create(
    strength: .words12,
    passphrase: "my secret passphrase",
    network: .mainnet
)
```

> Warning: If you use a passphrase, you must remember it along with the mnemonic to restore your wallet. There is no way to recover a forgotten passphrase.

## Restoring a Wallet

### From Mnemonic Phrase

Restore a wallet by providing the mnemonic words:

```swift
let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

let wallet = try await HDWallet(
    mnemonic: mnemonic,
    network: .mainnet
)

// The wallet will derive the same addresses as the original
let address = try await wallet.deriveAddress(account: 0, index: 0)
```

### With Passphrase

If the original wallet used a passphrase, provide it during restoration:

```swift
let wallet = try await HDWallet(
    mnemonic: mnemonic,
    passphrase: "my secret passphrase",
    network: .mainnet
)
```

### Validating Mnemonics

Before attempting restoration, validate the mnemonic, so you can tell the user what is wrong with it:

```swift
let userInput = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

switch validateMnemonicDetailed(userInput).error {
case nil:
    // Mnemonic is valid - proceed with restoration
    let wallet = try await HDWallet(mnemonic: userInput, network: .mainnet)
case .emptyMnemonic:
    print("Enter your recovery phrase")
case .invalidWordCount:
    print("A recovery phrase has 12, 15, 18, 21, or 24 words")
case .invalidWords(let positions):
    // Zero-based positions of the words that aren't in the word list
    print("Check word \(positions.map { String($0 + 1) }.joined(separator: ", "))")
case .invalidChecksum:
    print("Every word is valid, but together they aren't a recovery phrase")
}
```

The validation checks, in this order:
- Correct word count (12, 15, 18, 21, or 24 words)
- Words are from the BIP39 English word list
- Checksum is valid

> Note: ``HDWallet/init(mnemonic:passphrase:network:)`` runs the same validation itself and throws ``DogecoinError/invalidMnemonic`` for an unknown word or a bad checksum. BIP39 can turn any string into a seed, so without this check a single mistyped word would silently restore a different, empty wallet.

Typed and pasted phrases rarely arrive in canonical form. Both ``validateMnemonicDetailed(_:)`` and ``HDWallet/init(mnemonic:passphrase:network:)`` judge a phrase as ``normalizedMnemonic(_:)`` writes it, in lowercase words separated by single spaces, so capitals, repeated spaces, and line breaks are not errors and never change which wallet a phrase opens. ``HDWallet/mnemonic`` holds the normalized phrase.

``verifyMnemonic(_:language:)`` is the exact check underneath: it accepts only the normalized form, so normalize first when you call it yourself:

```swift
let phrase = normalizedMnemonic(userInput)
let isValid = verifyMnemonic(phrase)
```

## Generating Mnemonics Directly

You can generate a mnemonic without creating a wallet:

```swift
// Generate a mnemonic phrase
let mnemonic = try await generateMnemonic(strength: .words12)
print(mnemonic)

// Use it later to create a wallet
let wallet = try await HDWallet(mnemonic: mnemonic, network: .mainnet)
```

This is useful when you need to:
- Display the mnemonic for user backup before wallet creation
- Store the mnemonic separately from the wallet

## Deriving Addresses

### Single Address

```swift
// First receiving address
let address0 = try await wallet.deriveAddress(account: 0, index: 0)

// Second receiving address
let address1 = try await wallet.deriveAddress(account: 0, index: 1)

// Change address (for receiving change from transactions)
let changeAddress = try await wallet.deriveAddress(account: 0, index: 0, change: true)
```

### Multiple Addresses

```swift
// Generate 20 receiving addresses
let addresses = try await wallet.deriveAddresses(
    count: 20,
    account: 0,
    change: false,
    startIndex: 0
)

// Generate addresses starting from index 20
let moreAddresses = try await wallet.deriveAddresses(
    count: 10,
    account: 0,
    change: false,
    startIndex: 20
)
```

### Custom Derivation Paths

For advanced use cases, derive addresses using custom BIP32 paths:

```swift
// Standard Dogecoin path: m/44'/3'/0'/0/0
let address = try await wallet.deriveAddress(path: "m/44'/3'/0'/0/0")

// Custom path for specific use cases
let customAddress = try await wallet.deriveAddress(path: "m/44'/3'/1'/0/5")
```

A path is `m` followed by one or more `/index` components, each below 2³¹ and optionally marked hardened with `'`, `h`, `H`, or `p`. Anything else throws ``DogecoinError/derivationFailed``.

### Private Keys

Signing a transaction takes the private key of each address being spent from. ``HDWallet/derivePrivateKey(account:index:change:)`` and ``HDWallet/derivePrivateKey(path:)`` return it in Wallet Import Format (WIF), for the same paths the address methods take:

```swift
// The key that controls the first receiving address
let privateKeyWIF = try await wallet.derivePrivateKey(account: 0, index: 0)
```

Derive keys when you are about to sign and let them go afterwards. <doc:SendingTransactions> shows where they are used.

## Multiple Accounts

HD wallets support multiple accounts for organizing funds:

```swift
// Account 0 - Primary account
let primaryAddress = try await wallet.deriveAddress(account: 0, index: 0)

// Account 1 - Savings account
let savingsAddress = try await wallet.deriveAddress(account: 1, index: 0)

// Account 2 - Business account
let businessAddress = try await wallet.deriveAddress(account: 2, index: 0)
```

Each account has its own set of receiving and change addresses, derived independently.

## Secure Storage Best Practices

### Storing the Mnemonic

Never store mnemonics in plain text. On Apple platforms, use ``SecureKeyStorage``, which keeps them in the Keychain (on Android, use the Android Keystore):

```swift
let storage = SecureKeyStorage(serviceName: "com.yourapp.wallet")

// Create a wallet and store its recovery phrase
let wallet = try await HDWallet.create(strength: .words12, network: .mainnet)
let keychainID = try await storage.storeWalletCredentials(
    mnemonic: wallet.mnemonic,
    network: .mainnet
)

// Or validate and store a phrase the user typed in
let (imported, importedID) = try await storage.importAndStoreWallet(
    mnemonic: userInput,
    network: .mainnet
)

// Persist `keychainID` (never the phrase) in your app's database.
// Later, rebuild the wallet from the Keychain:
let restored = try await storage.restoreWallet(keychainID: keychainID)

// Read the phrase back to show it on a backup screen
let credentials = try await storage.retrieveWalletCredentials(id: keychainID)
let words = credentials.mnemonic.split(separator: " ")

// Remove the wallet
try await storage.deleteWalletCredentials(id: keychainID)
```

``SecureKeyStorage/storeWalletCredentials(mnemonic:passphrase:network:)`` stores only a phrase that passes ``verifyMnemonic(_:language:)`` and throws ``DogecoinError/invalidMnemonic`` for any other, because ``SecureKeyStorage/restoreWallet(keychainID:)`` derives the wallet from the stored text without checking it again. The ``HDWallet/mnemonic`` of a wallet you created or restored from a phrase is in that form, and ``SecureKeyStorage/importAndStoreWallet(mnemonic:passphrase:network:)`` normalizes what it is given before storing it. A wallet created with a passphrase needs the same passphrase stored with it.

To learn whether credentials are still there without reading the phrase, call ``SecureKeyStorage/walletCredentialsExist(id:)``. It throws ``DogecoinError/keychainRetrievalFailed(_:)`` when the Keychain can't answer, such as while the device is locked. That is not the same as the credentials being gone, so don't treat it as "no wallet".

### Security Recommendations

1. **Never log mnemonics** — Avoid printing or logging recovery phrases
2. **Use secure displays** — Prevent screenshots when showing mnemonics
3. **Encourage backups** — Prompt users to write down their recovery phrase
4. **Verify backups** — Ask users to confirm words from their backup
5. **Device-only storage** — ``SecureKeyStorage`` already stores items as `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`

## Error Handling

Handle wallet creation errors gracefully:

```swift
do {
    let wallet = try await HDWallet(mnemonic: userInput, network: .mainnet)
    // Success - proceed with wallet
} catch DogecoinError.invalidMnemonic {
    // Unknown word, wrong word count, or bad checksum
    showError("Please check your recovery phrase and try again.")
} catch DogecoinError.initializationFailed {
    // The secp256k1 context the library needs could not be created
    showError("This device could not start the wallet's cryptography.")
} catch {
    // Other error
    showError("An error occurred: \(error.localizedDescription)")
}
```

``HDWallet`` reports every validation failure as ``DogecoinError/invalidMnemonic``. To show a more specific message, such as a wrong word count, check the phrase with ``validateMnemonicDetailed(_:)`` first.

## See Also

- ``HDWallet``
- ``MnemonicStrength``
- ``generateMnemonic(strength:)``
- ``validateMnemonicDetailed(_:)``
- ``normalizedMnemonic(_:)``
- ``SecureKeyStorage``
- <doc:GettingStarted>
- <doc:WorkingWithAddresses>
