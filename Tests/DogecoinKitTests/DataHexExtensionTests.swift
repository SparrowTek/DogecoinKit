import Foundation
import Testing
@testable import DogecoinKit

@Suite("Data(hexString:) / Data.hexString")
struct DataHexExtensionTests {

    // MARK: - Valid input

    @Test("Empty string decodes to empty Data")
    func testEmptyString() {
        let data = Data(hexString: "")
        #expect(data == Data())
    }

    @Test("Lowercase hex round-trips")
    func testLowercaseRoundTrip() {
        let hex = "deadbeef"
        let data = Data(hexString: hex)
        #expect(data == Data([0xde, 0xad, 0xbe, 0xef]))
        #expect(data?.hexString == hex)
    }

    @Test("Uppercase hex decodes identically")
    func testUppercaseAccepted() {
        let lower = Data(hexString: "deadbeef")
        let upper = Data(hexString: "DEADBEEF")
        #expect(upper == lower)
    }

    @Test("Mixed case hex decodes correctly")
    func testMixedCase() {
        let data = Data(hexString: "DeAdBeEf")
        #expect(data == Data([0xde, 0xad, 0xbe, 0xef]))
    }

    @Test("32-byte (txid-shaped) hex decodes to 32 bytes")
    func testThirtyTwoByteHex() {
        let txid = String(repeating: "ab", count: 32)
        let data = Data(hexString: txid)
        #expect(data?.count == 32)
    }

    @Test(".hexString emits lowercase two-digit bytes")
    func testEncodeLowercasePadded() {
        // Leading-zero byte must still be two characters wide.
        let data = Data([0x00, 0x0f, 0xff, 0x01])
        #expect(data.hexString == "000fff01")
    }

    // MARK: - Invalid input — every case must return nil, never crash

    @Test("Odd-length input returns nil")
    func testOddLengthReturnsNil() {
        #expect(Data(hexString: "a") == nil)
        #expect(Data(hexString: "abc") == nil)
        #expect(Data(hexString: "deadbee") == nil)
    }

    @Test("Non-hex characters return nil")
    func testNonHexCharactersReturnNil() {
        #expect(Data(hexString: "zz") == nil)
        #expect(Data(hexString: "ghij") == nil)
        #expect(Data(hexString: "de ad") == nil) // space is not hex
        #expect(Data(hexString: "de-ad") == nil)
        #expect(Data(hexString: "de\nad") == nil)
    }

    @Test("Valid prefix followed by invalid suffix returns nil")
    func testInvalidSuffixRejected() {
        // Must reject the whole string, not return the parsed prefix.
        #expect(Data(hexString: "deadzz") == nil)
    }

    @Test("0x prefix is not stripped — leading 'x' is not hex")
    func testZeroXPrefixNotSpecialCased() {
        // `0x...` input contains 'x', which is not a hex digit. The decoder
        // should reject it rather than silently accepting the prefix.
        #expect(Data(hexString: "0xdeadbeef") == nil)
    }
}
