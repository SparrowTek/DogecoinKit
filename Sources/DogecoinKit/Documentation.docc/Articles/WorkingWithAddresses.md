# Working with Addresses

Validate, create, and manage Dogecoin addresses.

@Metadata {
    @PageKind(article)
}

## Overview

Dogecoin addresses are the public identifiers used to receive funds. DogecoinKit provides comprehensive tools for validating addresses, detecting networks, and converting between different representations.

## Address Formats

DogecoinKit generates Pay-to-Public-Key-Hash (P2PKH) addresses:

| Network | Prefix | Example |
|---------|--------|---------|
| Mainnet | D | `D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD` |
| Testnet | n | `nmcez45bygdYA2CY9mP78eJy37AFwrUXp2` |

Validation also accepts Pay-to-Script-Hash (P2SH) addresses, which start with `9` or `A` on mainnet and `2` on testnet. ``Address/kind(_:)`` tells the two kinds apart.

## Validating Addresses

### Basic Validation

Always validate addresses before using them:

```swift
import DogecoinKit

let address = "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"

if Address.isValid(address) {
    print("Valid Dogecoin address")
} else {
    print("Invalid address")
}
```

### Network Detection

Determine which network an address belongs to:

```swift
let address = "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"

if Address.isMainnet(address) {
    print("This is a mainnet address")
} else if Address.isTestnet(address) {
    print("This is a testnet address")
}

// Or use detectNetwork for a cleaner approach
if let network = Address.detectNetwork(address) {
    switch network {
    case .mainnet:
        print("Mainnet address")
    case .testnet:
        print("Testnet address")
    }
}
```

### Validating User Input

When accepting addresses from users, validate thoroughly:

```swift
enum AddressError: Error {
    case invalid
    case wrongNetwork(expected: DogecoinNetwork, got: DogecoinNetwork)
}

func validateRecipientAddress(_ input: String, expectedNetwork: DogecoinNetwork) -> Result<String, AddressError> {
    // Trim whitespace
    let address = input.trimmingCharacters(in: .whitespacesAndNewlines)

    // A valid address always has a network, so one check covers both
    guard let network = Address.detectNetwork(address) else {
        return .failure(.invalid)
    }

    guard network == expectedNetwork else {
        return .failure(.wrongNetwork(expected: expectedNetwork, got: network))
    }

    return .success(address)
}

// Usage
switch validateRecipientAddress(userInput, expectedNetwork: .mainnet) {
case .success(let address):
    // Proceed with the validated address
    sendPayment(to: address)
case .failure(.invalid):
    showError("Please enter a valid Dogecoin address")
case .failure(.wrongNetwork(let expected, let got)):
    showError("Expected a \(expected) address, but got a \(got) address")
}
```

## Type-Safe Addresses

Use ``DogecoinAddress`` for compile-time safety:

```swift
let input = "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"  // e.g. text the user entered

// This throws if the address is invalid
let validAddress = try DogecoinAddress(input)
print("Network: \(validAddress.network)")
print("Value: \(validAddress.value)")
print("Kind: \(validAddress.kind)")  // "Kind: p2pkh"
print("Script: \(validAddress.scriptPubKey.count) bytes")  // "Script: 25 bytes"

// Specify expected network
let mainnetAddress = try DogecoinAddress(input, network: .mainnet)

// This will throw because it's a mainnet address
do {
    let _ = try DogecoinAddress(input, network: .testnet)
} catch DogecoinError.invalidAddress {
    print("Network mismatch!")
}
```

### Using DogecoinAddress in Your Code

``DogecoinAddress`` conforms to common protocols:

```swift
// Codable - for JSON serialization
struct PaymentRequest: Codable {
    let address: DogecoinAddress
    let amount: DogecoinAmount
}

let request = PaymentRequest(
    address: try DogecoinAddress(input),
    amount: DogecoinAmount(doge: 100)
)
let json = try JSONEncoder().encode(request)

// Equatable & Hashable - for collections
var usedAddresses: Set<DogecoinAddress> = []
usedAddresses.insert(try DogecoinAddress(input))

// CustomStringConvertible - for display
let address = try DogecoinAddress(input)
print(address)  // "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"
```

``DogecoinAddress`` is not `ExpressibleByStringLiteral`: every address, even one fixed in source, goes through the throwing initializer, so a typo surfaces as an error instead of a crash. Decoding validates too: an invalid address in JSON fails the decode.

## Address Components

### Public Key to Address

Generate an address from a public key, compressed (33 bytes) or uncompressed (65 bytes). Each form controls a different address. A key that is not a point on secp256k1 throws ``DogecoinError/invalidPublicKey``, so keys pulled out of transactions are safe to pass:

```swift
let publicKeyHex = "02a1633cafcc01ebfb6d78e39f687a1f0995c62fc95f51ead10a02ee0be551b5dc"

let address = try await Address.fromPublicKey(publicKeyHex, network: .mainnet)
print(address)  // "D..."
```

### Address to Public Key Hash

Get the output script for a P2PKH address. Despite its name, ``Address/toPubkeyHash(_:)`` returns the full P2PKH scriptPubKey (`76a914<hash160>88ac`) as hex, not the bare 20-byte hash, and it rejects P2SH addresses. ``Address/scriptPubKey(for:)`` returns the raw script for either kind:

