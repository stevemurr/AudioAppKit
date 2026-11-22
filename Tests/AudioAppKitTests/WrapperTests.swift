import AudioAppKit
import AudioAppTesting
import Testing

@Suite struct WrapperTests {
    @Test func dryWetKeepsTheDrySignalInStepWithALateProcessor() {
        // The processor is 6 frames late and halves the level.
        let gain = Gain()
        gain.level.value = -6.0206
        var blend = DryWet(Chain(Late(frames: 6), gain))
        blend.mix.value = 0.5
        blend.prepare(Format(sampleRate: 48_000, layout: .mono), maxFrames: 32)
        #expect(blend.latencyFrames == 6)
        var samples = [Float](repeating: 0, count: 32)
        samples[4] = 1
        let buffer = AudioBuffer([samples])
        var block = buffer.block
        checked(&blend, &block, offline48)
        // Half of the dry impulse and half of the halved one, both at frame 10. Were the dry
        // signal not held back, they would land on different frames.
        let out = buffer.samples(channel: 0)
        #expect(close(out[10], 0.75, within: 1e-4))
        #expect(out.enumerated().allSatisfy { $0.offset == 10 || $0.element == 0 })
    }

    @Test func dryWetAtItsEndsIsAllDryOrAllWet() {
        for (mix, expected) in [(Float(0), Float(1)), (1, 0.5)] {
            let gain = Gain()
            gain.level.value = -6.0206
            var blend = DryWet(gain)
            blend.mix.value = mix
            let out = ProcessorHarness.run(&blend, input: AudioBuffer([[1, 1, 1, 1]]), sampleRate: 48_000)
            #expect(close(out.samples(channel: 0)[3], expected, within: 1e-4))
        }
    }

    @Test func bypassCrossfadesWithoutAStep() {
        var filter = Bypassable(Biquad(.lowShelf, frequency: 500, gain: 12), fadeSeconds: 0.01)
        let format = Format(sampleRate: 48_000, layout: .mono)
        filter.prepare(format, maxFrames: 256)
        let tone = TestSignal.sine(frequency: 100, sampleRate: 48_000, frames: 4_096, amplitude: 0.2)
        let buffer = AudioBuffer([tone])
        for start in stride(from: 0, to: 4_096, by: 256) {
            if start == 2_048 { filter.isBypassed = true }
            var block = buffer.block(from: start, frames: 256)
            checked(&filter, &block, offline48)
        }
        let out = buffer.samples(channel: 0)
        // Boosted by about 12 dB while active, back to the input once bypassed.
        #expect(Measure.peak(Array(out[1_000..<2_000])) > 0.7)
        #expect(Array(out[3_000...]) == Array(tone[3_000...]))
        // The 10 ms fade spreads the change over 480 frames. A hard switch at this point in
        // the wave would jump by several times this.
        let steps = zip(out[2_040..<2_600], out[2_041..<2_601]).map { abs($0 - $1) }
        #expect(steps.max()! < 0.02)
        let bypassed = filter.isBypassed
        #expect(bypassed)
    }

    @Test func midSideProcessesWhatTheChannelsShareAndDiffer() {
        // A gain of -6 dB on mid and side alike is just -6 dB overall.
        let gain = Gain()
        gain.level.value = -6.0206
        var wrapped = MidSide(gain)
        wrapped.prepare(stereo48, maxFrames: 8)
        let buffer = AudioBuffer([[1, 0, 0.5, -1], [1, 1, -0.5, 0.25]])
        var block = buffer.block
        checked(&wrapped, &block, offline48)
        #expect(zip(buffer.samples(channel: 0), [0.5, 0, 0.25, -0.5]).allSatisfy { close($0, $1, within: 1e-4) })
        #expect(zip(buffer.samples(channel: 1), [0.5, 0.5, -0.25, 0.125]).allSatisfy { close($0, $1, within: 1e-4) })
    }

    @Test func midSideSeesMidOnChannelZeroAndSideOnChannelOne() {
        // Silencing channel 1 inside the wrapper removes the side signal, leaving mono.
        struct MuteSecond: Processor, ~Copyable {
            mutating func prepare(_ format: Format, maxFrames: Int) {}
            mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
                for frame in 0..<io.frameCount { io[1][frame] = 0 }
            }
        }
        var wrapped = MidSide(MuteSecond())
        let out = ProcessorHarness.run(&wrapped, input: AudioBuffer([[1, 0.5], [0, 0.5]]), sampleRate: 48_000)
        #expect(out.samples(channel: 0) == [0.5, 0.5])
        #expect(out.samples(channel: 1) == [0.5, 0.5])
    }

    @Test func perChannelGivesEachChannelItsOwnProcessor() {
        // A different filter per channel: channel 0 low-passed, channel 1 high-passed.
        var split = PerChannel { channel in Biquad(channel == 0 ? .lowPass : .highPass, frequency: 1_000) }
        let rate: SampleRate = 48_000
        let low = TestSignal.sine(frequency: 100, sampleRate: rate, frames: 4_800, amplitude: 0.5)
        let out = ProcessorHarness.run(&split, input: AudioBuffer([low, low]), sampleRate: rate)
        #expect(Measure.rms(Array(out.samples(channel: 0)[2_400...])) > 0.34)
        #expect(Measure.rms(Array(out.samples(channel: 1)[2_400...])) < 0.01)

        var block = out.block(frames: 256)
        let report = RealtimeProbe.measure { checked(&split, &block, offline48) }
        #expect(report.isClean, "\(report)")
    }

    @Test func wrappersStayOffTheHeap() {
        // Measured through the checked calls. A wrapper is generic, and in a debug build
        // generic code that is not reached from a checked function does runtime type lookups.
        let buffer = AudioBuffer([TestSignal.noise(frames: 512, amplitude: 0.5), TestSignal.noise(frames: 512, amplitude: 0.5, seed: 2)])
        var block = buffer.block

        var blend = DryWet(Chain(Late(frames: 6), Gain()))
        blend.prepare(stereo48, maxFrames: 512)
        blend.mix.value = 0.3
        var report = RealtimeProbe.measure {
            var turn = 0
            while turn < 50 { checked(&blend, &block, offline48); turn += 1 }
        }
        #expect(report.isClean, "\(report)")

        var filter = Bypassable(Biquad(.peak, frequency: 1_000, gain: 3))
        filter.prepare(stereo48, maxFrames: 512)
        filter.isBypassed = true
        report = RealtimeProbe.measure {
            var turn = 0
            while turn < 50 { checked(&filter, &block, offline48); turn += 1 }
        }
        #expect(report.isClean, "\(report)")

        var wide = MidSide(Gain())
        wide.prepare(stereo48, maxFrames: 512)
        report = RealtimeProbe.measure {
            var turn = 0
            while turn < 50 { checked(&wide, &block, offline48); turn += 1 }
        }
        #expect(report.isClean, "\(report)")
    }
}
