# Handling Amounts

Work with Dogecoin amounts safely and accurately.

@Metadata {
    @PageKind(article)
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
let amount = DogecoinAmount(doge: 100.5)
```

The value is rounded to the nearest koinu. Negative and non-finite values become zero. A `Double` holds an amount exactly to the koinu only up to about 90 million DOGE, so where every koinu matters create the amount from koinu or from a string.

### From Koinu Value

```swift
// From koinu (integer)
let amount = DogecoinAmount(koinu: 150_000_000)  // 1.5 DOGE
```

### From String

```swift
// From a string representation
let amount = try DogecoinAmount(dogeString: "123.456")
```

The string must be plain ASCII digits, optionally followed by `.` and one to eight decimal places, such as `"100"` or `"0.5"`. Surrounding whitespace is ignored. A sign, a grouping separator, a decimal comma, an exponent, or a ninth decimal place throws ``DogecoinError/amountConversionFailed``, so bring text typed in the user's locale into this form first:

```swift
do {
    let amount = try DogecoinAmount(dogeString: userInput)
    print("Sending \(amount)")
} catch DogecoinError.amountConversionFailed {
    showError("Enter an amount such as 12.5")
}
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

// Always 8 decimal places, computed without floating point
print(amount.dogeString)  // "1234.56789000"

// As description (includes "DOGE" suffix)
print(amount.description)  // "1234.56789000 DOGE"
```

To show fewer decimal places or the user's digit grouping, see <doc:HandlingAmounts#Displaying-Amounts>.

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

> Warning: Subtraction saturates at zero. Subtracting a larger amount from a smaller one returns ``DogecoinAmount/zero`` instead of trapping, so a shortfall can go unnoticed. Always validate before subtraction. Addition and multiplication saturate at `UInt64.max` the same way, and dividing by zero gives zero.

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

``DogecoinAmount`` conforms to `Comparable`:

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
// A transaction with 2 inputs and 2 outputs is at most 374 bytes
let size = FeeEstimation.estimateTransactionSize(inputCount: 2, outputCount: 2)

// At the standard rate: 0.01 DOGE per 1,000 bytes
let fee = FeeEstimation.calculateFee(sizeBytes: size, feePerKB: FeeEstimation.standardFeePerKB)
print("Estimated fee: \(fee)")  // "Estimated fee: 0.00374000 DOGE"
```

``FeeEstimation/estimateFee(inputCount:outputCount:priority:)`` does both steps in one call. <doc:SendingTransactions> covers the fee rates and the dust rules.

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

``SpendPlan`` works the inputs, the fee, and the change out together.

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
let fee = FeeEstimation.typicalFee

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
print("Total: \(total)")  // "Total: 100.00000000 DOGE"
```

## Displaying Amounts

``DogecoinAmount/dogeString`` always shows eight decimal places. For anything else, format the exact value as a `Decimal` rather than the `Double` in ``DogecoinAmount/doge``, which can be off by a few koinu for very large amounts.

### User-Friendly Formatting

```swift
extension DogecoinAmount {
    /// The exact amount in DOGE
    var decimalValue: Decimal {
        Decimal(koinu) / Decimal(Self.koinuPerDoge)
    }

    /// Format for display with appropriate precision
    func displayString(showSymbol: Bool = true) -> String {
        let decimals = switch doge {
        case 1000...: 2
        case 1...: 4
        default: 8
        }
        let formatted = decimalValue.formatted(
            .number
                .precision(.fractionLength(decimals))
                .grouping(.never)
                .locale(Locale(identifier: "en_US_POSIX"))
        )
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
    /// Uses `decimalValue` from the extension above
    func localizedString(locale: Locale = .current) -> String {
        decimalValue.formatted(
            .number
                .precision(.fractionLength(2...8))
                .locale(locale)
        )
    }
}

let amount = DogecoinAmount(doge: 1234567.89)
print(amount.localizedString(locale: Locale(identifier: "en_US")))  // "1,234,567.89"
print(amount.localizedString(locale: Locale(identifier: "de_DE")))  // "1.234.567,89"
```

## Serialization

``DogecoinAmount`` conforms to `Codable`:

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
    fee: DogecoinAmount(koinu: 226_000)
)
let json = try JSONEncoder().encode(tx)

// Decode
let decoded = try JSONDecoder().decode(Transaction.self, from: json)
print(decoded.amount.doge)  // 100.0
```

> Note: ``DogecoinAmount`` serializes as its koinu value (UInt64) for precision.

## Best Practices

1. **Always use DogecoinAmount** — Never store amounts as Double or String
2. **Validate inputs** — Check for negative amounts or overflow, and against ``DogecoinAmount/maxMoney``, the most any transaction output may carry
3. **Use koinu for storage** — Store amounts as UInt64 in databases
4. **Format for display** — Use appropriate decimal places based on amount size
5. **Check before subtraction** — Ensure the result won't be negative

## See Also

- ``DogecoinAmount``
- ``FeeEstimation``
- ``SpendPlan``
- <doc:SendingTransactions>
