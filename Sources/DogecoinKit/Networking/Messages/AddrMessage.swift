import Foundation

public struct AddrMessage: Sendable {
    public struct Entry: Sendable {
        public let timestamp: UInt32
        public let address: NetworkAddress

        public init(timestamp: UInt32, address: NetworkAddress) {
            self.timestamp = timestamp
            self.address = address
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public func serialize() -> Data {
        var data = Data()
        data.append(VarInt(UInt64(entries.count)).serialize())

        for entry in entries {
            var timestamp = entry.timestamp.littleEndian
            data.append(Data(bytes: &timestamp, count: 4))
            data.append(entry.address.serialize())
        }

        return data
    }

    public static func parse(from data: Data) -> AddrMessage? {
        guard let (count, varIntSize) = VarInt.parse(from: data) else { return nil }
        guard count <= 1000 else { return nil }

        var offset = varIntSize
        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))

        for _ in 0..<count {
            guard let timestampRaw: UInt32 = data.readInteger(at: offset),
                  let addressBytes = data.bytes(at: offset + 4, count: 26),
                  let address = NetworkAddress.parse(from: addressBytes) else { return nil }
            let timestamp = UInt32(littleEndian: timestampRaw)

            entries.append(Entry(timestamp: timestamp, address: address))
            offset += 30
        }

        return AddrMessage(entries: entries)
    }
}
