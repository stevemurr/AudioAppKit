import Darwin
import AudioAppCore
import AudioAppRealtime

/// One channel of delay memory. Write a sample, then read what was written any number of
/// samples ago, including a fraction of a sample for chorus, flanging and tuned delays.
///
/// Memory is reserved when the line is made, so make it away from the audio thread.
public struct DelayLine: ~Copyable {
    /// The longest delay that can be read, in frames.
    public let maxDelayFrames: Int
    @usableFromInline let storage: UnsafeMutablePointer<Float>
    @usableFromInline let mask: Int
    @usableFromInline var head = 0

    public init(maxDelayFrames: Int) {
        self.maxDelayFrames = max(1, maxDelayFrames)
        // Room for the longest delay plus the neighbours a cubic read reaches for.
        var size = 4
        while size < self.maxDelayFrames + 4 { size <<= 1 }
        mask = size - 1
        storage = Memory.floats(size)
    }

    deinit { storage.deallocate() }

    /// Stores the newest sample.
    @_noAllocation @_noLocks
    @inlinable public mutating func write(_ sample: Float) {
        head = (head &+ 1) & mask
        storage[head] = sample
    }

    /// The sample written `delay` writes ago. Zero is the one just written.
    @_noAllocation @_noLocks
    @inlinable public func read(delay: Int) -> Float {
        storage[(head &- min(max(delay, 0), maxDelayFrames)) & mask]
    }

    /// A read between samples, on a straight line between its two neighbours. Cheap, and
    /// slightly dull at the top when the fraction sits near a half.
    @_noAllocation @_noLocks
    @inlinable public func readLinear(delay: Float) -> Float {
        let clamped = min(max(delay, 0), Float(maxDelayFrames))
        let whole = Int(clamped)
        let fraction = clamped - Float(whole)
        let a = storage[(head &- whole) & mask]
        let b = storage[(head &- whole &- 1) & mask]
        return a + fraction * (b - a)
    }

    /// A read between samples on a smooth curve through four neighbours. Flatter at the top
    /// than a linear read.
    @_noAllocation @_noLocks
    @inlinable public func readCubic(delay: Float) -> Float {
        let clamped = min(max(delay, 1), Float(maxDelayFrames))
        let whole = Int(clamped)
        let t = clamped - Float(whole)
        let y0 = storage[(head &- whole &+ 1) & mask]
        let y1 = storage[(head &- whole) & mask]
        let y2 = storage[(head &- whole &- 1) & mask]
        let y3 = storage[(head &- whole &- 2) & mask]
        // Catmull-Rom.
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * t + c2) * t + c1) * t + y1
    }

    /// Writes a sample and returns the one from `delay` writes before it: a plain delay.
    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ sample: Float, delay: Int) -> Float {
        write(sample)
        return read(delay: delay)
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func reset() {
        Memory.zero(storage, mask + 1)
    }
}

/// Follows how loud a signal is, rising and falling at set speeds. Feed it samples; it
/// returns a level as a linear amplitude.
@frozen public struct EnvelopeFollower: Sendable {
    @frozen public enum Detector: Hashable, Sendable {
        /// Follows the size of each sample.
        case peak
        /// Follows average power, the way loudness is heard.
        case rms
    }

    public var detector: Detector
    /// True for the peak detector. Kept beside `detector` because comparing enums does not
    /// pass the compiler's real-time checks.
    @inlinable var followsPeak: Bool {
        if case .peak = detector { return true }
        return false
    }

    @usableFromInline var attack: Float = 1
    @usableFromInline var release: Float = 1
    @usableFromInline var state: Float = 0

    @inlinable public init(_ detector: Detector = .peak) { self.detector = detector }

    /// Sets how fast the level rises and falls: the time to cover 63% of a step.
    @_noAllocation @_noLocks
    @inlinable public mutating func setTimes(attack: Double, release: Double, sampleRate: SampleRate) {
        self.attack = attack > 0 ? Float(1 - exp(-1 / (attack * sampleRate.hertz))) : 1
        self.release = release > 0 ? Float(1 - exp(-1 / (release * sampleRate.hertz))) : 1
    }

    /// Takes one sample and returns the level so far.
    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ sample: Float) -> Float {
        let input = followsPeak ? abs(sample) : sample * sample
        state += (input > state ? attack : release) * (input - state)
        return followsPeak ? state : RealtimeMath.sqrt(state)
    }

    /// The level so far.
    @inlinable public var level: Float { followsPeak ? state : RealtimeMath.sqrt(state) }

    @_noAllocation @_noLocks
    @inlinable public mutating func reset() { state = 0 }
}
