import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

/// A return kept under the mix it is added to, band by band.
@Suite struct ReturnFollowerTests {
    let layout = BandCurveLayout.erb(bands: 16, from: 40, to: 18_000)
    let rate: SampleRate = 48_000
    let size = 2_048, hop = 512

    func makeFollower() -> ReturnFollower {
        ReturnFollower(layout: layout, sampleRate: rate, frameSize: size, hop: hop, taps: 1_024, designSize: 4_096)
    }

    func plan(clears: Bool = true, keyDB: Double = 0, releaseSeconds: Double = 0.5) -> ReturnFollowerPlan {
        ReturnFollowerPlan(clears: clears, marginDB: -8, mostDB: 12, keyDB: keyDB, keyShare: (0.25, 0.75), releaseSeconds: releaseSeconds, hop: hop, sampleRate: rate, silent: 1e-9)
    }

    /// Runs a return through the follower in uneven blocks and gives back what came out of the left side.
    func run(_ follower: borrowing ReturnFollower, wet: [Float], dry: [Float], key: [Float], _ plan: ReturnFollowerPlan, heard: Float = 1) -> [Float] {
        var left = wet, right = wet
        var done = 0, turn = 0
        let blocks = [300, 512, 77, 1_000]
        while done < wet.count {
            let count = min(blocks[turn % blocks.count], wet.count - done)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    dry.withUnsafeBufferPointer { d in
                        key.withUnsafeBufferPointer { k in
                            follower.follow(l.baseAddress! + done, r.baseAddress! + done, heard: heard, dry: d.baseAddress! + done, d.baseAddress! + done,
                                            key: k.baseAddress! + done, k.baseAddress! + done, frames: count, plan)
                        }
                    }
                }
            }
            done += count
            turn += 1
        }
        return left
    }

    func rows(_ follower: borrowing ReturnFollower) -> [Float] { (0..<follower.bandCount).map { follower.row[$0] } }

    @Test func everyBinOfTheLayoutsRangeBelongsToOneBand() {
        let bins = layout.bins(fftSize: size, sampleRate: rate)
        let edges = layout.edges
        #expect(bins.count == 16 && edges.count == 17)
        #expect(abs(edges[0] - 40) < 1e-6 && edges[16] == 18_000)
        var owners = [Int](repeating: 0, count: size / 2 + 1)
        for band in bins { for run in band { for bin in run { owners[bin] += 1 } } }
        for bin in 0...(size / 2) {
            let hertz = Double(bin) * 48_000 / Double(size)
            #expect(owners[bin] == (hertz >= 40 && hertz < 18_000 ? 1 : 0))
        }
        // A band narrower than a bin takes the bin nearest its middle.
        let narrow = BandCurveLayout(centres: [100, 101, 102, 5_000]).bins(fftSize: 1_024, sampleRate: 48_000)
        #expect(narrow[1] == [2..<3])
    }

    @Test func aReturnUnderTheMarginIsLeftAlone() {
        let follower = makeFollower()
        let frames = 16 * hop
        let dry = TestSignal.noise(frames: frames, amplitude: 0.5, seed: 21)
        // 20 dB under the dry mix, where 8 dB under is allowed.
        let wet = dry.map { $0 * 0.1 }
        let out = run(follower, wet: wet, dry: dry, key: TestSignal.silence(frames: frames), plan())
        let made = follower.rowCount
        #expect(made == 16 - 3)
        #expect(rows(follower).allSatisfy { $0 == 0 })
        for index in 0..<frames { #expect(abs(out[index] - wet[index]) < 1e-6) }
    }

    @Test func aReturnOverTheMarginIsTurnedDownByTheExcessAndNoFurtherThanTheMost() {
        let frames = 24 * hop
        let dry = TestSignal.noise(frames: frames, amplitude: 0.25, seed: 22)
        let silence = TestSignal.silence(frames: frames)
        // Half the dry mix: 6.02 dB under it, so 1.98 dB over a margin of 8 under.
        let follower = makeFollower()
        let wet = dry.map { $0 * 0.5 }
        let out = run(follower, wet: wet, dry: dry, key: silence, plan())
        for gain in rows(follower) { #expect(abs(gain + 1.98) < 0.01) }
        let tail = (frames - 4 * hop)..<frames
        let change = 20 * log10(Measure.rms(Array(out[tail])) / Measure.rms(Array(wet[tail])))
        #expect(abs(change + 1.98) < 0.3)
        // Measured as it will arrive: through a gain of 4 it is 6 dB over the dry mix, and the cut stops at the most.
        let louder = makeFollower()
        _ = run(louder, wet: wet, dry: dry, key: silence, plan(), heard: 4)
        #expect(rows(louder).allSatisfy { $0 == -12 })
        // Off, it listens and makes its rows but the return passes untouched.
        let listening = makeFollower()
        let passed = run(listening, wet: wet, dry: dry, key: silence, plan(clears: false))
        #expect(passed == wet)
        #expect(rows(listening) == rows(follower))
    }

    @Test func whereTheKeyHoldsTheBandTheReturnIsTurnedDownFurther() {
        let frames = 16 * hop
        let dry = TestSignal.noise(frames: frames, amplitude: 0.25, seed: 23)
        let wet = dry.map { $0 * 0.1 }
        // The key is all of the dry mix: the whole of its cut. Half the mix's power: half-way between the shares.
        let whole = makeFollower()
        _ = run(whole, wet: wet, dry: dry, key: dry, plan(keyDB: 4))
        for gain in rows(whole) { #expect(abs(gain + 4) < 1e-4) }
        let part = makeFollower()
        _ = run(part, wet: wet, dry: dry, key: dry.map { $0 * Float(0.5.squareRoot()) }, plan(keyDB: 4))
        for gain in rows(part) { #expect(abs(gain + 2) < 1e-3) }
    }

    @Test func aCutIsMadeAtOnceAndLetGoSlowly() {
        let follower = makeFollower()
        let loud = 8 * hop, quiet = 8 * hop
        let dry = TestSignal.noise(frames: loud + quiet, amplitude: 0.25, seed: 24)
        var wet = dry.map { $0 * 2 }
        for index in loud..<(loud + quiet) { wet[index] = 0 }
        let settings = plan(releaseSeconds: 0.5)
        _ = run(follower, wet: Array(wet[..<loud]), dry: Array(dry[..<loud]), key: TestSignal.silence(frames: loud), settings)
        // The first row made is already the whole cut.
        #expect(rows(follower).allSatisfy { $0 == -12 })
        let before = follower.rowCount
        _ = run(follower, wet: Array(wet[loud...]), dry: Array(dry[loud...]), key: TestSignal.silence(frames: quiet), settings)
        let made = follower.rowCount - before
        #expect(made == 8)
        // Four frames on the return is out of the window; from then each hop keeps exp(-hop / (release * rate)) of the cut.
        let keep = exp(-Double(hop) / (0.5 * 48_000))
        for gain in rows(follower) {
            #expect(gain < -12 * Float(pow(keep, 8)) + 0.01 && gain > -12 * Float(pow(keep, 4)) - 0.01)
        }
        follower.reset(at: 100)
        let room = follower.room, count = follower.rowCount
        #expect(room == hop - 100 && count == 0)
        #expect(rows(follower).allSatisfy { $0 == 0 })
    }

    @Test func followingTouchesNoHeap() {
        let follower = makeFollower()
        let frames = 8 * hop
        let dry = TestSignal.noise(frames: frames, amplitude: 0.25, seed: 25)
        var left = dry.map { $0 * 2 }, right = left
        let settings = plan(keyDB: 4)
        let report = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                dry.withUnsafeBufferPointer { d in
                    RealtimeProbe.measure {
                        follower.reset(at: 0)
                        follower.follow(l.baseAddress!, r.baseAddress!, heard: 1, dry: d.baseAddress!, d.baseAddress!, key: d.baseAddress!, d.baseAddress!, frames: frames, settings)
                    }
                }
            }
        }
        #expect(report.isClean, "\(report)")
    }
}
