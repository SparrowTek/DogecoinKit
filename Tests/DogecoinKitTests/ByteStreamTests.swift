import Foundation
import Testing
@testable import DogecoinKit
#if canImport(Android)
import Android
#endif

/// The `ByteStream` contract, checked against the platform's own transport:
/// Network.framework on Apple platforms, SwiftNIO on Android.
@Suite("Byte Stream", .timeLimit(.minutes(1)))
struct ByteStreamTests {

    @Test("Bytes flow both ways, and the remote close ends the stream")
    func roundTrip() async throws {
        let server = try LoopbackServer()
        let stream = defaultByteStreamFactory("127.0.0.1", server.port, false)
        async let accepted = server.nextConnection()
        try await stream.open(timeout: .seconds(10))
        let connection = try await accepted

        try await stream.write(Data("ping".utf8))
        #expect(await connection.receive(count: 4) == Data("ping".utf8))

        #expect(await connection.write(Data("pong".utf8)) == 4)
        #expect(try await stream.read(count: 4) == Data("pong".utf8))

        connection.hangUp()
        #expect(try await stream.read() == nil)
        stream.close()
    }

    @Test("Closing the stream mid-handshake fails the open")
    func closeDuringOpen() async throws {
        let server = try LoopbackServer()
        let stream = defaultByteStreamFactory("127.0.0.1", server.port, true)
        async let accepted = server.nextConnection()
        let opening = Task { try await stream.open() }
        // The server never answers the TLS handshake.
        let connection = try await accepted

        stream.close()
        await #expect(throws: CancellationError.self) { try await opening.value }
        connection.hangUp()
    }

    @Test("A failed TLS handshake fails the open")
    func failedHandshake() async throws {
        let server = try LoopbackServer()
        let stream = defaultByteStreamFactory("127.0.0.1", server.port, true)
        async let accepted = server.nextConnection()
        let opening = Task { try await stream.open(timeout: .seconds(10)) }
        let connection = try await accepted

        // Not a TLS server: it answers the handshake with plain text.
        _ = await connection.write(Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
        connection.hangUp()
        let error = await #expect(throws: (any Error).self) { try await opening.value }
        #expect(error as? ByteStreamError != .timedOut)
    }

    @Test("A closed port fails the open")
    func refusedConnection() async throws {
        // Nothing listens once the server is gone.
        let port = try LoopbackServer().port
        let stream = defaultByteStreamFactory("127.0.0.1", port, false)
        let error = await #expect(throws: (any Error).self) { try await stream.open(timeout: .seconds(10)) }
        #expect(error as? ByteStreamError != .timedOut)
    }

    @Test("Cancelling a read closes the stream")
    func cancelledRead() async throws {
        let server = try LoopbackServer()
        let stream = defaultByteStreamFactory("127.0.0.1", server.port, false)
        async let accepted = server.nextConnection()
        try await stream.open(timeout: .seconds(10))
        let connection = try await accepted

        let reading = Task { try await stream.read() }
        reading.cancel()
        await #expect(throws: (any Error).self) { try await reading.value }
        #expect(await connection.clientHungUp())
        await #expect(throws: (any Error).self) { try await stream.write(Data("late".utf8)) }
    }

    @Test("Bytes are taken off the socket only as they are read")
    func backpressure() async throws {
        let server = try LoopbackServer()
        let stream = defaultByteStreamFactory("127.0.0.1", server.port, false)
        async let accepted = server.nextConnection()
        try await stream.open(timeout: .seconds(10))
        let connection = try await accepted

        // With nothing reading, the socket buffers fill and the server
        // stalls long before 64 MB are through.
        let total = 64 << 20
        let sent = await connection.write(Data(count: total), stallTimeout: 1)
        #expect(sent > 0)
        #expect(sent < total)
        stream.close()
        connection.hangUp()
    }
}

extension ByteStream {
    /// Reads until `count` bytes have arrived or the stream ends.
    fileprivate func read(count: Int) async throws -> Data {
        var received = Data()
        while received.count < count, let chunk = try await read() {
            received.append(chunk)
        }
        return received
    }
}

// MARK: - Loopback server

/// A TCP server on 127.0.0.1. Its socket calls run on threads of their own,
/// so they never hold up the concurrency pool, and each gives up after ten
/// seconds so a broken stream fails its test instead of hanging it.
private final class LoopbackServer: Sendable {
    let port: UInt16
    private let listener: Int32

