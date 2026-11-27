import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

/// A few parametric sections with fixed centres fitted to a curve, and run as cascades whose gains glide.
@Suite struct SectionEQTests {
    let rate: SampleRate = 48_000
    let sections = [EQSection(.lowShelf, frequency: 100, q: 0.7), EQSection(.peak, frequency: 400, q: 0.9), EQSection(.peak, frequency: 2_500, q: 0.9),
                    EQSection(.highShelf, frequency: 9_000, q: 0.7)]
    /// Twenty-four frequencies from 40 Hz to 16 kHz, evenly spaced by ratio.
    let grid = (0..<24).map { 40 * pow(400.0, Double($0) / 23) }

    @Test func aSectionAtAGainIsTheCookbooksFilter() {
        let bell = EQSection(.peak, frequency: 1_000, q: 1).coefficients(gainDB: 6, sampleRate: rate)
        #expect(abs(bell.magnitudeDB(at: 1_000, sampleRate: rate) - 6) < 1e-6 && abs(bell.magnitudeDB(at: 50, sampleRate: rate)) < 0.05)
        let shelf = EQSection(.lowShelf, frequency: 90, q: 0.7).coefficients(gainDB: -4, sampleRate: rate)
        #expect(abs(shelf.magnitudeDB(at: 5, sampleRate: rate) + 4) < 0.01 && abs(shelf.magnitudeDB(at: 5_000, sampleRate: rate)) < 0.01)
        // The same filter as the plain design gives, whose gain is worked out another way.
        let plain = BiquadCoefficients.design(.peak, frequency: 1_000, gain: 6, q: 1, sampleRate: rate)
        for (a, b) in zip([bell.b0, bell.b1, bell.b2, bell.a1, bell.a2], [plain.b0, plain.b1, plain.b2, plain.a1, plain.a2]) { #expect(abs(a - b) < 1e-12) }
        // The magnitude from angles worked out once is the magnitude at the frequency.
        let w = 2 * Double.pi * 700 / 48_000
        #expect(abs(bell.magnitudeDB(cosine: cos(w), sine: sin(w), cosine2: cos(2 * w), sine2: sin(2 * w)) - bell.magnitudeDB(at: 700, sampleRate: rate)) < 1e-9)
    }

    @Test func theFitFindsTheGainsThatMadeACurve() {
        let fit = SectionFit(sections: sections, at: grid, sampleRate: rate)
        // Small gains, where a section's response in decibels is close to its shape times its gain.
        let small = [1.0, -1.5, 0.8, -0.6]
        let curve = SectionFit.response(sections, gainsDB: small, at: grid, sampleRate: rate)
        let found = fit.solve(curve)
        for (a, b) in zip(found, small) { #expect(abs(a - b) < 0.15) }
        // The gains are a fixed matrix times the curve, until they are limited.
        let wiggly = grid.indices.map { 4 * sin(Double($0) * 0.7) + Double($0) * 0.2 - 3 }
        let direct = fit.solve(wiggly, maxGainDB: 1_000)
        for section in sections.indices {
            let sum = grid.indices.reduce(0.0) { $0 + fit.inverse[section * grid.count + $1] * wiggly[$1] }
            #expect(abs(sum - direct[section]) < 1e-8)
        }
        #expect(fit.solve([Double](repeating: 40, count: grid.count)).allSatisfy { abs($0) <= 12 })
        #expect(SectionFit(sections: sections, at: grid, sampleRate: rate, maxGainDB: 3).solve(wiggly).allSatisfy { abs($0) <= 3 })
    }

    @Test func withAFreeOffsetTheFitLeavesTheCurvesLevelAlone() {
        let shaped = SectionFit(sections: sections, at: grid, sampleRate: rate, freeOffset: true)
        let whole = SectionFit(sections: sections, at: grid, sampleRate: rate)
        #expect(shaped.hasFreeOffset && !whole.hasFreeOffset)
        let curve = SectionFit.response(sections, gainsDB: [1.0, -1.5, 0.8, -0.6], at: grid, sampleRate: rate)
        let lifted = curve.map { $0 + 5 }
        #expect(zip(shaped.solve(lifted), shaped.solve(curve)).allSatisfy { abs($0 - $1) < 1e-4 })
        #expect(zip(whole.solve(lifted), whole.solve(curve)).contains { abs($0 - $1) > 1 })
    }

    @Test func theLevelHoldLeavesTheSummedPowerWhereItWas() {
        let power = [1.0, 4, 2, 0.5]
        let response = [3.0, -2, 0, 6]
        let trim = SectionFit.levelHold(power: power, responseDB: response)
        let after = zip(power, response).reduce(0.0) { $0 + $1.0 * pow(10, ($1.1 + trim) / 10) }
        #expect(abs(after - 7.5) < 1e-9)
        #expect(SectionFit.levelHold(power: [0, 0], responseDB: [3, 3]) == 0)
    }

    @Test func aCurvesGainsGlideAndItsTracksKeepTheirOwnMemory() {
        let bank = SectionBank(sections: sections, curves: 2, tracks: 2, sampleRate: rate, step: 0.2)
        // The first gains after a reset are taken at once: four gains and then the trim.
        var wanted: [Float] = [3, -2, 0, 4, -0.5]
        bank.update(0, wanted: wanted)
        var gain = bank.gainDB(curve: 0, section: 0), trim = bank.trimDB(curve: 0)
        #expect(gain == 3 && trim == -0.5)
        // After that each moves by a step at most.
        wanted = [4, -2, 0, 4, 0]
        bank.update(0, wanted: wanted)
        gain = bank.gainDB(curve: 0, section: 0)
        trim = bank.trimDB(curve: 0)
        #expect(abs(gain - 3.2) < 1e-9 && abs(trim + 0.3) < 1e-6)
        for _ in 0..<4 { bank.update(0, wanted: wanted) }
        gain = bank.gainDB(curve: 0, section: 0)
        trim = bank.trimDB(curve: 0)
        #expect(gain == 4 && trim == 0)

        // A steady tone comes out at the cascade's gain at its frequency; both tracks on the curve the same.
        let frames = 24_000
        let tone = TestSignal.sine(frequency: 400, sampleRate: rate, frames: frames, amplitude: 0.25)
        var a = tone, b = tone, right = tone
        a.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in bank.process(track: 0, curve: 0, l.baseAddress!, r.baseAddress!, frames: frames) } }
        b.withUnsafeMutableBufferPointer { bank.process(track: 1, curve: 0, $0.baseAddress!, nil, frames: frames) }
        #expect(a == b && a == right)
        let response = SectionFit.response(sections, gainsDB: [4, -2, 0, 4], at: [400], sampleRate: rate)[0]
        let measured = 20 * log10(Measure.amplitude(of: 400, in: Array(a[12_000...]), sampleRate: rate) / 0.25)
        #expect(abs(measured - response) < 0.02)
        // A curve with nothing asked of it leaves its tracks alone, as does a curve or track it has no room for.
        var untouched = tone
        untouched.withUnsafeMutableBufferPointer { bank.process(track: 0, curve: 1, $0.baseAddress!, nil, frames: frames) }
        untouched.withUnsafeMutableBufferPointer { bank.process(track: 5, curve: 0, $0.baseAddress!, nil, frames: frames) }
        #expect(untouched == tone)
        bank.update(0, wanted: nil)
        gain = bank.gainDB(curve: 0, section: 0)
        #expect(abs(gain - 3.8) < 1e-9)
        bank.reset()
        gain = bank.gainDB(curve: 0, section: 0)
        #expect(gain == 0)
    }

    @Test func theBankTouchesNoHeap() {
        let bank = SectionBank(sections: sections, curves: 1, tracks: 1, sampleRate: rate)
        let wanted: [Float] = [3, -2, 1, 4, -0.5], other: [Float] = [-3, 2, 0, 1, 0.5]
        var left = TestSignal.noise(frames: 2_048, seed: 1), right = TestSignal.noise(frames: 2_048, seed: 2)
        let report = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                wanted.withUnsafeBufferPointer { first in
                    other.withUnsafeBufferPointer { second in
                        RealtimeProbe.measure {
                            bank.reset()
                            bank.update(0, wanted: first.baseAddress)
                            bank.process(track: 0, curve: 0, l.baseAddress!, r.baseAddress!, frames: 2_048)
                            bank.update(0, wanted: second.baseAddress)
                            bank.process(track: 0, curve: 0, l.baseAddress!, r.baseAddress!, frames: 2_048)
                        }
                    }
                }
            }
        }
        #expect(report.isClean, "\(report)")
    }
}
