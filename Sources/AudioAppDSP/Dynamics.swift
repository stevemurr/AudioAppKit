import AudioAppCore
import AudioAppProcessing
import AudioAppRealtime
import Darwin

/// The decision at the heart of every compressor, expander and gate: given how loud the
/// signal is, how much to turn it down, and how fast to get there.
///
/// It has no sound of its own. Feed it a level from any detector, and apply the gain it
/// returns to any signal: that is what makes side-chains, look-ahead and linked channels
/// possible.
@frozen public struct DynamicsCore: Sendable {
    @frozen public enum Mode: Hashable, Sendable {
        /// Turns down what is above the threshold.
        case compressor
        /// Turns down what is below the threshold. A high ratio makes a gate.
        case expander
    }

    public var mode: Mode
    public var thresholdDB: Double
    /// How many decibels of level change give one decibel at the output, 1 or more.
    public var ratio: Double
    /// The width in decibels, centred on the threshold, over which the ratio eases in.
    public var kneeDB: Double

    // Kept in double precision: a release of seconds moves the gain by less each sample than single precision
    // can add up, and a render can then be matched against an offline reference sample for sample.
    @usableFromInline var attack = 1.0
    @usableFromInline var release = 1.0
    @usableFromInline var currentDB = 0.0

    @inlinable public init(mode: Mode = .compressor, thresholdDB: Double = -18, ratio: Double = 4, kneeDB: Double = 6) {
        self.mode = mode
        self.thresholdDB = thresholdDB
        self.ratio = ratio
        self.kneeDB = kneeDB
    }

    /// Sets how fast gain is taken away and given back: the time to cover 63% of a change.
    @_noAllocation @_noLocks
    @inlinable public mutating func setTimes(attack: Double, release: Double, sampleRate: SampleRate) {
        self.attack = attack > 0 ? 1 - exp(-1 / (attack * sampleRate.hertz)) : 1
        self.release = release > 0 ? 1 - exp(-1 / (release * sampleRate.hertz)) : 1
    }

    /// The gain in decibels, zero or below, that a steady level would settle at.
    @_noAllocation @_noLocks
    @inlinable public func settledGain(atDB levelDB: Double) -> Double {
        let slope: Double
        let past: Double
        switch mode {
        case .compressor:
            slope = 1 / max(ratio, 1) - 1
            past = levelDB - thresholdDB
        case .expander:
            slope = 1 - max(ratio, 1)
            past = thresholdDB - levelDB
        }
        let knee = max(kneeDB, 0)
        if 2 * past <= -knee { return 0 }
        if 2 * past < knee { return slope * (past + knee / 2) * (past + knee / 2) / (2 * knee) }
        return slope * past
    }

    /// As `settledGain(atDB:)`, in single precision.
    @_noAllocation @_noLocks
    @inlinable public func settledGainDB(levelDB: Float) -> Float { Float(settledGain(atDB: Double(levelDB))) }

    /// Takes the signal's level in decibels and returns the gain to apply now, in decibels, zero or below. For a
    /// detector that already works in decibels, and for the full precision the gain is kept in. Call once per
    /// sample, or once per block with times set to match.
    @_noAllocation @_noLocks
    @inlinable public mutating func gainDB(levelDB: Double) -> Double {
        let target = settledGain(atDB: levelDB)
        currentDB += (target < currentDB ? attack : release) * (target - currentDB)
        return currentDB
    }

    /// Takes the signal's level as a linear amplitude and returns the gain to apply now, in
    /// decibels. Call once per sample, or once per block with times set to match.
    @_noAllocation @_noLocks
    @inlinable public mutating func gainDB(level: Float) -> Float {
        Float(gainDB(levelDB: Double(20 * log10(max(level, 1e-10)))))
    }

    /// As `gainDB(level:)`, as a linear gain.
    @_noAllocation @_noLocks
    @inlinable public mutating func gain(level: Float) -> Float {
        exp(gainDB(level: level) * 0.115_129_254_649_702_28)
    }

    /// The gain being applied now, in decibels: zero or below.
    @inlinable public var reductionDB: Float { Float(currentDB) }

