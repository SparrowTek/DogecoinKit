import Foundation
import Testing

/// What the opt-in tests need. Used through `.enabled(if:)`, so a test whose
/// precondition is not met is reported as skipped — not as a pass that
/// checked nothing.
enum TestEnvironment {
    /// `DOGECOINKIT_LIVE_ELECTRUM=1`: talk to the public mainnet Electrum servers.
    static var runsLiveElectrumTests: Bool {
        isEnabled("DOGECOINKIT_LIVE_ELECTRUM")
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

/// The standard BIP 39 test phrase: eleven times "abandon", then "about".
/// Everyone knows it, so nothing that matters is ever kept under it.
let testPhrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

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

/// Polls until `condition` holds or `timeout` passes.
/// - Returns: Whether the condition came to hold
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Bytes queued for the code under test to read, as a connection hands
/// them over: in order, a chunk at a time, until it is closed.
actor ChunkInbox {
    private var chunks: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var closed = false

    func push(_ chunk: Data) {
        guard !closed else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: chunk)
        } else {
            chunks.append(chunk)
        }
    }

    func close() {
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func next() async -> Data? {
        if !chunks.isEmpty {
            return chunks.removeFirst()
        }
        if closed {
            return nil
        }
        return await withCheckedContinuation { waiter = $0 }
    }
}
