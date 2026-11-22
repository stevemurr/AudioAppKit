import Foundation
import AudioAppKit
import AudioAppTesting
import Testing

@Suite struct DSPTests {
    @Test func gainSetsLevel() {
        var gain = Gain()
        gain.level.value = -6.0206
        let input = SampleBuffer([[Float](repeating: 1, count: 256), [Float](repeating: -1, count: 256)])
        let output = ProcessorHarness.run(&gain, input: input, sampleRate: 48_000)
        #expect(close(output.samples(channel: 0)[255], 0.5, within: 1e-4))
        #expect(close(output.samples(channel: 1)[255], -0.5, within: 1e-4))
    }

    @Test func gainGlidesToANewLevelWithoutAStep() {
        var gain = Gain(glideSeconds: 0.02)
        let format = Format(sampleRate: 48_000, layout: .stereo)
        gain.prepare(format, maxFrames: 512)
        gain.level.value = -12
        let buffer = SampleBuffer([[Float](repeating: 1, count: 2_048), [Float](repeating: 1, count: 2_048)])
        for start in stride(from: 0, to: 2_048, by: 512) {
            var block = buffer.block(from: start, frames: 512)
            gain.process(&block, offline48)
        }
        let left = buffer.samples(channel: 0)
        let target = Decibels(-12).gain
        // 20 ms at 48 kHz is 960 frames, so the glide crosses a block boundary.
        let steps = zip(left, left.dropFirst()).map { $0 - $1 }
        #expect(steps.allSatisfy { $0 >= 0 })
        #expect(steps.max()! < 2 * (1 - target) / 960)
        #expect(left[0] < 1 && left[0] > 0.99)
        #expect(left[959] == target)
        #expect(left[2_047] == target)
        #expect(buffer.samples(channel: 1) == left)
    }

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func peakFilterMatchesItsDesign(rate: Double) {
        let sampleRate = SampleRate(rate)
        let design = BiquadCoefficients.design(.peak, frequency: 1_000, gain: 6, q: 1, sampleRate: sampleRate)
        #expect(close(design.magnitudeDB(at: 1_000, sampleRate: sampleRate), 6, within: 0.01))
        #expect(close(design.magnitudeDB(at: 20, sampleRate: sampleRate), 0, within: 0.05))

        for frequency in [100.0, 500, 1_000, 2_000, 8_000] {
            var filter = Biquad(.peak, frequency: 1_000, gain: 6, q: 1)
            let frames = Int(rate)
            let input = SampleBuffer([TestSignal.sine(frequency: frequency, sampleRate: sampleRate, frames: frames, amplitude: 0.5)])
            let output = ProcessorHarness.run(&filter, input: input, sampleRate: sampleRate, blockSizes: [64, 1, 333])
            // Measure the second half, after the filter has settled, over whole cycles.
            let settled = Array(output.samples(channel: 0)[(frames / 2)...])
            let measured = 20 * log10(Measure.amplitude(of: frequency, in: settled, sampleRate: sampleRate) / 0.5)
            #expect(close(measured, design.magnitudeDB(at: frequency, sampleRate: sampleRate), within: 0.02),
                    "\(frequency) Hz at \(rate)")
        }
    }

    @Test func eachResponseDoesWhatItsNameSays() {
        let rate: SampleRate = 48_000
        func level(_ response: FilterResponse, _ frequency: Double, gain: Double = 0) -> Double {
            BiquadCoefficients.design(response, frequency: 1_000, gain: gain, sampleRate: rate).magnitudeDB(at: frequency, sampleRate: rate)
        }
        #expect(close(level(.lowPass, 1_000), -3.01, within: 0.02))
        #expect(close(level(.lowPass, 20), 0, within: 0.01))
        #expect(level(.lowPass, 10_000) < -35)
        #expect(close(level(.highPass, 1_000), -3.01, within: 0.02))
        #expect(level(.highPass, 100) < -35)
        #expect(level(.notch, 1_000) < -100)
        #expect(close(level(.lowShelf, 20, gain: 6), 6, within: 0.05))
        #expect(close(level(.lowShelf, 20_000, gain: 6), 0, within: 0.05))
        #expect(close(level(.lowShelf, 1_000, gain: 6), 3, within: 0.05))
        #expect(close(level(.highShelf, 20_000, gain: -6), -6, within: 0.05))
        #expect(close(level(.highShelf, 20, gain: -6), 0, within: 0.05))
    }

    @Test func filterOutputDoesNotDependOnBlockSize() {
        let noise = TestSignal.noise(frames: 4_800, amplitude: 0.5)
        var a = Biquad(.lowShelf, frequency: 200, gain: 4)
        var b = Biquad(.lowShelf, frequency: 200, gain: 4)
        let whole = ProcessorHarness.run(&a, input: SampleBuffer([noise, noise]), sampleRate: 48_000, blockSizes: [4_800])
        let pieces = ProcessorHarness.run(&b, input: SampleBuffer([noise, noise]), sampleRate: 48_000, blockSizes: [1, 7, 512, 64])
        #expect(whole.samples(channel: 0) == pieces.samples(channel: 0))
        #expect(whole.samples(channel: 1) == pieces.samples(channel: 0))
    }

    @Test func filterFollowsItsParametersAndResets() {
        var filter = Biquad(.peak, frequency: 1_000, gain: 0, q: 1)
        let rate: SampleRate = 48_000
        filter.prepare(Format(sampleRate: rate, layout: .mono), maxFrames: 4_800)
        func pass() -> Double {
            let buffer = SampleBuffer([TestSignal.sine(frequency: 1_000, sampleRate: rate, frames: 4_800, amplitude: 0.5)])
            var block = buffer.block
            filter.process(&block, offline48)
            return 20 * log10(Measure.amplitude(of: 1_000, in: Array(buffer.samples(channel: 0)[2_400...]), sampleRate: rate) / 0.5)
        }
        #expect(close(pass(), 0, within: 0.01))
        filter.gain.value = -9
        #expect(close(pass(), -9, within: 0.05))

        // After a reset, silence in gives exact silence out.
        filter.reset()
        let quiet = SampleBuffer([TestSignal.silence(frames: 64)])
        var block = quiet.block
        filter.process(&block, offline48)
        #expect(quiet.samples(channel: 0).allSatisfy { $0 == 0 })
    }

    @Test func processorsStayOffTheHeap() {
        let format = Format(sampleRate: 48_000, layout: .stereo)
        var gain = Gain()
        gain.prepare(format, maxFrames: 512)
        gain.level.value = -3
        #expect(ProcessorHarness.heapActivity(&gain, sampleRate: 48_000).isClean)

        var filter = Biquad(.highShelf, frequency: 4_000, gain: 3)
        filter.prepare(format, maxFrames: 512)
        filter.frequency.value = 6_000
        #expect(ProcessorHarness.heapActivity(&filter, sampleRate: 48_000).isClean)

        var chain = Chain(Biquad(.highPass, frequency: 80), Gain())
        chain.prepare(format, maxFrames: 512)
        #expect(ProcessorHarness.heapActivity(&chain, sampleRate: 48_000).isClean)
    }

    @Test func chainRunsBothInOrder() {
        var chain = Chain(Offset(value: 1), Gain())
        chain.second.level.value = -6.0206
        let output = ProcessorHarness.run(&chain, input: SampleBuffer([[1, 1, 1, 1]]), sampleRate: 48_000)
        #expect(close(output.samples(channel: 0)[3], 1, within: 1e-4))
    }

    @Test func parameterClampsAndFollowsItsTaper() {
        let frequency = Parameter(id: "f", default: 1_000, in: 20...20_000, taper: .logarithmic, unit: .hertz)
        frequency.value = 50_000
        #expect(frequency.value == 20_000)
        frequency.position = 0.5
        #expect(close(frequency.value, 632.46, within: 0.1))
        frequency.resetToDefault()
        #expect(frequency.value == 1_000)
        #expect(frequency.name == "f")
    }
}
