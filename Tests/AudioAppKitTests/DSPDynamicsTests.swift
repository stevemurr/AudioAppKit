import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

@Suite struct DSPDynamicsTests {
    @Test func theCurveIsFlatBelowThresholdAndFollowsTheRatioAbove() {
        let hard = DynamicsCore(mode: .compressor, thresholdDB: -18, ratio: 4, kneeDB: 0)
        #expect(hard.settledGainDB(levelDB: -30) == 0)
        #expect(hard.settledGainDB(levelDB: -18) == 0)
        #expect(close(hard.settledGainDB(levelDB: -6), -9, within: 1e-5))

        // A knee eases in: nothing below its start, the full line above its end, and no
        // jump at either.
        let soft = DynamicsCore(mode: .compressor, thresholdDB: -18, ratio: 4, kneeDB: 12)
        #expect(soft.settledGainDB(levelDB: -24) == 0)
        #expect(close(soft.settledGainDB(levelDB: -12), -4.5, within: 1e-5))
        #expect(close(soft.settledGainDB(levelDB: -18), -1.125, within: 1e-5))
        #expect(close(soft.settledGainDB(levelDB: -12.001), soft.settledGainDB(levelDB: -11.999), within: 0.01))

        let expander = DynamicsCore(mode: .expander, thresholdDB: -40, ratio: 2, kneeDB: 0)
        #expect(expander.settledGainDB(levelDB: -30) == 0)
        #expect(close(expander.settledGainDB(levelDB: -50), -10, within: 1e-5))
        let gate = DynamicsCore(mode: .expander, thresholdDB: -40, ratio: 20, kneeDB: 0)
        #expect(gate.settledGainDB(levelDB: -46) < -100)
    }

    @Test func gainArrivesAndLeavesOnTime() {
        var core = DynamicsCore(mode: .compressor, thresholdDB: -20, ratio: 2, kneeDB: 0)
        core.setTimes(attack: 0.01, release: 0.1, sampleRate: 48_000)
        // 20 dB over the threshold settles at -10 dB. After one attack time it is 63% there.
        var gain: Float = 0
        for _ in 0..<480 { gain = core.gainDB(level: 1) }
        #expect(close(gain, -10 * (1 - exp(-1)), within: 0.02))
        for _ in 0..<48_000 { gain = core.gainDB(level: 1) }
        #expect(close(gain, -10, within: 0.001))
        #expect(close(core.gain(level: 1), Decibels(-10).gain, within: 1e-4))
        #expect(core.reductionDB == gain)
        // After one release time it has given back 63%.
        for _ in 0..<4_800 { gain = core.gainDB(level: 0.001) }
        #expect(close(gain, -10 * exp(-1), within: 0.02))
        core.reset()
        #expect(core.reductionDB == 0)
    }

    @Test func theCompressorHoldsALoudToneAtTheLevelItsSettingsGive() {
        var compressor = Dynamics(.compressor)
        compressor.threshold.value = -18
        compressor.ratio.value = 4
        compressor.knee.value = 0
        compressor.attack.value = 0.001
        compressor.release.value = 2
        let frames = 96_000
        let input = sineBuffer(1_000, frames: frames, amplitude: Decibels(-6).gain, channels: 2)
        let output = ProcessorHarness.run(&compressor, input: input, sampleRate: 48_000)
        // -6 dB is 12 over the threshold; at 4:1 that leaves 3 over: -15 dB.
        let level = decibels(Double(Measure.peak(Array(output.samples(channel: 0)[48_000...]))))
        #expect(close(level, -15, within: 0.3))
        #expect(close(Double(compressor.reductionDB), -9, within: 0.3))
        #expect(output.samples(channel: 0) == output.samples(channel: 1))

        // Below the threshold nothing changes, and make-up gain is added after.
        var lifted = Dynamics(.compressor)
        lifted.threshold.value = 0
        lifted.makeup.value = 6
        #expect(close(measuredGainDB(&lifted, at: 1_000), 6, within: 0.01))
        var untouched = Dynamics(.compressor)
        let soft = sineBuffer(1_000, frames: 4_800, amplitude: 0.05)
        let same = ProcessorHarness.run(&untouched, input: soft, sampleRate: 48_000)
        #expect(same.samples(channel: 0) == soft.samples(channel: 0))
    }

