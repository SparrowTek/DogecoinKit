import Foundation

/// Delivers events to an async handler one at a time, in the order they were
/// yielded, without making the producer wait.
///
/// Spawning a `Task` per delegate callback gives no ordering guarantee: a
/// transaction's `.confirmed` event can overtake its `.unconfirmed` one and
/// leave the app showing the stale state. Events yielded here are handled
/// strictly first-in, first-out.
///
/// The queue grows while the handler is slower than the producer. Events
/// that only report how far something has got can be yielded with
/// ``yield(_:supersedingLastWhere:)``, which keeps one of them waiting
/// rather than one for every step.
final class SerialEventQueue<Event: Sendable>: Sendable {
    private let pending = Pending()
    private let wake: AsyncStream<Void>.Continuation

    init(handler: @escaping @Sendable (Event) async -> Void) {
        // One buffered wake-up is enough: whoever is woken empties the queue.
        let (wakeUps, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.wake = wake
        Task { [pending] in
            for await _ in wakeUps {
                while let event = pending.next() {
                    await handler(event)
                }
            }
        }
    }

    func yield(_ event: Event) {
        pending.append(event)
        wake.yield()
    }

    /// Yields `event`, taking the place of the event at the back of the
    /// queue if that one is `superseded`: only the back, so the event keeps
    /// its place behind everything yielded before it.
    func yield(_ event: Event, supersedingLastWhere superseded: (Event) -> Bool) {
        pending.append(event, supersedingLastWhere: superseded)
        wake.yield()
    }

    /// Events waiting for the handler
    var count: Int {
        pending.count
    }

    deinit {
        // Lets already-queued events drain, then ends the consumer task.
        wake.finish()
    }

    /// The events not yet handed to the handler.
    private final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [Event] = []
        /// Index of the next event to hand out; what lies before it is
        /// dropped in one go once it is half the array.
        private var head = 0

        var count: Int {
            lock.withLock { events.count - head }
        }

        func append(_ event: Event) {
            lock.withLock { events.append(event) }
        }

        func append(_ event: Event, supersedingLastWhere superseded: (Event) -> Bool) {
            lock.withLock {
                if events.count > head, let last = events.last, superseded(last) {
                    events[events.count - 1] = event
                } else {
                    events.append(event)
                }
            }
        }

        func next() -> Event? {
            lock.withLock {
                guard head < events.count else {
                    events.removeAll(keepingCapacity: true)
                    head = 0
                    return nil
                }
                let event = events[head]
                head += 1
                if head > 64, head * 2 > events.count {
                    events.removeFirst(head)
                    head = 0
                }
                return event
            }
        }
    }
}
