import Foundation

/// Version message for P2P handshake
public struct VersionMessage: Sendable {
    /// Protocol version
    public let version: UInt32

    /// Services bitmap
    public let services: UInt64

    /// Unix timestamp
    public let timestamp: Int64

    /// Receiver's address info
    public let addrRecv: NetworkAddress

    /// Sender's address info
    public let addrFrom: NetworkAddress

    /// Random nonce for connection identification
    public let nonce: UInt64

    /// User agent string
    public let userAgent: String

    /// Last block height known to sender
    public let startHeight: Int32

    /// Whether the node wants to receive relayed transactions
    public let relay: Bool

    /// Create a version message
    public init(
        version: UInt32 = NetworkConstants.protocolVersion,
        services: UInt64 = NetworkConstants.services,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970),
        addrRecv: NetworkAddress = .empty,
        addrFrom: NetworkAddress = .empty,
        nonce: UInt64 = UInt64.random(in: 0...UInt64.max),
        userAgent: String = NetworkConstants.userAgent,
        startHeight: Int32 = 0,
        relay: Bool = true
    ) {
        self.version = version
        self.services = services
        self.timestamp = timestamp
        self.addrRecv = addrRecv
        self.addrFrom = addrFrom
        self.nonce = nonce
        self.userAgent = userAgent
        self.startHeight = startHeight
        self.relay = relay
    }

    /// Serialize to Data
    public func serialize() -> Data {
        var data = Data()

        // Version (4 bytes)
        var version = self.version.littleEndian
        data.append(Data(bytes: &version, count: 4))

        // Services (8 bytes)
        var services = self.services.littleEndian
        data.append(Data(bytes: &services, count: 8))

        // Timestamp (8 bytes)
        var timestamp = self.timestamp.littleEndian
        data.append(Data(bytes: &timestamp, count: 8))

        // Receiver address (26 bytes)
        data.append(addrRecv.serialize())

        // Sender address (26 bytes)
        data.append(addrFrom.serialize())

        // Nonce (8 bytes)
        var nonce = self.nonce.littleEndian
        data.append(Data(bytes: &nonce, count: 8))

        // User agent (var_str)
        data.append(VarInt(UInt64(userAgent.utf8.count)).serialize())
        data.append(Data(userAgent.utf8))

        // Start height (4 bytes)
        var startHeight = self.startHeight.littleEndian
        data.append(Data(bytes: &startHeight, count: 4))

        // Relay (1 byte)
        data.append(relay ? 1 : 0)

        return data
    }

    /// Parse from Data
    public static func parse(from data: Data) -> VersionMessage? {
        guard data.count >= 85 else { return nil }

        var offset = 0

        guard let versionRaw: UInt32 = data.readInteger(at: offset) else { return nil }
        let version = UInt32(littleEndian: versionRaw)
        offset += 4

        guard let servicesRaw: UInt64 = data.readInteger(at: offset) else { return nil }
        let services = UInt64(littleEndian: servicesRaw)
        offset += 8

        guard let timestampRaw: Int64 = data.readInteger(at: offset) else { return nil }
        let timestamp = Int64(littleEndian: timestampRaw)
        offset += 8

        guard let addrRecv = NetworkAddress.parse(from: Data(data[offset..<offset+26])) else { return nil }
        offset += 26

        guard let addrFrom = NetworkAddress.parse(from: Data(data[offset..<offset+26])) else { return nil }
        offset += 26

        guard let nonceRaw: UInt64 = data.readInteger(at: offset) else { return nil }
        let nonce = UInt64(littleEndian: nonceRaw)
        offset += 8

        // Parse var_str for user agent
        guard let (userAgentLength, varIntSize) = VarInt.parse(from: Data(data[offset...])) else { return nil }
        offset += varIntSize

        let userAgentEnd = offset + Int(userAgentLength)
        guard data.count >= userAgentEnd else { return nil }
        let userAgent = String(data: Data(data[offset..<userAgentEnd]), encoding: .utf8) ?? ""
        offset = userAgentEnd

        guard data.count >= offset + 4 else { return nil }
        guard let startHeightRaw: Int32 = data.readInteger(at: offset) else { return nil }
        let startHeight = Int32(littleEndian: startHeightRaw)
        offset += 4

        let relay: Bool
        if data.count > offset {
            relay = data[offset] != 0
        } else {
            relay = true
        }

        return VersionMessage(
            version: version,
            services: services,
            timestamp: timestamp,
            addrRecv: addrRecv,
            addrFrom: addrFrom,
            nonce: nonce,
            userAgent: userAgent,
            startHeight: startHeight,
            relay: relay
        )
    }
}

// MARK: - Network Address

/// Network address structure for version messages
public struct NetworkAddress: Sendable {
    /// Services bitmap
    public let services: UInt64

    /// IPv6-mapped IPv4 address (16 bytes)
    public let address: Data

    /// Port number (big-endian)
    public let port: UInt16

    /// Create an empty network address
    public static let empty = NetworkAddress(services: 0, address: Data(count: 16), port: 0)

