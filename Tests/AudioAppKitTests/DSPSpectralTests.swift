import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

@Suite struct DSPSpectralTests {
    @Test func aSineLandsInItsBinAtHalfTheSizeTimesItsLevel() {
        let fft = FFT(size: 1_024)
        #expect(fft.size == 1_024)
        let frame = SpectralFrame(fftSize: 1_024)
        #expect(frame.binCount == 513)
        // Sixteen whole cycles in the frame, with a quarter-turn of phase.
        let wave = (0..<1_024).map { Float(0.5 * cos(2 * Double.pi * 16 * Double($0) / 1_024 + 0.25 * Double.pi)) }
        wave.withUnsafeBufferPointer { fft.forward($0.baseAddress!, into: frame) }
        #expect(close(frame.magnitude(16), 256, within: 0.01))
        #expect(close(frame.real[16], Float(256 * cos(0.25 * Double.pi)), within: 0.01))
        #expect(close(frame.imaginary[16], Float(256 * sin(0.25 * Double.pi)), within: 0.01))
        for bin in 0..<513 where bin != 16 { #expect(frame.magnitude(bin) < 0.01) }
    }

    @Test func theBottomAndTopBinsAreRight() {
        let fft = FFT(size: 64)
        let frame = SpectralFrame(fftSize: 64)
        let steady = [Float](repeating: 0.25, count: 64)
        steady.withUnsafeBufferPointer { fft.forward($0.baseAddress!, into: frame) }
        #expect(close(frame.real[0], 16, within: 1e-4))
        #expect(frame.magnitude(32) < 1e-4)
        let alternating = (0..<64).map { Float($0 % 2 == 0 ? 0.25 : -0.25) }
        alternating.withUnsafeBufferPointer { fft.forward($0.baseAddress!, into: frame) }
        #expect(close(frame.real[32], 16, within: 1e-4))
        #expect(frame.magnitude(0) < 1e-4)
    }

    @Test(arguments: [16, 256, 4_096])
    func forwardThenInverseGivesBackTheInput(size: Int) {
        let fft = FFT(size: size)
        let frame = SpectralFrame(fftSize: size)
        let noise = TestSignal.noise(frames: size, amplitude: 0.8, seed: UInt64(size))
        var output = [Float](repeating: 0, count: size)
        noise.withUnsafeBufferPointer { fft.forward($0.baseAddress!, into: frame) }
        output.withUnsafeMutableBufferPointer { fft.inverse(frame, into: $0.baseAddress!) }
        let worst = zip(noise, output).map { abs($0 - $1) }.max()!
        #expect(worst < 2e-6)
    }

    @Test func sizesRoundUpToAPowerOfTwo() {
        #expect(FFT(size: 1_000).size == 1_024)
        #expect(FFT(size: 1).size == 4)
    }

    @Test func theTransformStaysOffTheHeap() {
        let fft = FFT(size: 2_048)
        let frame = SpectralFrame(fftSize: 2_048)
        let input = AudioBuffer([TestSignal.noise(frames: 2_048)])
        let output = AudioBuffer(channelCount: 1, frameCapacity: 2_048)
        var bank = FilterBank.octave(perOctave: 3)
        bank.prepare(fftSize: 2_048, sampleRate: 48_000)
        let powers = AudioBuffer(channelCount: 1, frameCapacity: bank.bandCount)
        let report = RealtimeProbe.measure {
            var turn = 0
            while turn < 50 {
                fft.forward(input.block[0].baseAddress!, into: frame)
                bank.powers(of: frame, into: powers.block[0].baseAddress!)
                fft.inverse(frame, into: output.block[0].baseAddress!)
                turn += 1
            }
        }
        #expect(report.isClean, "\(report)")
    }

    @Test func windowsOverlapToAConstant() {
        let hann = Window.hann.values(count: 512)
        let root = Window.sqrtHann.values(count: 512)
        for index in 0..<256 {
            #expect(close(hann[index] + hann[index + 256], 1, within: 1e-6))
            #expect(close(root[index] * root[index] + root[index + 256] * root[index + 256], 1, within: 1e-6))
        }
        #expect(Window.rectangular.values(count: 4) == [1, 1, 1, 1])
        #expect(close(Window.hamming.value(at: 0, count: 64), 0.08, within: 1e-6))
        #expect(close(Window.blackmanHarris.value(at: 32, count: 64), 1, within: 1e-5))
        #expect(Window.blackmanHarris.value(at: 0, count: 64) < 1e-4)
    }

    @Test func filterBankBandsLeaveNoGapsAndDoNotOverlap() {
        let fft = FFT(size: 4_096)
        let frame = SpectralFrame(fftSize: 4_096)
        let noise = TestSignal.noise(frames: 4_096, amplitude: 0.5, seed: 9)
        noise.withUnsafeBufferPointer { fft.forward($0.baseAddress!, into: frame) }
        let width = 48_000.0 / 4_096

        for kind in 0..<3 {
            var bank = kind == 0 ? FilterBank.octave(perOctave: 3, from: 100, to: 10_000)
                : (kind == 1 ? FilterBank.erb(bands: 40, from: 100, to: 10_000) : FilterBank.mel(bands: 24, from: 100, to: 10_000))
            bank.prepare(fftSize: 4_096, sampleRate: 48_000)
            var powers = [Float](repeating: 0, count: bank.bandCount)
            powers.withUnsafeMutableBufferPointer { bank.powers(of: frame, into: $0.baseAddress!) }
            // One wide band over the same span must hold the same power as all the narrow ones.
            var whole = FilterBank(edges: [bank.edges.first!, bank.edges.last!])
            whole.prepare(fftSize: 4_096, sampleRate: 48_000)
            var total: Float = 0
            whole.powers(of: frame, into: &total)
            #expect(close(powers.reduce(0, +) / total, 1, within: 1e-4))
            #expect(zip(bank.edges, bank.edges.dropFirst()).allSatisfy { $0 < $1 })
            #expect(bank.centres.count == bank.bandCount)
            // And the span itself: whole bins inside, part bins at the ends.
            let low = bank.edges.first! / width + 0.5, high = bank.edges.last! / width + 0.5
            var direct = 0.0
            for bin in Int(low)...Int(high) {
                let share = min(Double(bin + 1), high) - max(Double(bin), low)
                direct += share * Double(frame.power(bin))
            }
            #expect(close(Double(total) / direct, 1, within: 1e-4))
        }
    }

    @Test func filterBankShapesAreWhatTheirNamesSay() {
        let thirds = FilterBank.octave(perOctave: 3, from: 100, to: 800)
        #expect(thirds.bandCount == 9)
        #expect(close(thirds.edges[3], 200, within: 1e-6))
        #expect(close(thirds.centres[0], 100 * pow(2, 1.0 / 6), within: 1e-6))
        let erb = FilterBank.erb(bands: 30)
        let mel = FilterBank.mel(bands: 30)
        #expect(erb.bandCount == 30 && mel.bandCount == 30)
        #expect(close(erb.edges.first!, 20, within: 1e-6) && close(erb.edges.last!, 20_000, within: 1e-3))
        // Both scales give low bands less width than high bands.
        #expect(erb.edges[1] - erb.edges[0] < erb.edges[30] - erb.edges[29])
        #expect(mel.edges[1] - mel.edges[0] < mel.edges[30] - mel.edges[29])

        // A tone shows up in the band that holds it and nowhere else.
        var bank = FilterBank.octave(perOctave: 3, from: 100, to: 10_000)
        bank.prepare(fftSize: 4_096, sampleRate: 48_000)
        let fft = FFT(size: 4_096)
        let frame = SpectralFrame(fftSize: 4_096)
        let window = Window.blackmanHarris.values(count: 4_096)
        let tone = zip(TestSignal.sine(frequency: 1_000, sampleRate: 48_000, frames: 4_096), window).map { $0 * $1 }
        tone.withUnsafeBufferPointer { fft.forward($0.baseAddress!, into: frame) }
        var powers = [Float](repeating: 0, count: bank.bandCount)
        powers.withUnsafeMutableBufferPointer { bank.powers(of: frame, into: $0.baseAddress!) }
        let home = bank.edges.lastIndex { $0 <= 1_000 }!
        #expect(powers.firstIndex(of: powers.max()!) == home)
        for band in 0..<bank.bandCount where abs(band - home) > 1 { #expect(powers[band] < powers[home] * 1e-8) }
    }

    @Test(arguments: [2, 4])
    func anUnchangedSpectrumComesBackAsTheInputLater(overlap: Int) {
        var host = STFTHost(SpectralPassthrough(), fftSize: 512, overlap: overlap)
        #expect(host.fftSize == 512 && host.hop == 512 / overlap)
        let noise = TestSignal.noise(frames: 6_000, amplitude: 0.5, seed: 3)
        let other = TestSignal.noise(frames: 6_000, amplitude: 0.5, seed: 4)
        let output = ProcessorHarness.run(&host, input: AudioBuffer([noise, other]), sampleRate: 48_000, blockSizes: [1, 37, 512, 700, 64])
        let delay = host.latencyFrames
        #expect(delay == 512)
        for (channel, source) in [noise, other].enumerated() {
            let result = output.samples(channel: channel)
            #expect(result[..<delay].allSatisfy { abs($0) < 1e-6 })
            let worst = (delay..<6_000).map { abs(result[$0] - source[$0 - delay]) }.max()!
            #expect(worst < 1e-5)
        }

        // The same audio in different block sizes gives the same answer.
        var again = STFTHost(SpectralPassthrough(), fftSize: 512, overlap: overlap)
        let whole = ProcessorHarness.run(&again, input: AudioBuffer([noise, other]), sampleRate: 48_000, blockSizes: [6_000])
        #expect(whole.samples(channel: 1) == output.samples(channel: 1))

        // After a reset nothing of the old audio is left.
        again.reset()
        let quiet = AudioBuffer(channelCount: 2, frameCapacity: 2_048)
        var block = quiet.block
        again.process(&block, offline48)
        #expect(quiet.samples(channel: 0).allSatisfy { $0 == 0 })
    }

    @Test func aSpectralLowPassKeepsLowsAndRemovesHighs() {
        var low = STFTHost(SpectralLowPass(cutoff: 2_000), fftSize: 1_024)
        #expect(close(measuredGainDB(&low, at: 500, blockSizes: [333]), 0, within: 0.05))
        var high = STFTHost(SpectralLowPass(cutoff: 2_000), fftSize: 1_024)
        #expect(measuredGainDB(&high, at: 8_000, blockSizes: [333]) < -80)
    }

    @Test func theSpectralHostStaysOffTheHeap() {
        var host = STFTHost(SpectralLowPass(cutoff: 4_000), fftSize: 1_024)
        host.prepare(stereo48, maxFrames: 480)
        let buffer = AudioBuffer([TestSignal.noise(frames: 480), TestSignal.noise(frames: 480, seed: 2)])
        var block = buffer.block
        let report = RealtimeProbe.measure {
            var turn = 0
            while turn < 100 {
                checked(&host, &block, offline48)
                turn += 1
            }
        }
        #expect(report.isClean, "\(report)")
        #expect(Measure.isFinite(buffer.samples(channel: 0)))
    }
}