    /// The gain being applied now, in decibels and in full precision. Set it to carry on from a known state.
    @inlinable public var heldGainDB: Double {
        get { currentDB }
        set { currentDB = min(newValue, 0) }
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func reset() { currentDB = 0 }
}

/// A third harmonic: the thickening of a transformer or a tape stage, as the simplest curve that makes one.
///
/// The signal is measured against a reference level; `amount` of its cube is taken away. A tone at the reference
/// comes out with a third harmonic a quarter of `amount` as strong as itself, and quieter signals with less, as
/// the square of their level. Past `clip` times the reference the curve stops bending, so nothing folds over.
/// It has no memory: drive `amount` from a gain reduction and the colour deepens as a compressor works harder.
@frozen public struct ThirdHarmonic: Sendable, BitwiseCopyable {
    /// The level the colour is measured against, as a linear amplitude.
    public var reference: Double
    /// How far past the reference the curve keeps bending, as a multiple of it.
    public var clip: Double

    @inlinable public init(reference: Double = 1, clip: Double = 4) {
        self.reference = max(reference, 1e-12)
        self.clip = clip
    }

    /// One sample through the curve.
    @_noAllocation @_noLocks
    @inlinable @inline(__always) public func process(_ x: Double, amount: Double) -> Double {
        let v = x / reference
        let bent = min(max(v, -clip), clip)
        return (v - amount * bent * bent * bent) * reference
    }
}

/// A plain compressor or expander: `DynamicsCore` with a detector, channels linked so the
/// stereo image holds still, and make-up gain.
public struct Dynamics: Processor, ~Copyable {
    public let threshold: Parameter
    public let ratio: Parameter
    public let knee: Parameter
    /// Seconds.
    public let attack: Parameter
    /// Seconds.
    public let release: Parameter
    /// Gain added after the reduction, in decibels.
    public let makeup: Parameter
    @usableFromInline var core: DynamicsCore
    @usableFromInline var follower: EnvelopeFollower
    @usableFromInline var sampleRate: SampleRate = 48_000
    @usableFromInline var times: (attack: Float, release: Float) = (-1, -1)
    @usableFromInline var deepestDB: Float = 0

    public init(_ mode: DynamicsCore.Mode = .compressor, detector: EnvelopeFollower.Detector = .peak) {
        threshold = Parameter(id: "threshold", name: "Threshold", default: -18, in: -80...0, unit: .decibels)
        ratio = Parameter(id: "ratio", name: "Ratio", default: 4, in: 1...100, taper: .logarithmic, unit: .ratio)
        knee = Parameter(id: "knee", name: "Knee", default: 6, in: 0...24, unit: .decibels)
        attack = Parameter(id: "attack", name: "Attack", default: 0.01, in: 0.0001...1, taper: .logarithmic, unit: .seconds)
        release = Parameter(id: "release", name: "Release", default: 0.15, in: 0.005...5, taper: .logarithmic, unit: .seconds)
        makeup = Parameter(id: "makeup", name: "Make-up", default: 0, in: -24...24, unit: .decibels)
        core = DynamicsCore(mode: mode)
        follower = EnvelopeFollower(detector)
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        sampleRate = format.sampleRate
        // An RMS detector averages over a short window; a peak detector follows at once.
        follower.setTimes(attack: 0, release: 0, sampleRate: sampleRate)
        if case .rms = follower.detector { follower.setTimes(attack: 0.01, release: 0.01, sampleRate: sampleRate) }
        times = (-1, -1)
        reset()
    }

    /// The most gain taken away during the last block, in decibels: zero or below.
    @inlinable public var reductionDB: Float { deepestDB }

    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        core.thresholdDB = Double(threshold.value)
        core.ratio = Double(ratio.value)
        core.kneeDB = Double(knee.value)
        let wanted = (attack: attack.value, release: release.value)
        if wanted != times {
            core.setTimes(attack: Double(wanted.attack), release: Double(wanted.release), sampleRate: sampleRate)
            times = wanted
        }
        let lift = makeup.value
        deepestDB = 0
        for frame in 0..<io.frameCount {
            var loudest: Float = 0
            for channel in 0..<io.channelCount { loudest = max(loudest, abs(io[channel][frame])) }
            let reduction = core.gainDB(level: follower.process(loudest))
            deepestDB = min(deepestDB, reduction)
            let gain = exp((reduction + lift) * 0.115_129_254_649_702_28)
            for channel in 0..<io.channelCount { io[channel][frame] *= gain }
        }
    }

    public mutating func reset() {
        core.reset()
        follower.reset()
        deepestDB = 0
    }
}

