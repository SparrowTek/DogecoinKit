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
            guard data.count >= offset + 30 else { return nil }
            guard let timestampRaw: UInt32 = data.readInteger(at: offset) else { return nil }
            let timestamp = UInt32(littleEndian: timestampRaw)
            let addrStart = offset + 4
            guard let address = NetworkAddress.parse(from: Data(data[addrStart..<addrStart + 26])) else { return nil }

            entries.append(Entry(timestamp: timestamp, address: address))
            offset += 30
        }

        return AddrMessage(entries: entries)
    }
}
