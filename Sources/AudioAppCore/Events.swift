/// Something that happens at an exact frame within a block: a note, a controller, a parameter
/// change from a host's automation.
@frozen public struct Event: Sendable {
    /// Frames from the start of the block.
    public var offset: Int
    public var kind: Kind

    @frozen public enum Kind: Sendable, Equatable {
        /// A short MIDI message: status and two data bytes.
        case midi(UInt8, UInt8, UInt8)
        /// A parameter, named by address, should take a value.
        case parameter(address: UInt64, value: Float)
        /// Anything an app wants to time to the frame.
        case custom(UInt32, Float)
    }

    @inlinable public init(offset: Int, _ kind: Kind) {
        self.offset = offset
        self.kind = kind
    }
}

/// The events for one block, in time order. A view onto memory an `EventBuffer` owns; valid
/// only for the block it was handed out for.
@frozen public struct EventList: @unchecked Sendable {
    @usableFromInline let events: UnsafePointer<Event>?
    public let count: Int
    /// Taken off each stored offset, so a slice of a block still counts from its own start.
    @usableFromInline let shift: Int

    @inlinable public init(events: UnsafePointer<Event>?, count: Int, shift: Int = 0) {
        self.events = events
        self.count = events == nil ? 0 : count
        self.shift = shift
    }

    /// No events.
    @inlinable public static var empty: EventList { EventList(events: nil, count: 0) }

    @inlinable public var isEmpty: Bool { count == 0 }

    @inlinable public subscript(index: Int) -> Event {
        var event = events.unsafelyUnwrapped[index]
        event.offset -= shift
        return event
    }

    /// The events that fall within part of the block, with offsets counted from that part's
    /// start.
    @_noAllocation @_noLocks
    @inlinable public func slice(from start: Int, count frames: Int) -> EventList {
        guard let events, count > 0 else { return .empty }
        var first = 0
        while first < count, events[first].offset - shift < start { first += 1 }
        var end = first
        while end < count, events[end].offset - shift < start + frames { end += 1 }
        return EventList(events: events + first, count: end - first, shift: shift + start)
    }
}

/// Owns the memory for a block's events. Make it away from the audio thread; fill it and
/// hand out its `list` on the audio thread.
public final class EventBuffer: @unchecked Sendable {
    public let capacity: Int
    @usableFromInline let storage: UnsafeMutablePointer<Event>
    @usableFromInline let filled: UnsafeMutablePointer<Int>

    public init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
        storage = .allocate(capacity: self.capacity)
        filled = .allocate(capacity: 1)
        filled.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        filled.deallocate()
    }

    @inlinable public var count: Int { filled.pointee }

    @inlinable public func clear() { filled.pointee = 0 }

    /// Adds an event, keeping time order. Events at the same frame keep the order they were
    /// added in. Returns false when the buffer is full.
    @_noAllocation @_noLocks
    @inlinable @discardableResult public func append(_ event: Event) -> Bool {
        let count = filled.pointee
        guard count < capacity else { return false }
        var slot = count
        while slot > 0, storage[slot - 1].offset > event.offset {
            (storage + slot).initialize(to: storage[slot - 1])
            slot -= 1
        }
        (storage + slot).initialize(to: event)
        filled.pointee = count + 1
        return true
    }

    /// The events added so far.
    @inlinable public var list: EventList { EventList(events: UnsafePointer(storage), count: filled.pointee) }
}
