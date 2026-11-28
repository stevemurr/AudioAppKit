import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

/// An overlap-add filterbank's pieces: gains per bin from band curves, and the frames.
@Suite struct OverlapAddTests {
    let layout = BandCurveLayout.erb(bands: 16, from: 40, to: 18_000)
    let rate: SampleRate = 48_000
    let size = 1_024, hop = 256
    var window: [Float] { (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size - 1))) } }

    @Test func curvesAddInDecibelsAndAreReadOntoTheBinsByTheLayout() {
        let gains = BandGains(layout: layout, sampleRate: rate, fftSize: size)
        let weights = layout.weights(fftSize: size, sampleRate: rate)
        let a: [Float] = (0..<16).map { Float($0) - 8 }, b = [Float](repeating: 3, count: 16)
        a.withUnsafeBufferPointer { gains.add($0.baseAddress!, scale: 0.5 * BandGains.decibels) }
        b.withUnsafeBufferPointer { gains.add($0.baseAddress!, scale: BandGains.decibels) }
        let shaping = gains.isShaping
        #expect(shaping)
        gains.finish()
        for bin in [3, 40, 200, 512] {
            let lower = Int(weights.band[bin]), lean = Double(weights.lean[bin])
            let decibels = 0.5 * (Double(a[lower]) * (1 - lean) + Double(a[lower + 1]) * lean) + 3
            #expect(abs(Double(gains.gains[bin]) - pow(10, decibels / 20)) < 1e-4)
        }
        gains.clear()
        let cleared = gains.isShaping
        #expect(!cleared)
    }

    /// Runs a signal through frames a hop apart, every one shaped by the same gains (or none), and reads it back.
    func filter(_ signal: [Float], gains: borrowing BandGains, shaped: Bool = true) -> [Float] {
        let frames = OverlapAddFrames(window: window, hop: hop)
        var sum = [Float](repeating: 0, count: size), out = [Float](repeating: 0, count: signal.count)
        signal.withUnsafeBufferPointer { s in
            sum.withUnsafeMutableBufferPointer { sum in
                out.withUnsafeMutableBufferPointer { out in
                    // Hop k's sum holds frames k - 3 to k.
                    for k in 0..<(signal.count / hop) {
                        if k > 0 { frames.advance(sum.baseAddress!) }
                        let lowest = k == 0 ? k - frames.overlap + 1 : k
                        for f in lowest...k {
                            let start = f * hop, skip = (k - f) * hop
                            let first = max(0, -start), last = min(size, signal.count - start)
                            if shaped {
                                frames.addShaped(s.baseAddress! + start, first: first, last: last, skip: skip, gains: gains, into: sum.baseAddress!)
                            } else {
                                frames.addUnchanged(s.baseAddress! + start, first: first, last: last, skip: skip, into: sum.baseAddress!)
                            }
                        }
                        frames.read(sum.baseAddress!, within: 0, count: hop, into: out.baseAddress! + k * hop)
                    }
                }
            }
        }
        return out
    }

    @Test func framesLeftAloneAddBackToTheSignal() {
        let signal = TestSignal.noise(frames: 16 * hop, amplitude: 0.5, seed: 51)
        let out = filter(signal, gains: BandGains(layout: layout, sampleRate: rate, fftSize: size), shaped: false)
        for index in 0..<(12 * hop) { #expect(abs(out[index] - signal[index]) < 1e-5) }
    }

    @Test func aFlatCurveChangesNothingAndAStandingOneScalesTheLevel() {
        let signal = TestSignal.noise(frames: 16 * hop, amplitude: 0.5, seed: 52)
        let flat = BandGains(layout: layout, sampleRate: rate, fftSize: size)
        [Float](repeating: 0, count: 16).withUnsafeBufferPointer { flat.add($0.baseAddress!, scale: BandGains.decibels) }
        flat.finish()
        let same = filter(signal, gains: flat)
        for index in 0..<(12 * hop) { #expect(abs(same[index] - signal[index]) < 1e-5) }
        let down = BandGains(layout: layout, sampleRate: rate, fftSize: size)
        [Float](repeating: -6, count: 16).withUnsafeBufferPointer { down.add($0.baseAddress!, scale: BandGains.decibels) }
        down.finish()
        let quieter = filter(signal, gains: down)
        for index in 0..<(12 * hop) { #expect(abs(quieter[index] - signal[index] * Float(pow(10, -6.0 / 20))) < 1e-5) }
    }

    @Test func shapingTouchesNoHeap() {
        let frames = OverlapAddFrames(window: window, hop: hop)
        let gains = BandGains(layout: layout, sampleRate: rate, fftSize: size)
        let signal = TestSignal.noise(frames: size, amplitude: 0.5, seed: 53), row = [Float](repeating: 2, count: 16)
        var sum = [Float](repeating: 0, count: size), out = [Float](repeating: 0, count: hop)
        let report = signal.withUnsafeBufferPointer { s in
            row.withUnsafeBufferPointer { r in
                sum.withUnsafeMutableBufferPointer { sum in
                    out.withUnsafeMutableBufferPointer { out in
                        RealtimeProbe.measure {
                            gains.clear()
                            gains.add(r.baseAddress!, scale: BandGains.decibels)
                            gains.finish()
                            frames.addShaped(s.baseAddress!, first: 0, last: size, skip: hop, gains: gains, into: sum.baseAddress!)
                            frames.addUnchanged(s.baseAddress!, first: 10, last: size, skip: 0, into: sum.baseAddress!)
                            frames.read(sum.baseAddress!, within: 0, count: hop, into: out.baseAddress!)
                            frames.advance(sum.baseAddress!)
                            frames.clear(sum.baseAddress!)
                        }
                    }
                }
            }
        }
        #expect(report.isClean, "\(report)")
    }
}
