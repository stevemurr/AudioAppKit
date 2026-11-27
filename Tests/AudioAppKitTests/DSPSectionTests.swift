import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

/// The pieces a processor's own loop is built from: the bare filter section, cascades, the gain decision in full
/// precision, and the third-harmonic colour.
@Suite struct DSPSectionTests {
    @Test func aBareSectionIsTheFilterTheProcessorRuns() {
        let rate: SampleRate = 48_000
        let noise = TestSignal.noise(frames: 4_096, seed: 7)
        let input = SampleBuffer([noise])
        var filter = Biquad(.peak, frequency: 1_200, gain: 5, q: 1.4)
        let processed = ProcessorHarness.run(&filter, input: input, sampleRate: rate)
        let design = BiquadCoefficients.design(.peak, frequency: 1_200, gain: 5, q: Double(Float(1.4)), sampleRate: rate)
        var state = BiquadState()
        let stepped = noise.map { Float(state.step(Double($0), design)) }
        #expect(Array(processed.samples(channel: 0)) == stepped)
        state.reset()
        #expect(state.z1 == 0 && state.z2 == 0)
        state.z1 = 1e-40
        state.z2 = 0.5
        state.settle()
        #expect(state.z1 == 0 && state.z2 == 0.5)
    }

    @Test(arguments: [FilterResponse.lowPass, .highPass], 1...6)
    func butterworthIsThreeDecibelsDownAtItsCornerAndFallsBySixPerOctavePerOrder(response: FilterResponse, order: Int) {
        let rate: SampleRate = 96_000
        let sections = BiquadCoefficients.butterworth(response, order: order, frequency: 1_000, sampleRate: rate)
        #expect(sections.count == (order + 1) / 2)
        #expect(close(sections.magnitudeDB(at: 1_000, sampleRate: rate), -3.0103, within: 1e-3))
        // Flat in the passband, with no ripple.
        let passed = response == .lowPass ? 100.0 : 10_000.0
        #expect(abs(sections.magnitudeDB(at: passed, sampleRate: rate)) < 0.05)
        // Two octaves out, 12 dB for each order.
        let stopped = response == .lowPass ? 4_000.0 : 250.0
        #expect(close(sections.magnitudeDB(at: stopped, sampleRate: rate), -12.04 * Double(order), within: 0.35 * Double(order)))
    }

    @Test func aSecondOrderButterworthIsTheUsualBilinearDesign() {
        // The textbook form, as scipy's butter(2, hz, fs=44100) gives it.
        let hz = 6_000.0, rate: SampleRate = 44_100
        let w = tan(Double.pi * hz / rate.hertz)
        let norm = 1 + 2.0.squareRoot() * w + w * w
        let wanted = BiquadCoefficients(b0: w * w / norm, b1: 2 * w * w / norm, b2: w * w / norm,
                                        a1: 2 * (w * w - 1) / norm, a2: (1 - 2.0.squareRoot() * w + w * w) / norm)
        let made = BiquadCoefficients.butterworth(.lowPass, order: 2, frequency: hz, sampleRate: rate)
        #expect(made.count == 1)
        for (a, b) in zip([made[0].b0, made[0].b1, made[0].b2, made[0].a1, made[0].a2], [wanted.b0, wanted.b1, wanted.b2, wanted.a1, wanted.a2]) {
            #expect(close(a, b, within: 1e-12))
        }
        #expect(BiquadCoefficients.butterworth(.peak, order: 2, frequency: hz, sampleRate: rate).isEmpty)
    }

