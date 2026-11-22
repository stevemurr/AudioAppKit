import AudioAppCore
import AudioAppProcessing
import AudioAppRealtime
import Darwin

/// The simplest smoothing filter: one multiply per sample. Use it to smooth a control, soften
/// highs, or follow a level.
@frozen public struct OnePole: Sendable {
    /// How far the output moves toward the input each sample, from 0 to 1.
    public var coefficient: Float
    @usableFromInline var state: Float = 0

    @inlinable public init(coefficient: Float = 1) { self.coefficient = coefficient }

    /// Sets the -3 dB point.
    @_noAllocation @_noLocks
    @inlinable public mutating func setCutoff(_ hertz: Double, sampleRate: SampleRate) {
        coefficient = Float(1 - exp(-2 * Double.pi * min(hertz, 0.49 * sampleRate.hertz) / sampleRate.hertz))
    }

    /// Sets the time to cover 63% of a step.
    @_noAllocation @_noLocks
    @inlinable public mutating func setTime(seconds: Double, sampleRate: SampleRate) {
        coefficient = seconds > 0 ? Float(1 - exp(-1 / (seconds * sampleRate.hertz))) : 1
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func lowPass(_ input: Float) -> Float {
        state += coefficient * (input - state)
        return state
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func highPass(_ input: Float) -> Float { input - lowPass(input) }

    @_noAllocation @_noLocks
    @inlinable public mutating func reset(to value: Float = 0) { state = value }
}

/// A first-order all-pass: every frequency passes at full level, but phase turns by 90
/// degrees at the corner and 180 by the top. The building block of phasers and of filters
/// that split a signal into bands that sum back flat.
@frozen public struct Allpass: Sendable {
    public var coefficient: Float
    @usableFromInline var lastInput: Float = 0
    @usableFromInline var lastOutput: Float = 0

    @inlinable public init(coefficient: Float = 0) { self.coefficient = coefficient }

    /// Sets the frequency at which phase has turned by 90 degrees.
    @_noAllocation @_noLocks
    @inlinable public mutating func setCorner(_ hertz: Double, sampleRate: SampleRate) {
        let t = RealtimeMath.tan(Double.pi * min(hertz, 0.49 * sampleRate.hertz) / sampleRate.hertz)
        coefficient = Float((t - 1) / (t + 1))
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ input: Float) -> Float {
        let output = coefficient * input + lastInput - coefficient * lastOutput
        lastInput = input
        lastOutput = output
        return output
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func reset() {
        lastInput = 0
        lastOutput = 0
    }
}

/// A second-order filter that stays stable and click-free while its frequency is moved, so
/// it suits swept and modulated filters. `Biquad` is cheaper for settings that are set and
/// left.
///
/// A change of frequency is reached over a short glide, and the filter is retuned every few
/// samples along the way.
public struct StateVariableFilter: Processor, ~Copyable {
    public let response: FilterResponse
    public let frequency: Parameter
    /// Lift or cut in decibels, for `peak` and the shelves.
    public let gain: Parameter
    public let q: Parameter

    @usableFromInline var sampleRate: SampleRate = 48_000
    @usableFromInline var glide = Smoothed(1_000)
    @usableFromInline let glideSeconds: Double
    /// Two state values per channel.
    @usableFromInline var state: UnsafeMutablePointer<Double>?
    @usableFromInline var channelCount = 0
    // The filter's tuning and the three weights that pick its response.
    @usableFromInline var a1 = 0.0, a2 = 0.0, a3 = 0.0, k = 1.0
    @usableFromInline var m0 = 1.0, m1 = 0.0, m2 = 0.0

    /// How many frames pass between retunings while the frequency glides.
    @inlinable static var retuneFrames: Int { 16 }

    public init(_ response: FilterResponse, frequency: Float = 1_000, gain: Float = 0, q: Float = 0.7071,
                glideSeconds: Double = 0.02) {
        self.response = response
        self.frequency = Parameter(id: "frequency", name: "Frequency", default: frequency, in: 10...24_000,
                                   taper: .logarithmic, unit: .hertz)
        self.gain = Parameter(id: "gain", name: "Gain", default: gain, in: -24...24, unit: .decibels)
        self.q = Parameter(id: "q", name: "Q", default: q, in: 0.1...20, taper: .logarithmic)
        self.glideSeconds = glideSeconds
    }

    deinit { state?.deallocate() }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        sampleRate = format.sampleRate
        if channelCount != format.channelCount {
            state?.deallocate()
            channelCount = format.channelCount
            state = Memory.doubles(2 * channelCount)
        }
        reset()
        glide.configure(sampleRate: sampleRate, seconds: glideSeconds)
        glide.snap(to: frequency.value)
        tune(Double(frequency.value), gain: Double(gain.value), q: Double(q.value))
    }

    /// Works out the filter's numbers for a frequency.
    @_noAllocation @_noLocks
    @inlinable mutating func tune(_ hertz: Double, gain decibels: Double, q sharpness: Double) {
        let a = exp(decibels * 0.057_564_627_324_851_14)        // 10^(gain/40)
        var g = RealtimeMath.tan(Double.pi * min(max(hertz, 1), 0.49 * sampleRate.hertz) / sampleRate.hertz)
        k = 1 / max(sharpness, 0.01)
        switch response {
        case .lowPass: m0 = 0; m1 = 0; m2 = 1
        case .highPass: m0 = 1; m1 = -k; m2 = -1
        case .notch: m0 = 1; m1 = -k; m2 = 0
        case .peak:
            k = 1 / (max(sharpness, 0.01) * a)
            m0 = 1; m1 = k * (a * a - 1); m2 = 0
        case .lowShelf:
            g /= RealtimeMath.sqrt(a)
            m0 = 1; m1 = k * (a - 1); m2 = a * a - 1
        case .highShelf:
            g *= RealtimeMath.sqrt(a)
            m0 = a * a; m1 = k * (1 - a) * a; m2 = 1 - a * a
        }
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        guard let state else { return }
        glide.set(frequency.value)
        let decibels = Double(gain.value), sharpness = Double(q.value)
        var start = 0
        while start < io.frameCount {
            let frames = min(Self.retuneFrames, io.frameCount - start)
            glide.advance(by: frames)
            tune(Double(glide.current), gain: decibels, q: sharpness)
            for channel in 0..<min(io.channelCount, channelCount) {
                let samples = io[channel]
                var s1 = state[2 * channel], s2 = state[2 * channel + 1]
                for frame in start..<(start + frames) {
                    let x = Double(samples[frame])
                    let v3 = x - s2
                    let v1 = a1 * s1 + a2 * v3
                    let v2 = s2 + a2 * s1 + a3 * v3
                    s1 = 2 * v1 - s1
                    s2 = 2 * v2 - s2
                    samples[frame] = Float(m0 * x + m1 * v1 + m2 * v2)
                }
                state[2 * channel] = s1
                state[2 * channel + 1] = s2
            }
            start += frames
        }
    }

    public mutating func reset() {
        if let state { Memory.zero(state, 2 * channelCount) }
    }
}
