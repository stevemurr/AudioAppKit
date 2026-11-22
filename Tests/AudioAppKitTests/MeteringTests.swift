import AudioAppKit
import AudioAppTesting
import Foundation
import Synchronization
import Testing

/// A meter whose reading is two numbers that always match, to show a reader never sees half
/// of one reading and half of the next.
private struct PairMeter: Meter {
    struct Pair: BitwiseCopyable, Sendable {
        var a = 0
        var b = 0
    }

    var reading = Pair()
    mutating func prepare(_ format: Format, maxFrames: Int) {}

    @_noAllocation @_noLocks
    mutating func measure(_ block: AudioBlock) {
        reading.a += 1
        reading.b += 1
    }

    mutating func reset() { reading = Pair() }
}

@Suite struct MeteringTests {
    /// Feeds a whole signal to a meter in blocks.
    private func measure<M: Meter & ~Copyable>(_ meter: inout M, _ channels: [[Float]], rate: SampleRate = 48_000, block: Int = 512) {
        let buffer = SampleBuffer(channels)
        var start = 0
        while start < buffer.frameCapacity {
            let frames = min(block, buffer.frameCapacity - start)
            meter.measure(buffer.block(from: start, frames: frames))
            start += frames
        }
    }

    private func sine(_ frequency: Double, dB: Float, seconds: Double, rate: SampleRate = 48_000) -> [Float] {
        TestSignal.sine(frequency: frequency, sampleRate: rate, frames: Int(seconds * rate.hertz), amplitude: Decibels(dB).gain)
    }

    @Test func kWeightingGivesTheStandardsNumbersAt48k() {
        let filter = KWeighting(sampleRate: 48_000)
        #expect(close(filter.shelf.b0, 1.53512485958697, within: 1e-8))
        #expect(close(filter.shelf.b1, -2.69169618940638, within: 1e-8))
        #expect(close(filter.shelf.b2, 1.19839281085285, within: 1e-8))
        #expect(close(filter.shelf.a1, -1.69065929318241, within: 1e-8))
        #expect(close(filter.shelf.a2, 0.73248077421585, within: 1e-8))
        #expect(close(filter.highPass.a1, -1.99004745483398, within: 1e-8))
        #expect(close(filter.highPass.a2, 0.99007225036621, within: 1e-8))
    }