    @Test func oneLoudChannelTurnsBothDownTogether() {
        var compressor = Dynamics(.compressor, detector: .rms)
        compressor.threshold.value = -30
        let loud = TestSignal.sine(frequency: 500, sampleRate: 48_000, frames: 24_000, amplitude: 0.9)
        let soft = TestSignal.sine(frequency: 700, sampleRate: 48_000, frames: 24_000, amplitude: 0.01)
        let output = ProcessorHarness.run(&compressor, input: AudioBuffer([loud, soft]), sampleRate: 48_000)
        let a = Measure.amplitude(of: 500, in: Array(output.samples(channel: 0)[12_000...]), sampleRate: 48_000) / 0.9
        let b = Measure.amplitude(of: 700, in: Array(output.samples(channel: 1)[12_000...]), sampleRate: 48_000) / 0.01
        #expect(a < 0.5)
        #expect(close(a, b, within: 0.01))
    }

    @Test func theLimiterNeverLetsASamplePastTheCeiling() {
        var limiter = LookaheadLimiter(ceiling: -1, release: 0.05)
        // Quiet noise with sudden bursts far over the ceiling, and single stray samples.
        var left = TestSignal.noise(frames: 48_000, amplitude: 0.3, seed: 5)
        var right = TestSignal.noise(frames: 48_000, amplitude: 0.3, seed: 6)
        for start in stride(from: 3_000, to: 45_000, by: 7_000) {
            for index in start..<(start + 900) {
                left[index] *= 12
                right[index] *= index % 2 == 0 ? 9 : 1
            }
            left[start + 2_500] = 4
            right[start + 2_501] = -3.5
        }
        let output = ProcessorHarness.run(&limiter, input: AudioBuffer([left, right]), sampleRate: 48_000, blockSizes: [64, 1, 500])
        let ceiling = Decibels(-1).gain
        #expect(Measure.peak(output.samples(channel: 0)) <= ceiling)
        #expect(Measure.peak(output.samples(channel: 1)) <= ceiling)
        // It works hard enough to matter, and not by clipping: the bursts come out close to
        // the ceiling, not flattened against it.
        #expect(Measure.peak(output.samples(channel: 0)) > 0.9 * ceiling)
        let pinned = output.samples(channel: 0).filter { abs($0) == ceiling }.count
        #expect(pinned < 50)
        #expect(limiter.latencyFrames == 240)
    }

    @Test func theLimiterLeavesQuietAudioExactlyAsItWasOnlyLater() {
        var limiter = LookaheadLimiter(ceiling: -1)
        let noise = TestSignal.noise(frames: 9_600, amplitude: 0.5, seed: 7)
        let output = ProcessorHarness.run(&limiter, input: AudioBuffer([noise]), sampleRate: 48_000, blockSizes: [97])
        let delay = limiter.latencyFrames
        let result = output.samples(channel: 0)
        #expect(result[..<delay].allSatisfy { $0 == 0 })
        #expect(Array(result[delay...]) == Array(noise[..<(9_600 - delay)]))
        #expect(limiter.reductionDB == 0)
    }

    @Test func theLimiterRampsDownBeforeAPeakInsteadOfSnapping() {
        var limiter = LookaheadLimiter(ceiling: -6, release: 0.2)
        // A steady tone at the ceiling's level, then double it.
        var wave = TestSignal.sine(frequency: 100, sampleRate: 48_000, frames: 48_000, amplitude: 0.5)
        for index in 24_000..<48_000 { wave[index] *= 2 }
        let output = ProcessorHarness.run(&limiter, input: AudioBuffer([wave]), sampleRate: 48_000)
        let result = output.samples(channel: 0)
        #expect(Measure.peak(result) <= Decibels(-6).gain)
        #expect(limiter.reductionDB < -5)
        // The gain change is spread over the look-ahead, so no sample jumps.
        let largestStep = zip(result, result.dropFirst()).map { abs($0 - $1) }.max()!
        #expect(largestStep < 0.02)
        // Once settled, the louder half comes out as loud as the ceiling allows.
        #expect(Measure.peak(Array(result[40_000...])) > 0.95 * Decibels(-6).gain)
    }

