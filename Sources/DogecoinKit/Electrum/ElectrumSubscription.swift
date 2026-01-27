import Foundation

public struct ElectrumSubscription: Sendable, Hashable {
    public let address: String
    public let scriptHash: String

    public init(address: String, scriptHash: String) {
        self.address = address
        self.scriptHash = scriptHash
    }
}
