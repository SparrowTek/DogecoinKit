import Foundation

/// LRU (Least Recently Used) cache with fixed capacity
///
/// When the cache reaches capacity, the least recently accessed item is evicted
/// to make room for new entries. Access operations (get) move items to the
/// most recently used position. Every operation is O(1): entries live in a
/// slot array threaded into a doubly linked recency list.
///
/// This type is not thread-safe on its own. It is intended to be owned
/// by an actor which provides isolation.
final class LRUCache<Key: Hashable, Value> {
    private struct Entry {
        var key: Key
        var value: Value
        /// Slot of the next-older entry, or -1
        var older: Int
        /// Slot of the next-newer entry, or -1
        var newer: Int
    }

    private var entries: [Entry] = []
    private var slots: [Key: Int] = [:]
    private var freeSlots: [Int] = []
    private var newest = -1
    private var oldest = -1
    private let capacity: Int

    /// Create a new LRU cache with the specified capacity
    /// - Parameter capacity: Maximum number of items to store (at least 1)
    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Get a value from the cache
    ///
    /// If the key exists, the item is moved to the most recently used position.
    /// - Parameter key: The key to look up
    /// - Returns: The value if found, nil otherwise
    func get(_ key: Key) -> Value? {
        guard let index = slots[key] else { return nil }
        moveToNewest(index)
        return entries[index].value
    }

    /// Store a value in the cache
    ///
    /// If the key already exists, the value is updated and moved to the most
    /// recently used position. If the cache is at capacity, the least recently
    /// used item is evicted.
    /// - Parameters:
    ///   - key: The key to store
    ///   - value: The value to store
    func set(_ key: Key, _ value: Value) {
        if let index = slots[key] {
            entries[index].value = value
            moveToNewest(index)
            return
        }

        let entry = Entry(key: key, value: value, older: -1, newer: -1)
        let index: Int
        if let free = freeSlots.popLast() {
            index = free
            entries[index] = entry
        } else if entries.count < capacity {
            index = entries.count
            entries.append(entry)
        } else {
            // Evict the least recently used entry and reuse its slot.
            index = oldest
            unlink(index)
            slots.removeValue(forKey: entries[index].key)
            entries[index] = entry
        }

        slots[key] = index
        linkAsNewest(index)
    }

    /// Remove a specific key from the cache
    /// - Parameter key: The key to remove
    /// - Returns: The removed value if it existed, nil otherwise
    @discardableResult
    func remove(_ key: Key) -> Value? {
        guard let index = slots.removeValue(forKey: key) else { return nil }
        unlink(index)
        freeSlots.append(index)
        return entries[index].value
    }

    /// Remove all items from the cache
    func clear() {
        entries.removeAll()
        slots.removeAll()
        freeSlots.removeAll()
        newest = -1
        oldest = -1
    }

    /// Check if a key exists in the cache without affecting LRU order
    /// - Parameter key: The key to check
    /// - Returns: true if the key exists
    func contains(_ key: Key) -> Bool {
        slots[key] != nil
    }

    /// Current number of items in the cache
    var count: Int {
        slots.count
    }

    /// Whether the cache is empty
    var isEmpty: Bool {
        slots.isEmpty
    }

    /// The maximum capacity of the cache
    var maxCapacity: Int {
        capacity
    }

    // MARK: - Recency List

    private func moveToNewest(_ index: Int) {
        guard index != newest else { return }
        unlink(index)
        linkAsNewest(index)
    }

    private func unlink(_ index: Int) {
        let older = entries[index].older
        let newer = entries[index].newer

        if older >= 0 {
            entries[older].newer = newer
        } else {
            oldest = newer
        }

        if newer >= 0 {
            entries[newer].older = older
        } else {
            newest = older
        }
    }

    private func linkAsNewest(_ index: Int) {
        entries[index].older = newest
        entries[index].newer = -1
        if newest >= 0 {
            entries[newest].newer = index
        }
        newest = index
        if oldest < 0 {
            oldest = index
        }
    }
}
