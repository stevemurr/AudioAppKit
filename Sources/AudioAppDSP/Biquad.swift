import Darwin
import AudioAppCore
import AudioAppProcessing
import AudioAppRealtime

/// The shape of a filter.
@frozen public enum FilterResponse: Hashable, Sendable {
    case lowPass, highPass, notch
    /// A bell that lifts or cuts around its frequency.
    case peak
    case lowShelf, highShelf
}

/// The five numbers that define a second-order filter, already divided by a0.
@frozen public struct BiquadCoefficients: Hashable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    @inlinable public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// Leaves audio unchanged.
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// Designs a filter from the Audio EQ Cookbook formulas.
    /// - Parameters:
    ///   - frequency: centre or corner, in hertz. Kept below 0.49 of the sample rate.
    ///   - gain: lift or cut in decibels. Used by `peak` and the shelves only.
    ///   - q: sharpness. 0.7071 gives the flattest low-pass and high-pass.
    @inlinable public static func design(_ response: FilterResponse, frequency: Double, gain: Double = 0,
                                         q: Double = 0.7071, sampleRate: SampleRate) -> BiquadCoefficients {
        let w = 2 * Double.pi * min(max(frequency, 1), 0.49 * sampleRate.hertz) / sampleRate.hertz
        let cosine = cos(w)
        let alpha = sin(w) / (2 * max(q, 0.01))
        let a = exp(gain * 0.057_564_627_324_851_14)        // 10^(gain/40)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch response {
        case .lowPass:
            b0 = (1 - cosine) / 2; b1 = 1 - cosine; b2 = (1 - cosine) / 2
            a0 = 1 + alpha; a1 = -2 * cosine; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosine) / 2; b1 = -(1 + cosine); b2 = (1 + cosine) / 2
            a0 = 1 + alpha; a1 = -2 * cosine; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cosine; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cosine; a2 = 1 - alpha
        case .peak:
            b0 = 1 + alpha * a; b1 = -2 * cosine; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosine; a2 = 1 - alpha / a
        case .lowShelf:
            let s = 2 * RealtimeMath.sqrt(a) * alpha
            b0 = a * ((a + 1) - (a - 1) * cosine + s); b1 = 2 * a * ((a - 1) - (a + 1) * cosine)
            b2 = a * ((a + 1) - (a - 1) * cosine - s)
            a0 = (a + 1) + (a - 1) * cosine + s; a1 = -2 * ((a - 1) + (a + 1) * cosine)
            a2 = (a + 1) + (a - 1) * cosine - s
        case .highShelf:
            let s = 2 * RealtimeMath.sqrt(a) * alpha
            b0 = a * ((a + 1) + (a - 1) * cosine + s); b1 = -2 * a * ((a - 1) + (a + 1) * cosine)
            b2 = a * ((a + 1) + (a - 1) * cosine - s)
            a0 = (a + 1) - (a - 1) * cosine + s; a1 = 2 * ((a - 1) - (a + 1) * cosine)
            a2 = (a + 1) - (a - 1) * cosine - s
        }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// What the filter does to a steady tone at a frequency, in decibels. For drawing curves
    /// and for tests.
    public func magnitudeDB(at frequency: Double, sampleRate: SampleRate) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate.hertz
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let top = (b0 + b1 * c1 + b2 * c2, -(b1 * s1 + b2 * s2))
        let bottom = (1 + a1 * c1 + a2 * c2, -(a1 * s1 + a2 * s2))
        let power = (top.0 * top.0 + top.1 * top.1) / (bottom.0 * bottom.0 + bottom.1 * bottom.1)
        return 10 * log10(max(power, 1e-30))
    }
}

extension BiquadCoefficients {
    /// A first-order low-pass or high-pass: 6 dB per octave, as a section with nothing in its second-order terms.
    @inlinable public static func firstOrder(_ response: FilterResponse, frequency: Double, sampleRate: SampleRate) -> BiquadCoefficients {
        let k = RealtimeMath.tan(Double.pi * min(max(frequency, 1), 0.49 * sampleRate.hertz) / sampleRate.hertz)
        if case .highPass = response { return BiquadCoefficients(b0: 1 / (1 + k), b1: -1 / (1 + k), b2: 0, a1: (k - 1) / (k + 1), a2: 0) }
        return BiquadCoefficients(b0: k / (1 + k), b1: k / (1 + k), b2: 0, a1: (k - 1) / (k + 1), a2: 0)
    }

    /// A Butterworth low-pass or high-pass of any order, as sections to run one after the other: the flattest
    /// passband there is, falling at 6 dB per octave for each order. Other responses give no sections.
    ///
    /// Two of the same in a row make a Linkwitz-Riley crossover of twice the order. Call it away from the audio
    /// thread: it makes an array.
    public static func butterworth(_ response: FilterResponse, order: Int, frequency: Double, sampleRate: SampleRate) -> [BiquadCoefficients] {
        guard response == .lowPass || response == .highPass, order > 0 else { return [] }
        var sections: [BiquadCoefficients] = []
        if order % 2 == 1 { sections.append(.firstOrder(response, frequency: frequency, sampleRate: sampleRate)) }
        for pair in 0..<(order / 2) {
            // The poles sit evenly round a half circle; an odd order has one on the axis, which is the first-order section.
            let angle = order % 2 == 1 ? Double.pi * Double(pair + 1) / Double(order) : Double.pi * Double(2 * pair + 1) / Double(2 * order)
            let q = 1 / (2 * cos(angle))
            sections.append(.design(response, frequency: frequency, q: q, sampleRate: sampleRate))
        }
        return sections
    }
}

