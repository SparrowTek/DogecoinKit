import Foundation

/// One ordered, reliable byte stream to a remote host — plain TCP for P2P
/// peers, TLS for Electrum servers.
///
/// Each instance represents exactly one connection attempt. Reconnecting
/// means making a new stream, so a late callback from a dead connection can
/// never be mistaken for activity on its replacement.
protocol ByteStream: AnyObject, Sendable {
    /// Resolves, connects, and — for TLS — completes the handshake.
    /// Cancelling the calling task abandons the attempt.
    func open() async throws

    /// Queues `data` for sending and returns once the network stack has it.
    func write(_ data: Data) async throws

    /// The next chunk of received bytes, or `nil` once the remote side has
    /// closed the stream. Cancelling the calling task closes the stream.
    func read() async throws -> Data?

    /// Closes the stream. Pending and future reads and writes fail.
    func close()
}

/// Creates the stream used to reach a host.
typealias ByteStreamFactory = @Sendable (_ host: String, _ port: UInt16, _ useTLS: Bool) -> any ByteStream

enum ByteStreamError: Error, Sendable, Equatable {
    case closed
    case timedOut
    /// The remote side stopped reading and what waits to be sent has
    /// outgrown its limit
    case backlogged
    /// The device has no network to reach the host over
    case offline
}

extension ByteStreamError: LocalizedError {
    /// These reach people inside the errors that wrap them.
    var errorDescription: String? {
        switch self {
        case .closed: "The connection was closed"
        case .timedOut: "The connection timed out"
        case .backlogged: "The other side stopped reading"
        case .offline: "There is no network connection"
        }
    }
}

/// Writes to one stream strictly in submission order, without making the
/// caller wait. A `Task` per write would let two messages overtake each
/// other on the wire — fatal for handshakes, where order is the protocol.
///
/// What a remote side does not read piles up here. Past
/// ``maximumBacklog`` the connection is treated as failed instead: nothing
/// this library sends comes near that size, so only a peer that has stopped
/// reading gets there.
final class OrderedStreamWriter: Sendable {
    /// Most bytes that may wait to be sent
    static let maximumBacklog = 4 * 1024 * 1024

    private let queue: SerialEventQueue<Data>
    private let backlog = Backlog()
    private let onFailure: @Sendable (Error) async -> Void

    /// - Parameter onFailure: Called once per failed write; the stream is
    ///   unusable from then on.
    init(stream: any ByteStream, onFailure: @escaping @Sendable (Error) async -> Void) {
        self.onFailure = onFailure
        queue = SerialEventQueue { [backlog] data in
            defer { backlog.remove(data.count) }
            do {
                try await stream.write(data)
            } catch {
                await onFailure(error)
            }
        }
    }

    func write(_ data: Data) {
        guard backlog.add(data.count, limit: Self.maximumBacklog) else {
            Task { [onFailure] in
                await onFailure(ByteStreamError.backlogged)
            }
            return
        }
        queue.yield(data)
    }

    /// Bytes handed to `write` that the stream has not taken yet.
    private final class Backlog: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0

        /// - Returns: Whether `count` more bytes fit
        func add(_ count: Int, limit: Int) -> Bool {
            lock.withLock {
                guard bytes + count <= limit else { return false }
                bytes += count
                return true
            }
        }

        func remove(_ count: Int) {
            lock.withLock { bytes -= count }
        }
    }
}

/// Resumes a checked continuation at most once, from whichever callback or
/// cancellation handler gets there first.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}

extension ResumeOnce where Value == Void {
    func resume() {
        resume(returning: ())
    }
}

#if canImport(Network)
import Network

