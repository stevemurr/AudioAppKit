import AudioAppCore
import AudioAppProcessing
import Darwin

/// Runs a processor at two or four times the sample rate.
///
/// Anything that bends the waveform (saturation, clipping, fast gain changes) makes new high
/// frequencies. At the ordinary rate, those above the limit fold back as tones that were
/// never in the music. Running the processor at a higher rate gives them room, and they are
/// filtered away on the way back down.
///
/// The filters add latency, reported by `latencyFrames`.
public struct Oversampled<Inner: Processor & ~Copyable>: Processor, ~Copyable {
    public var inner: Inner
    @usableFromInline var core: OversamplingCore

    /// - Parameter factor: 2 or 4.
    public init(_ inner: consuming Inner, factor: Int = 2) {
        self.inner = inner
        core = OversamplingCore(factor: factor >= 4 ? 4 : 2)
    }

    public var factor: Int { core.factor }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        core.prepare(channelCount: format.channelCount, maxFrames: maxFrames)
        inner.prepare(Format(sampleRate: SampleRate(format.sampleRate.hertz * Double(core.factor)), layout: format.layout),
                      maxFrames: maxFrames * core.factor)
    }

    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        let channels = min(io.channelCount, core.channelCount)
        var fast = copy context
        fast.sampleRate = SampleRate(context.sampleRate.hertz * Double(core.factor))
        var done = 0
        while done < io.frameCount {
            let frames = min(core.maxFrames, io.frameCount - done)
            var channel = 0
            while channel < channels {
                core.raise(channel: channel, io[channel].baseAddress! + done, count: frames)
                channel += 1
            }
            var block = core.block(channelCount: channels, frames: frames)
            inner.process(&block, fast)
            channel = 0
            while channel < channels {
                core.lower(channel: channel, io[channel].baseAddress! + done, count: frames)
                channel += 1
            }
            done += frames
        }
    }

    public mutating func reset() {
        core.reset()
        inner.reset()
    }

    /// The filters' delay, plus the inner processor's own, in frames at the ordinary rate.
    public var latencyFrames: Int {
        core.latencyFrames + (inner.latencyFrames + core.factor - 1) / core.factor
    }
}

/// The rate changes of an `Oversampled`, kept apart from it so they do not depend on the
/// kind of processor inside.
@usableFromInline struct OversamplingCore: ~Copyable {
    @usableFromInline let factor: Int
    /// The filter between the ordinary rate and twice it, and the one from there to four
    /// times. The second has an easier job and is shorter.
    @usableFromInline let firstTaps: UnsafeMutablePointer<Float>
    @usableFromInline let secondTaps: UnsafeMutablePointer<Float>
    @inlinable static var firstLength: Int { 63 }
    @inlinable static var secondLength: Int { 33 }
    @usableFromInline var channelCount = 0
    @usableFromInline var maxFrames = 0
    /// Per channel: the audio at twice and at four times the rate.
    @usableFromInline var double: UnsafeMutablePointer<Float>
    @usableFromInline var quadruple: UnsafeMutablePointer<Float>
    /// Per channel, each filter's memory on the way up and on the way down, stored twice
    /// over so it can be read in one run.
    @usableFromInline var firstUp: UnsafeMutablePointer<Float>
    @usableFromInline var firstDown: UnsafeMutablePointer<Float>
    @usableFromInline var secondUp: UnsafeMutablePointer<Float>
    @usableFromInline var secondDown: UnsafeMutablePointer<Float>
    /// Per channel and filter direction, where the next sample is written.
    @usableFromInline var cursors: UnsafeMutablePointer<Int>
    @usableFromInline var pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    @usableFromInline init(factor: Int) {
        self.factor = factor
        firstTaps = Self.design(Self.firstLength)
        secondTaps = Self.design(Self.secondLength)
        double = Memory.floats(0)
        quadruple = Memory.floats(0)
        firstUp = Memory.floats(0)
        firstDown = Memory.floats(0)
        secondUp = Memory.floats(0)
        secondDown = Memory.floats(0)
        cursors = .allocate(capacity: 1)
        pointers = .allocate(capacity: 1)
    }

    /// A low-pass at a quarter of the higher rate: half of the lower one.
    private static func design(_ length: Int) -> UnsafeMutablePointer<Float> {
        let taps = Memory.floats(length)
        let centre = Double(length - 1) / 2
        var values = [Double](repeating: 0, count: length)
        for tap in 0..<length {
            values[tap] = SincDesign.lowPass(at: Double(tap) - centre, cutoff: 0.25, halfWidth: centre + 1, beta: 10)
        }
        let sum = values.reduce(0, +)
        for tap in 0..<length { taps[tap] = Float(values[tap] / sum) }
        return taps
    }

    deinit {
        firstTaps.deallocate()
        secondTaps.deallocate()
        double.deallocate()
        quadruple.deallocate()
        firstUp.deallocate()
        firstDown.deallocate()
        secondUp.deallocate()
        secondDown.deallocate()
        cursors.deallocate()
        pointers.deallocate()
    }

    @inlinable static var firstMemory: Int { (firstLength + 1) / 2 }
    @inlinable static var secondMemory: Int { (secondLength + 1) / 2 }

