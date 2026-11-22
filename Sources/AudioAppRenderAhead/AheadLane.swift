import AudioAppCore
import Darwin
import Foundation
import Synchronization

/// Makes audio ahead of time. Unlike a `Processor`, a producer runs on a worker thread, so it
/// may allocate, lock, read a disk or run a model, and may take as long as it needs so long
/// as it keeps ahead of playback on average.
public protocol AheadProducer: SendableMetatype {
    /// Fills `output` with the timeline's audio starting at `position`. Blocks are asked for
    /// in order, one after the other, until a seek.
    mutating func produce(at position: FramePosition, into output: AudioBlock)

    /// The next block asked for will start at `position`, which does not follow on from the
    /// last. Forget anything carried from block to block. Called before the first block, after
    /// a seek, and when playback overtook the worker and blocks were skipped.
    mutating func seek(to position: FramePosition)
}

extension AheadProducer {
    public mutating func seek(to position: FramePosition) {}
}

/// How a lane is keeping up.
public struct AheadDiagnostics: Equatable, Sendable {
    /// Frames made and waiting ahead of the playhead.
    public var framesAhead: Int
    /// Reads that found audio missing.
    public var underruns: Int
    /// Frames that played as silence because they were not ready.
    public var missingFrames: Int
    /// Time spent making audio against the time that audio lasts: 1 means the producer only
    /// just keeps up. Nil until a block has been made.
    public var producerLoad: Float?

    public init(framesAhead: Int, underruns: Int, missingFrames: Int, producerLoad: Float?) {
        self.framesAhead = framesAhead
        self.underruns = underruns
        self.missingFrames = missingFrames
        self.producerLoad = producerLoad
    }
}

/// Runs a producer ahead of playback and keeps its output ready for the audio thread.
///
/// The timeline is cut into blocks. A worker makes the blocks from the playhead up to a set
/// distance ahead; the audio thread, through `reader`, copies them out and never waits. A
/// seek starts a new numbering, so blocks made for the old position are never played.
///
/// Use `start()` for live playback. For offline rendering and tests leave the worker stopped
/// and call `fill()` before each read: the same code then runs on the calling thread.
public final class AheadLane<Producer: AheadProducer>: @unchecked Sendable {
    public let format: Format
    public let blockFrames: Int
    /// How many blocks the worker keeps ready ahead of the playhead.
    public let depthBlocks: Int
    /// What the audio thread reads through. Valid for as long as this lane is alive.
    public let reader: AheadReader

    private var producer: Producer
    /// Held while blocks are being made, by the worker or by `fill()`.
    private let gate = NSLock()
    private var workerEpoch = -1
    private var nextBlock = 0
    private var smoothedLoad: Float?
    private let loadBits = Atomic<UInt32>(Float.nan.bitPattern)
    /// The seek count and frame the worker has made audio up to.
    private let producedThrough = Atomic<Int>(-1)
    private let seeks = Atomic<Int>(0)

    /// What the lane and its worker thread share. The thread holds this, not the lane, so a
    /// lane can go away while its worker is asleep.
    private final class Worker: Sendable {
        let running = Atomic<Bool>(false)
        let finished = Atomic<Bool>(true)
        let wake = DispatchSemaphore(value: 0)
        /// The worker thread's identity, so the lane can tell when it is being torn down there.
        let thread = Atomic<UInt>(0)
    }
    private let worker = Worker()

