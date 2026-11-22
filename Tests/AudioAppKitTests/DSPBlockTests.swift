import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

@Suite struct DSPBlockTests {
    @Test(arguments: [FilterResponse.lowPass, .highPass, .peak, .lowShelf, .highShelf])
    func stateVariableFilterMatchesTheSameDesignAsTheBiquad(response: FilterResponse) {
        let rate: SampleRate = 48_000
        let design = BiquadCoefficients.design(response, frequency: 1_000, gain: 6, q: 1, sampleRate: rate)
        for frequency in [100.0, 500, 1_000, 3_000, 10_000] {
            var filter = StateVariableFilter(response, frequency: 1_000, gain: 6, q: 1)
            let measured = measuredGainDB(&filter, at: frequency, blockSizes: [64, 7, 300])
            #expect(close(measured, design.magnitudeDB(at: frequency, sampleRate: rate), within: 0.05), "\(response) at \(frequency) Hz")
        }
    }

    @Test func stateVariableNotchRemovesItsFrequency() {
        var filter = StateVariableFilter(.notch, frequency: 1_000, q: 2)
        #expect(measuredGainDB(&filter, at: 1_000) < -60)
        var again = StateVariableFilter(.notch, frequency: 1_000, q: 2)
        #expect(close(measuredGainDB(&again, at: 100), 0, within: 0.1))
    }

    @Test func stateVariableFilterGlidesWhenSweptAndStaysBounded() {
        var filter = StateVariableFilter(.lowPass, frequency: 200, q: 4)
        filter.prepare(Format(sampleRate: 48_000, layout: .mono), maxFrames: 256)
        let input = TestSignal.sine(frequency: 100, sampleRate: 48_000, frames: 48_000, amplitude: 0.5)
        let buffer = AudioBuffer([input])
        var start = 0
        var turn = 0
        while start < 48_000 {
            // A new frequency every block, jumping across six octaves.
            filter.frequency.value = turn % 2 == 0 ? 12_000 : 150
            var block = buffer.block(from: start, frames: 256)
            filter.process(&block, offline48)
            start += 256
            turn += 1
        }
        let output = buffer.samples(channel: 0)
        #expect(Measure.isFinite(output))
        #expect(Measure.peak(output) < 1)
        // A 100 Hz sine moves 0.0065 per sample at most. A click would be far larger.
        let largestStep = zip(output, output.dropFirst()).map { abs($0 - $1) }.max()!
        #expect(largestStep < 0.02)
    }

    @Test func onePoleHasItsCutoffAndItsTime() {
        var filter = OnePole()
        filter.setCutoff(1_000, sampleRate: 48_000)
        let wave = TestSignal.sine(frequency: 1_000, sampleRate: 48_000, frames: 48_000, amplitude: 0.5)
        let low = wave.map { filter.lowPass($0) }
        #expect(close(decibels(Measure.amplitude(of: 1_000, in: Array(low[24_000...]), sampleRate: 48_000) / 0.5), -3.01, within: 0.15))

        var smoother = OnePole()
        smoother.setTime(seconds: 0.01, sampleRate: 48_000)
        var value: Float = 0
        for _ in 0..<480 { value = smoother.lowPass(1) }
        #expect(close(value, 1 - exp(-1), within: 0.002))
        smoother.reset(to: 0.25)
        #expect(smoother.lowPass(0.25) == 0.25)

        var high = OnePole()
        high.setCutoff(1_000, sampleRate: 48_000)
        #expect(abs(high.highPass(1)) < 1)
        var settled: Float = 1
        for _ in 0..<4_800 { settled = high.highPass(1) }
        #expect(abs(settled) < 1e-4)
    }

    @Test func allpassKeepsLevelAndTurnsPhaseAQuarterAtItsCorner() {
        for frequency in [100.0, 1_000, 8_000] {
            var filter = Allpass()
            filter.setCorner(1_000, sampleRate: 48_000)
            let wave = TestSignal.sine(frequency: frequency, sampleRate: 48_000, frames: 48_000, amplitude: 0.5)
            let output = wave.map { filter.process($0) }
            let level = Measure.amplitude(of: frequency, in: Array(output[24_000...]), sampleRate: 48_000)
            #expect(close(decibels(level / 0.5), 0, within: 0.01))
            if frequency == 1_000 {
                // A quarter turn puts the output at right angles to the input.
                let dot = zip(wave[24_000...], output[24_000...]).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
                #expect(abs(dot) / 24_000 < 1e-4)
            }
        }
    }

