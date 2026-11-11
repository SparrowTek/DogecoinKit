import Foundation
import Testing
@testable import DogecoinKit

/// The filter a wallet hands its peers has to be the filter they compute:
/// one differing bit and they stop sending the wallet's transactions. These
/// are the known answers from Bitcoin Core's own `bloom_tests.cpp`.
@Suite("Bloom Filter")
struct BloomFilterTests {

    private static let elements = [
        "99108ad8ed9bb6274d3980bab5a85c048f0950c8",
        "b5a2c786d9ef4658287ced5914b37a1b4aa32eee",
        "b9300670b4c5366e95b2699e8b18bc75e5f729c5",
    ]

    private func filter(tweak: UInt32) throws -> BloomFilter {
        var filter = BloomFilter(elementCount: 3, falsePositiveRate: 0.01, tweak: tweak, flags: 1)
        for element in Self.elements {
            filter.insert(try #require(Data(hexString: element)))
        }
        return filter
    }

    @Test("A filter of three elements serializes to Core's bytes", arguments: [
        (UInt32(0), "03614e9b050000000000000001"),
        (UInt32(2_147_483_649), "03ce4299050000000100008001"),
    ])
    func knownAnswer(tweak: UInt32, expected: String) throws {
        let filter = try filter(tweak: tweak)

        #expect(filter.loadMessage().serialize().hexString == expected)
    }

    @Test("What was inserted is found, and its near neighbour is not")
    func membership() throws {
        let filter = try filter(tweak: 0)

        for element in Self.elements {
            #expect(filter.contains(try #require(Data(hexString: element))))
        }
        // One bit away from the first element.
        #expect(!filter.contains(try #require(Data(hexString: "19108ad8ed9bb6274d3980bab5a85c048f0950c8"))))
    }

    @Test("A filter rebuilt from its parts answers as the original does")
    func rebuilt() throws {
        let original = try filter(tweak: 2_147_483_649)
        // As a slice of a larger buffer, the way a message hands it over.
        let buffer = Data([0xFF, 0xFF]) + original.data
        let rebuilt = BloomFilter(
            data: buffer.dropFirst(2),
            hashFunctions: original.hashFunctions,
            tweak: original.tweak,
            flags: original.flags
        )

        for element in Self.elements {
            #expect(rebuilt.contains(try #require(Data(hexString: element))))
        }
        #expect(rebuilt.loadMessage().serialize() == original.loadMessage().serialize())
    }

    @Test("A filter never grows past what peers accept")
    func sizeLimits() {
        let huge = BloomFilter(elementCount: 10_000_000, falsePositiveRate: 0.0001)

        // BIP 37: at most 36,000 bytes and 50 hash functions.
        #expect(huge.data.count == 36_000)
        #expect(huge.hashFunctions <= 50)
        #expect(BloomFilter(elementCount: 0).data.count >= 1)
    }

    @Test("An element is added to a loaded filter by its bytes, length first")
    func filterAdd() throws {
        let element = try #require(Data(hexString: Self.elements[0]))

        #expect(FilterAddMessage(element: element).serialize().hexString == "14" + Self.elements[0])
    }
}
