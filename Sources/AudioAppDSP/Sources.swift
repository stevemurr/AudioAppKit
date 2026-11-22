import AudioAppCore
import AudioAppProcessing
import Darwin

/// Makes a steady tone. It replaces whatever is in the block, writing the same signal to
/// every channel.
///
/// Saw and square are rounded at their jumps so their harmonics do not fold back as noise.
/// The triangle is drawn directly; its harmonics are already quiet.
public struct Oscillator: Processor, ~Copyable {
    @frozen public enum Waveform: Hashable, Sendable {
        case sine, saw, square, triangle
    }

    public let waveform: Waveform
    public let frequency: Parameter
    /// The peak level in decibels.
    public let level: Parameter
    @usableFromInline var sampleRate: SampleRate = 48_000
    /// Where the wave is in its cycle, from 0 to 1.
    @usableFromInline var phase = 0.0
    @usableFromInline var gain = Smoothed(1)

    public init(_ waveform: Waveform = .sine, frequency: Float = 440, level: Float = -12) {
        self.waveform = waveform
        self.frequency = Parameter(id: "frequency", name: "Frequency", default: frequency, in: 1...24_000,
                                   taper: .logarithmic, unit: .hertz)
        self.level = Parameter(id: "level", name: "Level", default: level, in: -100...0, unit: .decibels)
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        sampleRate = format.sampleRate
        gain.configure(sampleRate: sampleRate, seconds: 0.01)
        gain.snap(to: Decibels(level.value).gain)
        phase = 0
    }

    /// The correction that rounds off a jump at phase 0, for a wave stepping `step` per sample.
    @_noAllocation @_noLocks
    @inlinable static func blep(_ phase: Double, _ step: Double) -> Double {
        if phase < step {
            let t = phase / step
            return t + t - t * t - 1
        }
        if phase > 1 - step {
            let t = (phase - 1) / step
            return t * t + t + t + 1
        }
        return 0
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        guard io.channelCount > 0 else { return }
        gain.set(Decibels(level.value).gain)
        let step = min(Double(frequency.value), 0.49 * sampleRate.hertz) / sampleRate.hertz
        let first = io[0]
        for frame in 0..<io.frameCount {
            var value: Double
            switch waveform {
            case .sine:
                value = sin(2 * Double.pi * phase)
            case .saw:
                value = 2 * phase - 1 - Self.blep(phase, step)
            case .square:
                let half = phase < 0.5 ? phase + 0.5 : phase - 0.5
                value = (phase < 0.5 ? 1 : -1) + Self.blep(phase, step) - Self.blep(half, step)
            case .triangle:
                value = phase < 0.5 ? 4 * phase - 1 : 3 - 4 * phase
            }
            value *= Double(gain.next())
            first[frame] = Float(value)
            phase += step
            if phase >= 1 { phase -= 1 }
        }
        for channel in 1..<max(1, io.channelCount) {
            let samples = io[channel]
            for frame in 0..<io.frameCount { samples[frame] = first[frame] }
        }
    }

    public mutating func reset() { phase = 0 }
}

/// Makes noise. It replaces whatever is in the block, writing the same signal to every
/// channel. White noise has equal power at every frequency; pink has equal power in every
/// octave, which is closer to how music is spread.
public struct NoiseSource: Processor, ~Copyable {
    @frozen public enum Color: Hashable, Sendable {
        case white, pink
    }

    public let color: Color
    /// The level in decibels: the peak of white noise. Pink noise at the same level is as loud
    /// on average, with higher peaks.
    public let level: Parameter
    @usableFromInline var random: UInt64
    @usableFromInline var gain = Smoothed(1)
    /// Pink noise is a stack of smoothed white noises an octave apart.
    @usableFromInline var stages: UnsafeMutablePointer<Float>?
    @usableFromInline var coefficients: UnsafeMutablePointer<Float>?
    @usableFromInline var weights: UnsafeMutablePointer<Float>?
    @usableFromInline var stageCount = 0

    public init(_ color: Color = .white, level: Float = -12, seed: UInt64 = 1) {
        self.color = color
        self.level = Parameter(id: "level", name: "Level", default: level, in: -100...0, unit: .decibels)
        random = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    deinit {
        stages?.deallocate()
        coefficients?.deallocate()
        weights?.deallocate()
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        gain.configure(sampleRate: format.sampleRate, seconds: 0.01)
        gain.snap(to: Decibels(level.value).gain)
        stages?.deallocate()
        coefficients?.deallocate()
        weights?.deallocate()
        // One smoothing stage per octave, from a quarter of the sample rate down to 10 Hz.
        var corners: [Double] = []
        var corner = format.sampleRate.hertz / 4
        while corner > 10 {
            corners.append(corner)
            corner /= 2
        }
        stageCount = corners.count
        stages = Memory.floats(stageCount)
        coefficients = Memory.floats(stageCount)
        weights = Memory.floats(stageCount)
        // Below its corner a stage passes white noise at full level, so weighting each stage's
        // power by one over its corner makes the stack fall 3 dB per octave. The whole is then
        // scaled to be as loud as white noise at the same level.
        var total = 0.0
        var kept: [Double] = []
        for hertz in corners {
            let pole = exp(-2 * Double.pi * hertz / format.sampleRate.hertz)
            // A smoothed white noise keeps (1 - pole) / (1 + pole) of its power.
            kept.append((1 - pole) / (1 + pole))
            total += kept.last! / hertz
        }
        for (index, hertz) in corners.enumerated() {
            coefficients![index] = Float(2 * kept[index] / (1 + kept[index]))
            weights![index] = Float((1 / hertz / total).squareRoot())
        }
    }

    /// The next white sample, from -1 to 1.
    @_noAllocation @_noLocks
    @inlinable mutating func white() -> Float {
        random ^= random << 13
        random ^= random >> 7
        random ^= random << 17
        return Float(random >> 40) * (1 / 8_388_608) - 1
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        guard io.channelCount > 0 else { return }
        gain.set(Decibels(level.value).gain)
        let first = io[0]
        if case .pink = color, let stages, let coefficients, let weights {
            for frame in 0..<io.frameCount {
                var sum: Float = 0
                for stage in 0..<stageCount {
                    stages[stage] += coefficients[stage] * (white() - stages[stage])
                    sum += weights[stage] * stages[stage]
                }
                first[frame] = sum * gain.next()
            }
        } else {
            for frame in 0..<io.frameCount { first[frame] = white() * gain.next() }
        }
        for channel in 1..<max(1, io.channelCount) {
            let samples = io[channel]
            for frame in 0..<io.frameCount { samples[frame] = first[frame] }
        }
    }

    public mutating func reset() {
        if let stages { Memory.zero(stages, stageCount) }
    }
}
