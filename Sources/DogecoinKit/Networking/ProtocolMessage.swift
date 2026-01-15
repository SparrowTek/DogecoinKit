import Foundation
import CryptoKit

/// A Dogecoin P2P protocol message
public struct ProtocolMessage: Sendable {
    /// The network magic bytes
    public let magic: UInt32

    /// Command name (up to 12 characters)
    public let command: String

    /// Payload data
    public let payload: Data

    /// Create a protocol message
    public init(magic: UInt32, command: String, payload: Data) {
        self.magic = magic
        self.command = command
        self.payload = payload
    }

    /// Create a protocol message for a specific network
    public init(network: DogecoinNetwork, command: String, payload: Data) {
        self.magic = NetworkConstants.magic(for: network)
        self.command = command
        self.payload = payload
    }

    /// Serialize the message for sending
    public func serialize() -> Data {
        var data = Data()

        // Magic (4 bytes, little-endian)
        var magic = self.magic.littleEndian
        data.append(Data(bytes: &magic, count: 4))

        // Command (12 bytes, null-padded)
        var commandBytes = [UInt8](command.utf8)
        while commandBytes.count < 12 {
            commandBytes.append(0)
        }
        data.append(contentsOf: commandBytes.prefix(12))

        // Payload length (4 bytes, little-endian)
        var length = UInt32(payload.count).littleEndian
        data.append(Data(bytes: &length, count: 4))

        // Checksum (first 4 bytes of double SHA256)
        let checksum = Self.computeChecksum(payload)
        data.append(checksum)

        // Payload
        data.append(payload)

        return data
    }

    /// Compute the checksum for a payload
    public static func computeChecksum(_ data: Data) -> Data {
        let hash1 = SHA256.hash(data: data)
        let hash2 = SHA256.hash(data: Data(hash1))
        return Data(hash2.prefix(4))
    }

    /// Parse a message from data
    /// - Parameter data: The raw message data
    /// - Returns: A tuple of the parsed message and remaining data, or nil if incomplete
    public static func parse(from data: Data) -> (message: ProtocolMessage, remaining: Data)? {
        switch parseDetailed(from: data) {
        case .message(let message, let remaining):
            return (message, remaining)
        case .incomplete, .invalid:
            return nil
        }
    }
}

// MARK: - Parsing

public extension ProtocolMessage {
    enum ParseError: Error, Sendable {
        case invalidCommandPadding
        case invalidCommand
        case invalidPayloadLength
        case invalidChecksum
    }

    enum ParseOutcome: Sendable {
        case message(ProtocolMessage, Data)
        case incomplete
        case invalid(ParseError)
    }

    static func parseDetailed(from data: Data) -> ParseOutcome {
        guard data.count >= NetworkConstants.headerSize else {
            return .incomplete
        }

        guard let magicRaw: UInt32 = data.readInteger(at: 0) else { return .invalid(.invalidPayloadLength) }
        let magic = UInt32(littleEndian: magicRaw)

        let commandBytes = [UInt8](data[4..<16])
        let commandResult = parseCommand(from: commandBytes)
        if case .failure(let error) = commandResult {
            return .invalid(error)
        }

        guard let lengthRaw: UInt32 = data.readInteger(at: 16) else { return .invalid(.invalidPayloadLength) }
        let length = UInt32(littleEndian: lengthRaw)

        guard length <= NetworkConstants.maxPayloadSize else {
            return .invalid(.invalidPayloadLength)
        }

        let totalSize = NetworkConstants.headerSize + Int(length)
        guard data.count >= totalSize else {
            return .incomplete
        }

        let checksum = Data(data[20..<24])
        let payload = Data(data[NetworkConstants.headerSize..<totalSize])

        let computedChecksum = computeChecksum(payload)
        guard checksum == computedChecksum else {
            return .invalid(.invalidChecksum)
        }

        guard case .success(let command) = commandResult else {
            return .invalid(.invalidCommand)
        }
        let message = ProtocolMessage(magic: magic, command: command, payload: payload)
        let remaining = Data(data[totalSize...])

        return .message(message, remaining)
    }

    static func isValidCommand(_ command: String) -> Bool {
        guard !command.isEmpty, command.count <= NetworkConstants.commandLength else { return false }
        for scalar in command.unicodeScalars {
            let value = scalar.value
            let isLowercase = value >= 0x61 && value <= 0x7a
            let isDigit = value >= 0x30 && value <= 0x39
            if !(isLowercase || isDigit) {
                return false
            }
        }
        return true
    }

    private static func parseCommand(from bytes: [UInt8]) -> Result<String, ParseError> {
        if let nullIndex = bytes.firstIndex(of: 0) {
            if bytes[(nullIndex + 1)...].contains(where: { $0 != 0 }) {
                return .failure(.invalidCommandPadding)
            }
            let trimmed = Array(bytes[..<nullIndex])
            guard let command = String(bytes: trimmed, encoding: .utf8), isValidCommand(command) else {
                return .failure(.invalidCommand)
            }
            return .success(command)
        }

        guard let command = String(bytes: bytes, encoding: .utf8), isValidCommand(command) else {
            return .failure(.invalidCommand)
        }
        return .success(command)
    }
}

// MARK: - Command Names

public extension ProtocolMessage {
    /// Known command names
    enum Command {
        public static let version = "version"
        public static let verack = "verack"
        public static let ping = "ping"
        public static let pong = "pong"
        public static let inv = "inv"
        public static let getdata = "getdata"
        public static let getblocks = "getblocks"
        public static let getheaders = "getheaders"
        public static let headers = "headers"
        public static let block = "block"
        public static let tx = "tx"
        public static let addr = "addr"
        public static let getaddr = "getaddr"
        public static let merkleblock = "merkleblock"
        public static let filterload = "filterload"
        public static let filteradd = "filteradd"
        public static let filterclear = "filterclear"
        public static let reject = "reject"
        public static let sendheaders = "sendheaders"
        public static let feefilter = "feefilter"
        public static let sendcmpct = "sendcmpct"
        public static let cmpctblock = "cmpctblock"
        public static let getblocktxn = "getblocktxn"
        public static let blocktxn = "blocktxn"
    }
}

// MARK: - Equatable

extension ProtocolMessage: Equatable {
    public static func == (lhs: ProtocolMessage, rhs: ProtocolMessage) -> Bool {
        lhs.magic == rhs.magic && lhs.command == rhs.command && lhs.payload == rhs.payload
    }
}
