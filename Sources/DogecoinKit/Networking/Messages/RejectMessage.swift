import Foundation

/// A peer's refusal of something it was sent (BIP 61).
///
/// Dogecoin Core answers a transaction it will not accept with one of
/// these, naming the transaction and the rule it broke.
struct RejectMessage: Sendable, Equatable {
    /// The command of the message being refused, such as `tx`
    let message: String

    /// The refusal code: `0x10` invalid, `0x12` inputs already spent,
    /// `0x40` non-standard, `0x41` dust, `0x42` insufficient fee, …
    let code: UInt8

    /// The peer's reason, such as `bad-txns-inputs-spent`
    let reason: String

    /// The hash of the transaction or block refused, in internal byte
    /// order, when the peer names one
    let hash: Data?

    /// Longest command and reason a node sends — Core's `COMMAND_SIZE` and
    /// `MAX_REJECT_MESSAGE_LENGTH`
    private static let maximumMessageLength = 12
    private static let maximumReasonLength = 111

    static func parse(from data: Data) -> RejectMessage? {
        guard let (messageLength, messageStart) = data.readBoundedLength(at: 0, trailing: 1),
              messageLength <= maximumMessageLength,
              let messageBytes = data.bytes(at: messageStart, count: messageLength),
              let code: UInt8 = data.readInteger(at: messageStart + messageLength),
              let (reasonLength, reasonStart) = data.readBoundedLength(at: messageStart + messageLength + 1),
              reasonLength <= maximumReasonLength,
              let reasonBytes = data.bytes(at: reasonStart, count: reasonLength) else {
            return nil
        }

        return RejectMessage(
            message: printable(messageBytes),
            code: code,
            reason: printable(reasonBytes),
            hash: data.bytes(at: reasonStart + reasonLength, count: 32)
        )
    }

    /// The text a peer chose ends up in logs and error messages: keep only
    /// what prints.
    private static func printable(_ bytes: Data) -> String {
        String(decoding: bytes.filter { (0x20...0x7e).contains($0) }, as: UTF8.self)
    }
}
