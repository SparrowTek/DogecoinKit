import Foundation

/// Inventory vector types
public enum InventoryType: UInt32, Sendable, CaseIterable {
    /// Error type
    case error = 0
    /// Transaction
    case transaction = 1
    /// Block
    case block = 2
    /// Filtered block (Merkle block)
    case filteredBlock = 3
}

/// Inventory vector
public struct InventoryVector: Sendable, Equatable, Hashable {
    /// Type of object
    public let type: InventoryType

    /// Hash of object (32 bytes)
    public let hash: Data

    /// Most entries an inv/getdata/notfound message may carry — Dogecoin
    /// Core's `MAX_INV_SZ`; larger messages are a protocol violation.
    public static let maxEntriesPerMessage = 50_000

    /// Create an inventory vector
    public init(type: InventoryType, hash: Data) {
        self.type = type
        self.hash = hash
    }

    /// Serialize to Data (36 bytes)
    public func serialize() -> Data {
        var data = Data()

        var type = self.type.rawValue.littleEndian
        data.append(Data(bytes: &type, count: 4))
        data.append(hash)

        return data
    }

    /// Parse from Data
    public static func parse(from data: Data) -> InventoryVector? {
        guard let typeRaw: UInt32 = data.readInteger(at: 0),
              let hash = data.bytes(at: 4, count: 32) else { return nil }
        // Kinds this client never asks for (compact blocks, witness data)
        // read as `.error` and are ignored.
        let type = InventoryType(rawValue: UInt32(littleEndian: typeRaw)) ?? .error

        return InventoryVector(type: type, hash: hash)
    }
}

/// Inventory message (inv)
public struct InvMessage: Sendable {
    /// List of inventory vectors
    public let inventory: [InventoryVector]

    /// Create an inv message
    public init(inventory: [InventoryVector]) {
        self.inventory = inventory
    }

    /// Serialize to Data
    public func serialize() -> Data {
        var data = Data()

        data.append(VarInt(UInt64(inventory.count)).serialize())
        for inv in inventory {
            data.append(inv.serialize())
        }

        return data
    }

    /// Parse from Data
    public static func parse(from data: Data) -> InvMessage? {
        guard let (count, varIntSize) = data.readBoundedCount(at: 0, minItemSize: 36),
              count <= InventoryVector.maxEntriesPerMessage else { return nil }

        var offset = varIntSize
        var inventory: [InventoryVector] = []
        inventory.reserveCapacity(count)

        for _ in 0..<count {
            guard let entry = data.bytes(at: offset, count: 36),
                  let inv = InventoryVector.parse(from: entry) else { return nil }
            inventory.append(inv)
            offset += 36
        }

        return InvMessage(inventory: inventory)
    }
}

/// Get data message
public struct GetDataMessage: Sendable {
    /// List of inventory vectors to request
    public let inventory: [InventoryVector]

    /// Create a getdata message
    public init(inventory: [InventoryVector]) {
        self.inventory = inventory
    }

    /// Serialize to Data
    public func serialize() -> Data {
        var data = Data()

        data.append(VarInt(UInt64(inventory.count)).serialize())
        for inv in inventory {
            data.append(inv.serialize())
        }

        return data
    }

    /// Parse from Data
    public static func parse(from data: Data) -> GetDataMessage? {
        guard let (count, varIntSize) = data.readBoundedCount(at: 0, minItemSize: 36),
              count <= InventoryVector.maxEntriesPerMessage else { return nil }

        var offset = varIntSize
        var inventory: [InventoryVector] = []
        inventory.reserveCapacity(count)

        for _ in 0..<count {
            guard let entry = data.bytes(at: offset, count: 36),
                  let inv = InventoryVector.parse(from: entry) else { return nil }
            inventory.append(inv)
            offset += 36
        }

        return GetDataMessage(inventory: inventory)
    }
}

/// Not found message: what a peer was asked for with `getdata` and does not have
public struct NotFoundMessage: Sendable {
    /// List of inventory vectors not found
    public let inventory: [InventoryVector]

    /// Create a notfound message
    public init(inventory: [InventoryVector]) {
        self.inventory = inventory
    }

    /// Serialize to Data
    public func serialize() -> Data {
        var data = Data()

        data.append(VarInt(UInt64(inventory.count)).serialize())
        for inv in inventory {
            data.append(inv.serialize())
        }

        return data
    }

    /// Parse from Data
    public static func parse(from data: Data) -> NotFoundMessage? {
        guard let (count, varIntSize) = data.readBoundedCount(at: 0, minItemSize: 36),
              count <= InventoryVector.maxEntriesPerMessage else { return nil }

        var offset = varIntSize
        var inventory: [InventoryVector] = []
        inventory.reserveCapacity(count)

        for _ in 0..<count {
            guard let entry = data.bytes(at: offset, count: 36),
                  let inv = InventoryVector.parse(from: entry) else { return nil }
            inventory.append(inv)
            offset += 36
        }

        return NotFoundMessage(inventory: inventory)
    }
}
