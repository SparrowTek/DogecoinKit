#if !canImport(Network)
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import Synchronization

/// `ByteStream` over SwiftNIO, for platforms without Network.framework.
///
/// TLS runs on NIOSSL, which trusts the platform's certificate store — on
/// Android, the system CA certificates — with the same TLS 1.2 floor as
/// `NetworkFrameworkStream`. Reads are pulled: the socket is read only while
/// a `read()` waits, so a peer that sends faster than DogecoinKit consumes is
/// held back by TCP flow control instead of piling up in memory.
final class NIOByteStream: ByteStream {
    private let host: String
    private let port: Int
    private let useTLS: Bool
    private let state = Mutex(State())

    /// One context serves every TLS connection.
    private static let tlsContext = Result<NIOSSLContext, any Error> {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        return try NIOSSLContext(configuration: configuration)
    }

    init(host: String, port: UInt16, useTLS: Bool) {
        self.host = host
        self.port = Int(port)
        self.useTLS = useTLS
    }

    deinit {
        close()
    }

    func open() async throws {
        let tlsContext = useTLS ? try Self.tlsContext.get() : nil
        // SNI and hostname verification take a name; for an IP address,
        // NIOSSL checks the certificate's IP addresses instead.
        let serverHostname = (try? SocketAddress(ipAddress: host, port: 0)) == nil ? host : nil
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            // Callers bound the attempt with `open(timeout:)`; this is a backstop.
            .connectTimeout(.minutes(1))
            .channelOption(.autoRead, value: false)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try self.track(channel)
                    let pipeline = channel.pipeline.syncOperations
                    if let tlsContext {
                        try pipeline.addHandler(NIOSSLClientHandler(context: tlsContext, serverHostname: serverHostname))
                    }
                    try pipeline.addHandler(Relay(stream: self, awaitsHandshake: tlsContext != nil))
                }
            }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if let refusal = state.withLock({ $0.beginOpening(continuation) }) {
                    continuation.resume(throwing: refusal)
                    return
                }
                bootstrap.connect(host: host, port: port).whenFailure { error in
                    self.end(.failed(error))
                }
            }
        } onCancel: {
            close()
        }
    }

    func write(_ data: Data) async throws {
        guard let channel = state.withLock({ $0.openChannel }) else {
            throw ByteStreamError.closed
        }
        try await channel.writeAndFlush(ByteBuffer(bytes: data)).get()
    }

    func read() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                switch state.withLock({ $0.read(continuation) }) {
                case .ready(let result):
                    continuation.resume(with: result)
                case .pull(let channel):
                    channel.read()
                }
            }
        } onCancel: {
            close()
        }
    }

    func close() {
        let abandoned = state.withLock { $0.close() }
        abandoned.opening?.resume(throwing: CancellationError())
        for reader in abandoned.readers {
            reader.resume(throwing: ByteStreamError.closed)
        }
        for channel in abandoned.channels {
            channel.close(promise: nil)
        }
    }

    // MARK: - Channel events

    /// Registers a connection attempt so `close()` can abandon it.
    private func track(_ channel: any Channel) throws {
        try state.withLock { try $0.track(channel) }
    }

    /// TCP is up. Happy Eyeballs closes the losing attempts before they
    /// activate, so only the winning channel reports here.
    fileprivate func connected(_ channel: any Channel) {
        if !state.withLock({ $0.connected(channel) }) {
            channel.close(promise: nil)
        }
    }

    /// The connection is ready for traffic: TCP is up and, for TLS, the
    /// handshake has completed.
    fileprivate func ready() {
        state.withLock { $0.ready() }?.resume()
    }

    fileprivate func received(_ data: Data) {
        state.withLock { $0.received(data) }?.resume(returning: data)
    }

    fileprivate func end(_ ending: Ending) {
        let abandoned = state.withLock { $0.end(ending) }
        if let opening = abandoned.opening {
            if case .failed(let error) = ending {
                opening.resume(throwing: error)
            } else {
                opening.resume(throwing: ByteStreamError.closed)
            }
        }
        for reader in abandoned.readers {
            if case .failed(let error) = ending {
                reader.resume(throwing: error)
            } else {
                reader.resume(returning: nil)
            }
        }
    }
}

// MARK: - State

extension NIOByteStream {
    /// Why a stream stopped.
    fileprivate enum Ending {
        /// The remote side closed the connection.
        case finished
        /// The connection failed.
        case failed(any Error)
        /// `close()` was called.
        case closed
    }

    /// Continuations and channels a transition leaves to be resumed or
    /// closed once the lock is released.
    fileprivate struct Abandoned {
        var opening: CheckedContinuation<Void, any Error>?
        var readers: [CheckedContinuation<Data?, any Error>] = []
        var channels: [any Channel] = []
    }