    @Test func filteringBothWaysShiftsNothingInTime() {
        let rate: SampleRate = 48_000
        let sections = BiquadCoefficients.butterworth(.lowPass, order: 4, frequency: 2_000, sampleRate: rate)
        var click = [Double](repeating: 0, count: 4_001)
        click[2_000] = 1
        var once = click
        sections.filter(&once)
        sections.filterBothWays(&click)
        // One way the peak comes late; both ways it stays where it was, and the result is the same either side of it.
        #expect(once.indices.max { once[$0] < once[$1] }! > 2_000)
        #expect(click.indices.max { click[$0] < click[$1] } == 2_000)
        for offset in 1...200 { #expect(close(click[2_000 - offset], click[2_000 + offset], within: 1e-9)) }
        // And a tone is turned down twice over.
        var tone = (0..<48_000).map { sin(2 * Double.pi * 2_000 * Double($0) / rate.hertz) }
        sections.filterBothWays(&tone)
        let middle = tone[12_000..<36_000].reduce(0) { max($0, abs($1)) }
        #expect(close(20 * log10(middle), 2 * sections.magnitudeDB(at: 2_000, sampleRate: rate), within: 0.01))
    }

    @Test func theGainDecisionInDecibelsIsAOnePoleEachWay() {
        // The plain loop it stands for: reduction rising at the attack and falling at the release.
        let rate: SampleRate = 44_100
        var core = DynamicsCore(mode: .compressor, thresholdDB: -23.456_789_012, ratio: 20, kneeDB: 0)
        core.setTimes(attack: 0.000_3, release: 0.04, sampleRate: rate)
        let attack = exp(-1 / (0.000_3 * rate.hertz)), release = exp(-1 / (0.04 * rate.hertz)), slope = 1 - 1 / 20.0
        var held = 0.0
        var generator = SystemRandomNumberGenerator()
        for index in 0..<20_000 {
            let level = (index / 2_000) % 2 == 0 ? Double.random(in: -12...0, using: &generator) : Double.random(in: -70 ... -40, using: &generator)
            let over = level - -23.456_789_012
            let wanted = over > 0 ? slope * over : 0
            if wanted > held { held += (wanted - held) * (1 - attack) } else { held = release * held + (1 - release) * wanted }
            #expect(close(-core.gainDB(levelDB: level), held, within: 1e-9))
        }
        #expect(core.heldGainDB == -held || close(core.heldGainDB, -held, within: 1e-9))
        core.heldGainDB = -3
        #expect(core.reductionDB == -3)
        core.heldGainDB = 2
        #expect(core.heldGainDB == 0)
    }

    @Test func aLongReleaseKeepsMoving() {
        // Ten seconds at 192 kHz: each step is far smaller than single precision could add to the gain held.
        var core = DynamicsCore(mode: .compressor, thresholdDB: -20, ratio: 2, kneeDB: 0)
        core.setTimes(attack: 0, release: 10, sampleRate: 192_000)
        _ = core.gainDB(levelDB: 0)
        #expect(core.heldGainDB == -10)
        for _ in 0..<1_920_000 { _ = core.gainDB(levelDB: -60) }
        #expect(close(core.heldGainDB, -10 * exp(-1), within: 1e-3))
    }

    @Test func theColourAddsAThirdHarmonicAndNothingElse() {
        let colour = ThirdHarmonic(reference: 0.25)
        let amount = 0.08, count = 4_800
        func part(_ signal: [Double], harmonic: Int) -> Double {
            var sum = 0.0
            for index in 0..<count { sum += signal[index] * cos(2 * Double.pi * Double(harmonic * 10 * index) / Double(count)) }
            return 2 * sum / Double(count)
        }
        // A tone at the reference: 3/4 of the amount comes off the tone, 1/4 of it appears three times up.
        let tone = (0..<count).map { 0.25 * cos(2 * Double.pi * Double(10 * $0) / Double(count)) }
        let coloured = tone.map { colour.process($0, amount: amount) }
        #expect(close(part(coloured, harmonic: 1), 0.25 * (1 - 0.75 * amount), within: 1e-9))
        #expect(close(part(coloured, harmonic: 3), -0.25 * amount / 4, within: 1e-9))
        #expect(abs(part(coloured, harmonic: 2)) < 1e-9 && abs(part(coloured, harmonic: 5)) < 1e-9)
        // Half as loud, a quarter of the colour, measured against the tone.
        let quiet = tone.map { colour.process($0 / 2, amount: amount) }
        #expect(close(part(quiet, harmonic: 3) / 0.125, -amount / 16, within: 1e-9))
        // With no amount it changes nothing, and far past the reference it stops bending.
        #expect(colour.process(0.123, amount: 0) == 0.123)
        #expect(close(colour.process(10, amount: 0.01) - colour.process(9, amount: 0.01), 1, within: 1e-9))
    }
}
