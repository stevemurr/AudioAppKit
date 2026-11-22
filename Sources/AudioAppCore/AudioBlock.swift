/// A view onto planar 32-bit float audio that someone else owns: some channels, each a run
/// of frames. It is what a processor is handed on the audio thread. Making, slicing and
/// reading one never allocates.
///
/// A block does not keep its memory alive. It is valid only while the buffer it came from is.
///
/// Its methods carry the compiler's real-time checks themselves, which also makes debug
/// builds compile them without the runtime type lookups a plain debug loop performs.
@frozen public struct AudioBlock {
    public let channelCount: Int
    public let frameCount: Int
    @usableFromInline let channels: UnsafePointer<UnsafeMutablePointer<Float>>
    @usableFromInline let offset: Int

    /// - Parameter channels: one pointer per channel, each to at least `offset + frameCount` samples.
    @inlinable public init(channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frameCount: Int, offset: Int = 0) {
        self.channels = channels
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.offset = offset
    }

    /// The samples of one channel.
    @inlinable public subscript(channel: Int) -> UnsafeMutableBufferPointer<Float> {
        UnsafeMutableBufferPointer(start: channels[channel] + offset, count: frameCount)
    }

    /// A one-channel view of a single channel.
    @_noAllocation @_noLocks
    @inlinable public func channel(_ index: Int) -> AudioBlock {
        AudioBlock(channels: channels + index, channelCount: 1, frameCount: frameCount, offset: offset)
    }

    /// A shorter view of the same memory. The range is clamped to the block.
    @_noAllocation @_noLocks
    @inlinable public func slice(from start: Int, count: Int) -> AudioBlock {
        let first = min(max(start, 0), frameCount)
        return AudioBlock(channels: channels, channelCount: channelCount,
                          frameCount: min(max(count, 0), frameCount - first), offset: offset + first)
    }

    @_noAllocation @_noLocks
    @inlinable public func clear() {
        for channel in 0..<channelCount {
            let samples = self[channel]
            for frame in 0..<frameCount { samples[frame] = 0 }
        }
    }

    /// Multiplies every sample by a gain.
    @_noAllocation @_noLocks
    @inlinable public func scale(by gain: Float) {
        for channel in 0..<channelCount {
            let samples = self[channel]
            for frame in 0..<frameCount { samples[frame] *= gain }
        }
    }

    /// Replaces this block's audio with another's, over the channels and frames both have.
    /// Channels the source lacks are cleared.
    @_noAllocation @_noLocks
    @inlinable public func copy(from source: AudioBlock) {
        let frames = min(frameCount, source.frameCount)
        for channel in 0..<channelCount {
            let samples = self[channel]
            if channel < source.channelCount {
                let other = source[channel]
                for frame in 0..<frames { samples[frame] = other[frame] }
                for frame in frames..<frameCount { samples[frame] = 0 }
            } else {
                for frame in 0..<frameCount { samples[frame] = 0 }
            }
        }
    }

    /// Adds another block into this one, over the channels and frames both have. A mono
    /// source is added to every channel.
    @_noAllocation @_noLocks
    @inlinable public func add(_ source: AudioBlock, gain: Float = 1) {
        let frames = min(frameCount, source.frameCount)
        guard source.channelCount > 0 else { return }
        for channel in 0..<channelCount {
            guard channel < source.channelCount || source.channelCount == 1 else { break }
            let samples = self[channel]
            let other = source[source.channelCount == 1 ? 0 : channel]
            for frame in 0..<frames { samples[frame] += other[frame] * gain }
        }
    }
}

/// Planar 32-bit float audio that owns its memory. Make these away from the audio thread and
/// hand out `AudioBlock` views of them.
public final class SampleBuffer {
    public let channelCount: Int
    public let frameCapacity: Int
    @usableFromInline let channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    /// A silent buffer.
    public init(channelCount: Int, frameCapacity: Int) {
        self.channelCount = max(1, channelCount)
        self.frameCapacity = max(0, frameCapacity)
        channels = .allocate(capacity: self.channelCount)
        for channel in 0..<self.channelCount {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: max(1, self.frameCapacity))
            samples.initialize(repeating: 0, count: max(1, self.frameCapacity))
            channels[channel] = samples
        }
    }

    /// A buffer holding the given samples, one array per channel. Shorter channels are padded
    /// with silence.
    public convenience init(_ samples: [[Float]]) {
        self.init(channelCount: samples.count, frameCapacity: samples.map(\.count).max() ?? 0)
        for (channel, values) in samples.enumerated() {
            for (frame, value) in values.enumerated() { channels[channel][frame] = value }
        }
    }

    deinit {
        for channel in 0..<channelCount { channels[channel].deallocate() }
        channels.deallocate()
    }

    /// A view of the whole buffer.
    @inlinable public var block: AudioBlock {
        AudioBlock(channels: UnsafePointer(channels), channelCount: channelCount, frameCount: frameCapacity)
    }

    /// A view of part of the buffer.
    @inlinable public func block(from start: Int = 0, frames: Int) -> AudioBlock {
        block.slice(from: start, count: frames)
    }

    /// A copy of one channel's samples.
    public func samples(channel: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: channels[channel], count: frameCapacity))
    }
}
