import AudioAppKit
import Darwin

/// Signals to feed a processor in a test.
public enum TestSignal {
    public static func sine(frequency: Double, sampleRate: SampleRate, frames: Int, amplitude: Float = 1) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate.hertz)) }
    }

    /// A single full-scale sample followed by silence.
    public static func impulse(frames: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        if frames > 0 { samples[0] = 1 }
        return samples
    }

    /// White noise that is the same on every run.
    public static func noise(frames: Int, amplitude: Float = 1, seed: UInt64 = 1) -> [Float] {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        return (0..<frames).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return amplitude * (Float(state >> 40) / Float(1 << 23) - 1)
        }
    }

    public static func silence(frames: Int) -> [Float] { [Float](repeating: 0, count: frames) }
}

/// Measurements of what came out.
public enum Measure {
    public static func peak(_ samples: [Float]) -> Float { samples.reduce(0) { max($0, abs($1)) } }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// The amplitude of one frequency in a signal. Use a whole number of cycles, and skip any
    /// start-up transient, for an exact answer.
    public static func amplitude(of frequency: Double, in samples: [Float], sampleRate: SampleRate) -> Double {
        guard !samples.isEmpty else { return 0 }
        var real = 0.0, imaginary = 0.0
        for (index, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate.hertz
            real += Double(sample) * cos(phase)
            imaginary += Double(sample) * sin(phase)
        }
        return 2 * (real * real + imaginary * imaginary).squareRoot() / Double(samples.count)
    }

    public static func isFinite(_ samples: [Float]) -> Bool { samples.allSatisfy(\.isFinite) }
}

/// Drives a processor the way a host would.
public enum ProcessorHarness {
    /// Prepares a processor and runs audio through it in blocks of varying length, cycling
    /// through `blockSizes`. Returns the output.
    public static func run<P: Processor & ~Copyable>(_ processor: inout P, input: AudioBuffer, sampleRate: SampleRate,
                                                    blockSizes: [Int] = [512]) -> AudioBuffer {
        let sizes = blockSizes.filter { $0 > 0 }.isEmpty ? [512] : blockSizes.filter { $0 > 0 }
        let format = Format(sampleRate: sampleRate, layout: .discrete(input.channelCount))
        processor.prepare(format, maxFrames: sizes.max()!)
        let output = AudioBuffer(channelCount: input.channelCount, frameCapacity: input.frameCapacity)
        output.block.copy(from: input.block)
        var done = 0, turn = 0
        while done < input.frameCapacity {
            let frames = min(sizes[turn % sizes.count], input.frameCapacity - done)
            var block = output.block(from: done, frames: frames)
            processor.process(&block, RenderContext(sampleRate: sampleRate, position: FramePosition(Int64(done)), isOffline: true))
            done += frames
            turn += 1
        }
        return output
    }

    /// Runs a prepared processor over noise under the probe and reports any heap activity.
    /// Prepare the processor first, with `maxFrames` of at least `blockSize`.
    public static func heapActivity<P: Processor & ~Copyable>(_ processor: inout P, channelCount: Int = 2, sampleRate: SampleRate,
                                                             blockSize: Int = 512, blocks: Int = 50) -> RealtimeProbe.Report {
        let buffer = AudioBuffer((0..<channelCount).map { TestSignal.noise(frames: blockSize, amplitude: 0.5, seed: UInt64($0 + 1)) })
        var block = buffer.block
        let context = RenderContext(sampleRate: sampleRate, isOffline: true)
        return RealtimeProbe.measure {
            // A `while` loop, because in a debug build a `for` loop over a range allocates.
            var done = 0
            while done < blocks {
                processor.process(&block, context)
                done += 1
            }
        }
    }
}