/// Holds peaks under a ceiling without distortion, by seeing them coming.
///
/// The audio is delayed by the look-ahead time, so the gain can start to fall before a peak
/// arrives and be fully down when it does. No output sample ever exceeds the ceiling. The
/// channels share one gain, so the stereo image holds still.
public struct LookaheadLimiter: Processor, ~Copyable {
    /// The level no sample will exceed, in decibels.
    public let ceiling: Parameter
    /// How fast gain is given back, in seconds.
    public let release: Parameter
    @usableFromInline let lookaheadSeconds: Double
    @usableFromInline var lookahead = 0
    @usableFromInline var channelCount = 0
    @usableFromInline var sampleRate: SampleRate = 48_000
    /// Per channel, the audio waiting out the look-ahead.
    @usableFromInline var delay: UnsafeMutablePointer<Float>?
    /// The gains of the last `lookahead` frames, and their running total.
    @usableFromInline var recent: UnsafeMutablePointer<Float>?
    @usableFromInline var total = 0.0
    @usableFromInline var position = 0
    /// The lowest gain wanted over the look-ahead, tracked with a queue that only ever holds
    /// candidates in rising order.
    @usableFromInline var queueGain: UnsafeMutablePointer<Float>?
    @usableFromInline var queueFrame: UnsafeMutablePointer<Int>?
    @usableFromInline var queueHead = 0
    @usableFromInline var queueCount = 0
    @usableFromInline var queueSize = 1
    @usableFromInline var frameNumber = 0
    @usableFromInline var envelope: Float = 1
    @usableFromInline var deepest: Float = 1

    public init(ceiling: Float = -1, release: Float = 0.1, lookaheadSeconds: Double = 0.005) {
        self.ceiling = Parameter(id: "ceiling", name: "Ceiling", default: ceiling, in: -40...0, unit: .decibels)
        self.release = Parameter(id: "release", name: "Release", default: release, in: 0.001...2,
                                 taper: .logarithmic, unit: .seconds)
        self.lookaheadSeconds = lookaheadSeconds
    }

    deinit {
        delay?.deallocate()
        recent?.deallocate()
        queueGain?.deallocate()
        queueFrame?.deallocate()
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        delay?.deallocate()
        recent?.deallocate()
        queueGain?.deallocate()
        queueFrame?.deallocate()
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        lookahead = max(1, sampleRate.frames(in: lookaheadSeconds))
        delay = Memory.floats(channelCount * lookahead)
        recent = Memory.floats(lookahead)
        queueSize = lookahead + 2
        queueGain = Memory.floats(queueSize)
        queueFrame = .allocate(capacity: queueSize)
        reset()
    }

    /// The most gain taken away during the last block, in decibels: zero or below.
    public var reductionDB: Float { Decibels(gain: deepest).value }

    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        guard let delay, let recent, let queueGain, let queueFrame else { return }
        let limit = Decibels(ceiling.value).gain
        let recovery = 1 - exp(-1 / (max(release.value, 0.001) * Float(sampleRate.hertz)))
        let channels = min(io.channelCount, channelCount)
        deepest = 1
        for frame in 0..<io.frameCount {
            var peak: Float = 0
            for channel in 0..<channels { peak = max(peak, abs(io[channel][frame])) }
            // The gain this frame needs, easing back toward unity after a peak.
            let needed = peak > limit ? limit / peak : 1
            envelope = min(needed, envelope + recovery * (1 - envelope))

            // The lowest gain needed by any frame still waiting in the delay.
            while queueCount > 0, queueGain[(queueHead + queueCount - 1) % queueSize] >= envelope { queueCount -= 1 }
            let slot = (queueHead + queueCount) % queueSize
            queueGain[slot] = envelope
            queueFrame[slot] = frameNumber
            queueCount += 1
            if queueFrame[queueHead] <= frameNumber - (lookahead + 1) {
                queueHead = (queueHead + 1) % queueSize
                queueCount -= 1
            }
            let lowest = queueGain[queueHead]

            // Averaging that over the look-ahead turns each step down into a ramp that ends
            // exactly as the peak leaves the delay.
            total += Double(lowest) - Double(recent[position])
            recent[position] = lowest
            let gain = min(Float(total / Double(lookahead)), 1)
            deepest = min(deepest, gain)

            for channel in 0..<channels {
                let line = delay + channel * lookahead
                let delayed = line[position]
                line[position] = io[channel][frame]
                // The clamp only ever trims rounding error.
                io[channel][frame] = min(max(delayed * gain, -limit), limit)
            }
            position += 1
            if position == lookahead { position = 0 }
            frameNumber &+= 1
        }
    }

    public mutating func reset() {
        if let delay { Memory.zero(delay, channelCount * lookahead) }
        if let recent {
            for index in 0..<lookahead { recent[index] = 1 }
        }
        total = Double(lookahead)
        position = 0
        queueHead = 0
        queueCount = 0
        frameNumber = 0
        envelope = 1
        deepest = 1
    }

    @inlinable public var latencyFrames: Int { lookahead }
}
