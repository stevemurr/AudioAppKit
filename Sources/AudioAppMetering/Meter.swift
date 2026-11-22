import AudioAppCore
import AudioAppProcessing
import Synchronization

/// Something that listens to audio and reports a measurement of it.
///
/// A meter never changes the audio. `measure` runs on the audio thread and keeps to the same
/// rule as a processor: no allocation, no locks, no waiting.
public protocol Meter: ~Copyable {
    /// What the meter reports: a small value that can be copied byte for byte.
    associatedtype Reading: BitwiseCopyable & Sendable

    /// Gets ready. Called away from the audio thread.
    mutating func prepare(_ format: Format, maxFrames: Int)

    /// Listens to one block, on the audio thread.
    mutating func measure(_ block: AudioBlock)

    /// Forgets everything heard so far.
    mutating func reset()

    /// The measurement as of the last block. Read it on the thread that calls `measure`;
    /// other threads read through a `MeterTap`'s `readout`.
    var reading: Reading { get }
}

/// A level for each channel, as linear amplitudes. Holds the first eight channels.
@frozen public struct ChannelLevels: Sendable, BitwiseCopyable {
    public static var capacity: Int { 8 }
    /// How many of the eight are in use.
    public var count: Int
    @usableFromInline var values: SIMD8<Float>

    @inlinable public init(count: Int = 0, repeating value: Float = 0) {
        self.count = min(max(count, 0), 8)
        values = SIMD8(repeating: value)
    }

    @inlinable public subscript(channel: Int) -> Float {
        get { values[channel & 7] }
        set { values[channel & 7] = newValue }
    }

    /// The highest level among the channels in use.
    @inlinable public var maximum: Float {
        var highest: Float = 0
        for channel in 0..<count { highest = max(highest, values[channel]) }
        return highest
    }

    /// One channel's level in decibels.
    public func decibels(_ channel: Int) -> Float { Decibels(gain: self[channel]).value }
}

/// A measurement that the audio thread writes and any other thread reads.
///
/// Neither side waits for the other and a reader never sees half of one reading and half of
/// the next. There are three copies: one the audio thread is writing, one a reader is
/// reading, and one in between holding the newest finished reading. Writing and reading each
/// end by swapping their copy with the one in between, in a single atomic step.
public final class MeterReadout<Reading: BitwiseCopyable & Sendable>: @unchecked Sendable {
    /// The audio thread's side: pointers only, so writing involves no reference counting.
    public let writer: MeterWriter<Reading>
    /// Which copy readers hold. Readers take turns; they never hold up the audio thread.
    private let front = Mutex(0)

    public init(_ initial: Reading) {
        let slots = UnsafeMutablePointer<Reading>.allocate(capacity: 3)
        slots.initialize(repeating: initial, count: 3)
        let middle = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
        middle.initialize(to: Atomic(1))
        let count = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
        count.initialize(to: Atomic(0))
        let back = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        back.initialize(to: 2)
        writer = MeterWriter(slots: slots, middle: middle, count: count, back: back)
    }

    deinit {
        writer.slots.deallocate()
        writer.middle.deinitialize(count: 1)
        writer.middle.deallocate()
        writer.count.deinitialize(count: 1)
        writer.count.deallocate()
        writer.back.deallocate()
    }

    /// The latest reading. Call from any thread but the audio thread.
    public var value: Reading {
        front.withLock { front in
            if writer.middle.pointee.load(ordering: .sequentiallyConsistent) & MeterWriter<Reading>.fresh != 0 {
                front = writer.middle.pointee.exchange(front, ordering: .sequentiallyConsistent) & 3
            }
            return writer.slots[front]
        }
    }

    /// How many readings have been stored. A display can skip redrawing when this is unchanged.
    public var publishCount: Int { writer.count.pointee.load(ordering: .sequentiallyConsistent) }
}

/// The audio thread's side of a `MeterReadout`: pointers into memory the readout owns, so it
/// must not be used after the readout is gone.
@frozen public struct MeterWriter<Reading: BitwiseCopyable & Sendable>: @unchecked Sendable {
    @usableFromInline let slots: UnsafeMutablePointer<Reading>
    /// The copy in between, with the `fresh` bit set when it is newer than the readers' copy.
    @usableFromInline let middle: UnsafeMutablePointer<Atomic<Int>>
    @usableFromInline let count: UnsafeMutablePointer<Atomic<Int>>
    /// The copy the audio thread writes next. Only the audio thread touches this.
    @usableFromInline let back: UnsafeMutablePointer<Int>
    @inlinable static var fresh: Int { 4 }

    @usableFromInline init(slots: UnsafeMutablePointer<Reading>, middle: UnsafeMutablePointer<Atomic<Int>>,
                           count: UnsafeMutablePointer<Atomic<Int>>, back: UnsafeMutablePointer<Int>) {
        self.slots = slots
        self.middle = middle
        self.count = count
        self.back = back
    }

    /// Stores a reading. Call from one thread only: the audio thread.
    @inlinable public func publish(_ reading: Reading) {
        slots[back.pointee] = reading
        back.pointee = middle.pointee.exchange(back.pointee | Self.fresh, ordering: .sequentiallyConsistent) & 3
        count.pointee.wrappingAdd(1, ordering: .relaxed)
    }
}

/// Puts a meter in a signal path. Audio passes through untouched; the meter's reading is
/// published after every block for the interface to pick up.
///
/// Keep a reference to `readout` before handing the tap to a graph, and read it from a
/// display timer.
public struct MeterTap<M: Meter & ~Copyable>: Processor, ~Copyable {
    public var meter: M
    public let readout: MeterReadout<M.Reading>
    @usableFromInline let writer: MeterWriter<M.Reading>

    public init(_ meter: consuming M) {
        readout = MeterReadout(meter.reading)
        writer = readout.writer
        self.meter = meter
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        meter.prepare(format, maxFrames: maxFrames)
        writer.publish(meter.reading)
    }

    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        meter.measure(io)
        writer.publish(meter.reading)
    }

    public mutating func reset() {
        meter.reset()
        writer.publish(meter.reading)
    }
}
