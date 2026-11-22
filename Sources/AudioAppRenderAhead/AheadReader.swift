import AudioAppCore
import AudioAppProcessing
import Synchronization

/// The audio thread's side of an `AheadLane`: it copies audio the worker has already made.
///
/// It is made only of pointers into memory the lane owns, so reading involves no reference
/// counting, and it must not be used after the lane is gone. Only one thread may read.
@frozen public struct AheadReader: @unchecked Sendable {
    /// The low bits of the playhead hold a frame; the bits above hold the seek count, so a
    /// block made before a seek can never be mistaken for one made after it.
    @inlinable static var frameMask: Int { (1 << 40) - 1 }

    public let channelCount: Int
    public let blockFrames: Int
    @usableFromInline let slotCount: Int
    /// The timeline's length in frames, or -1 when it has no end.
    @usableFromInline let length: Int
    /// The seek count and frame the next read starts from.
    @usableFromInline let playhead: UnsafeMutablePointer<Atomic<Int>>
    /// Which block each slot holds, tagged with the seek count, or -1 while it is being made.
    @usableFromInline let tags: UnsafeMutablePointer<Atomic<Int>>
    /// How many reads are inside each slot. The worker waits for zero before reusing one.
    @usableFromInline let readers: UnsafeMutablePointer<Atomic<Int>>
    /// Every slot's audio: slot, then channel, then frame.
    @usableFromInline let samples: UnsafeMutablePointer<Float>
    @usableFromInline let underruns: UnsafeMutablePointer<Atomic<Int>>
    @usableFromInline let missingFrames: UnsafeMutablePointer<Atomic<Int>>

    @usableFromInline init(channelCount: Int, blockFrames: Int, slotCount: Int, length: Int,
                           playhead: UnsafeMutablePointer<Atomic<Int>>, tags: UnsafeMutablePointer<Atomic<Int>>,
                           readers: UnsafeMutablePointer<Atomic<Int>>, samples: UnsafeMutablePointer<Float>,
                           underruns: UnsafeMutablePointer<Atomic<Int>>, missingFrames: UnsafeMutablePointer<Atomic<Int>>) {
        self.channelCount = channelCount
        self.blockFrames = blockFrames
        self.slotCount = slotCount
        self.length = length
        self.playhead = playhead
        self.tags = tags
        self.readers = readers
        self.samples = samples
        self.underruns = underruns
        self.missingFrames = missingFrames
    }

    /// The timeline position the next read starts from.
    @inlinable public var position: FramePosition {
        FramePosition(Int64(playhead.pointee.load(ordering: .sequentiallyConsistent) & Self.frameMask))
    }

    /// Fills `output` with the next frames of the timeline and moves on by that many.
    ///
    /// Frames the worker has not made yet come out as silence and count as an underrun; they
    /// are skipped, not played late. Frames past the end of the timeline are silence and not
    /// an underrun. Safe on the audio thread.
    /// - Returns: how many frames were real audio or past the end, so `output.frameCount`
    ///   when nothing was missing.
    @_noAllocation @_noLocks
    @inlinable @discardableResult public func read(into output: AudioBlock) -> Int {
        let head = playhead.pointee.load(ordering: .sequentiallyConsistent)
        let epoch = head & ~Self.frameMask
        var frame = head & Self.frameMask
        var done = 0, missing = 0
        while done < output.frameCount {
            if length >= 0, frame >= length {
                output.slice(from: done, count: output.frameCount - done).clear()
                break
            }
            let index = frame / blockFrames, offset = frame % blockFrames
            var count = min(output.frameCount - done, blockFrames - offset)
            if length >= 0 { count = min(count, length - frame) }
            let slot = index % slotCount, key = epoch | index
            var copied = false
            if tags[slot].load(ordering: .sequentiallyConsistent) == key {
                readers[slot].wrappingAdd(1, ordering: .sequentiallyConsistent)
                if tags[slot].load(ordering: .sequentiallyConsistent) == key {
                    for channel in 0..<output.channelCount {
                        let target = output[channel]
                        if channel < channelCount {
                            let source = samples + (slot * channelCount + channel) * blockFrames + offset
                            for i in 0..<count { target[done + i] = source[i] }
                        } else {
                            for i in 0..<count { target[done + i] = 0 }
                        }
                    }
                    copied = true
                }
                readers[slot].wrappingSubtract(1, ordering: .sequentiallyConsistent)
            }
            if !copied {
                output.slice(from: done, count: count).clear()
                missing += count
            }
            done += count
            frame += count
        }
        if missing > 0 {
            underruns.pointee.wrappingAdd(1, ordering: .relaxed)
            missingFrames.pointee.wrappingAdd(missing, ordering: .relaxed)
        }
        // A seek that landed during this read wins: the exchange fails and its position stands.
        _ = playhead.pointee.compareExchange(expected: head, desired: epoch | frame, ordering: .sequentiallyConsistent)
        return output.frameCount - missing
    }
}

/// A lane's audio as a processor, so it can be a node in a graph. It replaces whatever it is
/// handed with the next frames of the lane's timeline.
public struct AheadSource: Processor, ~Copyable {
    public let reader: AheadReader
    /// Keeps the lane alive for as long as the node exists. Never touched on the audio thread.
    let lane: AnyObject

    public init<P: AheadProducer>(_ lane: AheadLane<P>) {
        reader = lane.reader
        self.lane = lane
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {}

    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        reader.read(into: io)
    }
}
