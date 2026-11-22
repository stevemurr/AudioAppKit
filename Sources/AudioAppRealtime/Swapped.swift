import Synchronization

/// State that an ordinary thread replaces whole and the audio thread reads, with nothing
/// freed on the audio thread.
///
/// The control thread publishes a new state. The audio thread picks it up at the start of its
/// next block and hands the old one back through a queue. The control thread frees old states
/// the next time it publishes or collects.
///
/// The audio thread reads through `reader`, a value made only of pointers, so that reading
/// involves no reference counting.
public final class Swapped<State>: @unchecked Sendable {
    /// What the audio thread reads through. Valid for as long as this object is alive.
    public let reader: SwappedReader<State>

    /// - Parameter retireCapacity: how many replaced states can await collection, rounded up
    ///   to a power of two. Publishing collects, so in normal use at most one is waiting; if
    ///   the queue ever were full, the audio thread would keep its current state until some
    ///   were collected.
    public init(_ initial: State, retireCapacity: Int = 8) {
        var size = 2
        while size < retireCapacity { size <<= 1 }
        let pending = UnsafeMutablePointer<Atomic<UnsafeMutableRawPointer?>>.allocate(capacity: 1)
        pending.initialize(to: Atomic(nil))
        let head = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
        head.initialize(to: Atomic(0))
        let tail = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
        tail.initialize(to: Atomic(0))
        let active = UnsafeMutablePointer<UnsafeMutablePointer<State>>.allocate(capacity: 1)
        active.initialize(to: Self.box(initial))
        reader = SwappedReader(pending: pending, active: active, retired: .allocate(capacity: size),
                               head: head, tail: tail, mask: size - 1)
    }

    deinit {
        collect()
        if let waiting = reader.pending.pointee.exchange(nil, ordering: .acquiringAndReleasing) { Self.free(waiting) }
        Self.free(UnsafeMutableRawPointer(reader.active.pointee))
        reader.active.deallocate()
        reader.retired.deallocate()
        reader.pending.deinitialize(count: 1)
        reader.pending.deallocate()
        reader.head.deinitialize(count: 1)
        reader.head.deallocate()
        reader.tail.deinitialize(count: 1)
        reader.tail.deallocate()
    }

    private static func box(_ state: State) -> UnsafeMutablePointer<State> {
        let pointer = UnsafeMutablePointer<State>.allocate(capacity: 1)
        pointer.initialize(to: state)
        return pointer
    }

    private static func free(_ raw: UnsafeMutableRawPointer) {
        let pointer = raw.assumingMemoryBound(to: State.self)
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    /// Replaces the state. Call from one control thread, never the audio thread. A state
    /// published before the audio thread picked up the previous one supersedes it.
    public func publish(_ state: State) {
        let fresh = UnsafeMutableRawPointer(Self.box(state))
        if let superseded = reader.pending.pointee.exchange(fresh, ordering: .acquiringAndReleasing) {
            Self.free(superseded)
        }
        collect()
    }

    /// Frees states the audio thread has finished with. Call from the control thread.
    public func collect() {
        var start = reader.head.pointee.load(ordering: .relaxed)
        while start != reader.tail.pointee.load(ordering: .acquiring) {
            Self.free(reader.retired[start & reader.mask])
            start &+= 1
            reader.head.pointee.store(start, ordering: .releasing)
        }
    }

    /// How many replaced states are waiting to be collected.
    public var retiredCount: Int {
        reader.tail.pointee.load(ordering: .acquiring) &- reader.head.pointee.load(ordering: .acquiring)
    }
}

/// The audio thread's side of a `Swapped`. It is made only of pointers into memory the
/// `Swapped` owns, so it must not be used after that object is gone.
@frozen public struct SwappedReader<State>: @unchecked Sendable {
    @usableFromInline let pending: UnsafeMutablePointer<Atomic<UnsafeMutableRawPointer?>>
    /// The state the audio thread is using. Only the audio thread touches this cell.
    @usableFromInline let active: UnsafeMutablePointer<UnsafeMutablePointer<State>>
    /// Replaced states on their way back to the control thread.
    @usableFromInline let retired: UnsafeMutablePointer<UnsafeMutableRawPointer>
    @usableFromInline let head: UnsafeMutablePointer<Atomic<Int>>
    @usableFromInline let tail: UnsafeMutablePointer<Atomic<Int>>
    @usableFromInline let mask: Int

    @usableFromInline init(pending: UnsafeMutablePointer<Atomic<UnsafeMutableRawPointer?>>,
                           active: UnsafeMutablePointer<UnsafeMutablePointer<State>>,
                           retired: UnsafeMutablePointer<UnsafeMutableRawPointer>,
                           head: UnsafeMutablePointer<Atomic<Int>>, tail: UnsafeMutablePointer<Atomic<Int>>, mask: Int) {
        self.pending = pending
        self.active = active
        self.retired = retired
        self.head = head
        self.tail = tail
        self.mask = mask
    }

    /// The state to use for this block. Call once at the start of each block, from the audio
    /// thread only. The pointer stays valid until the next call.
    @inlinable public func current() -> UnsafeMutablePointer<State> {
        let end = tail.pointee.load(ordering: .relaxed)
        if end &- head.pointee.load(ordering: .acquiring) <= mask,
           let fresh = pending.pointee.exchange(nil, ordering: .acquiringAndReleasing) {
            (retired + (end & mask)).initialize(to: UnsafeMutableRawPointer(active.pointee))
            tail.pointee.store(end &+ 1, ordering: .releasing)
            active.pointee = fresh.assumingMemoryBound(to: State.self)
        }
        return active.pointee
    }
}
