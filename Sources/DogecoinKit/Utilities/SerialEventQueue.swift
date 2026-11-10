import Foundation

/// Delivers events to an async handler one at a time, in the order they were
/// yielded, without making the producer wait.
///
/// Spawning a `Task` per delegate callback gives no ordering guarantee: a
/// transaction's `.confirmed` event can overtake its `.unconfirmed` one and
/// leave the app showing the stale state. Events yielded here are handled
/// strictly first-in, first-out.
final class SerialEventQueue<Event: Sendable>: Sendable {
    private let continuation: AsyncStream<Event>.Continuation

    init(handler: @escaping @Sendable (Event) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        self.continuation = continuation
        Task {
            for await event in stream {
                await handler(event)
            }
        }
    }

    func yield(_ event: Event) {
        continuation.yield(event)
    }

    deinit {
        // Lets already-queued events drain, then ends the consumer task.
        continuation.finish()
    }
}
