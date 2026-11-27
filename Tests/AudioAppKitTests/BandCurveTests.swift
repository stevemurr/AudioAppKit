import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

/// A curve of band gains made into a filter with no delay, and the filter run with its curve changing.
@Suite struct BandCurveTests {
    let layout = BandCurveLayout.erb(bands: 32, from: 30, to: 20_000)
    let rate: SampleRate = 44_100

    /// A curve with broad and narrow moves in it, within 9 dB either way.
    func curve(_ seed: Float = 0) -> [Float] {
        (0..<32).map { 6 * sin(Float($0) * 0.45 + seed) + 3 * cos(Float($0) * 1.3 - seed) }
    }

    func makeFilter(hop: Int = 1_024) -> BandCurveFilter {
        BandCurveFilter(layout: layout, sampleRate: rate, hop: hop, taps: 2_048, designSize: 8_192, fade: 256)
    }

    /// The gain in decibels a filter has at each bin of an FFT.
    func response(_ taps: [Float], size: Int = 8_192) -> [Float] {
        let fft = FFT(size: size)
        let frame = SpectralFrame(fftSize: size)
        let padded = taps + [Float](repeating: 0, count: size - taps.count)
        padded.withUnsafeBufferPointer { fft.forward($0.baseAddress!, into: frame) }
        return (0...(size / 2)).map { 10 * log10(frame.power($0) + 1e-30) }
    }

