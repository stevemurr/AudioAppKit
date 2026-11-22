import Synchronization

/// A fixed-size queue for exactly one thread that pushes and one that pops. Neither side ever
/// waits, allocates or takes a lock, so either may be the audio thread.
public final class SPSCQueue<Element>: @unchecked Sendable {
    @usableFromInline let storage: UnsafeMutablePointer<Element>
    @usableFromInline let mask: Int
    @usableFromInline let head = Atomic<Int>(0)
    @usableFromInline let tail = Atomic<Int>(0)

    /// - Parameter capacity: rounded up to a power of two.
    public init(capacity: Int) {
        var size = 2
        while size < capacity { size <<= 1 }
        mask = size - 1
        storage = .allocate(capacity: size)
    }

    deinit {
        while pop() != nil {}
        storage.deallocate()
    }

    public var capacity: Int { mask + 1 }

    /// How many elements are waiting. Exact only from the pushing or popping thread.
    @inlinable public var count: Int {
        tail.load(ordering: .acquiring) &- head.load(ordering: .acquiring)
    }

    @inlinable public var isFull: Bool { count > mask }

    /// Adds an element. Returns false, leaving the queue as it was, when there is no room.
    @inlinable @discardableResult public func push(_ element: Element) -> Bool {
        let end = tail.load(ordering: .relaxed)
        guard end &- head.load(ordering: .acquiring) <= mask else { return false }
        (storage + (end & mask)).initialize(to: element)
        tail.store(end &+ 1, ordering: .releasing)
        return true
    }

    /// Removes the oldest element, or returns nil when the queue is empty.
    @inlinable public func pop() -> Element? {
        let start = head.load(ordering: .relaxed)
        guard start != tail.load(ordering: .acquiring) else { return nil }
        let element = (storage + (start & mask)).move()
        head.store(start &+ 1, ordering: .releasing)
        return element
    }
}
