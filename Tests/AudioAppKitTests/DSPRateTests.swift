import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

/// Reports the format it was prepared with.
private final class Seen: @unchecked Sendable {
    var rate = 0.0
    var maxFrames = 0
    var contextRate = 0.0
}

private struct Spy: Processor, ~Copyable {
    let seen: Seen
    mutating func prepare(_ format: Format, maxFrames: Int) {
        seen.rate = format.sampleRate.hertz
        seen.maxFrames = maxFrames
    }

    mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        seen.contextRate = context.sampleRate.hertz
    }
}

@Suite struct DSPRateTests {
    /// Runs a whole signal through a resampler in pieces.
    private func resample(_ input: [Float], with resampler: inout Resampler, chunk: Int = 4_096) -> [Float] {
        var output = [Float](repeating: 0, count: Int(Double(input.count) * resampler.ratio) + 64)
        var consumed = 0, produced = 0
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                while consumed < input.count, produced < target.count {
                    let take = min(chunk, input.count - consumed)
                    let result = resampler.process(UnsafeBufferPointer(rebasing: source[consumed..<(consumed + take)]),
                                                   into: UnsafeMutableBufferPointer(rebasing: target[produced...]))
                    consumed += result.consumed
                    produced += result.produced
                    if result.consumed == 0, result.produced == 0 { break }
                }
            }
        }
        return Array(output[..<produced])
    }

    @Test(arguments: [(44_100.0, 48_000.0), (48_000.0, 44_100.0), (48_000.0, 96_000.0), (44_100.0, 32_000.0)])
    func aToneKeepsItsLevelAndGainsNothing(from: Double, to: Double) {
        var resampler = Resampler(from: SampleRate(from), to: SampleRate(to))
        let input = TestSignal.sine(frequency: 1_000, sampleRate: SampleRate(from), frames: Int(from), amplitude: 0.5)
        let output = resample(input, with: &resampler)
        #expect(abs(output.count - Int(to)) <= 2)
        // Skip the start, where the filter is filling, and measure whole cycles.
        let settled = Array(output[4_000..<(4_000 + Int(to) / 2)])
        let tone = toneAndResidual(settled, frequency: 1_000, rate: SampleRate(to))
        #expect(close(decibels(tone.amplitude / 0.5), 0, within: 0.01))
        #expect(tone.residualDB < -85, "everything else is \(tone.residualDB) dB down")
    }

    @Test func aToneNearTheTopOfTheBandSurvives() {
        var resampler = Resampler(from: 44_100, to: 48_000)
        let input = TestSignal.sine(frequency: 16_000, sampleRate: 44_100, frames: 44_100, amplitude: 0.5)
        let output = resample(input, with: &resampler)
        let tone = toneAndResidual(Array(output[4_000..<28_000]), frequency: 16_000, rate: 48_000)
        #expect(close(decibels(tone.amplitude / 0.5), 0, within: 0.05))
        #expect(tone.residualDB < -80)
    }

    @Test func loweringTheRateRemovesWhatWouldFoldBack() {
        // 30 kHz cannot exist at 48 kHz. Left in, it would fold back to 18 kHz.
        var resampler = Resampler(from: 96_000, to: 48_000)
        let input = TestSignal.sine(frequency: 30_000, sampleRate: 96_000, frames: 96_000, amplitude: 0.5)
        let output = resample(input, with: &resampler)
        #expect(decibels(Double(Measure.rms(Array(output[4_000...]))) / 0.3536) < -80)

        var again = Resampler(from: 96_000, to: 48_000)
        let low = resample(TestSignal.sine(frequency: 10_000, sampleRate: 96_000, frames: 96_000, amplitude: 0.5), with: &again)
        let tone = toneAndResidual(Array(low[4_000..<28_000]), frequency: 10_000, rate: 48_000)
        #expect(close(decibels(tone.amplitude / 0.5), 0, within: 0.02))
    }

    @Test func theSizeOfThePiecesDoesNotChangeTheResult() {
        let noise = TestSignal.noise(frames: 20_000, amplitude: 0.5, seed: 11)
        var a = Resampler(from: 44_100, to: 48_000)
        var b = Resampler(from: 44_100, to: 48_000)
        let whole = resample(noise, with: &a, chunk: 20_000)
        let pieces = resample(noise, with: &b, chunk: 173)
        #expect(whole == pieces)
        // After a reset it starts again from nothing.
        b.reset()
        #expect(resample(noise, with: &b, chunk: 999) == whole)
    }

    @Test func theResamplerReportsItsDelay() {
        var resampler = Resampler(from: 48_000, to: 48_000, quality: 64)
        #expect(resampler.latencyFrames == 32)
        var input = [Float](repeating: 0, count: 2_000)
        input[500] = 1
        let output = resample(input, with: &resampler)
        let peak = output.firstIndex(of: output.max()!)!
        #expect(abs(peak - (500 + resampler.latencyFrames)) <= 1)
        // The filter stops a little short of the top of the band, so a single sample comes
        // out slightly spread.
        #expect(output[peak] > 0.85 && output[peak] <= 1)
        #expect(close(output.reduce(0, +), 1, within: 1e-3))
    }

    @Test func theResamplerStaysOffTheHeap() {
        var resampler = Resampler(from: 44_100, to: 48_000)
        let input = TestSignal.noise(frames: 441)
        var output = [Float](repeating: 0, count: 600)
        var made = 0
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                let report = RealtimeProbe.measure {
                    var turn = 0
                    while turn < 100 {
                        made += resampler.process(source, into: target).produced
                        turn += 1
                    }
                }
                #expect(report.isClean, "\(report)")
            }
        }
        #expect(abs(made - 48_000) <= 2)
    }

    @Test(arguments: [2, 4])
    func oversamplingLeavesTheAudioBandAloneAndReportsItsDelay(factor: Int) {
        var wrapped = Oversampled(Gain(), factor: factor)
        #expect(wrapped.factor == factor)
        for frequency in [100.0, 1_000, 10_000, 18_000] {
            #expect(close(measuredGainDB(&wrapped, at: frequency, blockSizes: [64, 1, 301]), 0, within: 0.05), "\(frequency) Hz")
        }
        let impulse = TestSignal.impulse(frames: 512)
        let output = ProcessorHarness.run(&wrapped, input: AudioBuffer([impulse]), sampleRate: 48_000, blockSizes: [100])
        let result = output.samples(channel: 0)
        #expect(result.firstIndex(of: result.max()!) == wrapped.latencyFrames)
        #expect(wrapped.latencyFrames == (factor == 2 ? 31 : 39))
        #expect(close(result.max()!, 1, within: 0.05))
    }

    @Test func theInnerProcessorRunsAtTheHigherRate() {
        let seen = Seen()
        var wrapped = Oversampled(Spy(seen: seen), factor: 4)
        let output = ProcessorHarness.run(&wrapped, input: AudioBuffer(channelCount: 2, frameCapacity: 256), sampleRate: 48_000,
                                          blockSizes: [128])
        #expect(seen.rate == 192_000)
        #expect(seen.maxFrames == 512)
        #expect(seen.contextRate == 192_000)
        #expect(output.samples(channel: 1).allSatisfy { $0 == 0 })
    }

    @Test func oversamplingKeepsAClippersNewHighsFromFoldingBack() {
        // Clipping a 5 kHz tone makes a seventh harmonic at 35 kHz, which at 48 kHz folds
        // back to 13 kHz: a tone that was never played.
        let rate: SampleRate = 48_000
        func folded(_ run: (AudioBuffer) -> AudioBuffer) -> Double {
            let output = run(sineBuffer(5_000, frames: 48_000, amplitude: 1))
            return Measure.amplitude(of: 13_000, in: Array(output.samples(channel: 0)[24_000...]), sampleRate: rate)
        }
        let plain = folded { input in
            var clip = Clip(limit: 0.5)
            return ProcessorHarness.run(&clip, input: input, sampleRate: rate)
        }
        let oversampled = folded { input in
            var clip = Oversampled(Clip(limit: 0.5), factor: 4)
            return ProcessorHarness.run(&clip, input: input, sampleRate: rate)
        }
        #expect(plain > 0.005)
        // A clipper's harmonics never end, so some still fold back from above four times the
        // rate. They are far weaker.
        #expect(decibels(oversampled / plain) < -20)
    }

    @Test func oversamplingStaysOffTheHeapAndResets() {
        var wrapped = Oversampled(Clip(limit: 0.3), factor: 4)
        wrapped.prepare(stereo48, maxFrames: 256)
        // Longer than the limit it was prepared for, so it must work in pieces.
        let buffer = AudioBuffer([TestSignal.noise(frames: 600), TestSignal.noise(frames: 600, seed: 2)])
        var block = buffer.block
        let report = RealtimeProbe.measure {
            var turn = 0
            while turn < 50 {
                checked(&wrapped, &block, offline48)
                turn += 1
            }
        }
        #expect(report.isClean, "\(report)")
        #expect(Measure.isFinite(buffer.samples(channel: 0)))

        wrapped.reset()
        let quiet = AudioBuffer(channelCount: 2, frameCapacity: 256)
        var silent = quiet.block
        wrapped.process(&silent, offline48)
        #expect(quiet.samples(channel: 0).allSatisfy { $0 == 0 })
    }
}
