import Foundation

/// Fixed-capacity FIFO that overwrites its oldest element once full.
///
/// Each metric series holds 600 samples — ten minutes at 1 Hz — so the memory
/// cost stays bounded no matter how long the app runs.
public struct RingBuffer<Element: Sendable>: Sendable {
    private var storage: [Element] = []
    private var writeIndex = 0
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(capacity, 0)
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int { storage.count }
    public var isFull: Bool { capacity > 0 && storage.count == capacity }

    public mutating func append(_ element: Element) {
        guard capacity > 0 else { return }

        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[writeIndex] = element
        }
        writeIndex = (writeIndex + 1) % capacity
    }

    /// Elements in insertion order, oldest first.
    public var elements: [Element] {
        guard isFull else { return storage }
        return Array(storage[writeIndex...] + storage[..<writeIndex])
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        writeIndex = 0
    }
}
