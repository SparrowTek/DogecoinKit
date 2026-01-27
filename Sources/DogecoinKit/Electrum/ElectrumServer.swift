import Foundation

public struct ElectrumServer: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let host: String
    public let port: Int
    public let useSSL: Bool
    public let network: DogecoinNetwork

    public init(host: String, port: Int, useSSL: Bool = true, network: DogecoinNetwork = .mainnet) {
        self.id = "\(host):\(port)"
        self.host = host
        self.port = port
        self.useSSL = useSSL
        self.network = network
    }
}

public struct ElectrumServerList: Sendable {

    // MARK: - Mainnet Servers

    public static let mainnetServers: [ElectrumServer] = [
        // Primary servers - SSL
        ElectrumServer(host: "electrum1.cipig.net", port: 20060, useSSL: true, network: .mainnet),
        ElectrumServer(host: "electrum2.cipig.net", port: 20060, useSSL: true, network: .mainnet),
        ElectrumServer(host: "electrum3.cipig.net", port: 20060, useSSL: true, network: .mainnet),

        // Backup servers - TCP (no SSL)
        ElectrumServer(host: "electrum1.cipig.net", port: 10060, useSSL: false, network: .mainnet),
        ElectrumServer(host: "electrum2.cipig.net", port: 10060, useSSL: false, network: .mainnet),
        ElectrumServer(host: "electrum3.cipig.net", port: 10060, useSSL: false, network: .mainnet),
    ]

    // MARK: - Testnet Servers

    public static let testnetServers: [ElectrumServer] = [
        // Add testnet servers when available
    ]

    // MARK: - Server Selection

    public static func servers(for network: DogecoinNetwork) -> [ElectrumServer] {
        switch network {
        case .mainnet:
            return mainnetServers
        case .testnet:
            return testnetServers
        }
    }

    public static func randomServer(for network: DogecoinNetwork) -> ElectrumServer? {
        servers(for: network).randomElement()
    }
}