    @Test func dynamicsStayOffTheHeap() {
        let format = Format(sampleRate: 48_000, layout: .stereo)
        var compressor = Dynamics(.compressor, detector: .rms)
        compressor.prepare(format, maxFrames: 512)
        compressor.threshold.value = -40
        #expect(ProcessorHarness.heapActivity(&compressor, sampleRate: 48_000).isClean)

        var limiter = LookaheadLimiter(ceiling: -12)
        limiter.prepare(format, maxFrames: 512)
        #expect(ProcessorHarness.heapActivity(&limiter, sampleRate: 48_000).isClean)

        var reverb = FeedbackDelayNetwork(lines: 16)
        reverb.prepare(format, maxFrames: 512)
        reverb.decay.value = 3
        #expect(ProcessorHarness.heapActivity(&reverb, sampleRate: 48_000).isClean)
    }

    /// The time for a tail to fall 60 dB, from the slope of the energy left to come.
    private func decayTime(_ samples: [Float], rate: Double) -> Double {
        var remaining = [Double](repeating: 0, count: samples.count)
        var sum = 0.0
        for index in stride(from: samples.count - 1, through: 0, by: -1) {
            sum += Double(samples[index]) * Double(samples[index])
            remaining[index] = sum
        }
        let levels = remaining.map { 10 * log10(max($0 / remaining[0], 1e-30)) }
        let from = levels.firstIndex { $0 <= -5 }!, to = levels.firstIndex { $0 <= -25 }!
        return 3 * Double(to - from) / rate
    }

    @Test(arguments: [(0.8, 8), (2.0, 8), (1.5, 4), (1.5, 16)])
    func theReverbTailLastsAsLongAsAsked(seconds: Double, lines: Int) {
        var reverb = FeedbackDelayNetwork(lines: lines)
        #expect(reverb.lineCount == lines)
        reverb.decay.value = Float(seconds)
        reverb.damping.value = 0
        let frames = Int(48_000 * seconds * 1.5)
        let impulse = TestSignal.impulse(frames: frames)
        let output = ProcessorHarness.run(&reverb, input: AudioBuffer([impulse, impulse]), sampleRate: 48_000)
        #expect(Measure.isFinite(output.samples(channel: 0)))
        let measured = decayTime(output.samples(channel: 0), rate: 48_000)
        #expect(close(measured, seconds, within: 0.1 * seconds), "measured \(measured)")
    }

    @Test func dampingShortensTheHighsAndChannelsHearDifferentTails() {
        func tail(damping: Float) -> AudioBuffer {
            var reverb = FeedbackDelayNetwork(lines: 8)
            reverb.decay.value = 2
            reverb.damping.value = damping
            let impulse = TestSignal.impulse(frames: 72_000)
            return ProcessorHarness.run(&reverb, input: AudioBuffer([impulse, impulse]), sampleRate: 48_000)
        }
        func highShare(_ buffer: AudioBuffer) -> Float {
            let late = Array(buffer.samples(channel: 0)[36_000..<60_000])
            var filter = Biquad(.highPass, frequency: 6_000)
            let highs = ProcessorHarness.run(&filter, input: AudioBuffer([late]), sampleRate: 48_000)
            return Measure.rms(highs.samples(channel: 0)) / Measure.rms(late)
        }
        let bright = tail(damping: 0), dark = tail(damping: 0.8)
        #expect(highShare(dark) < 0.25 * highShare(bright))

        let left = bright.samples(channel: 0), right = bright.samples(channel: 1)
        let dot = zip(left, right).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let correlation = dot / (Float(left.count) * Measure.rms(left) * Measure.rms(right))
        #expect(abs(correlation) < 0.3)
    }

    @Test func reverbMixAtZeroIsTheDrySignalAndResetClearsTheTail() {
        var reverb = FeedbackDelayNetwork()
        reverb.mix.value = 0
        let noise = TestSignal.noise(frames: 4_800, amplitude: 0.5)
        let output = ProcessorHarness.run(&reverb, input: AudioBuffer([noise, noise]), sampleRate: 48_000)
        #expect(output.samples(channel: 0) == noise)

        reverb.mix.value = 1
        reverb.reset()
        let quiet = AudioBuffer(channelCount: 2, frameCapacity: 4_800)
        var block = quiet.block
        reverb.process(&block, offline48)
        #expect(quiet.samples(channel: 0).allSatisfy { $0 == 0 })
    }
}