    init() throws {
        // A client that hangs up mid-write must not kill the test process.
        signal(SIGPIPE, SIG_IGN)

        let descriptor = socket(AF_INET, Int32(SOCK_STREAM), 0)
        guard descriptor >= 0 else { throw SocketError(call: "socket") }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length) == 0
                    && listen(descriptor, 1) == 0
                    && getsockname(descriptor, $0, &length) == 0
            }
        }
        guard listening else {
            let error = SocketError(call: "bind")
            closeDescriptor(descriptor)
            throw error
        }

        listener = descriptor
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit {
        closeDescriptor(listener)
    }

    func nextConnection() async throws -> LoopbackConnection {
        let listener = self.listener
        let descriptor = await onOwnThread {
            guard waitUntil(listener, isReadyFor: POLLIN, seconds: 10) else { return Int32(-1) }
            return accept(listener, nil, nil)
        }
        guard descriptor >= 0 else { throw SocketError(call: "accept") }
        return LoopbackConnection(descriptor: descriptor)
    }
}

/// The server's end of one connection. Its socket never blocks; every call
/// waits for readiness with `poll` instead.
private final class LoopbackConnection: Sendable {
    private let descriptor: Int32

    init(descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        self.descriptor = descriptor
    }

    deinit {
        closeDescriptor(descriptor)
    }

    /// Receives until `count` bytes have arrived or the client stops sending.
    func receive(count: Int) async -> Data {
        let descriptor = self.descriptor
        return await onOwnThread {
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while received.count < count, waitUntil(descriptor, isReadyFor: POLLIN, seconds: 10) {
                let read = recv(descriptor, &buffer, min(buffer.count, count - received.count), 0)
                guard read > 0 else { break }
                received.append(contentsOf: buffer[..<read])
            }
            return received
        }
    }

    /// Whether the client closed the connection, as opposed to going quiet.
    func clientHungUp() async -> Bool {
        let descriptor = self.descriptor
        return await onOwnThread {
            guard waitUntil(descriptor, isReadyFor: POLLIN, seconds: 10) else { return false }
            var byte: UInt8 = 0
            let read = recv(descriptor, &byte, 1, 0)
            return read == 0 || (read < 0 && errno == ECONNRESET)
        }
    }

    /// Writes `data`, giving up once the client has taken nothing for
    /// `stallTimeout` seconds. Returns the number of bytes written.
    func write(_ data: Data, stallTimeout: Int32 = 10) async -> Int {
        let descriptor = self.descriptor
        return await onOwnThread {
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return 0 }
                var written = 0
                while written < bytes.count, waitUntil(descriptor, isReadyFor: POLLOUT, seconds: stallTimeout) {
                    let sent = send(descriptor, base + written, bytes.count - written, 0)
                    guard sent > 0 else { break }
                    written += sent
                }
                return written
            }
        }
    }

    /// Ends the connection from the server's side.
    func hangUp() {
        shutdown(descriptor, Int32(SHUT_RDWR))
    }
}

private struct SocketError: Error {
    let call: String
    let code = errno
}

private func closeDescriptor(_ descriptor: Int32) {
    _ = close(descriptor)
}

/// Waits up to `seconds` for `descriptor` to be ready for `events`.
private func waitUntil(_ descriptor: Int32, isReadyFor events: Int32, seconds: Int32) -> Bool {
    var request = pollfd(fd: descriptor, events: Int16(events), revents: 0)
    return poll(&request, 1, seconds * 1000) == 1
}

/// Runs blocking work on a dedicated thread.
private func onOwnThread<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(returning: work())
        }
    }
}
