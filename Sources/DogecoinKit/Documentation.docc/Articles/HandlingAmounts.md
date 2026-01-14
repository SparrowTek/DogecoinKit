# Handling Amounts

Work with Dogecoin amounts safely and accurately.

@Metadata {
    @PageKind(article)
    @PageImage(purpose: card, source: "amounts-card", alt: "Handling Dogecoin amounts")
}

## Overview

Dogecoin amounts require careful handling to avoid floating-point errors. DogecoinKit provides ``DogecoinAmount``, a type-safe wrapper that stores values as integers internally while providing a convenient API for working with decimal amounts.

## Understanding Units

Dogecoin uses two units:

| Unit | Relationship | Example |
|------|--------------|---------|
| DOGE | Base unit | 1.5 DOGE |
| Koinu | Smallest unit | 150,000,000 koinu |

**1 DOGE = 100,000,000 koinu** (100 million)

Koinu is to Dogecoin what satoshi is to Bitcoin.

## Creating Amounts

### From Dogecoin Value

```swift
import DogecoinKit

// From a Double
let amount1 = DogecoinAmount(doge: 100.5)

// Using static method
let amount2 = DogecoinAmount.doge(100)
```

### From Koinu Value

```swift
// From koinu (integer)
let amount1 = DogecoinAmount(koinu: 150_000_000)  // 1.5 DOGE

// Using static method
let amount2 = DogecoinAmount.koinu(50_000_000)   // 0.5 DOGE
```

### From String

```swift
// From a string representation
let amount = try DogecoinAmount(dogeString: "123.456")
```

### Literal Syntax

``DogecoinAmount`` supports literal syntax for convenience:

```swift
// Integer literal (whole DOGE)
let wholeDoge: DogecoinAmount = 100  // 100 DOGE

// Float literal
let fractionalDoge: DogecoinAmount = 1.5  // 1.5 DOGE
```

## Reading Values

### Get the Dogecoin Value

```swift
let amount = DogecoinAmount(koinu: 150_000_000)

// As Double
print(amount.doge)  // 1.5

// As formatted String
print(amount.dogeString)  // "1.50000000"
```

### Get the Koinu Value

```swift
let amount = DogecoinAmount(doge: 1.5)
print(amount.koinu)  // 150000000
```

### Formatted Output

```swift
let amount = DogecoinAmount(doge: 1234.56789)

// Default: 8 decimal places
print(amount.dogeString)  // "1234.56789000"

// Custom decimal places
print(amount.formatted(decimals: 2))  // "1234.57"
print(amount.formatted(decimals: 0))  // "1235"
print(amount.formatted(decimals: 4))  // "1234.5679"

// As description (includes "DOGE" suffix)
print(amount.description)  // "1234.56789000 DOGE"
```

## Arithmetic Operations

``DogecoinAmount`` supports standard arithmetic:

### Addition

```swift
let a = DogecoinAmount(doge: 100)
let b = DogecoinAmount(doge: 50)

let sum = a + b
print(sum.doge)  // 150.0

// Compound assignment
var total = DogecoinAmount.zero
total += a
total += b
print(total.doge)  // 150.0
```

### Subtraction

```swift
let balance = DogecoinAmount(doge: 100)
let spend = DogecoinAmount(doge: 30)

let remaining = balance - spend
print(remaining.doge)  // 70.0

// Compound assignment
var wallet = DogecoinAmount(doge: 100)
wallet -= spend
print(wallet.doge)  // 70.0
```

> Warning: Subtracting a larger amount from a smaller one will cause an underflow. Always validate before subtraction.

### Multiplication

```swift
let price = DogecoinAmount(doge: 10)
let quantity: UInt64 = 5

let total = price * quantity
print(total.doge)  // 50.0
```

### Division

```swift
let total = DogecoinAmount(doge: 100)
let parts: UInt64 = 4

let each = total / parts
print(each.doge)  // 25.0
```

## Comparisons

``DogecoinAmount`` conforms to ``Comparable``:

```swift
let small = DogecoinAmount(doge: 10)
let large = DogecoinAmount(doge: 100)

print(small < large)   // true
print(small > large)   // false
print(small <= large)  // true
print(small >= large)  // false
print(small == large)  // false
```

### Checking for Zero

```swift
let amount = DogecoinAmount.zero

if amount == .zero {
    print("Empty balance")
}
```

## Common Use Cases

### Calculating Transaction Fee

