import Darwin

/// A sample rate in hertz. Nothing in the library assumes a particular rate.
@frozen public struct SampleRate: Hashable, Comparable, Sendable, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    public var hertz: Double

    @inlinable public init(_ hertz: Double) { self.hertz = hertz }
    @inlinable public init(floatLiteral value: Double) { hertz = value }
    @inlinable public init(integerLiteral value: Int) { hertz = Double(value) }

    @inlinable public static func < (a: SampleRate, b: SampleRate) -> Bool { a.hertz < b.hertz }

    /// The number of whole frames that best covers a duration.
    @inlinable public func frames(in seconds: Double) -> Int { Int((seconds * hertz).rounded()) }
    @inlinable public func seconds(in frames: Int) -> Double { Double(frames) / hertz }
}

/// A position on a timeline, counted in frames.
@frozen public struct FramePosition: Hashable, Comparable, Sendable, ExpressibleByIntegerLiteral {
    public var frames: Int64

    @inlinable public init(_ frames: Int64) { self.frames = frames }
    @inlinable public init(integerLiteral value: Int64) { frames = value }

    @inlinable public static func < (a: FramePosition, b: FramePosition) -> Bool { a.frames < b.frames }
    @inlinable public static func + (a: FramePosition, b: Int) -> FramePosition { FramePosition(a.frames + Int64(b)) }
    @inlinable public static func += (a: inout FramePosition, b: Int) { a.frames += Int64(b) }

    @inlinable public func seconds(at rate: SampleRate) -> Double { Double(frames) / rate.hertz }
}

/// A level in decibels, with conversions to and from linear gain and power.
@frozen public struct Decibels: Hashable, Comparable, Sendable, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    public var value: Float

    /// The level reported for silence.
    public static let silence = Decibels(-200)

    @inlinable public init(_ value: Float) { self.value = value }
    @inlinable public init(floatLiteral value: Float) { self.value = value }
    @inlinable public init(integerLiteral value: Int) { self.value = Float(value) }

    /// The level of a linear amplitude gain.
    @inlinable public init(gain: Float) {
        value = gain > 1e-10 ? 20 * log10(gain) : -200
    }

    /// The level of a power, such as a mean square.
    @inlinable public init(power: Float) {
        value = power > 1e-20 ? 10 * log10(power) : -200
    }

    /// Linear amplitude gain.
    @inlinable public var gain: Float { exp(value * 0.115_129_254_649_702_28) }
    /// Linear power gain.
    @inlinable public var power: Float { exp(value * 0.230_258_509_299_404_56) }

    @inlinable public static func < (a: Decibels, b: Decibels) -> Bool { a.value < b.value }
    @inlinable public static func + (a: Decibels, b: Decibels) -> Decibels { Decibels(a.value + b.value) }
    @inlinable public static func - (a: Decibels, b: Decibels) -> Decibels { Decibels(a.value - b.value) }
}

/// How many channels a signal has.
@frozen public struct ChannelLayout: Hashable, Sendable {
    public let channelCount: Int

    @inlinable public init(channelCount: Int) { self.channelCount = max(1, channelCount) }

    public static let mono = ChannelLayout(channelCount: 1)
    public static let stereo = ChannelLayout(channelCount: 2)
    @inlinable public static func discrete(_ channels: Int) -> ChannelLayout { ChannelLayout(channelCount: channels) }
}

/// The rate and channel layout of a signal.
@frozen public struct Format: Hashable, Sendable {
    public var sampleRate: SampleRate
    public var layout: ChannelLayout

    @inlinable public init(sampleRate: SampleRate, layout: ChannelLayout = .stereo) {
        self.sampleRate = sampleRate
        self.layout = layout
    }

    @inlinable public var channelCount: Int { layout.channelCount }
}

/// How a control's travel from 0 to 1 maps onto a range of values. Parameters and controls
/// share this, so a fader and the value it drives always agree.
@frozen public enum Taper: Hashable, Sendable {
    /// Equal travel for equal change in value.
    case linear
    /// Equal travel for equal ratio. Both ends of the range must be above zero.
    case logarithmic
    /// Travel raised to a power. Above 1 gives the low end of the range more room.
    case skewed(Float)

    /// The value at a position from 0 to 1.
    @inlinable public func value(at position: Float, in range: ClosedRange<Float>) -> Float {
        let t = min(max(position, 0), 1)
        switch self {
        case .linear:
            return range.lowerBound + t * (range.upperBound - range.lowerBound)
        case .logarithmic:
            return range.lowerBound * exp(t * log(range.upperBound / range.lowerBound))
        case .skewed(let power):
            guard t > 0 else { return range.lowerBound }
            return range.lowerBound + exp(power * log(t)) * (range.upperBound - range.lowerBound)
        }
    }

    /// The position from 0 to 1 of a value.
    @inlinable public func position(of value: Float, in range: ClosedRange<Float>) -> Float {
        let v = min(max(value, range.lowerBound), range.upperBound)
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        switch self {
        case .linear:
            return (v - range.lowerBound) / span
        case .logarithmic:
            return log(v / range.lowerBound) / log(range.upperBound / range.lowerBound)
        case .skewed(let power):
            let t = (v - range.lowerBound) / span
            return t <= 0 ? 0 : exp(log(t) / power)
        }
    }
}
