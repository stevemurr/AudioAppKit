import AudioAppCore
import AudioAppDSP
import AudioAppRealtime
import Darwin

/// What a `PeakMeter` reports.
@frozen public struct PeakReading: Sendable, BitwiseCopyable {
    /// Each channel's level: it jumps to a new peak at once, then falls at the meter's rate.
    public var level: ChannelLevels
    /// Each channel's highest recent peak, held still for the hold time before it lets go.
    public var held: ChannelLevels

    @inlinable public init(level: ChannelLevels = ChannelLevels(), held: ChannelLevels = ChannelLevels()) {
        self.level = level
        self.held = held
    }
}

/// The classic peak meter: a bar that jumps up with the signal and falls back steadily, and
/// a marker that holds the highest recent peak.
///
/// It reads the samples themselves. Peaks between samples can be higher; `TruePeakMeter`
/// finds those.
public struct PeakMeter: Meter {
    @inlinable public var reading: PeakReading { current }
    @usableFromInline var current: PeakReading = PeakReading()
    @usableFromInline let holdSeconds: Double
    @usableFromInline let fallDBPerSecond: Double
    @usableFromInline var sampleRate: SampleRate = 48_000
    @usableFromInline var holdFrames = 0
    /// Frames each channel's held peak has left before it lets go.
    @usableFromInline var holdLeft = SIMD8<Int32>(repeating: 0)

    /// - Parameters:
    ///   - holdSeconds: how long the peak marker stays put.
    ///   - fallDBPerSecond: how fast the bar falls once the signal drops.
    public init(holdSeconds: Double = 1.5, fallDBPerSecond: Double = 20) {
        self.holdSeconds = holdSeconds
        self.fallDBPerSecond = fallDBPerSecond
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        sampleRate = format.sampleRate
        holdFrames = sampleRate.frames(in: holdSeconds)
        current = PeakReading(level: ChannelLevels(count: format.channelCount), held: ChannelLevels(count: format.channelCount))
        holdLeft = SIMD8(repeating: 0)
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func measure(_ block: AudioBlock) {
        let frames = block.frameCount
        // How far the bar falls over this block.
        let fall = Float(exp(-fallDBPerSecond * Double(frames) / sampleRate.hertz * 0.115_129_254_649_702_28))
        for channel in 0..<min(block.channelCount, current.level.count) {
            let samples = block[channel]
            var peak: Float = 0
            for frame in 0..<frames { peak = max(peak, abs(samples[frame])) }
            let level = max(peak, current.level.values[channel] * fall)
            current.level.values[channel] = level
            if peak >= current.held.values[channel] {
                current.held.values[channel] = peak
                holdLeft[channel] = Int32(truncatingIfNeeded: holdFrames)
            } else {
                holdLeft[channel] = holdLeft[channel] &- Int32(truncatingIfNeeded: frames)
                if holdLeft[channel] <= 0 { current.held.values[channel] = level }
            }
        }
    }

    public mutating func reset() {
        current = PeakReading(level: ChannelLevels(count: current.level.count), held: ChannelLevels(count: current.level.count))
        holdLeft = SIMD8(repeating: 0)
    }

}

/// Average level over a short window, per channel: closer to how loud something sounds than
/// its peaks are. A full-scale sine reads 0.7071, which is -3.01 dB.
public struct RMSMeter: Meter {
    /// Each channel's RMS level as a linear amplitude.
    @inlinable public var reading: ChannelLevels { current }
    @usableFromInline var current: ChannelLevels = ChannelLevels()
    @usableFromInline let windowSeconds: Double
    @usableFromInline var sampleRate: SampleRate = 48_000
    @usableFromInline var power = SIMD8<Float>(repeating: 0)

    /// - Parameter windowSeconds: the averaging time. 0.3 gives the familiar VU-like motion.
    public init(windowSeconds: Double = 0.3) { self.windowSeconds = windowSeconds }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        sampleRate = format.sampleRate
        current = ChannelLevels(count: format.channelCount)
        power = SIMD8(repeating: 0)
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func measure(_ block: AudioBlock) {
        let frames = block.frameCount
        guard frames > 0 else { return }
        let share = Float(1 - exp(-Double(frames) / (max(windowSeconds, 1e-4) * sampleRate.hertz)))
        for channel in 0..<min(block.channelCount, current.count) {
            let samples = block[channel]
            var sum: Float = 0
            for frame in 0..<frames { sum += samples[frame] * samples[frame] }
            power[channel] += share * (sum / Float(frames) - power[channel])
            current.values[channel] = RealtimeMath.sqrt(power[channel])
        }
    }

    public mutating func reset() {
        power = SIMD8(repeating: 0)
        current = ChannelLevels(count: current.count)
    }
}

/// What a `TruePeakMeter` reports.
@frozen public struct TruePeakReading: Sendable, BitwiseCopyable {
    /// Each channel's true peak over the last block.
    public var latest: ChannelLevels
    /// Each channel's highest true peak since the meter was reset.
    public var maximum: ChannelLevels

    @inlinable public init(latest: ChannelLevels = ChannelLevels(), maximum: ChannelLevels = ChannelLevels()) {
        self.latest = latest
        self.maximum = maximum
    }