```swift
func calculateFee(inputCount: Int, outputCount: Int) -> DogecoinAmount {
    // Estimate transaction size
    let estimatedSize = inputCount * 148 + outputCount * 34 + 10

    // Fee rate: 1 DOGE per KB (minimum)
    let feePerByte = DogecoinAmount(koinu: 1000)  // 0.00001 DOGE per byte

    return feePerByte * UInt64(estimatedSize)
}

let fee = calculateFee(inputCount: 2, outputCount: 2)
print("Estimated fee: \(fee)")
```

### Calculating Change

```swift
func calculateChange(
    inputs: [UTXO],
    sendAmount: DogecoinAmount,
    fee: DogecoinAmount
) -> DogecoinAmount {
    let totalInput = inputs.reduce(.zero) { $0 + $1.amount }
    return totalInput - sendAmount - fee
}
```

### Validating Sufficient Balance

```swift
func canAffordTransaction(
    balance: DogecoinAmount,
    sendAmount: DogecoinAmount,
    fee: DogecoinAmount
) -> Bool {
    let totalNeeded = sendAmount + fee
    return balance >= totalNeeded
}

let balance = DogecoinAmount(doge: 100)
let sending = DogecoinAmount(doge: 50)
let fee = DogecoinAmount(doge: 1)

if canAffordTransaction(balance: balance, sendAmount: sending, fee: fee) {
    print("Transaction is affordable")
} else {
    print("Insufficient funds")
}
```

### Summing UTXOs

```swift
func totalBalance(utxos: [UTXO]) -> DogecoinAmount {
    utxos.reduce(.zero) { $0 + $1.amount }
}

let utxos = [
    UTXO(txid: "...", vout: 0, address: "...", amount: DogecoinAmount(doge: 50)),
    UTXO(txid: "...", vout: 1, address: "...", amount: DogecoinAmount(doge: 30)),
    UTXO(txid: "...", vout: 0, address: "...", amount: DogecoinAmount(doge: 20))
]

let total = totalBalance(utxos: utxos)
print("Total: \(total)")  // "100.00000000 DOGE"
```

## Displaying Amounts

### User-Friendly Formatting

```swift
extension DogecoinAmount {
    /// Format for display with appropriate precision
    func displayString(showSymbol: Bool = true) -> String {
        let formatted: String
        if doge >= 1000 {
            formatted = self.formatted(decimals: 2)
        } else if doge >= 1 {
            formatted = self.formatted(decimals: 4)
        } else {
            formatted = self.formatted(decimals: 8)
        }
        return showSymbol ? "Ð\(formatted)" : formatted
    }
}

let large = DogecoinAmount(doge: 12345.6789)
print(large.displayString())  // "Ð12345.68"

let medium = DogecoinAmount(doge: 123.456789)
print(medium.displayString())  // "Ð123.4568"

let small = DogecoinAmount(doge: 0.00001234)
print(small.displayString())  // "Ð0.00001234"
```

### Locale-Aware Formatting

```swift
extension DogecoinAmount {
    func localizedString(locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 8

        return formatter.string(from: NSNumber(value: doge)) ?? dogeString
    }
}

let amount = DogecoinAmount(doge: 1234567.89)
print(amount.localizedString())  // "1,234,567.89" (US) or "1.234.567,89" (DE)
```

## Serialization

``DogecoinAmount`` conforms to ``Codable``:

```swift
struct Transaction: Codable {
    let id: String
    let amount: DogecoinAmount
    let fee: DogecoinAmount
}

// Encode
let tx = Transaction(
    id: "abc123",
    amount: DogecoinAmount(doge: 100),
    fee: DogecoinAmount(doge: 1)
)
let json = try JSONEncoder().encode(tx)

// Decode
let decoded = try JSONDecoder().decode(Transaction.self, from: json)
print(decoded.amount.doge)  // 100.0
```

> Note: ``DogecoinAmount`` serializes as its koinu value (UInt64) for precision.

## Utility Functions

### Convert Koinu to String

```swift
let koinu: UInt64 = 150_000_000
let string = koinuToDogeString(koinu)
print(string)  // "1.50000000"
```

### Convert String to Koinu

```swift
let string = "1.5"
let koinu = try dogeStringToKoinu(string)
print(koinu)  // 150000000
```

## Best Practices

1. **Always use DogecoinAmount** — Never store amounts as Double or String
2. **Validate inputs** — Check for negative amounts or overflow
3. **Use koinu for storage** — Store amounts as UInt64 in databases
4. **Format for display** — Use appropriate decimal places based on amount size
5. **Check before subtraction** — Ensure the result won't be negative

## See Also

- ``DogecoinAmount``
- ``koinuToDogeString(_:)``
- ``dogeStringToKoinu(_:)``
- <doc:SendingTransactions>
