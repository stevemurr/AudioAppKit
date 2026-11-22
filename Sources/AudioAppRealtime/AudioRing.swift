import Synchronization

/// A fixed-size store of audio for exactly one thread that writes and one that reads, such as
/// a worker rendering ahead of the audio callback. Neither side waits, allocates or locks.
public final class AudioRing: @unchecked Sendable {
    public let channelCount: Int
    @usableFromInline let storage: UnsafeMutablePointer<Float>
    @usableFromInline let size: Int
    @usableFromInline let head = Atomic<Int>(0)
    @usableFromInline let tail = Atomic<Int>(0)

    /// - Parameter frameCapacity: rounded up to a power of two.
    public init(channelCount: Int, frameCapacity: Int) {
        self.channelCount = max(1, channelCount)
        var frames = 2
        while frames < frameCapacity { frames <<= 1 }
        size = frames
        storage = .allocate(capacity: frames * self.channelCount)
        storage.initialize(repeating: 0, count: frames * self.channelCount)
    }

    deinit { storage.deallocate() }

    public var frameCapacity: Int { size }

    /// Frames waiting to be read.
    @inlinable public var availableFrames: Int {
        tail.load(ordering: .acquiring) &- head.load(ordering: .acquiring)
    }

    /// Frames that can be written before the ring is full.
    @inlinable public var freeFrames: Int { size - availableFrames }

    /// Writes as many frames of `count` as fit, calling `sample(channel, frame)` for each.
    /// Returns how many were written.
    @inlinable @discardableResult
    public func write(frames count: Int, _ sample: (_ channel: Int, _ frame: Int) -> Float) -> Int {
        let end = tail.load(ordering: .relaxed)
        let frames = min(count, size - (end &- head.load(ordering: .acquiring)))
        guard frames > 0 else { return 0 }
        for channel in 0..<channelCount {
            let lane = storage + channel * size
            for frame in 0..<frames { lane[(end &+ frame) & (size - 1)] = sample(channel, frame) }
        }
        tail.store(end &+ frames, ordering: .releasing)
        return frames
    }

    /// Reads up to `count` frames, calling `store(channel, frame, sample)` for each. Returns
    /// how many were read.
    @inlinable @discardableResult
    public func read(frames count: Int, _ store: (_ channel: Int, _ frame: Int, _ sample: Float) -> Void) -> Int {
        let start = head.load(ordering: .relaxed)
        let frames = min(count, tail.load(ordering: .acquiring) &- start)
        guard frames > 0 else { return 0 }
        for channel in 0..<channelCount {
            let lane = storage + channel * size
            for frame in 0..<frames { store(channel, frame, lane[(start &+ frame) & (size - 1)]) }
        }
        head.store(start &+ frames, ordering: .releasing)
        return frames
    }

    /// Discards everything waiting. Call from the reading thread.
    @inlinable public func drain() {
        head.store(tail.load(ordering: .acquiring), ordering: .releasing)
    }
}
