import Foundation
import Testing
@testable import DogecoinKit

@Suite("Serial Event Queue", .timeLimit(.minutes(1)))
struct SerialEventQueueTests {

    private enum Event: Equatable, Sendable {
        case step(Int)
        case found(String)
    }

    /// Collects what a queue hands over, and can hold the handler up.
    private actor Sink {
        private(set) var received: [Event] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var isHeld = false

        func hold() {
            isHeld = true
        }

        func release() {
            isHeld = false
            gate?.resume()
            gate = nil
        }

        func take(_ event: Event) async {
            if isHeld {
                await withCheckedContinuation { gate = $0 }
            }
            received.append(event)
        }
    }

    @Test("Events are handled one at a time, in the order they were yielded")
    func ordered() async {
        let sink = Sink()
        let queue = SerialEventQueue<Event> { await sink.take($0) }

        for index in 0..<500 {
            queue.yield(.step(index))
        }

        #expect(await eventually { await sink.received.count == 500 })
        #expect(await sink.received == (0..<500).map { .step($0) })
        #expect(queue.count == 0)
    }

    @Test("A superseding event takes the place of the last one waiting, and of no other")
    func supersedes() async {
        let sink = Sink()
        let queue = SerialEventQueue<Event> { await sink.take($0) }
        let isStep: @Sendable (Event) -> Bool = { if case .step = $0 { true } else { false } }

        // The handler is busy with the first event while the rest pile up.
        await sink.hold()
        queue.yield(.found("first"))
        #expect(await eventually { queue.count == 0 })

        queue.yield(.step(1), supersedingLastWhere: isStep)
        queue.yield(.step(2), supersedingLastWhere: isStep)
        queue.yield(.step(3), supersedingLastWhere: isStep)
        queue.yield(.found("payment"))
        queue.yield(.step(4), supersedingLastWhere: isStep)
        queue.yield(.step(5), supersedingLastWhere: isStep)
        #expect(queue.count == 3)

        await sink.release()

        // The latest step of each run — and never one that jumped ahead of
        // what was found before it.
        #expect(await eventually { await sink.received.count == 4 })
        #expect(await sink.received == [.found("first"), .step(3), .found("payment"), .step(5)])
    }

    @Test("An event already with the handler is not superseded")
    func doesNotSupersedeWhatIsBeingHandled() async {
        let sink = Sink()
        let queue = SerialEventQueue<Event> { await sink.take($0) }
        let isStep: @Sendable (Event) -> Bool = { if case .step = $0 { true } else { false } }

        await sink.hold()
        queue.yield(.step(1), supersedingLastWhere: isStep)
        #expect(await eventually { queue.count == 0 })
        queue.yield(.step(2), supersedingLastWhere: isStep)
        await sink.release()

        #expect(await eventually { await sink.received.count == 2 })
        #expect(await sink.received == [.step(1), .step(2)])
    }

    @Test("Events still waiting when the queue goes away are handled all the same")
    func drainsAfterRelease() async {
        let sink = Sink()
        do {
            let queue = SerialEventQueue<Event> { await sink.take($0) }
            for index in 0..<100 {
                queue.yield(.step(index))
            }
        }

        #expect(await eventually { await sink.received.count == 100 })
        #expect(await sink.received.last == .step(99))
    }
}

@Suite("Ordered Stream Writer", .timeLimit(.minutes(1)))
struct OrderedStreamWriterTests {

    /// A stream whose writes do not return until it is told to read.
    private final class StalledStream: ByteStream, @unchecked Sendable {
        private let lock = NSLock()
        private var written: [Data] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isReading = false

        var bytesWritten: Int {
            lock.withLock { written.reduce(0) { $0 + $1.count } }
        }

        func startReading() {
            let waiting = lock.withLock {
                isReading = true
                defer { waiters = [] }
                return waiters
            }
            waiting.forEach { $0.resume() }
        }

        func open() async throws {}

        func write(_ data: Data) async throws {
            await withCheckedContinuation { continuation in
                let proceed = lock.withLock {
                    if !isReading {
                        waiters.append(continuation)
                    }
                    return isReading
                }
                if proceed {
                    continuation.resume()
                }
            }
            lock.withLock { written.append(data) }
        }

        func read() async throws -> Data? { nil }

        func close() {}
    }

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [ByteStreamError] = []

        var all: [ByteStreamError] { lock.withLock { errors } }

        func record(_ error: Error) {
            lock.withLock { errors.append(error as? ByteStreamError ?? .closed) }
        }
    }

    @Test("What a remote side does not read is held only up to a limit")
    func backlogIsBounded() async {
        let stream = StalledStream()
        let failures = Failures()
        let writer = OrderedStreamWriter(stream: stream) { failures.record($0) }
        let megabyte = Data(count: 1024 * 1024)

        // The remote side reads nothing: four megabytes wait, and that is all.
        for _ in 0..<4 {
            writer.write(megabyte)
        }
        #expect(failures.all.isEmpty)

        writer.write(Data([0x01]))
        #expect(await eventually { failures.all == [.backlogged] })

        // Nothing was lost of what had been accepted, and room returns as
        // it is sent.
        stream.startReading()
        #expect(await eventually { stream.bytesWritten == 4 * 1024 * 1024 })
        writer.write(megabyte)
        #expect(await eventually { stream.bytesWritten == 5 * 1024 * 1024 })
        #expect(failures.all == [.backlogged])
    }
}
