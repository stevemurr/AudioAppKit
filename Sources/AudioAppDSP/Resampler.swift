import AudioAppCore
import Darwin

/// Converts one channel of audio from one sample rate to another, at any ratio, as a stream.
///
/// It keeps everything below the lower of the two rates' limits and removes what would
/// otherwise fold back as false tones. Feed it input in pieces of any size; it produces
/// output as it can. Use one resampler per channel.
///
/// The filter table is built when the resampler is made, so make it away from the audio
/// thread.
public struct Resampler: ~Copyable {
    public let inputRate: SampleRate
    public let outputRate: SampleRate
    /// How many input frames late the output is.
    public let latencyFrames: Int

    /// The filter is stored at this many positions between samples, and read between those.
    @inlinable static var phases: Int { 512 }
    @usableFromInline let width: Int
    @usableFromInline let step: Double
    /// `phases + 1` filters of `width` taps each.
    @usableFromInline let table: UnsafeMutablePointer<Float>
    /// The last `width` input samples, stored twice over so they can be read in one run.
    @usableFromInline let history: UnsafeMutablePointer<Float>
    @usableFromInline var writeIndex = 0
    /// How far past the newest centred input sample the next output sits, in input samples.
    @usableFromInline var phase = 0.0

    /// - Parameter quality: taps per filter when not slowing the rate; more keeps more of the
    ///   top octave. Rounded up to an even number.
    public init(from inputRate: SampleRate, to outputRate: SampleRate, quality: Int = 96) {
        self.inputRate = inputRate
        self.outputRate = outputRate
        step = inputRate.hertz / outputRate.hertz
        // Lowering the rate needs a lower cutoff, and so a proportionally longer filter.
        let scale = min(1, outputRate.hertz / inputRate.hertz)
        var taps = Int((Double(max(8, quality)) / scale).rounded(.up))
        taps += taps & 1
        width = min(taps, 2_048)
        latencyFrames = width / 2
        let beta = 9.0
        // The distance from full level to silence, in cycles per input sample, for this
        // window and length. The cutoff sits so that silence is reached by the lower limit.
        let transition = (90.0 - 8) / (2.285 * 2 * Double.pi * Double(width))
        let cutoff = max(0.5 * scale - transition / 2, 0.05 * scale)
        let phases = Self.phases
        table = Memory.floats((phases + 1) * width)
        let centre = Double(width / 2 - 1)
        for index in 0...phases {
            let fraction = Double(index) / Double(phases)
            var sum = 0.0
            var taps = [Double](repeating: 0, count: width)
            for tap in 0..<width {
                taps[tap] = SincDesign.lowPass(at: Double(tap) - centre - fraction, cutoff: cutoff,
                                               halfWidth: Double(width / 2), beta: beta)
                sum += taps[tap]
            }
            for tap in 0..<width { table[index * width + tap] = Float(taps[tap] / sum) }
        }
        history = Memory.floats(2 * width)
    }

    deinit {
        table.deallocate()
        history.deallocate()
    }

    /// Output frames made for each input frame.
    public var ratio: Double { outputRate.hertz / inputRate.hertz }

    /// Converts as much as it can: until the input runs out or the output is full. Returns
    /// how many input frames it used and how many output frames it made. Call again with the
    /// unused input when the output was the limit.
    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ input: UnsafeBufferPointer<Float>,
                                            into output: UnsafeMutableBufferPointer<Float>) -> (consumed: Int, produced: Int) {
        var consumed = 0, produced = 0
        let phases = Double(Self.phases)
        while produced < output.count {
            while phase >= 1 {
                guard consumed < input.count else { return (consumed, produced) }
                history[writeIndex] = input[consumed]
                history[writeIndex + width] = input[consumed]
                writeIndex += 1
                if writeIndex == width { writeIndex = 0 }
                consumed += 1
                phase -= 1
            }
            let position = phase * phases
            let index = Int(position)
            let blend = Float(position - Double(index))
            let near = table + index * width, far = table + (index + 1) * width
            let window = history + writeIndex
            var a: Float = 0, b: Float = 0
            for tap in 0..<width {
                a += window[tap] * near[tap]
                b += window[tap] * far[tap]
            }
            output[produced] = a + blend * (b - a)
            produced += 1
            phase += step
        }
        return (consumed, produced)
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func reset() {
        Memory.zero(history, 2 * width)
        writeIndex = 0
        phase = 0
    }
}