    /// - Parameters:
    ///   - blockFrames: the length of the blocks the producer is asked for.
    ///   - aheadFrames: how far ahead of the playhead to stay. Make it at least the most the
    ///     audio device asks for in one go, plus time for the worker to be scheduled.
    ///   - frameCount: the length of the timeline, or nil when it has no end.
    public init(_ producer: Producer, format: Format, blockFrames: Int, aheadFrames: Int, frameCount: Int? = nil) {
        self.producer = producer
        self.format = format
        self.blockFrames = max(1, blockFrames)
        // One more than asked, because the block under the playhead may be nearly used up.
        depthBlocks = (max(1, aheadFrames) + self.blockFrames - 1) / self.blockFrames + 1
        // Two spare, so a slot is reused only after the playhead is well past its block.
        let slots = depthBlocks + 2
        let channels = format.channelCount

        func atomics(_ count: Int, _ value: Int) -> UnsafeMutablePointer<Atomic<Int>> {
            let pointer = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: count)
            for index in 0..<count { (pointer + index).initialize(to: Atomic(value)) }
            return pointer
        }
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: slots * channels * self.blockFrames)
        samples.initialize(repeating: 0, count: slots * channels * self.blockFrames)
        reader = AheadReader(channelCount: channels, blockFrames: self.blockFrames, slotCount: slots,
                             length: frameCount.map { max(0, $0) } ?? -1,
                             playhead: atomics(1, 0), tags: atomics(slots, -1), readers: atomics(slots, 0),
                             samples: samples, underruns: atomics(1, 0), missingFrames: atomics(1, 0))
        channelPointers = .allocate(capacity: channels)
    }

    deinit {
        stop()
        reader.playhead.deinitialize(count: 1)
        reader.playhead.deallocate()
        reader.tags.deinitialize(count: reader.slotCount)
        reader.tags.deallocate()
        reader.readers.deinitialize(count: reader.slotCount)
        reader.readers.deallocate()
        reader.underruns.deinitialize(count: 1)
        reader.underruns.deallocate()
        reader.missingFrames.deinitialize(count: 1)
        reader.missingFrames.deallocate()
        reader.samples.deallocate()
        channelPointers.deallocate()
    }

    /// Scratch for handing one slot to the producer as a block. Used only under the gate.
    private let channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    // MARK: Control

    /// The timeline position the next read starts from.
    public var position: FramePosition { reader.position }

    /// Moves the playhead. Audio made for the old position is dropped, and reads return
    /// silence until the worker has made the new position's first block. Call from any
    /// thread but the audio thread.
    public func seek(to position: FramePosition) {
        let epoch = seeks.wrappingAdd(1, ordering: .sequentiallyConsistent).newValue
        let frame = Int(max(0, position.frames)) & AheadReader.frameMask
        reader.playhead.pointee.store((epoch << 40) | frame, ordering: .sequentiallyConsistent)
        worker.wake.signal()
    }

    /// Starts the worker thread. Does nothing if it is already running.
    public func start() {
        guard !worker.running.exchange(true, ordering: .sequentiallyConsistent) else { return }
        worker.finished.store(false, ordering: .sequentiallyConsistent)
        // Check often enough that a block's worth of playback never goes unnoticed.
        let seconds = Double(blockFrames) / format.sampleRate.hertz
        let interval = DispatchTimeInterval.microseconds(Int(min(max(seconds / 4, 0.0005), 0.005) * 1_000_000))
        let thread = Thread { [weak self, worker] in
            worker.thread.store(UInt(bitPattern: pthread_self()), ordering: .sequentiallyConsistent)
            while worker.running.load(ordering: .sequentiallyConsistent) {
                // Hold the lane only while filling, so it can go away while the worker sleeps.
                guard let lane = self else { break }
                lane.fill()
                _ = consume lane
                _ = worker.wake.wait(timeout: .now() + interval)
            }
            worker.finished.store(true, ordering: .sequentiallyConsistent)
        }
        thread.name = "AudioAppKit.AheadLane"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the worker thread and waits for it to finish its current block.
    public func stop() {
        guard worker.running.exchange(false, ordering: .sequentiallyConsistent) else { return }
        worker.wake.signal()
        // If the last reference went away on the worker itself, it is already on its way out.
        guard worker.thread.load(ordering: .sequentiallyConsistent) != UInt(bitPattern: pthread_self()) else { return }
        while !worker.finished.load(ordering: .sequentiallyConsistent) { usleep(200) }
    }

    public var isRunning: Bool { worker.running.load(ordering: .sequentiallyConsistent) }

    /// Waits until the audio from the playhead on is ready, or the timeout passes. Call after
    /// `start()` or a seek, before starting playback, so the first read is not an underrun.
    @discardableResult public func waitUntilReady(timeout seconds: Double = 2) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isReady { return true }
            usleep(500)
        }
        return isReady
    }

    private var isReady: Bool {
        let head = reader.playhead.pointee.load(ordering: .sequentiallyConsistent)
        let made = producedThrough.load(ordering: .sequentiallyConsistent)
        guard made >= 0, made & ~AheadReader.frameMask == head & ~AheadReader.frameMask else { return false }
        let frame = head & AheadReader.frameMask
        let wanted = min(frame + (depthBlocks - 1) * blockFrames, reader.length >= 0 ? reader.length : .max)
        return made & AheadReader.frameMask >= wanted
    }

    /// Lends the producer to `body`, between blocks. Use it to change a producer's settings.
    public func withProducer<Result>(_ body: (inout Producer) throws -> Result) rethrows -> Result {
        gate.lock()
        defer { gate.unlock() }
        return try body(&producer)
    }

    public var diagnostics: AheadDiagnostics {
        let head = reader.playhead.pointee.load(ordering: .sequentiallyConsistent)
        let made = producedThrough.load(ordering: .sequentiallyConsistent)
        let sameSeek = made >= 0 && made & ~AheadReader.frameMask == head & ~AheadReader.frameMask
        let load = Float(bitPattern: loadBits.load(ordering: .relaxed))
        return AheadDiagnostics(framesAhead: sameSeek ? max(0, (made & AheadReader.frameMask) - (head & AheadReader.frameMask)) : 0,
                                underruns: reader.underruns.pointee.load(ordering: .relaxed),
                                missingFrames: reader.missingFrames.pointee.load(ordering: .relaxed),
                                producerLoad: load.isFinite ? load : nil)
    }

    // MARK: Producing

    /// Makes every block wanted right now, on the calling thread. The worker calls this; call
    /// it yourself, with the worker stopped, to render offline or in a test.
    public func fill() {
        gate.lock()
        defer { gate.unlock() }
        // Start again whenever a seek lands part-way through.
        while !fillOnce() {}
    }

    /// One pass. Returns false if a seek interrupted it.
    private func fillOnce() -> Bool {
        let head = reader.playhead.pointee.load(ordering: .sequentiallyConsistent)
        let epoch = head & ~AheadReader.frameMask
        let first = (head & AheadReader.frameMask) / blockFrames
        if epoch != workerEpoch {
            workerEpoch = epoch
            nextBlock = first
            producer.seek(to: FramePosition(Int64(first * blockFrames)))
        } else if nextBlock < first {
            // Playback overtook the worker. Skip to where it is now.
            nextBlock = first
            producer.seek(to: FramePosition(Int64(first * blockFrames)))
        }
        var limit = first + depthBlocks
        if reader.length >= 0 { limit = min(limit, (reader.length + blockFrames - 1) / blockFrames) }

        while nextBlock < limit {
            guard reader.playhead.pointee.load(ordering: .sequentiallyConsistent) & ~AheadReader.frameMask == epoch else { return false }
            let slot = nextBlock % reader.slotCount
            // Take the slot out of use, then wait out a read already inside it.
            reader.tags[slot].store(-1, ordering: .sequentiallyConsistent)
            while reader.readers[slot].load(ordering: .sequentiallyConsistent) != 0 { sched_yield() }
            for channel in 0..<reader.channelCount {
                channelPointers[channel] = reader.samples + (slot * reader.channelCount + channel) * blockFrames
            }
            let block = AudioBlock(channels: UnsafePointer(channelPointers), channelCount: reader.channelCount, frameCount: blockFrames)
            let began = DispatchTime.now().uptimeNanoseconds
            producer.produce(at: FramePosition(Int64(nextBlock * blockFrames)), into: block)
            let spent = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
            reader.tags[slot].store(epoch | nextBlock, ordering: .sequentiallyConsistent)
            nextBlock += 1
            var through = nextBlock * blockFrames
            if reader.length >= 0 { through = min(through, reader.length) }
            producedThrough.store(epoch | through, ordering: .sequentiallyConsistent)

            let load = Float(spent * format.sampleRate.hertz / Double(blockFrames))
            smoothedLoad = smoothedLoad.map { $0 + 0.2 * (load - $0) } ?? load
            loadBits.store(smoothedLoad!.bitPattern, ordering: .relaxed)
        }
        return true
    }
}