    /// Create a network address from IPv4
    public static func ipv4(_ ip: String, port: UInt16, services: UInt64 = 0) -> NetworkAddress {
        var address = Data(count: 16)
        // IPv4-mapped IPv6 prefix
        address[10] = 0xFF
        address[11] = 0xFF

        let components = ip.split(separator: ".").compactMap { UInt8($0) }
        if components.count == 4 {
            address[12] = components[0]
            address[13] = components[1]
            address[14] = components[2]
            address[15] = components[3]
        }

        return NetworkAddress(services: services, address: address, port: port)
    }

    /// Create a network address from IPv6
    public static func ipv6(_ ip: String, port: UInt16, services: UInt64 = 0) -> NetworkAddress? {
        var addr = in6_addr()
        let result = ip.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard result == 1 else { return nil }

        let data = Data(bytes: &addr, count: MemoryLayout<in6_addr>.size)
        return NetworkAddress(services: services, address: data, port: port)
    }

    /// Create a network address from a host string
    public static func from(host: String, port: UInt16, services: UInt64 = 0) -> NetworkAddress? {
        if host.contains(":") {
            return ipv6(host, port: port, services: services)
        }

        return ipv4(host, port: port, services: services)
    }

    /// Whether this address is IPv4-mapped
    public var isIPv4Mapped: Bool {
        guard address.count == 16 else { return false }
        let prefix = address.prefix(12)
        var mappedPrefix = Data(repeating: 0, count: 10)
        mappedPrefix.append(0xFF)
        mappedPrefix.append(0xFF)
        return prefix == mappedPrefix
    }

    /// String representation of the address
    public var addressString: String? {
        if isIPv4Mapped {
            let octets = address.suffix(4).map { String($0) }
            return octets.joined(separator: ".")
        }

        guard address.count == 16 else { return nil }
        var addr = in6_addr()
        _ = withUnsafeMutableBytes(of: &addr) { buffer in
            address.copyBytes(to: buffer)
        }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &output, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return nil
        }
        
        let bytes = Data(output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Basic routability check (filters local/invalid addresses)
    public var isRoutable: Bool {
        if isIPv4Mapped {
            let bytes = Array(address.suffix(4))
            guard bytes.count == 4 else { return false }
            let a = bytes[0]
            let b = bytes[1]
            if a == 0 || a == 10 || a == 127 || a >= 224 {
                return false
            }
            if a == 192 && b == 168 {
                return false
            }
            if a == 172 && (16...31).contains(b) {
                return false
            }
            if a == 169 && b == 254 {
                return false
            }
            return true
        }

        guard address.count == 16 else { return false }
        let bytes = [UInt8](address)
        if bytes.allSatisfy({ $0 == 0 }) {
            return false
        }
        if bytes.dropFirst(15).first == 1 && bytes.prefix(15).allSatisfy({ $0 == 0 }) {
            return false
        }
        if bytes[0] == 0xff {
            return false
        }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 {
            return false
        }
        return true
    }

    /// Serialize to Data (26 bytes - without timestamp)
    public func serialize() -> Data {
        var data = Data()

        var services = self.services.littleEndian
        data.append(Data(bytes: &services, count: 8))

        data.append(address)

        var port = self.port.bigEndian
        data.append(Data(bytes: &port, count: 2))

        return data
    }

    /// Parse from Data
    public static func parse(from data: Data) -> NetworkAddress? {
        guard data.count >= 26 else { return nil }

        guard let servicesRaw: UInt64 = data.readInteger(at: 0) else { return nil }
        let services = UInt64(littleEndian: servicesRaw)
        let address = Data(data[8..<24])
        guard let portRaw: UInt16 = data.readInteger(at: 24) else { return nil }
        let port = UInt16(bigEndian: portRaw)

        return NetworkAddress(services: services, address: address, port: port)
    }
}

// MARK: - VarInt

/// Variable-length integer encoding
public struct VarInt: Sendable {
    public let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }

    /// Serialize to Data
    public func serialize() -> Data {
        var data = Data()

        if value < 0xFD {
            data.append(UInt8(value))
        } else if value <= 0xFFFF {
            data.append(0xFD)
            var v = UInt16(value).littleEndian
            data.append(Data(bytes: &v, count: 2))
        } else if value <= 0xFFFFFFFF {
            data.append(0xFE)
            var v = UInt32(value).littleEndian
            data.append(Data(bytes: &v, count: 4))
        } else {
            data.append(0xFF)
            var v = value.littleEndian
            data.append(Data(bytes: &v, count: 8))
        }

        return data
    }

    /// Parse from Data, returns (value, bytesConsumed)
    public static func parse(from data: Data) -> (UInt64, Int)? {
        guard !data.isEmpty else { return nil }

        let first = data[data.startIndex]

        if first < 0xFD {
            return (UInt64(first), 1)
        } else if first == 0xFD {
            guard data.count >= 3 else { return nil }
            guard let valueRaw: UInt16 = data.readInteger(at: 1) else { return nil }
            let value = UInt16(littleEndian: valueRaw)
            return (UInt64(value), 3)
        } else if first == 0xFE {
            guard data.count >= 5 else { return nil }
            guard let valueRaw: UInt32 = data.readInteger(at: 1) else { return nil }
            let value = UInt32(littleEndian: valueRaw)
            return (UInt64(value), 5)
        } else {
            guard data.count >= 9 else { return nil }
            guard let valueRaw: UInt64 = data.readInteger(at: 1) else { return nil }
            let value = UInt64(littleEndian: valueRaw)
            return (value, 9)
        }
    }
}