    @usableFromInline mutating func prepare(channelCount channels: Int, maxFrames frames: Int) {
        double.deallocate()
        quadruple.deallocate()
        firstUp.deallocate()
        firstDown.deallocate()
        secondUp.deallocate()
        secondDown.deallocate()
        cursors.deallocate()
        pointers.deallocate()
        channelCount = channels
        maxFrames = max(1, frames)
        double = Memory.floats(channels * maxFrames * 2)
        quadruple = Memory.floats(channels * maxFrames * 4)
        firstUp = Memory.floats(channels * 2 * Self.firstMemory)
        firstDown = Memory.floats(channels * 2 * Self.firstLength)
        secondUp = Memory.floats(channels * 2 * Self.secondMemory)
        secondDown = Memory.floats(channels * 2 * Self.secondLength)
        cursors = .allocate(capacity: max(1, channels * 4))
        cursors.initialize(repeating: 0, count: max(1, channels * 4))
        pointers = .allocate(capacity: max(1, channels))
        for channel in 0..<channels {
            pointers[channel] = factor == 4 ? quadruple + channel * maxFrames * 4 : double + channel * maxFrames * 2
        }
    }

    @usableFromInline mutating func reset() {
        Memory.zero(firstUp, channelCount * 2 * Self.firstMemory)
        Memory.zero(firstDown, channelCount * 2 * Self.firstLength)
        Memory.zero(secondUp, channelCount * 2 * Self.secondMemory)
        Memory.zero(secondDown, channelCount * 2 * Self.secondLength)
        for index in 0..<(channelCount * 4) { cursors[index] = 0 }
    }

    /// The delay of going up and coming back down, in frames at the ordinary rate.
    @usableFromInline var latencyFrames: Int {
        (Self.firstLength - 1) / 2 + (factor == 4 ? (Self.secondLength - 1) / 4 : 0)
    }

    /// The audio at the higher rate, for the inner processor to work on.
    @_noAllocation @_noLocks
    @inlinable func block(channelCount channels: Int, frames: Int) -> AudioBlock {
        AudioBlock(channels: UnsafePointer(pointers), channelCount: channels, frameCount: frames * factor)
    }

    /// Doubles the rate of `count` samples: each input sample becomes two.
    @_noAllocation @_noLocks
    @inlinable static func double(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, count: Int,
                                  taps: UnsafePointer<Float>, length: Int, memory: UnsafeMutablePointer<Float>,
                                  cursor: UnsafeMutablePointer<Int>) {
        let size = (length + 1) / 2
        var write = cursor.pointee
        for index in 0..<count {
            memory[write] = input[index]
            memory[write + size] = input[index]
            write += 1
            if write == size { write = 0 }
            // The newest sample is last in the window.
            let window = memory + write
            var even: Float = 0, odd: Float = 0
            for tap in 0..<size { even += taps[2 * tap] * window[size - 1 - tap] }
            for tap in 0..<(size - 1) { odd += taps[2 * tap + 1] * window[size - 1 - tap] }
            output[2 * index] = 2 * even
            output[2 * index + 1] = 2 * odd
        }
        cursor.pointee = write
    }

    /// Halves the rate: `count` output samples from twice as many input samples.
    @_noAllocation @_noLocks
    @inlinable static func halve(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, count: Int,
                                 taps: UnsafePointer<Float>, length: Int, memory: UnsafeMutablePointer<Float>,
                                 cursor: UnsafeMutablePointer<Int>) {
        var write = cursor.pointee
        for index in 0..<count {
            for half in 0..<2 {
                memory[write] = input[2 * index + half]
                memory[write + length] = input[2 * index + half]
                write += 1
                if write == length { write = 0 }
                if half == 0 {
                    let window = memory + write
                    var sum: Float = 0
                    for tap in 0..<length { sum += taps[tap] * window[length - 1 - tap] }
                    output[index] = sum
                }
            }
        }
        cursor.pointee = write
    }

    /// Takes a channel's samples up to the higher rate.
    @_noAllocation @_noLocks
    @inlinable mutating func raise(channel: Int, _ samples: UnsafePointer<Float>, count: Int) {
        let twice = double + channel * maxFrames * 2
        Self.double(samples, twice, count: count, taps: firstTaps, length: Self.firstLength,
                    memory: firstUp + channel * 2 * Self.firstMemory, cursor: cursors + channel * 4)
        if factor == 4 {
            Self.double(twice, quadruple + channel * maxFrames * 4, count: 2 * count, taps: secondTaps,
                        length: Self.secondLength, memory: secondUp + channel * 2 * Self.secondMemory,
                        cursor: cursors + channel * 4 + 1)
        }
    }

    /// Brings a channel back down to the ordinary rate, into `samples`.
    @_noAllocation @_noLocks
    @inlinable mutating func lower(channel: Int, _ samples: UnsafeMutablePointer<Float>, count: Int) {
        let twice = double + channel * maxFrames * 2
        if factor == 4 {
            Self.halve(quadruple + channel * maxFrames * 4, twice, count: 2 * count, taps: secondTaps,
                       length: Self.secondLength, memory: secondDown + channel * 2 * Self.secondLength,
                       cursor: cursors + channel * 4 + 2)
        }
        Self.halve(twice, samples, count: count, taps: firstTaps, length: Self.firstLength,
                   memory: firstDown + channel * 2 * Self.firstLength, cursor: cursors + channel * 4 + 3)
    }
}
