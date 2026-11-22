import AudioAppKit
import AudioAppTesting
import Foundation

func sineBuffer(_ frequency: Double, rate: SampleRate = 48_000, frames: Int, amplitude: Float = 0.5, channels: Int = 1) -> AudioBuffer {
    let wave = TestSignal.sine(frequency: frequency, sampleRate: rate, frames: frames, amplitude: amplitude)
    return AudioBuffer([[Float]](repeating: wave, count: channels))
}

/// What a processor does to a steady tone, in decibels, measured once it has settled. Use
/// frequencies that are a whole number of hertz.
func measuredGainDB<P: Processor & ~Copyable>(_ processor: inout P, at frequency: Double, rate: SampleRate = 48_000,
                                              blockSizes: [Int] = [512]) -> Double {
    let frames = 2 * Int(rate.hertz)
    let output = ProcessorHarness.run(&processor, input: sineBuffer(frequency, rate: rate, frames: frames),
                                      sampleRate: rate, blockSizes: blockSizes)
    let settled = Array(output.samples(channel: 0)[(frames / 2)...])
    return 20 * log10(max(Measure.amplitude(of: frequency, in: settled, sampleRate: rate), 1e-12) / 0.5)
}

/// The level of one tone in a signal, and how loud everything else is beside it, in decibels
/// below the tone.
func toneAndResidual(_ samples: [Float], frequency: Double, rate: SampleRate) -> (amplitude: Double, residualDB: Double) {
    var real = 0.0, imaginary = 0.0
    let step = 2 * Double.pi * frequency / rate.hertz
    for (index, sample) in samples.enumerated() {
        real += Double(sample) * cos(step * Double(index))
        imaginary += Double(sample) * sin(step * Double(index))
    }
    let count = Double(samples.count)
    let a = 2 * real / count, b = 2 * imaginary / count
    var residual = 0.0
    for (index, sample) in samples.enumerated() {
        let fit = a * cos(step * Double(index)) + b * sin(step * Double(index))
        residual += (Double(sample) - fit) * (Double(sample) - fit)
    }
    let tone = (a * a + b * b) / 2
    return ((a * a + b * b).squareRoot(), 10 * log10(max(residual / count, 1e-30) / max(tone, 1e-30)))
}

func decibels(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-12)) }

/// Flattens the top of a wave: a simple thing that makes new high frequencies.
struct Clip: Processor, ~Copyable {
    let limit: Float
    mutating func prepare(_ format: Format, maxFrames: Int) {}

    @_noAllocation @_noLocks
    mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        for channel in 0..<io.channelCount {
            let samples = io[channel]
            for frame in 0..<io.frameCount { samples[frame] = min(max(samples[frame], -limit), limit) }
        }
    }
}

/// Leaves every spectrum as it is.
struct SpectralPassthrough: SpectralProcessor, ~Copyable {
    mutating func prepare(fftSize: Int, hop: Int, format: Format) {}

    @_noAllocation @_noLocks
    mutating func process(_ frame: inout SpectralFrame, channel: Int, _ context: borrowing RenderContext) {}
}

/// Silences everything above a frequency.
struct SpectralLowPass: SpectralProcessor, ~Copyable {
    let cutoff: Double
    var firstSilentBin = 0

    mutating func prepare(fftSize: Int, hop: Int, format: Format) {
        firstSilentBin = Int(cutoff / format.sampleRate.hertz * Double(fftSize))
    }

    @_noAllocation @_noLocks
    mutating func process(_ frame: inout SpectralFrame, channel: Int, _ context: borrowing RenderContext) {
        for bin in firstSilentBin..<frame.binCount { frame.scale(bin, by: 0) }
    }
}

// The audio callbacks an app would write around the generic hosts. Each names its types, so
// the compiler checks the whole path; if any of it could allocate or lock, this file does
// not compile.

@_noAllocation @_noLocks
func checked(_ host: inout STFTHost<SpectralLowPass>, _ io: inout AudioBlock, _ context: RenderContext) {
    host.process(&io, context)
}

@_noAllocation @_noLocks
func checked(_ host: inout STFTHost<SpectralPassthrough>, _ io: inout AudioBlock, _ context: RenderContext) {
    host.process(&io, context)
}

@_noAllocation @_noLocks
func checked(_ processor: inout Oversampled<Clip>, _ io: inout AudioBlock, _ context: RenderContext) {
    processor.process(&io, context)
}

@_noAllocation @_noLocks
func checked(_ tap: inout MeterTap<PeakMeter>, _ io: inout AudioBlock, _ context: RenderContext) {
    tap.process(&io, context)
}

@_noAllocation @_noLocks
func checked(_ tap: inout MeterTap<RMSMeter>, _ io: inout AudioBlock, _ context: RenderContext) {
    tap.process(&io, context)
}

@_noAllocation @_noLocks
func checked(_ tap: inout MeterTap<TruePeakMeter>, _ io: inout AudioBlock, _ context: RenderContext) {
    tap.process(&io, context)
}

@_noAllocation @_noLocks
func checked(_ tap: inout MeterTap<LoudnessMeter>, _ io: inout AudioBlock, _ context: RenderContext) {
    tap.process(&io, context)
}

@_noAllocation @_noLocks
func checked(_ tap: inout MeterTap<CorrelationMeter>, _ io: inout AudioBlock, _ context: RenderContext) {
    tap.process(&io, context)
}

@_noAllocation @_noLocks
func checked(_ tap: inout MeterTap<SpectrumAnalyzer>, _ io: inout AudioBlock, _ context: RenderContext) {
    tap.process(&io, context)
}
