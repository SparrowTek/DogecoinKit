import Foundation
import CryptoKit

enum MerkleTree {
    static func doubleSHA256(_ data: Data) -> Data {
        let hash1 = SHA256.hash(data: data)
        let hash2 = SHA256.hash(data: Data(hash1))
        return Data(hash2)
    }

    static func hashPair(_ left: Data, _ right: Data) -> Data {
        var combined = Data()
        combined.append(left)
        combined.append(right)
        return doubleSHA256(combined)
    }

    static func calculateRoot(from hashes: [Data]) -> Data? {
        guard !hashes.isEmpty else { return nil }

        var level = hashes
        while level.count > 1 {
            var next: [Data] = []
            next.reserveCapacity((level.count + 1) / 2)

            var index = 0
            while index < level.count {
                let left = level[index]
                let right = (index + 1 < level.count) ? level[index + 1] : left
                next.append(hashPair(left, right))
                index += 2
            }

            level = next
        }

        return level[0]
    }
}
