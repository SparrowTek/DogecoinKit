import Foundation

public struct BloomFilter: Sendable {
    public let hashFunctions: UInt32
    public let tweak: UInt32
    public let flags: UInt8

    public private(set) var data: Data

    public init(
        elementCount: Int,
        falsePositiveRate: Double = 0.001,
        tweak: UInt32 = UInt32.random(in: 0...UInt32.max),
        flags: UInt8 = 0
    ) {
        let params = BloomFilterParameters(elementCount: elementCount, falsePositiveRate: falsePositiveRate)
        self.hashFunctions = params.hashFunctions
        self.data = Data(repeating: 0, count: params.size)
        self.tweak = tweak
        self.flags = flags
    }

    public init(data: Data, hashFunctions: UInt32, tweak: UInt32, flags: UInt8) {
        self.data = data
        self.hashFunctions = hashFunctions
        self.tweak = tweak
        self.flags = flags
    }

    public mutating func insert(_ element: Data) {
        guard !data.isEmpty else { return }
        for i in 0..<hashFunctions {
            let seed = i &* 0xfba4c795 &+ tweak
            let hash = murmurHash(seed: seed, data: element)
            let bitIndex = Int(hash % UInt32(data.count * 8))
            setBit(bitIndex)
        }
    }

    public func contains(_ element: Data) -> Bool {
        guard !data.isEmpty else { return false }
        for i in 0..<hashFunctions {
            let seed = i &* 0xfba4c795 &+ tweak
            let hash = murmurHash(seed: seed, data: element)
            let bitIndex = Int(hash % UInt32(data.count * 8))
            if !isBitSet(bitIndex) {
                return false
            }
        }
        return true
    }

    public func loadMessage() -> FilterLoadMessage {
        FilterLoadMessage(filter: self)
    }

    private mutating func setBit(_ index: Int) {
        let byteIndex = index / 8
        let bit = UInt8(1 << (index % 8))
        data[byteIndex] |= bit
    }

    private func isBitSet(_ index: Int) -> Bool {
        let byteIndex = index / 8
        let bit = UInt8(1 << (index % 8))
        return (data[byteIndex] & bit) != 0
    }

    private func murmurHash(seed: UInt32, data: Data) -> UInt32 {
        let c1: UInt32 = 0xcc9e2d51
        let c2: UInt32 = 0x1b873593

        var hash = seed
        let bytes = [UInt8](data)
        let blockCount = bytes.count / 4

        for i in 0..<blockCount {
            let base = i * 4
            var k = UInt32(bytes[base])
                | (UInt32(bytes[base + 1]) << 8)
                | (UInt32(bytes[base + 2]) << 16)
                | (UInt32(bytes[base + 3]) << 24)

            k &*= c1
            k = (k << 15) | (k >> 17)
            k &*= c2

            hash ^= k
            hash = (hash << 13) | (hash >> 19)
            hash = hash &* 5 &+ 0xe6546b64
        }

        var k1: UInt32 = 0
        let tailIndex = blockCount * 4
        let tailCount = bytes.count - tailIndex

        if tailCount > 0 {
            if tailCount >= 3 {
                k1 ^= UInt32(bytes[tailIndex + 2]) << 16
            }
            if tailCount >= 2 {
                k1 ^= UInt32(bytes[tailIndex + 1]) << 8
            }
            if tailCount >= 1 {
                k1 ^= UInt32(bytes[tailIndex])
                k1 &*= c1
                k1 = (k1 << 15) | (k1 >> 17)
                k1 &*= c2
                hash ^= k1
            }
        }

        hash ^= UInt32(bytes.count)
        hash ^= hash >> 16
        hash &*= 0x85ebca6b
        hash ^= hash >> 13
        hash &*= 0xc2b2ae35
        hash ^= hash >> 16

        return hash
    }
}

public struct FilterLoadMessage: Sendable {
    public let filter: BloomFilter

    public init(filter: BloomFilter) {
        self.filter = filter
    }

    public func serialize() -> Data {
        var data = Data()
        data.append(VarInt(UInt64(filter.data.count)).serialize())
        data.append(filter.data)

        var hashFunctions = filter.hashFunctions.littleEndian
        data.append(Data(bytes: &hashFunctions, count: 4))

        var tweak = filter.tweak.littleEndian
        data.append(Data(bytes: &tweak, count: 4))

        data.append(filter.flags)
        return data
    }
}

public struct FilterAddMessage: Sendable {
    public let element: Data

    public init(element: Data) {
        self.element = element
    }

    public func serialize() -> Data {
        var data = Data()
        data.append(VarInt(UInt64(element.count)).serialize())
        data.append(element)
        return data
    }
}

public struct FilterClearMessage: Sendable {
    public init() {}

    public func serialize() -> Data {
        Data()
    }
}

private struct BloomFilterParameters: Sendable {
    let size: Int
    let hashFunctions: UInt32

    init(elementCount: Int, falsePositiveRate: Double) {
        let n = max(1, elementCount)
        let p = max(0.0001, min(0.25, falsePositiveRate))
        let ln2 = log(2.0)

        let sizeDouble = (-1.0 / (ln2 * ln2)) * Double(n) * log(p)
        let sizeBytes = Int(max(1.0, min(sizeDouble / 8.0, 36000.0)))

        let hashFuncs = UInt32(max(1.0, min(Double(sizeBytes * 8) / Double(n) * ln2, 50.0)))

        self.size = sizeBytes
        self.hashFunctions = hashFuncs
    }
}
