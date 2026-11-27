import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

/// A curve that moves a signal's spectrum toward a reference.
@Suite struct BandMatchTests {
    /// Sixteen bands of power, tilted so the top has less.
    let power = (0..<16).map { pow(10, -Double($0) / 10) }

    @Test func aShapeIsEachBandsShareOfTheWholeInDecibels() {
        let shape = BandMatch.shape([1, 1, 2])
        #expect(abs(shape[0] + 6.0206) < 1e-3 && abs(shape[2] + 3.0103) < 1e-3)
        // Level-free: twice the power is the same shape.
        #expect(zip(BandMatch.shape(power), BandMatch.shape(power.map { $0 * 2 })).allSatisfy { abs($0 - $1) < 1e-9 })
    }

    @Test func allOfTheGapPutsTheSignalOnTheReference() {
        // Toward a flat spectrum, with nothing smoothed, clipped or limited away.
        let flat = BandMatch.shape([Double](repeating: 1, count: 16))
        let match = BandMatch(amount: 1, limitDB: 40, smooth: 0, holdsLevel: false)
        let curve = match.curve(power: power, reference: flat)
        #expect(curve.holdDB == 0)
        let after = BandMatch.shape((0..<16).map { power[$0] * pow(10, curve.gainsDB[$0] / 10) })
        for band in 0..<16 { #expect(abs(after[band] - flat[band]) < 1e-9) }
        // Half the amount closes half the gap in decibels; the limit stops any band going further.
        let half = BandMatch(amount: 0.5, limitDB: 40, smooth: 0, holdsLevel: false).curve(power: power, reference: flat)
        for band in 0..<16 { #expect(abs(half.gainsDB[band] - 0.5 * curve.gainsDB[band]) < 1e-9) }
        let limited = BandMatch(amount: 1, limitDB: 3, smooth: 0, holdsLevel: false).curve(power: power, reference: flat)
        #expect(limited.gainsDB.allSatisfy { abs($0) <= 3 } && limited.gainsDB.contains { abs($0) == 3 })
        // With no reference, or on its own shape, it asks for nothing.
        #expect(match.curve(power: power, reference: nil).gainsDB.allSatisfy { $0 == 0 })
        #expect(match.curve(power: power, reference: BandMatch.shape(power)).gainsDB.allSatisfy { abs($0) < 1e-9 })
    }

    @Test func holdingTheLevelLeavesTheSummedPowerWhereItWas() {
        let flat = BandMatch.shape([Double](repeating: 1, count: 16))
        let curve = BandMatch(amount: 0.7, limitDB: 6, smooth: 1, holdsLevel: true).curve(power: power, reference: flat)
        let before = power.reduce(0, +)
        let after = (0..<16).reduce(0.0) { $0 + power[$1] * pow(10, curve.gainsDB[$1] / 10) }
        #expect(abs(after / before - 1) < 1e-9)
        #expect(curve.holdDB != 0)
        // The hold is one gain in every band: without it the curve is the same shape.
        let free = BandMatch(amount: 0.7, limitDB: 6, smooth: 1, holdsLevel: false).curve(power: power, reference: flat)
        for band in 0..<16 { #expect(abs(curve.gainsDB[band] - free.gainsDB[band] - curve.holdDB) < 1e-9) }
    }

    @Test func whereTheSignalHasNextToNothingTheCurveAsksForNothing() {
        // The top four bands 60 dB under the rest: past the 45 dB at which a band counts as absent.
        var gappy = [Double](repeating: 1, count: 16)
        for band in 12..<16 { gappy[band] = 1e-6 }
        let flat = BandMatch.shape([Double](repeating: 1, count: 16))
        let curve = BandMatch(amount: 1, limitDB: 40, clipDB: 20, smooth: 0, holdsLevel: false).curve(power: gappy, reference: flat)
        // What is left there is only the shift that makes the gap level-free, the same in every band: the twelve
        // bands that are there each hold a twelfth of the power where the reference wants a sixteenth.
        let shift = curve.gainsDB[15]
        for band in 12..<16 { #expect(abs(curve.gainsDB[band] - shift) < 1e-9) }
        #expect(abs(shift - 10 * log10(16.0 / 12)) < 1e-3)
        for band in 0..<12 { #expect(abs(curve.gainsDB[band]) < 1e-3) }
    }

    @Test func smoothingSpreadsAStepAndHoldsTheEnds() {
        let step = (0..<16).map { $0 < 8 ? 0.0 : 1.0 }
        let smooth = BandMatch.smoothed(step, sigma: 1.5)
        #expect(BandMatch.smoothed(step, sigma: 0) == step)
        #expect(abs(smooth[0]) < 1e-3 && abs(smooth[15] - 1) < 1e-3)
        #expect(abs(smooth[7] + smooth[8] - 1) < 1e-9 && smooth[7] > 0.2 && smooth[7] < 0.5)
        for band in 1..<16 { #expect(smooth[band] >= smooth[band - 1]) }
        // A constant stays what it was.
        #expect(BandMatch.smoothed([Double](repeating: 2.5, count: 9), sigma: 2).allSatisfy { abs($0 - 2.5) < 1e-12 })
    }

    @Test func theRestoringCurveUndoesWhatWasDoneToASum() {
        let before = power
        let done = (0..<16).map { 3 * sin(Double($0) * 0.4) }
        let after = (0..<16).map { power[$0] * pow(10, done[$0] / 10) }
        let back = BandMatch.restoring(before: before, after: after, smooth: 0, limitDB: 12)
        for band in 0..<16 { #expect(abs(back[band] + done[band]) < 1e-9) }
        #expect(BandMatch.restoring(before: before, after: after, smooth: 0, limitDB: 1).allSatisfy { abs($0) <= 1 })
    }
}
