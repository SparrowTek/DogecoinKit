import Foundation

/// Thread-safe LRU (Least Recently Used) cache with fixed capacity
///
/// When the cache reaches capacity, the least recently accessed item is evicted
/// to make room for new entries. Access operations (get) move items to the
/// most recently used position.
public final class LRUCache<Key: Hashable, Value>: @unchecked Sendable {
    private var cache: [Key: Value] = [:]
    private var order: [Key] = []
    private let capacity: Int
    private let lock = NSLock()

    /// Create a new LRU cache with the specified capacity
    /// - Parameter capacity: Maximum number of items to store
    public init(capacity: Int) {
        precondition(capacity > 0, "LRUCache capacity must be positive")
        self.capacity = capacity
    }

    /// Get a value from the cache
    ///
    /// If the key exists, the item is moved to the most recently used position.
    /// - Parameter key: The key to look up
    /// - Returns: The value if found, nil otherwise
    public func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }

        guard let value = cache[key] else { return nil }

        // Move to end (most recently used)
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }

        return value
    }

    /// Store a value in the cache
    ///
    /// If the key already exists, the value is updated and moved to the most
    /// recently used position. If the cache is at capacity, the least recently
    /// used item is evicted.
    /// - Parameters:
    ///   - key: The key to store
    ///   - value: The value to store
    public func set(_ key: Key, _ value: Value) {
        lock.lock()
        defer { lock.unlock() }

        if cache[key] != nil {
            // Update existing
            cache[key] = value
            if let index = order.firstIndex(of: key) {
                order.remove(at: index)
                order.append(key)
            }
        } else {
            // Insert new
            if order.count >= capacity {
                // Evict oldest
                let oldest = order.removeFirst()
                cache.removeValue(forKey: oldest)
            }
            cache[key] = value
            order.append(key)
        }
    }

    /// Remove a specific key from the cache
    /// - Parameter key: The key to remove
    /// - Returns: The removed value if it existed, nil otherwise
    @discardableResult
    public func remove(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }

        guard let value = cache.removeValue(forKey: key) else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        return value
    }

    /// Remove all items from the cache
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        order.removeAll()
    }

    /// Check if a key exists in the cache without affecting LRU order
    /// - Parameter key: The key to check
    /// - Returns: true if the key exists
    public func contains(_ key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache[key] != nil
    }

    /// Current number of items in the cache
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    /// Whether the cache is empty
    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache.isEmpty
    }

    /// The maximum capacity of the cache
    public var maxCapacity: Int {
        capacity
    }
}
