import Foundation
import Testing

/// What the opt-in tests need. Used through `.enabled(if:)`, so a test whose
/// precondition is not met is reported as skipped — not as a pass that
/// checked nothing.
enum TestEnvironment {
    /// `ELECTRUM_INTEGRATION_TESTS=1`: talk to the public mainnet Electrum servers.
    static var runsLiveElectrumTests: Bool {
        isEnabled("ELECTRUM_INTEGRATION_TESTS")
    }

    /// `DOGECOINKIT_LIVE_P2P=1`: talk to the real Dogecoin peer-to-peer network.
    static var runsLiveP2PTests: Bool {
        isEnabled("DOGECOINKIT_LIVE_P2P")
    }

    /// `DOGECOINKIT_MAINNET_HEADERS=<path>`: a full mainnet `headers.sqlite`,
    /// as DogecoinNodeSync produces, to replay through the consensus rules.
    static var mainnetHeadersPath: String? {
        ProcessInfo.processInfo.environment["DOGECOINKIT_MAINNET_HEADERS"]
    }

    /// `DOGECOINKIT_HEADER_CACHE=<directory>`: a real pre-built header cache
    /// (`headers.sqlite` plus `metadata.json`), such as the one the app ships.
    static var headerCacheDirectory: String? {
        ProcessInfo.processInfo.environment["DOGECOINKIT_HEADER_CACHE"]
    }

    private static func isEnabled(_ variable: String) -> Bool {
        ProcessInfo.processInfo.environment[variable] == "1"
    }
}

/// Scratch space for tests that need a database on disk.
enum TestDirectories {
    /// One directory per test process, removed when the process exits, so
    /// test runs stop piling databases up in the temporary directory.
    private static let root: URL = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DogecoinKitTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        atexit {
            try? FileManager.default.removeItem(at: TestDirectories.root)
        }
        return root
    }()

    /// A path for a new directory that no other test uses. It does not exist
    /// yet; `HeaderChain` creates its storage directory itself.
    static func unique() -> URL {
        root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