    @Test func delayLineReadsWholeAndPartSamples() {
        var line = DelayLine(maxDelayFrames: 100)
        var whole: [Float] = [], linear: [Float] = []
        for index in 0..<200 {
            line.write(Float(index))
            whole.append(line.read(delay: 37))
            linear.append(line.readLinear(delay: 2.5))
        }
        #expect(whole[36] == 0)
        #expect(whole[150] == 113)
        #expect(line.read(delay: 0) == 199)
        // A ramp lies on a straight line, so a straight-line read of it is exact.
        #expect(linear[150] == 147.5)
        #expect(line.read(delay: 5_000) == line.read(delay: 100))

        // On a high tone, the curved read is closer to the truth than the straight one.
        var tone = DelayLine(maxDelayFrames: 64)
        let rate: SampleRate = 48_000
        var straight = 0.0, curved = 0.0
        for index in 0..<4_800 {
            tone.write(Float(sin(2 * Double.pi * 6_000 * Double(index) / rate.hertz)))
            guard index > 100 else { continue }
            let truth = sin(2 * Double.pi * 6_000 * (Double(index) - 10.5) / rate.hertz)
            straight += pow(Double(tone.readLinear(delay: 10.5)) - truth, 2)
            curved += pow(Double(tone.readCubic(delay: 10.5)) - truth, 2)
        }
        #expect(curved < straight / 4)

        tone.reset()
        #expect(tone.read(delay: 3) == 0)
        #expect(tone.process(1, delay: 0) == 1)
    }

    @Test func envelopeFollowerFindsPeakAndRMSAndLetsGoOnTime() {
        let rate: SampleRate = 48_000
        let wave = TestSignal.sine(frequency: 1_000, sampleRate: rate, frames: 48_000, amplitude: 0.8)
        var peak = EnvelopeFollower(.peak)
        peak.setTimes(attack: 0.001, release: 0.5, sampleRate: rate)
        var rms = EnvelopeFollower(.rms)
        rms.setTimes(attack: 0.05, release: 0.05, sampleRate: rate)
        var levels: (Float, Float) = (0, 0)
        for sample in wave { levels = (peak.process(sample), rms.process(sample)) }
        #expect(levels.0 > 0.75 && levels.0 <= 0.8)
        #expect(close(levels.1, 0.8 / Float(2).squareRoot(), within: 0.01))
        #expect(rms.level == levels.1)

        // Half a second of silence takes the peak follower down to 1/e of where it was.
        let before = levels.0
        var after: Float = 0
        for _ in 0..<24_000 { after = peak.process(0) }
        #expect(close(after / before, exp(-1), within: 0.01))
        peak.reset()
        #expect(peak.level == 0)
    }

    @Test func oscillatorPlaysItsFrequencyAtItsLevel() {
        let rate: SampleRate = 48_000
        func harmonic(_ waveform: Oscillator.Waveform, _ frequency: Double, of fundamental: Float = 1_000) -> Double {
            var oscillator = Oscillator(waveform, frequency: fundamental, level: -6.0206)
            let output = ProcessorHarness.run(&oscillator, input: AudioBuffer(channelCount: 2, frameCapacity: 48_000), sampleRate: rate)
            #expect(output.samples(channel: 0) == output.samples(channel: 1))
            return Measure.amplitude(of: frequency, in: output.samples(channel: 0), sampleRate: rate) / 0.5
        }
        #expect(close(harmonic(.sine, 1_000), 1, within: 0.001))
        #expect(harmonic(.sine, 2_000) < 1e-4)
        // The first harmonic of each shape, from its Fourier series.
        #expect(close(harmonic(.saw, 1_000), 2 / Double.pi, within: 0.01))
        #expect(close(harmonic(.saw, 2_000), 1 / Double.pi, within: 0.01))
        #expect(close(harmonic(.square, 1_000), 4 / Double.pi, within: 0.01))
        #expect(harmonic(.square, 2_000) < 0.01)
        #expect(close(harmonic(.triangle, 1_000), 8 / (Double.pi * Double.pi), within: 0.01))
    }

    @Test func roundedSawFoldsBackLessThanAPlainOne() {
        // A 5 kHz saw's sixth harmonic, at 30 kHz, is above the limit and folds back to
        // 18 kHz. Drawn plainly it would arrive at full strength.
        let rate: SampleRate = 48_000
        var oscillator = Oscillator(.saw, frequency: 5_000, level: 0)
        let output = ProcessorHarness.run(&oscillator, input: AudioBuffer(channelCount: 1, frameCapacity: 48_000), sampleRate: rate)
        let folded = Measure.amplitude(of: 18_000, in: output.samples(channel: 0), sampleRate: rate)
        let plain = 2 / (Double.pi * 6)
        #expect(folded < plain / 3)
        #expect(Measure.peak(output.samples(channel: 0)) < 1.3)
    }