/// `ByteStream` over Network.framework.
final class NetworkFrameworkStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.sparrowtek.DogecoinKit.stream", qos: .utility)

    /// Set once the remote side has finished sending; guarded by `lock`.
    private var receivedEnd = false
    private let lock = NSLock()

    /// Largest chunk handed back by a single `read()`.
    private static let maximumReadLength = 64 * 1024

    init(host: String, port: UInt16, useTLS: Bool) {
        let parameters: NWParameters
        if useTLS {
            parameters = NWParameters(tls: Self.makeTLSOptions(serverHost: host))
        } else {
            parameters = .tcp
        }
        parameters.prohibitExpensivePaths = false
        parameters.prohibitConstrainedPaths = false

        connection = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port)),
            using: parameters
        )
    }

    deinit {
        connection.cancel()
    }

    func open() async throws {
        let gate = ResumeGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = ResumeOnce(continuation)
                guard gate.install(once) else { return }
                connection.stateUpdateHandler = { [weak connection] state in
                    switch state {
                    case .ready:
                        once.resume()
                    case .failed(let error):
                        once.resume(throwing: error)
                    case .waiting(let error) where connection?.currentPath?.status == .satisfied:
                        // The network is up, so the host itself turned us away
                        // (a closed port, a failed TLS handshake); a path
                        // change won't help.
                        once.resume(throwing: error)
                        connection?.cancel()
                    case .waiting where connection?.currentPath?.status == .unsatisfied:
                        // No network at all. Network.framework would wait
                        // for one; every caller here has a retry of its own,
                        // and would rather know now than after its timeout —
                        // with a list of servers to get through, a timeout
                        // each.
                        once.resume(throwing: ByteStreamError.offline)
                        connection?.cancel()
                    case .cancelled:
                        once.resume(throwing: CancellationError())
                    default:
                        // Including `.waiting` on a path that starting the
                        // connection may yet bring up — cellular data that
                        // was idle, a VPN on demand: Network.framework goes
                        // on as soon as it is there, until the caller's
                        // timeout.
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            gate.cancel()
            connection.cancel()
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func read() async throws -> Data? {
        if lock.withLock({ receivedEnd }) { return nil }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumReadLength) { [weak self] content, _, isComplete, error in
                    if isComplete, let self {
                        self.lock.withLock { self.receivedEnd = true }
                    }
                    if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else if isComplete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: ByteStreamError.closed)
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func close() {
        connection.cancel()
    }

    /// Hardened TLS options for Electrum connections.
    ///
    /// - Minimum TLS protocol pinned to 1.2 (blocks legacy TLS 1.0/1.1 downgrade).
    /// - Explicit SNI set to the configured server hostname, so the server
    ///   presents a certificate for the host we intended to reach.
    ///
    /// Default system trust-chain evaluation remains in place.
    private static func makeTLSOptions(serverHost: String) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let securityOptions = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
        serverHost.withCString { cString in
            sec_protocol_options_set_tls_server_name(securityOptions, cString)
        }
        return options
    }
}

/// Lets a cancellation handler that runs before the continuation exists
/// still fail it once it is installed.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var once: ResumeOnce<Void>?
    private var cancelled = false

    /// Returns `false` (after failing `once`) if cancellation already won.
    func install(_ once: ResumeOnce<Void>) -> Bool {
        let alreadyCancelled = lock.withLock {
            self.once = once
            return cancelled
        }
        if alreadyCancelled {
            once.resume(throwing: CancellationError())
        }
        return !alreadyCancelled
    }

    func cancel() {
        let pending = lock.withLock {
            cancelled = true
            return once
        }
        pending?.resume(throwing: CancellationError())
    }
}
#endif

extension ByteStream {
    /// Opens the stream, giving up after `timeout`.
    func open(timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.open() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ByteStreamError.timedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

/// The platform's default stream implementation.
let defaultByteStreamFactory: ByteStreamFactory = { host, port, useTLS in
    #if canImport(Network)
    NetworkFrameworkStream(host: host, port: port, useTLS: useTLS)
    #else
    NIOByteStream(host: host, port: port, useTLS: useTLS)
    #endif
}