    @Test(arguments: [44_100.0, 88_200.0, 96_000.0, 192_000.0])
    func kWeightingHasTheSameCurveAtEveryRate(rate: Double) {
        let reference = KWeighting(sampleRate: 48_000)
        let other = KWeighting(sampleRate: SampleRate(rate))
        for frequency in [30.0, 100, 997, 4_000, 10_000] {
            #expect(close(other.magnitudeDB(at: frequency, sampleRate: SampleRate(rate)),
                          reference.magnitudeDB(at: frequency, sampleRate: 48_000), within: 0.1), "\(frequency) Hz")
        }
        // The curve itself: about +0.7 dB at 1 kHz, +4 dB at the top, rolling off in the bass.
        #expect(close(reference.magnitudeDB(at: 997, sampleRate: 48_000), 0.691, within: 0.01))
        #expect(close(reference.magnitudeDB(at: 15_000, sampleRate: 48_000), 4, within: 0.1))
        #expect(reference.magnitudeDB(at: 30, sampleRate: 48_000) < -5)
    }

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func aFullScaleToneInOneChannelReadsMinusThreePointOhOne(rate: Double) {
        // The standard's own check: a 997 Hz sine at 0 dBFS in one channel is -3.01 LKFS.
        let sampleRate = SampleRate(rate)
        var meter = LoudnessMeter()
        meter.prepare(Format(sampleRate: sampleRate, layout: .stereo), maxFrames: 512)
        let tone = sine(997, dB: 0, seconds: 6, rate: sampleRate)
        measure(&meter, [tone, TestSignal.silence(frames: tone.count)], rate: sampleRate, block: 333)
        #expect(close(meter.reading.integrated, -3.01, within: 0.02))
        #expect(close(meter.reading.momentary, -3.01, within: 0.02))
        #expect(close(meter.reading.shortTerm, -3.01, within: 0.02))
        #expect(meter.reading.range == 0)
    }

    @Test func theSameToneInBothChannelsReadsThreeDecibelsMore() {
        // EBU Tech 3341, case 1: a stereo 1 kHz sine at -23 dBFS reads -23.0 LUFS.
        var meter = LoudnessMeter()
        meter.prepare(stereo48, maxFrames: 512)
        let tone = sine(1_000, dB: -23, seconds: 20)
        measure(&meter, [tone, tone])
        #expect(close(meter.reading.integrated, -23, within: 0.1))
        #expect(close(meter.reading.momentary, -23, within: 0.1))
    }

    @Test func quietPassagesAndSilenceAreLeftOutOfTheIntegratedFigure() {
        // EBU Tech 3341, case 3 in spirit: a quiet stretch more than 10 LU below the average
        // is gated out, as is silence.
        var meter = LoudnessMeter()
        meter.prepare(stereo48, maxFrames: 512)
        let loud = sine(1_000, dB: -23, seconds: 10), soft = sine(1_000, dB: -50, seconds: 10)
        let quiet = TestSignal.silence(frames: 480_000)
        measure(&meter, [soft + loud + quiet + soft, soft + loud + quiet + soft])
        #expect(close(meter.reading.integrated, -23, within: 0.15))
        #expect(meter.reading.momentary < -45)

        // Without the gate the average would be about 6 dB lower.
        meter.reset()
        #expect(meter.reading.integrated == -200)
        measure(&meter, [quiet, quiet])
        #expect(meter.reading.integrated == -200)
    }

    @Test func loudnessRangeIsTheGapBetweenQuietAndLoudPassages() {
        // EBU Tech 3342, case 1: 20 s at -20 LUFS then 20 s at -30 LUFS has a range of 10 LU.
        var meter = LoudnessMeter()
        meter.prepare(stereo48, maxFrames: 512)
        let a = sine(1_000, dB: -20, seconds: 20), b = sine(1_000, dB: -30, seconds: 20)
        measure(&meter, [a + b, a + b])
        #expect(close(meter.reading.range, 10, within: 1))
        // Case 2: -20 then -15 has a range of 5 LU.
        meter.reset()
        let c = sine(1_000, dB: -15, seconds: 20)
        measure(&meter, [a + c, a + c])
        #expect(close(meter.reading.range, 5, within: 1))
    }

    @Test func channelWeightsDecideWhatCounts() {
        var meter = LoudnessMeter()
        meter.prepare(stereo48, maxFrames: 512, channelWeights: [1, 0])
        let tone = sine(997, dB: 0, seconds: 3)
        measure(&meter, [tone, tone])
        #expect(close(meter.reading.integrated, -3.01, within: 0.02))

        // In a six-channel layout the standard leaves out the LFE and lifts the surrounds.
        var surround = LoudnessMeter()
        surround.prepare(Format(sampleRate: 48_000, layout: .discrete(6)), maxFrames: 512)
        let silent = TestSignal.silence(frames: tone.count)
        measure(&surround, [silent, silent, silent, tone, silent, silent])
        #expect(surround.reading.integrated == -200)
        surround.reset()
        measure(&surround, [silent, silent, silent, silent, tone, silent])
        #expect(close(surround.reading.integrated, -3.01 + 10 * log10(1.41), within: 0.02))
    }

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func truePeakFindsThePeakBetweenSamples(rate: Double) {
        // A tone at a quarter of the sample rate, timed so that every sample lands 45
        // degrees from a peak: the samples reach 0.7071 but the wave reaches 1.
        let sampleRate = SampleRate(rate)
        let frames = Int(rate)
        // It fades in, because a tone that starts abruptly really does overshoot.
        let wave = (0..<frames).map { Float(min(1, Double($0) / 2_000) * sin(2 * Double.pi * 0.25 * Double($0) + 0.25 * Double.pi)) }
        #expect(close(Measure.peak(wave), 0.7071, within: 1e-3))
        var meter = TruePeakMeter()
        meter.prepare(Format(sampleRate: sampleRate, layout: .stereo), maxFrames: 512)
        measure(&meter, [wave, wave.map { $0 * 0.5 }], rate: sampleRate, block: 441)
        #expect(close(meter.reading.maximumDB, 0, within: 0.1))
        #expect(close(Decibels(gain: meter.reading.maximum[1]).value, -6.02, within: 0.1))
        #expect(meter.reading.maximum.count == 2)
    }

    @Test func truePeakOfAnOrdinaryToneIsItsLevelAndIsHeldUntilReset() {
        var meter = TruePeakMeter()
        meter.prepare(stereo48, maxFrames: 512)
        let tone = sine(997, dB: -6, seconds: 1)
        measure(&meter, [tone, tone])
        #expect(close(meter.reading.maximumDB, -6, within: 0.02))
        measure(&meter, [TestSignal.silence(frames: 4_800), TestSignal.silence(frames: 4_800)])
        #expect(close(meter.reading.maximumDB, -6, within: 0.02))
        #expect(meter.reading.latest[0] < 1e-3)
        meter.reset()
        #expect(meter.reading.maximum.maximum == 0)

        // At 192 kHz the samples are already close enough together.
        var fast = TruePeakMeter()
        fast.prepare(Format(sampleRate: 192_000, layout: .mono), maxFrames: 512)
        let wave = (0..<19_200).map { Float(min(1, Double($0) / 2_000) * sin(2 * Double.pi * 0.25 * Double($0) + 0.25 * Double.pi)) }
        measure(&fast, [wave], rate: 192_000)
        #expect(close(fast.reading.maximum[0], 0.7071, within: 1e-3))
    }

    @Test func peakMeterJumpsUpFallsSteadilyAndHoldsItsMarker() {
        var meter = PeakMeter(holdSeconds: 1, fallDBPerSecond: 20)
        meter.prepare(stereo48, maxFrames: 480)
        let burst = [Float](repeating: 0.8, count: 480), quiet = TestSignal.silence(frames: 480)
        measure(&meter, [burst, burst.map { $0 * -0.5 }], block: 480)
        #expect(meter.reading.level[0] == 0.8)
        #expect(meter.reading.level[1] == 0.4)
        #expect(meter.reading.held[0] == 0.8)
        #expect(meter.reading.level.maximum == 0.8)
        #expect(close(meter.reading.level.decibels(1), -7.96, within: 0.01))

        // Half a second of silence: the bar has fallen 10 dB, the marker has not moved.
        for _ in 0..<50 { measure(&meter, [quiet, quiet], block: 480) }
        #expect(close(Decibels(gain: meter.reading.level[0] / 0.8).value, -10, within: 0.05))
        #expect(meter.reading.held[0] == 0.8)
        // Past the hold time the marker lets go and joins the bar.
        for _ in 0..<60 { measure(&meter, [quiet, quiet], block: 480) }
        #expect(meter.reading.held[0] == meter.reading.level[0])
        #expect(meter.reading.held[0] < 0.1)

        // A quieter burst still lifts the bar straight away.
        measure(&meter, [burst.map { $0 * 0.25 }, quiet], block: 480)
        #expect(meter.reading.level[0] == 0.2)
        meter.reset()
        #expect(meter.reading.level.maximum == 0)
    }

    @Test func rmsMeterReadsAToneAtPointSevenOfItsPeak() {
        var meter = RMSMeter(windowSeconds: 0.1)
        meter.prepare(stereo48, maxFrames: 512)
        let tone = sine(1_000, dB: 0, seconds: 2)
        measure(&meter, [tone, tone.map { $0 * 0.1 }], block: 96)
        #expect(close(meter.reading[0], 0.7071, within: 0.002))
        #expect(close(meter.reading[1], 0.07071, within: 0.0002))
        // One window of silence later it has fallen to 1/e of its power.
        measure(&meter, [TestSignal.silence(frames: 4_800), TestSignal.silence(frames: 4_800)], block: 96)
        #expect(close(meter.reading[0], 0.7071 * exp(-0.5), within: 0.005))
        meter.reset()
        #expect(meter.reading[0] == 0)
    }

    @Test func correlationTellsMonoFromWideFromInverted() {
        var meter = CorrelationMeter()
        meter.prepare(stereo48, maxFrames: 512)
        let a = TestSignal.noise(frames: 48_000, amplitude: 0.5, seed: 1)
        let b = TestSignal.noise(frames: 48_000, amplitude: 0.5, seed: 2)
        measure(&meter, [a, a])
        #expect(close(meter.reading, 1, within: 1e-4))
        meter.reset()
        measure(&meter, [a, a.map { -0.3 * $0 }])
        #expect(close(meter.reading, -1, within: 1e-4))
        meter.reset()
        measure(&meter, [a, b])
        #expect(abs(meter.reading) < 0.1)
        meter.reset()
        measure(&meter, [TestSignal.silence(frames: 4_800), TestSignal.silence(frames: 4_800)])
        #expect(meter.reading == 0)
        // Half shared, half not: half correlated.
        meter.reset()
        measure(&meter, [zip(a, b).map { $0 + $1 }, a])
        #expect(close(meter.reading, Float(0.5).squareRoot(), within: 0.05))
    }

    @Test func spectrumPutsAToneInItsBandAtItsLevel() {
        var analyzer = SpectrumAnalyzer(fftSize: 4_096, bands: FilterBank.octave(perOctave: 3, from: 1_000 / pow(2, 5 + 1.0 / 6), to: 20_000))
        analyzer.prepare(Format(sampleRate: 48_000, layout: .mono), maxFrames: 512)
        measure(&analyzer, [sine(1_000, dB: -12, seconds: 2)])
        let levels = analyzer.readout.levels
        #expect(levels.count == analyzer.frequencies.count)
        let home = analyzer.frequencies.enumerated().min { abs($0.element - 1_000) < abs($1.element - 1_000) }!.offset
        #expect(close(levels[home], -12, within: 0.2))
        for (band, level) in levels.enumerated() where abs(band - home) > 2 { #expect(level < -80) }
        #expect(analyzer.reading == analyzer.readout.publishCount - 1)

        // The bands are third-octaves placed so that 1 kHz is the centre of one.
        #expect(close(analyzer.frequencies[home], 1_000, within: 0.01))
        // Levels climb quickly and fall slowly.
        let before = levels[home]
        measure(&analyzer, [TestSignal.silence(frames: 9_600)])
        let after = analyzer.readout.levels[home]
        #expect(after < before - 5 && after > -100)
        analyzer.reset()
        #expect(analyzer.readout.levels.allSatisfy { $0 == -120 })
    }

    @Test func spectrumWithoutBandsReportsEveryBin() {
        var analyzer = SpectrumAnalyzer(fftSize: 1_024, riseSeconds: 0, fallSeconds: 0)
        analyzer.prepare(stereo48, maxFrames: 512)
        #expect(analyzer.fftSize == 1_024)
        // Bin 32 of 1024 at 48 kHz is 1500 Hz. Two channels at -12 dB sum to -6 dB.
        let tone = sine(1_500, dB: -12, seconds: 0.5)
        measure(&analyzer, [tone, tone], block: 100)
        let levels = analyzer.readout.levels
        #expect(levels.count == 513)
        #expect(analyzer.frequencies[32] == 1_500)
        #expect(close(levels[32], -6.02, within: 0.05))
        #expect(levels[100] < -100)
    }

    @Test func aTapPassesAudioUntouchedAndPublishesTheReading() {
        var tap = MeterTap(PeakMeter())
        let readout = tap.readout
        tap.prepare(stereo48, maxFrames: 512)
        let noise = TestSignal.noise(frames: 512, amplitude: 0.6)
        let buffer = SampleBuffer([noise, noise])
        var block = buffer.block
        checked(&tap, &block, offline48)
        #expect(buffer.samples(channel: 0) == noise)
        #expect(readout.value.level[0] == Measure.peak(noise))
        #expect(readout.publishCount == 2)
        tap.reset()
        #expect(readout.value.level[0] == 0)
    }

    @Test func aReaderOnAnotherThreadNeverSeesAHalfWrittenReading() {
        var tap = MeterTap(PairMeter())
        let readout = tap.readout
        tap.prepare(stereo48, maxFrames: 64)
        let stop = Atomic<Bool>(false)
        let torn = Counter(), seen = Counter()
        let reader = Thread {
            while !stop.load(ordering: .relaxed) {
                let pair = readout.value
                if pair.a != pair.b { torn.bump() }
                seen.bump()
            }
        }
        reader.start()
        let buffer = SampleBuffer(channelCount: 2, frameCapacity: 64)
        var block = buffer.block
        var turns = 0
        while turns < 200_000 || seen.value < 1_000 {
            tap.process(&block, offline48)
            turns += 1
        }
        stop.store(true, ordering: .relaxed)
        while !reader.isFinished { usleep(1_000) }
        #expect(torn.value == 0)
        #expect(readout.value.a == turns)
    }

    @Test func metersStayOffTheHeap() {
        let noise = SampleBuffer([TestSignal.noise(frames: 480, amplitude: 0.5), TestSignal.noise(frames: 480, amplitude: 0.5, seed: 2)])
        var block = noise.block

        var peak = MeterTap(PeakMeter())
        var rms = MeterTap(RMSMeter())
        var truePeak = MeterTap(TruePeakMeter())
        var loudness = MeterTap(LoudnessMeter())
        var correlation = MeterTap(CorrelationMeter())
        var spectrum = MeterTap(SpectrumAnalyzer(fftSize: 2_048, bands: FilterBank.erb(bands: 40)))
        peak.prepare(stereo48, maxFrames: 480)
        rms.prepare(stereo48, maxFrames: 480)
        truePeak.prepare(stereo48, maxFrames: 480)
        loudness.prepare(stereo48, maxFrames: 480)
        correlation.prepare(stereo48, maxFrames: 480)
        spectrum.prepare(stereo48, maxFrames: 480)
        // Four seconds, so the loudness meter closes blocks, gates them and takes a range.
        let report = RealtimeProbe.measure {
            var turn = 0
            while turn < 400 {
                checked(&peak, &block, offline48)
                checked(&rms, &block, offline48)
                checked(&truePeak, &block, offline48)
                checked(&loudness, &block, offline48)
                checked(&correlation, &block, offline48)
                checked(&spectrum, &block, offline48)
                turn += 1
            }
        }
        #expect(report.isClean, "\(report)")
        #expect(loudness.readout.value.integrated > -30)
        #expect(loudness.readout.value.shortTerm > -30)
        #expect(spectrum.readout.value > 10)
        #expect(spectrum.meter.readout.levels.max()! > -40)
        #expect(truePeak.readout.value.maximumDB > -8)
        #expect(abs(correlation.readout.value) < 0.3)
        #expect(rms.readout.value[0] > 0.2)
    }
}
