import Foundation
import clibdogecoin
import DogecoinKitShims

/// Arms libdogecoin's ECC state for the current thread.
///
/// libdogecoin ≥ 0.1.5 keeps its secp256k1 context in **thread-local**
/// storage: `dogecoin_ecc_start()` creates a context only for the calling
/// thread, and ECC-backed functions assert (crash) on any thread that never
/// called it. Swift concurrency schedules continuations across a pool of
/// threads, so every synchronous stretch that reaches an ECC-backed C
/// function must arm its current thread first — with no `await` between
/// arming and the C calls. After the first call on a given thread this is a
/// dictionary lookup. Pool threads are long-lived, so the handful of
/// per-thread contexts persists for the life of the process.
enum ECC {
    private static let armedKey = "com.sparrowtek.DogecoinKit.eccArmed"

    /// Gives the current thread its secp256k1 context, unless it has one.
    /// - Throws: `DogecoinError.initializationFailed` if the context cannot
    ///   be created or seeded. Nothing that needs it may be called then:
    ///   libdogecoin would abort the process.
    static func armCurrentThread() throws(DogecoinError) {
        let threadDictionary = Thread.current.threadDictionary
        guard threadDictionary[armedKey] == nil else { return }

        guard dogecoinkit_ecc_start() else {
            // A context that was created but could not be seeded must not
            // stay behind for the next attempt to replace and leak.
            dogecoin_ecc_stop()
            throw .initializationFailed
        }
        threadDictionary[armedKey] = true
    }

    // libdogecoin asserts — aborting the process — when handed a key that
    // fails these checks, and its asserts stay enabled in release builds, so
    // every key from outside the library is checked here first.

    /// Whether `publicKey` is a point on secp256k1, in compressed (33-byte)
    /// or uncompressed (65-byte) form.
    static func isValidPublicKey(_ publicKey: Data) -> Bool {
        guard publicKey.count == 33 || publicKey.count == 65, (try? armCurrentThread()) != nil else { return false }

        var key = dogecoin_pubkey()
        key.compressed = publicKey.count == 33 ? 1 : 0
        withUnsafeMutableBytes(of: &key.pubkey) { $0.copyBytes(from: publicKey) }
        return dogecoin_pubkey_is_valid(&key) == 1
    }

    /// Whether `privateKey` is a usable secp256k1 secret: 32 bytes encoding
    /// a scalar between 1 and the curve order.
    static func isValidPrivateKey(_ privateKey: Data) -> Bool {
        guard privateKey.count == 32, (try? armCurrentThread()) != nil else { return false }

        var key = dogecoin_key()
        defer { dogecoin_privkey_cleanse(&key) }
        withUnsafeMutableBytes(of: &key.privkey) { $0.copyBytes(from: privateKey) }
        return dogecoin_privkey_is_valid(&key) == 1
    }
}

/// Main entry point for the Dogecoin library.
public enum Dogecoin {

    /// Checks that the library's cryptography can start.
    ///
    /// Calling this is optional. Every operation prepares the thread it runs
    /// on, so nothing has to be initialized first; calling it at launch only
    /// surfaces a failure early. Operations that cannot prepare their thread
    /// throw ``DogecoinError/initializationFailed``.
    /// - Returns: Whether the secp256k1 context could be created
    @discardableResult
    public static func initialize() async -> Bool {
        (try? ECC.armCurrentThread()) != nil
    }
}

// MARK: - Network Configuration

/// Represents the Dogecoin network type
public enum DogecoinNetwork: Sendable {
    /// Main network for real transactions
    case mainnet
    /// Test network for development
    case testnet

    /// Boolean flag for C API compatibility
    internal var isTestnet: dogecoin_bool {
        self == .testnet ? 1 : 0
    }

    /// Address prefix for P2PKH addresses
    public var addressPrefix: String {
        switch self {
        case .mainnet: return "D"
        case .testnet: return "n"
        }
    }

    /// BIP44 coin type used in the derivation path `m/44'/<coinType>'/...`.
    ///
    /// Mainnet is coin type **3** per SLIP-0044; SLIP-0044 also reserves
    /// coin type **1** for every testnet coin. Centralizing these constants
    /// keeps `HDWallet.deriveAddress`, address-path formatters, and any
    /// future `m/44'/…/…/…/…` construction in lockstep — one edit away
    /// from disaster if they drift.
    public var bip44CoinType: UInt32 {
        switch self {
        case .mainnet: return 3
        case .testnet: return 1
        }
    }

    /// Fully-qualified BIP44 derivation path for the given account / chain /
    /// index. Returns a string of the form `m/44'/<coin>'/<account>'/<chain>/<index>`
    /// where `chain = 1` for change addresses and `0` for external
    /// (receive) addresses.
    public func bip44Path(account: UInt32, change: Bool, index: UInt32) -> String {
        let chain = change ? 1 : 0
        return "m/44'/\(bip44CoinType)'/\(account)'/\(chain)/\(index)"
    }
}

// MARK: - Codable

/// Encoded as `0` (mainnet) or `1` (testnet).
extension DogecoinNetwork: Codable {
    /// - Throws: `DecodingError.dataCorrupted` for any other value. Reading
    ///   an unknown value as mainnet would turn a corrupted or
    ///   newer-format record into a real-money wallet.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(Int.self) {
        case 0:
            self = .mainnet
        case 1:
            self = .testnet
        case let value:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown Dogecoin network \(value)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self == .testnet ? 1 : 0)
    }
}
