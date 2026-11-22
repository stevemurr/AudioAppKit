import AudioAppCore
import AudioAppProcessing
import AudioAppRealtime
import Darwin

/// A reverb tail: several delay lines feeding back into one another through a mixing matrix,
/// so that one echo becomes thousands.
///
/// The decay time is how long the tail takes to fall by 60 dB. Damping makes the highs die
/// away sooner, as they do in a real room. Every channel of the input feeds the network, and
/// the lines are shared out among the output channels so each hears a different tail.
public struct FeedbackDelayNetwork: Processor, ~Copyable {
    /// Seconds for the tail to fall by 60 dB.
    public let decay: Parameter
    /// How much sooner the highs die away, from 0 (not at all) to 1.
    public let damping: Parameter
    /// The share of the output that is reverb, from 0 to 1. Leave at 1 on a send.
    public let mix: Parameter

    public let lineCount: Int
    @usableFromInline let meanDelaySeconds: Double
    @usableFromInline var sampleRate: SampleRate = 48_000
    @usableFromInline var storage: UnsafeMutablePointer<Float>?
    @usableFromInline var lengths: UnsafeMutablePointer<Int>
    @usableFromInline var gains: UnsafeMutablePointer<Float>
    @usableFromInline var damped: UnsafeMutablePointer<Float>
    @usableFromInline var taps: UnsafeMutablePointer<Float>
    @usableFromInline var mask = 0
    @usableFromInline var head = 0
    @usableFromInline var designedDecay: Float = -1

    /// - Parameters:
    ///   - lines: 4, 8 or 16. More lines give a denser, smoother tail.
    ///   - meanDelaySeconds: the average length of a line. Longer suggests a larger space.
    public init(lines: Int = 8, meanDelaySeconds: Double = 0.045) {
        lineCount = lines >= 16 ? 16 : (lines >= 8 ? 8 : 4)
        self.meanDelaySeconds = meanDelaySeconds
        decay = Parameter(id: "decay", name: "Decay", default: 1.5, in: 0.1...30, taper: .logarithmic, unit: .seconds)
        damping = Parameter(id: "damping", name: "Damping", default: 0.3, in: 0...1)
        mix = Parameter(id: "mix", name: "Mix", default: 1, in: 0...1)
        lengths = .allocate(capacity: lineCount)
        lengths.initialize(repeating: 1, count: lineCount)
        gains = Memory.floats(lineCount)
        damped = Memory.floats(lineCount)
        taps = Memory.floats(lineCount)
    }

    deinit {
        storage?.deallocate()
        lengths.deallocate()
        gains.deallocate()
        damped.deallocate()
        taps.deallocate()
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        sampleRate = format.sampleRate
        // Lengths spread from 0.6 to 1.6 times the mean, each moved to a prime so no two
        // lines ever repeat together.
        var longest = 1
        for line in 0..<lineCount {
            let spread = 0.6 * pow(1.6 / 0.6, Double(line) / Double(max(1, lineCount - 1)))
            var length = max(3, sampleRate.frames(in: meanDelaySeconds * spread))
            while !Self.isPrime(length) { length += 1 }
            lengths[line] = length
            longest = max(longest, length)
        }
        var size = 4
        while size < longest + 1 { size <<= 1 }
        storage?.deallocate()
        mask = size - 1
        storage = Memory.floats(size * lineCount)
        designedDecay = -1
        reset()
    }

    private static func isPrime(_ value: Int) -> Bool {
        guard value > 3 else { return value > 1 }
        guard value % 2 != 0 else { return false }
        var divisor = 3
        while divisor * divisor <= value {
            if value % divisor == 0 { return false }
            divisor += 2
        }
        return true
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        guard let storage, io.channelCount > 0 else { return }
        let seconds = decay.value
        if seconds != designedDecay {
            // Each trip round a line loses just enough for the whole to fall 60 dB in time.
            for line in 0..<lineCount {
                gains[line] = exp(-6.907_755_3 * Float(lengths[line]) / (seconds * Float(sampleRate.hertz)))
            }
            designedDecay = seconds
        }
        let smoothing = 0.7 * damping.value
        let wet = mix.value, dry = 1 - wet
        let size = mask + 1
        let channels = io.channelCount
        let spread = 1 / RealtimeMath.sqrt(Float(lineCount))
        // Each output channel hears its own share of the lines, at the level one line in
        // every `channels` would give.
        let outputGain = RealtimeMath.sqrt(Float(channels) / Float(lineCount))
        for frame in 0..<io.frameCount {
            var input: Float = 0
            for channel in 0..<channels { input += io[channel][frame] }
            input /= Float(channels)

            for line in 0..<lineCount {
                let out = storage[line * size + ((head &- lengths[line]) & mask)]
                damped[line] += (1 - smoothing) * (out - damped[line])
                taps[line] = out
            }
            for channel in 0..<channels {
                var sum: Float = 0
                var line = channel
                while line < lineCount {
                    sum += taps[line]
                    line += channels
                }
                io[channel][frame] = dry * io[channel][frame] + wet * outputGain * sum
            }

            // Mix the lines into one another: a Hadamard matrix, built from sums and
            // differences, which spreads each line evenly across all the others.
            for line in 0..<lineCount { taps[line] = damped[line] * gains[line] }
            var width = 1
            while width < lineCount {
                var start = 0
                while start < lineCount {
                    for index in start..<(start + width) {
                        let a = taps[index], b = taps[index + width]
                        taps[index] = a + b
                        taps[index + width] = a - b
                    }
                    start += 2 * width
                }
                width *= 2
            }
            head = (head &+ 1) & mask
            for line in 0..<lineCount {
                // Alternate the sign of the input so the lines do not all start in step.
                let feed = (line & 1) == 0 ? input : -input
                storage[line * size + head] = feed + spread * taps[line]
            }
        }
    }

    public mutating func reset() {
        if let storage { Memory.zero(storage, (mask + 1) * lineCount) }
        Memory.zero(damped, lineCount)
        head = 0
    }
}
