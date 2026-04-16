import Foundation
import clibdogecoin

/// Main entry point for the Dogecoin library.
/// Call `initialize()` before using any cryptographic functions.
public enum Dogecoin {

    private actor InitState {
        var isInitialized = false

        func initialize() {
            guard !isInitialized else { return }
            dogecoin_ecc_start()
            isInitialized = true
        }

        func cleanup() {
            guard isInitialized else { return }
            dogecoin_ecc_stop()
            isInitialized = false
        }

        var initialized: Bool { isInitialized }
    }

    private static let state = InitState()

    /// Initialize the Dogecoin ECC context.
    /// This must be called before using any cryptographic functions.
    /// Safe to call multiple times - subsequent calls are no-ops.
    public static func initialize() async {
        await state.initialize()
    }

    /// Clean up the Dogecoin ECC context.
    /// Call this when completely done with cryptographic operations.
    /// After calling this, you must call `initialize()` again before using crypto functions.
    public static func cleanup() async {
        await state.cleanup()
    }

    /// Check if the library is initialized
    public static var initialized: Bool {
        get async { await state.initialized }
    }

    /// Ensure the library is initialized, throwing if not
    internal static func ensureInitialized() async throws {
        guard await state.initialized else {
            throw DogecoinError.initializationFailed
        }
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

    /// Boolean flag for C API compatibility (bool version)
    internal var isTestnetBool: Bool {
        self == .testnet
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

// MARK: - Utility Extensions

extension String {
    /// Convert Swift String to C string buffer and call closure
    internal func withCStringBuffer<T>(size: Int, _ body: (UnsafeMutablePointer<CChar>) throws -> T) rethrows -> T {
        var buffer = [CChar](repeating: 0, count: size)
        return try body(&buffer)
    }
}

extension Array where Element == CChar {
    /// Convert CChar array to Swift String, trimming null terminator
    internal var asString: String {
        let bytes = Data(self.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
        return String(decoding: bytes, as: UTF8.self)
    }
}
