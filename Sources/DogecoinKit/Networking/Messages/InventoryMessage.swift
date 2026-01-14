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
    /// Compact block
    case compactBlock = 4
    /// Witness transaction (segwit)
    case witnessTransaction = 0x40000001
    /// Witness block (segwit)
    case witnessBlock = 0x40000002
    /// Witness filtered block (segwit)
    case witnessFilteredBlock = 0x40000003
}

/// Inventory vector
public struct InventoryVector: Sendable, Equatable, Hashable {
    /// Type of object
    public let type: InventoryType

    /// Hash of object (32 bytes)
    public let hash: Data

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
        guard data.count >= 36 else { return nil }

        let typeRaw = data.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let type = InventoryType(rawValue: typeRaw) ?? .error
        let hash = Data(data[4..<36])

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
        guard let (count, varIntSize) = VarInt.parse(from: data) else { return nil }

        var offset = varIntSize
        var inventory: [InventoryVector] = []

        for _ in 0..<count {
            guard data.count >= offset + 36 else { return nil }
            guard let inv = InventoryVector.parse(from: Data(data[offset..<offset+36])) else { return nil }
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
        guard let (count, varIntSize) = VarInt.parse(from: data) else { return nil }

        var offset = varIntSize
        var inventory: [InventoryVector] = []

        for _ in 0..<count {
            guard data.count >= offset + 36 else { return nil }
            guard let inv = InventoryVector.parse(from: Data(data[offset..<offset+36])) else { return nil }
            inventory.append(inv)
            offset += 36
        }

        return GetDataMessage(inventory: inventory)
    }
}

/// Not found message
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
        guard let (count, varIntSize) = VarInt.parse(from: data) else { return nil }

        var offset = varIntSize
        var inventory: [InventoryVector] = []

        for _ in 0..<count {
            guard data.count >= offset + 36 else { return nil }
            guard let inv = InventoryVector.parse(from: Data(data[offset..<offset+36])) else { return nil }
            inventory.append(inv)
            offset += 36
        }

        return NotFoundMessage(inventory: inventory)
    }
}
