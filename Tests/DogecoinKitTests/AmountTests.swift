import Foundation
import Testing
@testable import DogecoinKit

@Suite("Amounts")
struct AmountTests {

    // MARK: - From text

    private static let readableText: [(String, UInt64)] = [
        ("0", 0),
        ("1", 100_000_000),
        ("1.5", 150_000_000),
        ("100", 10_000_000_000),
        ("0.00000001", 1),
        ("  2.5\n", 250_000_000),
        ("123456789.12345678", 12_345_678_912_345_678),
        // More than a Double can tell apart.
        ("10000000000.00000001", 1_000_000_000_000_000_001),
        ("184467440737.09551615", .max),
    ]

    @Test("Text is read exactly, to the koinu", arguments: readableText)
    func fromText(text: String, koinu: UInt64) throws {
        #expect(try DogecoinAmount(dogeString: text).koinu == koinu)
    }

    @Test("Text that is not a plain amount is refused", arguments: [
        "",
        " ",
        "abc",
        "-1",
        "+1",
        "1.123456789",
        "1e5",
        "0x10",
        "1,5",
        "1.5.0",
        ".5",
        "5.",
        "1 000",
        // Digits, though not the ones an amount is written in.
        "١٢٣",
        // One koinu more than fits.
        "184467440737.09551616",
        "999999999999999999999999",
    ])
    func refusedText(text: String) {
        #expect(throws: DogecoinError.amountConversionFailed) {
            _ = try DogecoinAmount(dogeString: text)
        }
    }

    private static let writtenAmounts: [(UInt64, String)] = [
        (0, "0.00000000"),
        (5, "0.00000005"),
        (123_456_789, "1.23456789"),
        (150_000_000, "1.50000000"),
        (1_000_000_000_000_000_001, "10000000000.00000001"),
        (.max, "184467440737.09551615"),
    ]

    @Test("An amount is written with all eight decimals, exactly", arguments: writtenAmounts)
    func asText(koinu: UInt64, text: String) throws {
        let amount = DogecoinAmount(koinu: koinu)

        #expect(amount.dogeString == text)
        #expect(amount.description == text + " DOGE")
        // What is written reads back as the same amount.
        #expect(try DogecoinAmount(dogeString: text) == amount)
    }

    // MARK: - From a floating-point number

    private static let roundedNumbers: [(Double, UInt64)] = [
        (1.5, 150_000_000),
        (0.1, 10_000_000),
        (0.00000001, 1),
        (0.000000014, 1),
        (0.000000016, 2),
        (0.000000004, 0),
        (21_000_000.12345678, 2_100_000_012_345_678),
    ]

    @Test("A number of DOGE is rounded to the nearest koinu", arguments: roundedNumbers)
    func fromNumber(doge: Double, koinu: UInt64) {
        #expect(DogecoinAmount(doge: doge).koinu == koinu)
    }

    private static let nonAmounts: [Double] = [-1.5, -0.0, .nan, -.infinity, .infinity]

    @Test("A number that is no amount becomes zero", arguments: nonAmounts)
    func notAnAmount(doge: Double) {
        #expect(DogecoinAmount(doge: doge) == .zero)
    }

    private static let oversizedNumbers: [Double] = [184_467_440_737.1, 1e12, 1e300, .greatestFiniteMagnitude]

    @Test("A number too large to hold stops at the largest amount", arguments: oversizedNumbers)
    func tooLarge(doge: Double) {
        #expect(DogecoinAmount(doge: doge).koinu == UInt64.max)
    }

    @Test("An amount is given in DOGE as a number")
    func asNumber() {
        #expect(DogecoinAmount(koinu: 150_000_000).doge == 1.5)
        #expect(DogecoinAmount.zero.doge == 0)
    }

    // MARK: - Arithmetic

    @Test("Sums and differences stop at the ends instead of wrapping")
    func saturatingSumsAndDifferences() {
        let nearMax = DogecoinAmount(koinu: .max - 10)
        let small = DogecoinAmount(koinu: 100)

        #expect((small + small).koinu == 200)
        #expect((nearMax + small).koinu == UInt64.max)
        #expect((nearMax - small).koinu == UInt64.max - 110)
        #expect((small - nearMax) == .zero)
        #expect((small - small) == .zero)

        var running = small
        running += nearMax
        #expect(running.koinu == UInt64.max)
        running -= running
        running -= small
        #expect(running == .zero)
    }

    @Test("Products stop at the largest amount instead of wrapping")
    func saturatingProducts() {
        let amount = DogecoinAmount(koinu: 300)

        #expect((amount * 3).koinu == 900)
        #expect((amount * 0) == .zero)
        #expect((DogecoinAmount(koinu: .max / 2 + 1) * 2).koinu == UInt64.max)
        #expect((DogecoinAmount.maxMoney * 19).koinu == UInt64.max)
    }

    @Test("Division drops the remainder, and by nothing gives nothing")
    func division() {
        let amount = DogecoinAmount(koinu: 1_000)

        #expect((amount / 3).koinu == 333)
        #expect((amount / 1_001) == .zero)
        #expect((amount / 0) == .zero)
    }

    @Test("Amounts order by their value")
    func ordering() {
        let amounts = [DogecoinAmount(koinu: 3), .zero, .maxMoney, DogecoinAmount(koinu: 1)]

        #expect(amounts.sorted().map(\.koinu) == [0, 1, 3, 1_000_000_000_000_000_000])
        #expect(DogecoinAmount.maxMoney.dogeString == "10000000000.00000000")
    }

    // MARK: - Coding

    @Test("An amount is stored as its whole number of koinu")
    func encoding() throws {
        let amounts = [DogecoinAmount.zero, DogecoinAmount(koinu: 150_000_000), DogecoinAmount(koinu: .max)]

        let encoded = try JSONEncoder().encode(amounts)

        #expect(String(decoding: encoded, as: UTF8.self) == "[0,150000000,18446744073709551615]")
        #expect(try JSONDecoder().decode([DogecoinAmount].self, from: encoded) == amounts)
    }

    @Test("Stored values that are not a whole, non-negative number of koinu do not decode", arguments: [
        "[-1]",
        "[1.5]",
        "[18446744073709551616]",
        #"["1"]"#,
        "[null]",
    ])
    func undecodable(json: String) {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode([DogecoinAmount].self, from: Data(json.utf8))
        }
    }
}