```swift
let address = "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"
let scriptHex = try Address.toPubkeyHash(address)
print(scriptHex)  // "76a9141a489a9364888ba3e81b61d16f59899bdca5badd88ac"

// Raw script bytes for P2PKH or P2SH, or nil if the address is invalid
if let script = Address.scriptPubKey(for: "A9rmPAxPNGTojaWevb571EYNmCiRLpXzcM") {
    print(script.count)  // 23: OP_HASH160 <hash160> OP_EQUAL
}
```

### Public Key Hash to Address

``Address/fromPubkeyHash(_:network:)`` accepts either the bare 20-byte hash160 or the P2PKH script hex that ``Address/toPubkeyHash(_:)`` returns, so the two round-trip. Anything else throws ``DogecoinError/invalidAddress(_:)``:

```swift
let scriptHex = "76a9141a489a9364888ba3e81b61d16f59899bdca5badd88ac"
let address = try Address.fromPubkeyHash(scriptHex, network: .mainnet)
print(address)  // "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"

// The bare hash gives the same address
let sameAddress = try Address.fromPubkeyHash("1a489a9364888ba3e81b61d16f59899bdca5badd", network: .mainnet)
```

### Script to Address

``Address/fromScriptPubKey(_:network:)`` is the inverse of ``Address/scriptPubKey(for:)``: it names the address an output script pays, P2PKH or P2SH, and returns `nil` for any other script. Use it with ``RawTransaction`` to read where a transaction's outputs go:

```swift
// `rawHex` is a transaction from a server or a peer
if let transaction = RawTransaction(hex: rawHex) {
    for output in transaction.outputs {
        let recipient = Address.fromScriptPubKey(output.script, network: .mainnet) ?? "(no address)"
        print("\(DogecoinAmount(koinu: output.value)) to \(recipient)")
    }
}
```

## Generating Addresses

### From HD Wallet

The recommended way to generate addresses:

```swift
let wallet = try await HDWallet.create(network: .mainnet)

// Receiving addresses (change = false)
let receiving0 = try await wallet.deriveAddress(account: 0, index: 0)
let receiving1 = try await wallet.deriveAddress(account: 0, index: 1)

// Change addresses (change = true)
let change0 = try await wallet.deriveAddress(account: 0, index: 0, change: true)
```

## Address Gap Limit

When scanning for used addresses (e.g., during wallet restoration), use a gap limit:

```swift
func scanForUsedAddresses(
    wallet: HDWallet,
    gapLimit: Int = 20,
    hasTransactions: (String) async throws -> Bool
) async throws -> [String] {
    var usedAddresses: [String] = []
    var consecutiveUnused = 0
    var index: UInt32 = 0

    while consecutiveUnused < gapLimit {
        let address = try await wallet.deriveAddress(account: 0, index: index)

        if try await hasTransactions(address) {
            usedAddresses.append(address)
            consecutiveUnused = 0
        } else {
            consecutiveUnused += 1
        }

        index += 1
    }

    return usedAddresses
}

// In Electrum mode, an address is used once it has any history
let usedAddresses = try await scanForUsedAddresses(wallet: wallet) { address in
    try await !electrum.fetchTransactionHistory(for: [address]).isEmpty
}
```

The gap limit (typically 20) determines how many consecutive unused addresses to check before stopping the scan.

## QR Code Integration

Addresses are commonly shared via QR codes. Here's how to read one from a QR scanner's result:

```swift
/// The Dogecoin address in a scanned QR code, or nil if it holds none
func address(fromQRCode content: String) -> String? {
    var candidate = content.trimmingCharacters(in: .whitespacesAndNewlines)

    // Handle the dogecoin: URI scheme, dropping parameters such as ?amount=
    if candidate.lowercased().hasPrefix("dogecoin:") {
        candidate = String(candidate.dropFirst("dogecoin:".count))
        candidate = candidate.components(separatedBy: "?").first ?? candidate
    }

    return Address.isValid(candidate) ? candidate : nil
}
```

## Best Practices

### Address Reuse

Avoid reusing addresses when possible:

```swift
actor AddressManager {
    private let wallet: HDWallet
    private var nextReceivingIndex: UInt32 = 0
    private var nextChangeIndex: UInt32 = 0

    init(wallet: HDWallet) {
        self.wallet = wallet
    }

    func getNextReceivingAddress() async throws -> String {
        // Claim the index before awaiting so concurrent callers never share one
        let index = nextReceivingIndex
        nextReceivingIndex += 1
        return try await wallet.deriveAddress(account: 0, index: index)
    }

    func getNextChangeAddress() async throws -> String {
        let index = nextChangeIndex
        nextChangeIndex += 1
        return try await wallet.deriveAddress(account: 0, index: index, change: true)
    }
}
```

### Displaying Addresses

Format addresses for better readability:

```swift
extension String {
    /// Format a Dogecoin address for display
    func formattedAddress() -> String {
        guard self.count >= 8 else { return self }
        let prefix = self.prefix(8)
        let suffix = self.suffix(8)
        return "\(prefix)...\(suffix)"
    }
}

let address = "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"
print(address.formattedAddress())  // "D7Y55r6Y...GJJ7M6yD"
```

### Copy to Clipboard

```swift
import UIKit

func copyAddressToClipboard(_ address: String) {
    UIPasteboard.general.string = address

    // Show feedback
    showToast("Address copied!")
}
```

## See Also

- ``Address``
- ``DogecoinAddress``
- ``HDWallet``
- ``RawTransaction``
- <doc:CreatingAWallet>
