import Darwin
import Synchronization

/// The newest value from one ordinary thread, readable from the audio thread without waiting.
///
/// The writer may wait for a read in progress to finish; the reader never waits. A read that
/// lands while a new value is being stored returns nil, and the reader carries on with what
/// it already has.
public final class LatestValue<Value>: @unchecked Sendable {
    /// Odd while a value is being stored.
    @usableFromInline let version = Atomic<Int>(0)
    @usableFromInline let readers = Atomic<Int>(0)
    @usableFromInline let storage: UnsafeMutablePointer<Value>

    public init(_ initial: Value) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: initial)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    /// Stores a new value. Call from one thread only, and never from the audio thread: it
    /// frees the old value and may wait briefly for a read to finish.
    public func publish(_ value: Value) {
        version.wrappingAdd(1, ordering: .sequentiallyConsistent)
        while readers.load(ordering: .sequentiallyConsistent) != 0 { sched_yield() }
        storage.pointee = value
        version.wrappingAdd(1, ordering: .sequentiallyConsistent)
    }

    /// How many values have been published.
    public var publishCount: Int { version.load(ordering: .sequentiallyConsistent) / 2 }

    /// Lends the current value to `body`, or returns nil when a new one is being stored.
    /// Safe on the audio thread.
    @inlinable public func read<Result>(_ body: (borrowing Value) -> Result) -> Result? {
        guard version.load(ordering: .sequentiallyConsistent) & 1 == 0 else { return nil }
        readers.wrappingAdd(1, ordering: .sequentiallyConsistent)
        defer { readers.wrappingSubtract(1, ordering: .sequentiallyConsistent) }
        guard version.load(ordering: .sequentiallyConsistent) & 1 == 0 else { return nil }
        return body(storage.pointee)
    }
}