    @Test func whiteNoiseIsFlatAndPinkNoiseFallsThreeDecibelsPerOctave() {
        let rate: SampleRate = 48_000
        func octaves(_ color: NoiseSource.Color) -> [Double] {
            var noise = NoiseSource(color, level: 0)
            let frames = 1 << 19
            let output = ProcessorHarness.run(&noise, input: AudioBuffer(channelCount: 1, frameCapacity: frames), sampleRate: rate)
            let samples = output.samples(channel: 0)
            let fft = FFT(size: 8_192)
            let frame = SpectralFrame(fftSize: 8_192)
            var bank = FilterBank.octave(perOctave: 1, from: 88, to: 11_300)
            bank.prepare(fftSize: 8_192, sampleRate: rate)
            var totals = [Double](repeating: 0, count: bank.bandCount)
            var powers = [Float](repeating: 0, count: bank.bandCount)
            let window = Window.hann.values(count: 8_192)
            var start = 0
            while start + 8_192 <= frames {
                let piece = zip(samples[start..<(start + 8_192)], window).map { $0 * $1 }
                piece.withUnsafeBufferPointer { fft.forward($0.baseAddress!, into: frame) }
                powers.withUnsafeMutableBufferPointer { bank.powers(of: frame, into: $0.baseAddress!) }
                for band in 0..<totals.count { totals[band] += Double(powers[band]) }
                start += 8_192
            }
            return totals.map { 10 * log10($0) }
        }
        // Each octave is twice as wide as the one below, so flat noise gains 3 dB per octave
        // and pink noise holds level.
        let white = octaves(.white)
        for (low, high) in zip(white, white.dropFirst()) { #expect(close(high - low, 3.01, within: 0.6)) }
        let pink = octaves(.pink)
        #expect(pink.count == 7)
        for (low, high) in zip(pink, pink.dropFirst()) { #expect(close(high - low, 0, within: 0.8)) }
        #expect(pink.max()! - pink.min()! < 1.2)
    }

    @Test func whiteNoiseFillsItsRangeEvenly() {
        var noise = NoiseSource(.white, level: 0)
        let output = ProcessorHarness.run(&noise, input: AudioBuffer(channelCount: 1, frameCapacity: 100_000), sampleRate: 48_000)
        let samples = output.samples(channel: 0)
        #expect(Measure.peak(samples) <= 1)
        #expect(Measure.peak(samples) > 0.99)
        #expect(close(Measure.rms(samples), 1 / Float(3).squareRoot(), within: 0.01))
        #expect(abs(samples.reduce(0, +) / 100_000) < 0.01)
    }

    @Test func blocksStayOffTheHeap() {
        let format = Format(sampleRate: 48_000, layout: .stereo)
        var filter = StateVariableFilter(.peak, frequency: 800, gain: 5)
        filter.prepare(format, maxFrames: 512)
        filter.frequency.value = 5_000
        #expect(ProcessorHarness.heapActivity(&filter, sampleRate: 48_000).isClean)

        var oscillator = Oscillator(.square, frequency: 330)
        oscillator.prepare(format, maxFrames: 512)
        #expect(ProcessorHarness.heapActivity(&oscillator, sampleRate: 48_000).isClean)

        var noise = NoiseSource(.pink)
        noise.prepare(format, maxFrames: 512)
        #expect(ProcessorHarness.heapActivity(&noise, sampleRate: 48_000).isClean)

        var line = DelayLine(maxDelayFrames: 1_000)
        var follower = EnvelopeFollower(.rms)
        follower.setTimes(attack: 0.01, release: 0.1, sampleRate: 48_000)
        var pole = OnePole(coefficient: 0.1)
        var allpass = Allpass(coefficient: 0.3)
        var total: Float = 0
        let report = RealtimeProbe.measure {
            var index = 0
            while index < 5_000 {
                line.write(Float(index & 7))
                total = line.readCubic(delay: 300.3) + line.readLinear(delay: 10.2)
                total = follower.process(total) + pole.lowPass(0.5) + allpass.process(0.1)
                index += 1
            }
        }
        #expect(report.isClean, "\(report)")
        #expect(total.isFinite)
    }
}
