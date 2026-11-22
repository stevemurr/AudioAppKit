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
    /// Two state values per channel.
    @usableFromInline var state: UnsafeMutablePointer<Double>?
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
            state = .allocate(capacity: 2 * channelCount)
        }
        state?.initialize(repeating: 0, count: 2 * channelCount)
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
            var z1 = state[2 * channel], z2 = state[2 * channel + 1]
            for frame in 0..<io.frameCount {
                let x = Double(samples[frame])
                let y = c.b0 * x + z1
                z1 = c.b1 * x - c.a1 * y + z2
                z2 = c.b2 * x - c.a2 * y
                samples[frame] = Float(y)
            }
            state[2 * channel] = z1
            state[2 * channel + 1] = z2
        }
    }

    public mutating func reset() {
        state?.initialize(repeating: 0, count: 2 * channelCount)
    }
}
