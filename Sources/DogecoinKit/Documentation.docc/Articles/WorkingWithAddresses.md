# Working with Addresses

Validate, create, and manage Dogecoin addresses.

@Metadata {
    @PageKind(article)
    @PageImage(purpose: card, source: "address-card", alt: "Working with Dogecoin addresses")
}

## Overview

Dogecoin addresses are the public identifiers used to receive funds. DogecoinKit provides comprehensive tools for validating addresses, detecting networks, and converting between different representations.

## Address Formats

Dogecoin uses Pay-to-Public-Key-Hash (P2PKH) addresses:

| Network | Prefix | Example |
|---------|--------|---------|
| Mainnet | D | `D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD` |
| Testnet | n | `nXpY8ywPq3JYqErKhgEE7dV9kKAz2qQPMN` |

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
func validateRecipientAddress(_ input: String, expectedNetwork: DogecoinNetwork) -> Result<String, AddressError> {
    // Trim whitespace
    let address = input.trimmingCharacters(in: .whitespacesAndNewlines)

    // Check if valid
    guard Address.isValid(address) else {
        return .failure(.invalid)
    }

    // Check network matches
    guard let network = Address.detectNetwork(address) else {
        return .failure(.unknownNetwork)
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
case .failure(.unknownNetwork):
    showError("Unable to determine address network")
}
```

## Type-Safe Addresses

Use ``DogecoinAddress`` for compile-time safety:

```swift
// This throws if the address is invalid
let validAddress = try DogecoinAddress("D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD")
print("Network: \(validAddress.network)")
print("Value: \(validAddress.value)")

// Specify expected network
let mainnetAddress = try DogecoinAddress("D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD", network: .mainnet)

// This will throw because it's a mainnet address
do {
    let _ = try DogecoinAddress("D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD", network: .testnet)
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
    address: try DogecoinAddress("D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"),
    amount: DogecoinAmount(doge: 100)
)
let json = try JSONEncoder().encode(request)

// Equatable & Hashable - for collections
var usedAddresses: Set<DogecoinAddress> = []
usedAddresses.insert(try DogecoinAddress("D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"))

// CustomStringConvertible - for display
let address = try DogecoinAddress("D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD")
print(address)  // "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"
```

## Address Components

### Public Key to Address

Generate an address from a public key:

```swift
let publicKeyHex = "02a1633cafcc01ebfb6d78e39f687a1f0995c62fc95f51ead10a02ee0be551b5dc"

let address = try Address.fromPublicKey(publicKeyHex, network: .mainnet)
print(address)  // "D..."
```

### Address to Public Key Hash

Extract the public key hash from an address:

```swift
let address = "D7Y55r6Yoc1G8EECxkQ6SuSjTgGJJ7M6yD"
let pubkeyHash = try Address.toPubkeyHash(address)
print(pubkeyHash)  // Hex string of the hash160
```

### Public Key Hash to Address

Convert a public key hash back to an address:

```swift
let pubkeyHash = "89abcdef..."  // Hex string
let address = try Address.fromPubkeyHash(pubkeyHash, network: .mainnet)
print(address)  // "D..."
```

## Generating Addresses

### From HD Wallet

The recommended way to generate addresses:

```swift
let wallet = try HDWallet.create(network: .mainnet)

// Receiving addresses (change = false)
let receiving0 = try wallet.deriveAddress(account: 0, index: 0)
let receiving1 = try wallet.deriveAddress(account: 0, index: 1)

// Change addresses (change = true)
let change0 = try wallet.deriveAddress(account: 0, index: 0, change: true)
```

### From Simple Key Pair

For simpler use cases without HD derivation:

```swift
let keyPair = try KeyPair.generate(network: .mainnet)
print("Address: \(keyPair.address)")
print("Private Key (WIF): \(keyPair.privateKeyWIF)")
```

> Warning: Simple key pairs don't benefit from mnemonic backup. Use HD wallets for production applications.

## Address Gap Limit

When scanning for used addresses (e.g., during wallet restoration), use a gap limit:

```swift
func scanForUsedAddresses(wallet: HDWallet, gapLimit: Int = 20) async throws -> [String] {
    var usedAddresses: [String] = []
    var consecutiveUnused = 0
    var index: UInt32 = 0

    while consecutiveUnused < gapLimit {
        let address = try wallet.deriveAddress(account: 0, index: index)

        if await checkAddressHasTransactions(address) {
            usedAddresses.append(address)
            consecutiveUnused = 0
        } else {
            consecutiveUnused += 1
        }

        index += 1
    }

    return usedAddresses
}
```

The gap limit (typically 20) determines how many consecutive unused addresses to check before stopping the scan.

## QR Code Integration

Addresses are commonly shared via QR codes. Here's how to integrate with a QR scanner:

```swift
import AVFoundation

func handleScannedQRCode(_ content: String) {
    // Handle dogecoin: URI scheme
    if content.lowercased().hasPrefix("dogecoin:") {
        let addressPart = String(content.dropFirst(9))
        let address = addressPart.components(separatedBy: "?").first ?? addressPart
        processScannedAddress(address)
    } else {
        // Plain address
        processScannedAddress(content)
    }
}

func processScannedAddress(_ address: String) {
    guard Address.isValid(address) else {
        showError("Invalid QR code - not a valid Dogecoin address")
        return
    }

    // Use the validated address
    recipientAddressField.text = address
}
```

## Best Practices

### Address Reuse

Avoid reusing addresses when possible:

```swift
class AddressManager {
    private let wallet: HDWallet
    private var nextReceivingIndex: UInt32 = 0
    private var nextChangeIndex: UInt32 = 0

    func getNextReceivingAddress() throws -> String {
        let address = try wallet.deriveAddress(account: 0, index: nextReceivingIndex)
        nextReceivingIndex += 1
        return address
    }

    func getNextChangeAddress() throws -> String {
        let address = try wallet.deriveAddress(account: 0, index: nextChangeIndex, change: true)
        nextChangeIndex += 1
        return address
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
print(address.formattedAddress())  // "D7Y55r6Y...J7M6yD"
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
- ``KeyPair``
- <doc:CreatingAWallet>