    fileprivate enum ReadOutcome {
        case ready(Result<Data?, any Error>)
        /// The reader waits; ask the channel for more bytes.
        case pull(any Channel)
    }

    fileprivate struct State {
        private enum Phase {
            case idle
            /// `channel` is set once TCP is up and TLS is handshaking.
            case opening(CheckedContinuation<Void, any Error>, channel: (any Channel)?)
            case open(any Channel)
            case ended(Ending)
        }

        private var phase = Phase.idle
        /// Happy Eyeballs may race several attempts until one connects.
        private var attempts: [any Channel] = []
        /// Bytes no reader has taken yet; delivered before an ending.
        private var buffered = Data()
        /// Readers waiting for bytes, oldest first. Only ever non-empty
        /// while `buffered` is empty.
        private var readers: [CheckedContinuation<Data?, any Error>] = []

        var openChannel: (any Channel)? {
            if case .open(let channel) = phase { channel } else { nil }
        }

        /// Returns the error to fail `open()` with, if the stream can't open.
        mutating func beginOpening(_ continuation: CheckedContinuation<Void, any Error>) -> (any Error)? {
            switch phase {
            case .idle:
                phase = .opening(continuation, channel: nil)
                return nil
            case .ended(.closed):
                return CancellationError()
            case .opening, .open, .ended:
                return ByteStreamError.closed
            }
        }

        mutating func track(_ channel: any Channel) throws {
            guard case .opening(_, .none) = phase else { throw ByteStreamError.closed }
            attempts.append(channel)
        }

        /// Returns `false` if the stream no longer wants the channel.
        mutating func connected(_ channel: any Channel) -> Bool {
            guard case .opening(let continuation, .none) = phase else { return false }
            attempts.removeAll()
            phase = .opening(continuation, channel: channel)
            return true
        }

        /// Returns the `open()` continuation to resume.
        mutating func ready() -> CheckedContinuation<Void, any Error>? {
            guard case .opening(let continuation, let channel?) = phase else { return nil }
            phase = .open(channel)
            return continuation
        }

        /// Returns the reader to hand `data` to, or keeps it for the next one.
        mutating func received(_ data: Data) -> CheckedContinuation<Data?, any Error>? {
            guard case .open = phase else { return nil }
            guard readers.isEmpty else { return readers.removeFirst() }
            buffered.append(data)
            return nil
        }

        mutating func read(_ continuation: CheckedContinuation<Data?, any Error>) -> ReadOutcome {
            if !buffered.isEmpty {
                defer { buffered = Data() }
                return .ready(.success(buffered))
            }
            switch phase {
            case .open(let channel):
                readers.append(continuation)
                return .pull(channel)
            case .ended(.finished):
                return .ready(.success(nil))
            case .ended(.failed(let error)):
                return .ready(.failure(error))
            case .idle, .opening, .ended(.closed):
                return .ready(.failure(ByteStreamError.closed))
            }
        }

        /// The first ending wins; bytes already received stay readable.
        mutating func end(_ ending: Ending) -> Abandoned {
            var abandoned = Abandoned()
            switch phase {
            case .ended:
                return abandoned
            case .opening(let continuation, _):
                abandoned.opening = continuation
            case .idle, .open:
                break
            }
            abandoned.readers = readers
            phase = .ended(ending)
            attempts.removeAll()
            readers.removeAll()
            return abandoned
        }

        /// Unlike `end(_:)`, closing also discards unread bytes.
        mutating func close() -> Abandoned {
            var abandoned = Abandoned(readers: readers, channels: attempts)
            switch phase {
            case .opening(let continuation, let channel):
                abandoned.opening = continuation
                if let channel {
                    abandoned.channels.append(channel)
                }
            case .open(let channel):
                abandoned.channels.append(channel)
            case .idle, .ended:
                break
            }
            phase = .ended(.closed)
            attempts.removeAll()
            buffered = Data()
            readers.removeAll()
            return abandoned
        }
    }
}

// MARK: - Relay

/// Passes one channel's events to its stream, on the channel's event loop.
private final class Relay: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    /// Weak, so a stream its owner drops still deinitializes and closes the
    /// channel.
    private weak var stream: NIOByteStream?
    private let awaitsHandshake: Bool

    init(stream: NIOByteStream, awaitsHandshake: Bool) {
        self.stream = stream
        self.awaitsHandshake = awaitsHandshake
    }

    func channelActive(context: ChannelHandlerContext) {
        stream?.connected(context.channel)
        if awaitsHandshake {
            // With reads pulled, the handshake needs a first read; NIOSSL
            // issues the rest until it completes.
            context.read()
        } else {
            stream?.ready()
        }
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .handshakeCompleted = event as? TLSUserEvent {
            stream?.ready()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        stream?.received(Data(unwrapInboundIn(data).readableBytesView))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        stream?.end(.failed(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        stream?.end(.finished)
        context.fireChannelInactive()
    }
}
#endif
