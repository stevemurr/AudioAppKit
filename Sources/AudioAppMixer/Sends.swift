import AudioAppCore
import AudioAppProcessing
import AudioAppRealtime

/// A stereo signal gathered over one block from any number of sources: what a return is fed, or a bus is summed
/// into.
///
/// A mixer rarely renders a block in one go: a loop can wrap inside it, and a source can start part-way through. So
/// sources are added a stretch at a time, each at its place in the block. Clear the block, add every source's
/// stretches, then read `left` and `right`.
///
/// Memory is reserved when it is made, so make it away from the audio thread.
public struct StereoFeed: ~Copyable {
    /// The longest block it can hold.
    public let maxFrames: Int
    public let left: UnsafeMutablePointer<Float>
    public let right: UnsafeMutablePointer<Float>

    public init(maxFrames: Int) {
        self.maxFrames = max(1, maxFrames)
        left = .allocate(capacity: self.maxFrames)
        left.initialize(repeating: 0, count: self.maxFrames)
        right = .allocate(capacity: self.maxFrames)
        right.initialize(repeating: 0, count: self.maxFrames)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// Silence, for the block about to be gathered.
    @_noAllocation @_noLocks
    @inlinable public func clear(frames: Int) {
        for frame in 0..<min(frames, maxFrames) {
            left[frame] = 0
            right[frame] = 0
        }
    }

    /// Adds a stretch of a source, each side through its own gain, starting `at` frames into the block.
    @_noAllocation @_noLocks
    @inlinable public func add(_ sourceLeft: UnsafePointer<Float>, gain leftGain: Float, _ sourceRight: UnsafePointer<Float>, gain rightGain: Float, at: Int, frames: Int) {
        let a = left + at, b = right + at
        for frame in 0..<frames {
            a[frame] += leftGain * sourceLeft[frame]
            b[frame] += rightGain * sourceRight[frame]
        }
    }

    /// Puts a stretch of a source in place of what was there: for a feed that has one source.
    @_noAllocation @_noLocks
    @inlinable public func set(_ sourceLeft: UnsafePointer<Float>, gain leftGain: Float, _ sourceRight: UnsafePointer<Float>, gain rightGain: Float, at: Int, frames: Int) {
        let a = left + at, b = right + at
        for frame in 0..<frames {
            a[frame] = leftGain * sourceLeft[frame]
            b[frame] = rightGain * sourceRight[frame]
        }
    }
}

/// A delay line for each source of a send, so each can reach the return a little late: a pre-delay per track.
///
/// Every source is written every stretch, sent or not, so a send can be opened at any moment and find its
/// source's recent past waiting. After all the sources have been written for a stretch, call `advance`.
///
/// Memory is reserved when it is made, so make it away from the audio thread.
public struct SendDelays: ~Copyable {
    public let sourceCount: Int
    /// The longest delay a send can have, in frames.
    public let maxDelay: Int
    @usableFromInline let length: Int
    /// Per source and side: its last `length` frames, after its gains.
    @usableFromInline let lines: UnsafeMutablePointer<Float>
    @usableFromInline let write: UnsafeMutablePointer<Int>

    /// - Parameter maxDelay: the longest delay wanted. The longest stretch written between two calls of `advance`
    ///   may not be longer than the memory this rounds up to, a power of two above it.
    public init(sourceCount: Int, maxDelay: Int) {
        self.sourceCount = max(0, sourceCount)
        var size = 1
        while size <= max(maxDelay, 0) { size *= 2 }
        length = size
        self.maxDelay = size - 1
        let count = max(1, self.sourceCount * 2 * size)
        lines = .allocate(capacity: count)
        lines.initialize(repeating: 0, count: count)
        write = .allocate(capacity: 1)
        write.initialize(to: 0)
    }

    deinit {
        lines.deallocate()
        write.deallocate()
    }

    /// Forgets everything heard so far.
    @_noAllocation @_noLocks
    @inlinable public func reset() {
        for index in 0..<(sourceCount * 2 * length) { lines[index] = 0 }
        write.pointee = 0
    }

    /// Remembers a stretch of a source, each side through its own gain, and adds it to a destination `delay` frames
    /// late and through `send`. With `send` at nothing the stretch is only remembered.
    /// - Parameters:
    ///   - destinationLeft, destinationRight: where the stretch goes, already moved to its place in the block.
    @_noAllocation @_noLocks
    @inlinable public func send(_ source: Int, _ sourceLeft: UnsafePointer<Float>, gain leftGain: Float, _ sourceRight: UnsafePointer<Float>, gain rightGain: Float,
                                delay: Int, send: Float, into destinationLeft: UnsafeMutablePointer<Float>, _ destinationRight: UnsafeMutablePointer<Float>, frames: Int) {
        guard source >= 0, source < sourceCount else { return }
        let mask = length - 1, start = write.pointee, late = min(max(delay, 0), maxDelay)
        for side in 0..<2 {
            let from = side == 0 ? sourceLeft : sourceRight, level = side == 0 ? leftGain : rightGain
            let kept = lines + (source * 2 + side) * length
            let destination = side == 0 ? destinationLeft : destinationRight
            for frame in 0..<frames {
                kept[(start + frame) & mask] = level * from[frame]
                if send != 0 { destination[frame] += send * kept[(start + frame - late + length) & mask] }
            }
        }
    }

    /// Every source has been written for `frames` more frames.
    @_noAllocation @_noLocks
    @inlinable public func advance(frames: Int) { write.pointee = (write.pointee + frames) & (length - 1) }
}

/// How loud a return is, gliding: what switches a return in and out without a click, and what says when it can
/// stop being worked out.
///
/// A return that is wanted, or still fading out, is sounding. One that is neither costs nothing: skip it.
@frozen public struct ReturnLevel: Sendable {
    @usableFromInline var glide = Smoothed(0)

    @inlinable public init() {}

    /// Sets how long a change of level takes.
    @inlinable public mutating func configure(sampleRate: SampleRate, seconds: Double) { glide.configure(sampleRate: sampleRate, seconds: seconds) }

    /// The level now, and whether it is on its way somewhere.
    @inlinable public var current: Float { glide.current }
    @inlinable public var isRamping: Bool { glide.isRamping }

    /// Whether the return is to be heard at a wanted level, or is still being heard on its way to nothing.
    @_noAllocation @_noLocks
    @inlinable public func isSounding(wanting level: Float) -> Bool { level != 0 || glide.current != 0 || glide.isRamping }

    /// Begins at a level. Where playback starts, and offline, the return is simply there; switched in while
    /// playing, it glides up from nothing.
    @_noAllocation @_noLocks
    @inlinable public mutating func start(wanting level: Float, snaps: Bool) { glide.snap(to: snaps ? level : 0) }

    /// Silent at once.
    @_noAllocation @_noLocks
    @inlinable public mutating func stop() { glide.snap(to: 0) }

    /// Heads for a level.
    @_noAllocation @_noLocks
    @inlinable public mutating func set(_ level: Float) { glide.set(level) }

    /// The level for the next frame.
    @_noAllocation @_noLocks
    @inlinable public mutating func next() -> Float { glide.next() }
}
