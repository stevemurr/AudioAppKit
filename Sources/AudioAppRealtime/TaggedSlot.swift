import Darwin
import Synchronization

/// A value an ordinary thread stores under a tag, which the audio thread can read only by
/// asking for that tag.
///
/// It is the building block of a render-ahead ring: each slot holds one block of audio,
/// tagged with the block's number, and the audio thread asks for the block it needs. A slot
/// that has since been reused for another block, or is being written, simply says no, and
/// the reader plays silence instead of the wrong audio.
///
/// The writer may wait for a read in progress to finish; the reader never waits.
public final class TaggedSlot<Value>: @unchecked Sendable {
    /// The tag of the value held, or -1 when there is none or one is being stored.
    @usableFromInline let held = Atomic<Int>(-1)
    @usableFromInline let readers = Atomic<Int>(0)
    @usableFromInline let storage: UnsafeMutablePointer<Value>

    /// - Parameter initial: a placeholder. It cannot be read until something is published.
    public init(_ initial: Value) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: initial)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    /// The tag of the value held, or -1.
    public var tag: Int { held.load(ordering: .sequentiallyConsistent) }

    /// Stores a value under a tag, which must not be negative. Call from one thread only,
    /// and never the audio thread: it frees the old value and may wait briefly for a read.
    public func publish(_ tag: Int, value: Value) {
        held.store(-1, ordering: .sequentiallyConsistent)
        while readers.load(ordering: .sequentiallyConsistent) != 0 { usleep(100) }
        storage.pointee = value
        held.store(tag, ordering: .sequentiallyConsistent)
    }

    /// Withdraws the value, so no tag can be read until the next publish.
    public func clear() {
        held.store(-1, ordering: .sequentiallyConsistent)
        while readers.load(ordering: .sequentiallyConsistent) != 0 { usleep(100) }
    }

    /// Lends the value to `body` if the slot holds `tag`, and says whether it did. Safe on
    /// the audio thread.
    @inlinable @discardableResult public func read(_ tag: Int, _ body: (borrowing Value) -> Void) -> Bool {
        guard held.load(ordering: .sequentiallyConsistent) == tag else { return false }
        readers.wrappingAdd(1, ordering: .sequentiallyConsistent)
        defer { readers.wrappingSubtract(1, ordering: .sequentiallyConsistent) }
        guard held.load(ordering: .sequentiallyConsistent) == tag else { return false }
        body(storage.pointee)
        return true
    }
}