    /// The highest true peak on any channel since the reset, in decibels (dBTP).
    public var maximumDB: Float { Decibels(gain: maximum.maximum).value }
}

/// Finds the peaks between samples.
///
/// Digital audio is rebuilt into a smooth wave on playback, and that wave can rise above
/// every sample that defines it. This meter rebuilds it at four times the rate, as the
/// loudness standard (ITU-R BS.1770-4) prescribes, and reports the highest point. At 96 kHz
/// and above it uses twice the rate, and at 192 kHz and above the samples themselves.
public struct TruePeakMeter: Meter, ~Copyable {
    @inlinable public var reading: TruePeakReading { current }
    @usableFromInline var current: TruePeakReading = TruePeakReading()
    /// Taps in each filter that finds one in-between point.
    @inlinable static var taps: Int { 16 }
    @usableFromInline var factor = 4
    @usableFromInline var channelCount = 0
    /// `factor - 1` filters, one for each point between two samples.
    @usableFromInline var kernels: UnsafeMutablePointer<Float>
    /// Per channel, the last `taps` samples, stored twice over so they can be read in one run.
    @usableFromInline var history: UnsafeMutablePointer<Float>
    @usableFromInline var cursor = 0

    public init() {
        kernels = .allocate(capacity: 1)
        history = .allocate(capacity: 1)
    }

    deinit {
        kernels.deallocate()
        history.deallocate()
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        let rate = format.sampleRate.hertz
        factor = rate >= 176_400 ? 1 : (rate >= 88_200 ? 2 : 4)
        channelCount = min(format.channelCount, ChannelLevels.capacity)
        let taps = Self.taps
        kernels.deallocate()
        history.deallocate()
        kernels = .allocate(capacity: max(1, (factor - 1) * taps))
        history = .allocate(capacity: max(1, channelCount * 2 * taps))
        history.initialize(repeating: 0, count: max(1, channelCount * 2 * taps))
        // Each filter rebuilds the wave at one fraction of the way from a sample to the next.
        let centre = Double(taps / 2 - 1)
        for point in 1..<max(1, factor) {
            let fraction = Double(point) / Double(factor)
            var values = [Double](repeating: 0, count: taps)
            for tap in 0..<taps {
                let time = Double(tap) - centre - fraction
                let sinc = time.magnitude < 1e-9 ? 1 : sin(Double.pi * time) / (Double.pi * time)
                let position = time / Double(taps / 2)
                // A Blackman window.
                let window = position.magnitude < 1 ? 0.42 + 0.5 * cos(Double.pi * position) + 0.08 * cos(2 * Double.pi * position) : 0
                values[tap] = sinc * window
            }
            let sum = values.reduce(0, +)
            for tap in 0..<taps { kernels[(point - 1) * taps + tap] = Float(values[tap] / sum) }
        }
        reset()
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func measure(_ block: AudioBlock) {
        let taps = Self.taps
        var end = cursor
        for channel in 0..<min(block.channelCount, channelCount) {
            let samples = block[channel]
            let memory = history + channel * 2 * taps
            var write = cursor
            var peak: Float = 0
            for frame in 0..<block.frameCount {
                let sample = samples[frame]
                memory[write] = sample
                memory[write + taps] = sample
                write += 1
                if write == taps { write = 0 }
                peak = max(peak, abs(sample))
                let window = memory + write
                for point in 0..<(factor - 1) {
                    let kernel = kernels + point * taps
                    var sum: Float = 0
                    // The filters are stored in time order; the window is oldest first.
                    for tap in 0..<taps { sum += window[tap] * kernel[taps - 1 - tap] }
                    peak = max(peak, abs(sum))
                }
            }
            end = write
            current.latest.values[channel] = peak
            current.maximum.values[channel] = max(current.maximum.values[channel], peak)
        }
        cursor = end
    }

    public mutating func reset() {
        for index in 0..<(channelCount * 2 * Self.taps) { history[index] = 0 }
        cursor = 0
        current = TruePeakReading(latest: ChannelLevels(count: channelCount), maximum: ChannelLevels(count: channelCount))
    }
}

/// How alike the left and right channels are, from +1 (identical: mono) through 0 (unrelated)
/// to -1 (opposite: they cancel when summed to mono). A mix that sits below zero for long
/// will lose level on a mono speaker.
public struct CorrelationMeter: Meter {
    /// The correlation, from -1 to 1. Zero for silence and for mono signals' missing channel.
    @inlinable public var reading: Float { current }
    @usableFromInline var current: Float = 0
    @usableFromInline let windowSeconds: Double
    @usableFromInline var sampleRate: SampleRate = 48_000
    @usableFromInline var both = 0.0, left = 0.0, right = 0.0

    public init(windowSeconds: Double = 0.3) { self.windowSeconds = windowSeconds }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        sampleRate = format.sampleRate
        reset()
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func measure(_ block: AudioBlock) {
        guard block.channelCount >= 2, block.frameCount > 0 else { return }
        let a = block[0], b = block[1]
        var ab = 0.0, aa = 0.0, bb = 0.0
        for frame in 0..<block.frameCount {
            let x = Double(a[frame]), y = Double(b[frame])
            ab += x * y
            aa += x * x
            bb += y * y
        }
        let share = 1 - exp(-Double(block.frameCount) / (max(windowSeconds, 1e-4) * sampleRate.hertz))
        let frames = Double(block.frameCount)
        both += share * (ab / frames - both)
        left += share * (aa / frames - left)
        right += share * (bb / frames - right)
        let size = left * right
        current = size > 1e-20 ? Float(min(max(both / RealtimeMath.sqrt(size), -1), 1)) : 0
    }

    public mutating func reset() {
        both = 0
        left = 0
        right = 0
        current = 0
    }
}