    func run(_ filter: borrowing BandCurveFilter, _ left: inout [Float], _ right: inout [Float], rows: [Float]?, rowCount: Int = 1, amount: Float = 1, blocks: [Int]) {
        var done = 0, turn = 0
        while done < left.count {
            let count = min(blocks[turn % blocks.count], left.count - done)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    if let rows {
                        rows.withUnsafeBufferPointer { filter.process(l.baseAddress! + done, r.baseAddress! + done, frames: count, rows: $0.baseAddress, rowCount: rowCount, position: done, amount: amount) }
                    } else {
                        filter.process(l.baseAddress! + done, r.baseAddress! + done, frames: count, rows: nil, rowCount: 0, position: done, amount: amount)
                    }
                }
            }
            done += count
            turn += 1
        }
    }

    @Test func aBinLeansBetweenTheTwoBandsEitherSideOfIt() {
        let weights = layout.weights(fftSize: 4_096, sampleRate: rate)
        let centres = layout.centres
        #expect(weights.band.count == 2_049 && centres.count == 32)
        for bin in 0..<2_049 {
            let lower = Int(weights.band[bin]), hertz = Double(bin) * 44_100 / 4_096
            #expect(lower >= 0 && lower <= 30)
            #expect(weights.lean[bin] >= 0 && weights.lean[bin] <= 1)
            // Between two centres it sits between them; outside them it holds the end band.
            if hertz <= centres[0] { #expect(lower == 0 && weights.lean[bin] == 0) }
            if hertz >= centres[31] { #expect(lower == 30 && weights.lean[bin] == 1) }
            if hertz > centres[0], hertz < centres[31] { #expect(centres[lower] <= hertz * 1.000_001 && hertz <= centres[lower + 1] * 1.000_001) }
        }
        // Centres given outright are leant between along the logarithm of frequency.
        let given = BandCurveLayout(centres: [100, 1_000, 10_000]).weights(fftSize: 4_096, sampleRate: 40_960)
        #expect(given.band[10] == 0 && given.lean[10] == 0)
        #expect(given.band[100] == 1 && abs(given.lean[100]) < 1e-6)
        #expect(given.band[316] == 1 && abs(given.lean[316] - 0.5) < 0.01)
        #expect(given.band[32] == 0 && abs(given.lean[32] - 0.505) < 0.01)
        #expect(given.band[2_048] == 1 && given.lean[2_048] == 1)
    }

    @Test func theDesignHasTheCurvesResponseAndAllItsEnergyEarly() {
        let design = BandCurveDesign(layout: layout, sampleRate: rate, size: 8_192)
        let size = design.size, bands = design.bandCount
        #expect(size == 8_192 && bands == 32)
        let gains = curve()
        var taps = [Float](repeating: 0, count: 2_048)
        design.filter(of: gains, into: &taps, taps: 2_048, fade: 256)
        let weights = layout.weights(fftSize: 8_192, sampleRate: rate)
        let got = response(taps)
        var worst: Float = 0
        // From the first band's centre up: below it the curve is held down to nothing.
        for bin in Int(45.0 / 44_100 * 8_192)...4_096 {
            let lower = Int(weights.band[bin])
            let wanted = gains[lower] * (1 - weights.lean[bin]) + gains[lower + 1] * weights.lean[bin]
            worst = max(worst, abs(got[bin] - wanted))
        }
        #expect(worst < 0.5)
        let energy = taps.reduce(Float(0)) { $0 + $1 * $1 }
        let early = taps[..<256].reduce(Float(0)) { $0 + $1 * $1 }
        #expect(abs(taps[0]) > 0.3 && early / energy > 0.98)

        // The amount scales the curve in decibels, and an offset moves all of it.
        var half = taps, lifted = taps
        design.filter(of: gains, amount: 0.5, into: &half, taps: 2_048, fade: 256)
        design.filter(of: gains, offsetDB: 6, into: &lifted, taps: 2_048, fade: 256)
        let halved = response(half), raised = response(lifted)
        for bin in 20...4_000 {
            #expect(abs(halved[bin] - 0.5 * got[bin]) < 0.3)
            #expect(abs(raised[bin] - got[bin] - 6) < 0.05)
        }
    }

    @Test func aStandingCurveIsInForceFromTheFirstSample() {
        let filter = makeFilter()
        let gains = curve(2)
        var left = [Float](repeating: 0, count: 4_096), right = left
        left[0] = 1
        right[0] = 1
        run(filter, &left, &right, rows: gains, blocks: [4_096])
        var taps = [Float](repeating: 0, count: 2_048)
        BandCurveDesign(layout: layout, sampleRate: rate, size: 8_192).filter(of: gains, into: &taps, taps: 2_048, fade: 256)
        // The click comes out as the filter itself, at once: no delay and no fade in.
        for index in 0..<2_048 { #expect(abs(left[index] - taps[index]) < 1e-6) }
        #expect(Measure.peak(Array(left[2_048...])) == 0)
        #expect(left == right)
    }

    @Test func howItIsCutIntoBlocksChangesNothing() {
        let frames = 20_000
        let noise = TestSignal.noise(frames: frames, amplitude: 0.5, seed: 11), other = TestSignal.noise(frames: frames, amplitude: 0.5, seed: 12)
        // Rows along a timeline, changing all the way.
        let rowCount = frames / 1_024 + 1
        let rows = (0..<rowCount).flatMap { curve(Float($0) * 0.3) }
        var wholeLeft = noise, wholeRight = other
        run(makeFilter(), &wholeLeft, &wholeRight, rows: rows, rowCount: rowCount, blocks: [frames])
        var cutLeft = noise, cutRight = other
        run(makeFilter(), &cutLeft, &cutRight, rows: rows, rowCount: rowCount, blocks: [97, 1_024, 3, 2_500])
        // The same to within the rounding of the system's convolution, which depends on how many samples it is given.
        var apart: Float = 0
        for index in 0..<frames { apart = max(apart, abs(wholeLeft[index] - cutLeft[index]), abs(wholeRight[index] - cutRight[index])) }
        #expect(apart < 1e-5)
        #expect(wholeLeft != noise)
        #expect(Measure.isFinite(wholeLeft))
    }

    @Test func aTimelinesRowIsHeardAroundItsMiddle() {
        let filter = BandCurveFilter(layout: layout, sampleRate: rate, hop: 1_024, taps: 2_048, designSize: 8_192, rowSpacing: 1_024, rowCentre: 2_048)
        let fade = filter.fade
        #expect(fade == 256)
        let rows = [0, 2_048 + 1_023, 2_048 + 1_024, 1_000_000].map { filter.row(at: $0, count: 10) }
        #expect(rows == [0, 0, 1, 9])
    }

    @Test func withNoCurveItIsAWireAndFadesBackToOne() {
        let filter = makeFilter()
        let frames = 8 * 1_024
        let noise = TestSignal.noise(frames: frames, amplitude: 0.5, seed: 5)
        var left = noise, right = noise
        run(filter, &left, &right, rows: nil, blocks: [500])
        var working = filter.isFiltering
        #expect(left == noise && !working)
        // A curve, then none: it fades to a wire over a hop, the next hop still runs both filters, and then it stops.
        run(filter, &left, &right, rows: curve(), blocks: [1_024])
        working = filter.isFiltering
        #expect(left != noise && working)
        left = noise
        right = noise
        run(filter, &left, &right, rows: curve(), amount: 0, blocks: [1_024])
        working = filter.isFiltering
        #expect(!working)
        #expect(Array(left[..<1_024]) != Array(noise[..<1_024]))
        for index in 2_048..<frames { #expect(abs(left[index] - noise[index]) < 1e-5) }
        // A curve of nothing is a wire after the hop it starts on.
        let silent = [Float](repeating: 0, count: 32)
        let nothing = [filter.isNothing(silent), filter.isNothing(silent, offsetDB: 1), filter.isNothing(curve()), filter.isNothing(curve(), amount: 0)]
        #expect(nothing == [true, false, false, true])
        filter.reset()
        left = noise
        right = noise
        run(filter, &left, &right, rows: silent, blocks: [700])
        for index in 0..<frames { #expect(abs(left[index] - noise[index]) < 1e-5) }
        #expect(Array(left[2_048...]) == Array(noise[2_048...]))
    }

    @Test func aCurveWorkedOutAsItGoesIsFadedToHopByHop() {
        // The steps `process` is made of, driven by hand: a steady tone while the curve changes every hop.
        let filter = makeFilter()
        let frames = 40 * 1_024
        var left = TestSignal.sine(frequency: 441, sampleRate: rate, frames: frames, amplitude: 0.5), right = left
        var hop = 0, done = 0
        while done < frames {
            let count = min(filter.room, 333, frames - done)
            let ended = left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in filter.pass(l.baseAddress! + done, r.baseAddress! + done, frames: count) }
            }
            done += count
            if ended {
                hop += 1
                filter.turn(to: curve(Float(hop) * 0.3))
            }
        }
        var room = filter.room
        #expect(hop == 40 && room == 1_024)
        // The output's slope never jumps, because each sample is a blend of two filtered copies.
        var worst: Float = 0
        for index in 4_098..<frames { worst = max(worst, abs(left[index] - 2 * left[index - 1] + left[index - 2])) }
        let ownCurvature = Float(pow(2 * Double.pi * 441 / 44_100, 2)) * 0.5
        #expect(worst < 6 * ownCurvature)
        #expect(left == right)
        // Started part-way through a hop, the first hop is that much shorter.
        filter.reset(phase: 1_000)
        room = filter.room
        let working = filter.isFiltering
        #expect(room == 24 && !working)
    }

    @Test func runningItTouchesNoHeap() {
        let filter = makeFilter()
        let frames = 4_096
        var left = TestSignal.noise(frames: frames, seed: 1), right = TestSignal.noise(frames: frames, seed: 2)
        let rows = curve() + curve(1) + curve(2) + curve(3)
        let report = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                rows.withUnsafeBufferPointer { rows in
                    RealtimeProbe.measure {
                        filter.reset()
                        filter.process(l.baseAddress!, r.baseAddress!, frames: frames, rows: rows.baseAddress, rowCount: 4, position: 0, amount: 0.7)
                        filter.process(l.baseAddress!, r.baseAddress!, frames: frames, rows: nil, rowCount: 0, position: frames, amount: 1)
                    }
                }
            }
        }
        #expect(report.isClean, "\(report)")
    }
}