/// What one second-order section remembers: two numbers. With `BiquadCoefficients` it is the whole filter, for
/// code that runs its own loop: a filter inside another processor's per-sample work, or over a whole file.
///
/// It is the transposed second direct form, in double precision so low frequencies stay accurate at high rates.
@frozen public struct BiquadState: Sendable, BitwiseCopyable {
    public var z1 = 0.0
    public var z2 = 0.0

    @inlinable public init() {}

    /// Takes one sample and returns the filtered one.
    @_noAllocation @_noLocks
    @inlinable @inline(__always) public mutating func step(_ x: Double, _ c: BiquadCoefficients) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }

    /// Forgets everything heard so far.
    @_noAllocation @_noLocks
    @inlinable public mutating func reset() {
        z1 = 0
        z2 = 0
    }

    /// Drops what is too small to matter, so a long silence does not slow the filter down. Call it once a block.
    @_noAllocation @_noLocks
    @inlinable public mutating func settle() {
        if abs(z1) < 1e-30 { z1 = 0 }
        if abs(z2) < 1e-30 { z2 = 0 }
    }
}

extension BiquadCoefficients {
    /// Runs a whole signal through the section in place, from silence.
    public func filter(_ samples: inout [Double]) {
        var state = BiquadState()
        samples.withUnsafeMutableBufferPointer { samples in
            for index in 0..<samples.count { samples[index] = state.step(samples[index], self) }
        }
    }
}

extension Array where Element == BiquadCoefficients {
    /// Runs a whole signal through the sections in turn, in place, each from silence.
    public func filter(_ samples: inout [Double]) {
        for section in self { section.filter(&samples) }
    }

    /// Filters a whole signal with no delay: the sections forwards, then backwards. Every frequency is turned
    /// down twice as far in decibels, and none is shifted in time. Nothing is added at the two ends, so the first
    /// and last moments carry the filter settling in.
    public func filterBothWays(_ samples: inout [Double]) {
        filter(&samples)
        samples.reverse()
        filter(&samples)
        samples.reverse()
    }

    /// What the sections do together to a steady tone at a frequency, in decibels.
    public func magnitudeDB(at frequency: Double, sampleRate: SampleRate) -> Double {
        reduce(0) { $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate) }
    }
}

/// A second-order filter: one band of an equaliser, a high-pass, a shelf.
///
/// Its frequency, gain and sharpness are parameters, read once per block. It suits settings
/// that are set and left; a filter that is swept continuously wants a different design.
/// Filter state is kept in double precision so low frequencies stay accurate at high rates.
public struct Biquad: Processor, ~Copyable {
    public let response: FilterResponse
    public let frequency: Parameter
    /// Lift or cut in decibels, for `peak` and the shelves.
    public let gain: Parameter
    public let q: Parameter

    @usableFromInline var coefficients = BiquadCoefficients.identity
    @usableFromInline var sampleRate: SampleRate = 48_000
    @usableFromInline var designed: (frequency: Float, gain: Float, q: Float) = (-1, 0, 0)
    /// One section's memory per channel.
    @usableFromInline var state: UnsafeMutablePointer<BiquadState>?
    @usableFromInline var channelCount = 0

    public init(_ response: FilterResponse, frequency: Float = 1_000, gain: Float = 0, q: Float = 0.7071) {
        self.response = response
        self.frequency = Parameter(id: "frequency", name: "Frequency", default: frequency, in: 10...24_000,
                                   taper: .logarithmic, unit: .hertz)
        self.gain = Parameter(id: "gain", name: "Gain", default: gain, in: -24...24, unit: .decibels)
        self.q = Parameter(id: "q", name: "Q", default: q, in: 0.1...20, taper: .logarithmic)
    }

    deinit { state?.deallocate() }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        sampleRate = format.sampleRate
        if channelCount != format.channelCount {
            state?.deallocate()
            channelCount = format.channelCount
            state = .allocate(capacity: channelCount)
        }
        state?.initialize(repeating: BiquadState(), count: channelCount)
        designed.frequency = -1
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        guard let state else { return }
        let wanted = (frequency: frequency.value, gain: gain.value, q: q.value)
        if wanted != designed {
            coefficients = .design(response, frequency: Double(wanted.frequency), gain: Double(wanted.gain),
                                   q: Double(wanted.q), sampleRate: sampleRate)
            designed = wanted
        }
        let c = coefficients
        for channel in 0..<min(io.channelCount, channelCount) {
            let samples = io[channel]
            var memory = state[channel]
            for frame in 0..<io.frameCount { samples[frame] = Float(memory.step(Double(samples[frame]), c)) }
            state[channel] = memory
        }
    }

    public mutating func reset() {
        state?.initialize(repeating: BiquadState(), count: channelCount)
    }
}
