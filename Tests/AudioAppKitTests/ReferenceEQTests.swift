import Accelerate
import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

/// The reference EQ: a listener that keeps a signal's band spectrum as it plays, a curve made from it, the level held,
/// and the curve applied with no delay.
@Suite struct ReferenceEQTests {
    let layout = BandCurveLayout.erb(bands: 16, from: 40, to: 18_000)
    let rate: SampleRate = 48_000
    let size = 2_048, hop = 512

    func makeAnalyser() -> BandAnalyser { BandAnalyser(layout: layout, sampleRate: rate, frameSize: size) }
    func makeListener() -> BandListener { BandListener(analyser: makeAnalyser()) }
    func makeFilter() -> BandCurveFilter { BandCurveFilter(layout: layout, sampleRate: rate, hop: hop, taps: 1_024, designSize: 4_096) }
    let plan = BandListenerPlan(slowKeep: 0.9, loudnessKeep: 0.8)

    /// A frame's levels worked out directly, the long way.
    func directLevels(_ samples: [Float], floor: Float = 1e-12) -> [Float] {
        let window = Window.hann.values(count: size)
        let fft = FFT(size: size)
        let frame = SpectralFrame(fftSize: size)
        let windowed = (0..<size).map { samples[$0] * window[$0] }
        windowed.withUnsafeBufferPointer { fft.forward($0.baseAddress!, into: frame) }
        return layout.bins(fftSize: size, sampleRate: rate).map { runs in
            var sum: Float = 0
            for run in runs {
                var part: Float = 0
                for bin in run { part += frame.real[bin] * frame.real[bin] + frame.imaginary[bin] * frame.imaginary[bin] }
                sum += part
            }
            return 10 * log10f(sum + floor)
        }
    }

    func levels(_ listener: borrowing BandListener) -> [Float] { (0..<listener.bandCount).map { listener.level[$0] } }

    /// Lets a listener hear a mono signal in uneven blocks.
    func hear(_ listener: borrowing BandListener, _ samples: [Float]) {
        let blocks = [300, 512, 77, 1_000]
        var done = 0, turn = 0
        samples.withUnsafeBufferPointer { s in
            while done < s.count {
                let count = min(blocks[turn % blocks.count], s.count - done)
                listener.hear(s.baseAddress! + done, nil, frames: count)
                done += count
                turn += 1
            }
        }
    }

    @Test func aListenerHearsTheLastFrameWhereverItsRingHasGot() {
        let signal = TestSignal.noise(frames: 3 * size + 333, amplitude: 0.3, seed: 31)
        let listener = makeListener()
        hear(listener, signal)
        #expect(listener.heard == signal.count && listener.isFull)
        listener.analyse(plan)
        #expect(levels(listener) == directLevels(Array(signal.suffix(size))))
        // The frame read back out is the last one heard, oldest first.
        var recent = [Float](repeating: 0, count: size)
        recent.withUnsafeMutableBufferPointer { listener.recent(into: $0.baseAddress!) }
        #expect(recent == Array(signal.suffix(size)))
        // Two channels are heard as their mean.
        let other = TestSignal.noise(frames: size, amplitude: 0.2, seed: 32)
        let stereo = makeListener()
        signal.prefix(size).withUnsafeBufferPointer { l in other.withUnsafeBufferPointer { r in stereo.hear(l.baseAddress!, r.baseAddress!, frames: size) } }
        stereo.analyse(plan)
        #expect(levels(stereo) == directLevels((0..<size).map { 0.5 * (signal[$0] + other[$0]) }))
    }

    @Test func levelsCanBeRoundedToHalfPrecision() {
        let signal = TestSignal.noise(frames: size, amplitude: 0.3, seed: 33)
        let listener = makeListener()
        hear(listener, signal)
        listener.analyse(BandListenerPlan(roundsToHalf: true, slowKeep: 0.9, loudnessKeep: 0.8))
        #expect(levels(listener) == directLevels(signal).map { Float(Float16($0)) })
    }

    @Test func theRunningSpectrumStartsAtTheFirstFrameAndThenFollows() {
        let listener = makeListener()
        let loud = TestSignal.noise(frames: size, amplitude: 0.5, seed: 34), quiet = loud.map { $0 * 0.1 }
        hear(listener, loud)
        listener.analyse(plan)
        let first = directLevels(loud).map { pow(10, Double($0) / 10) }
        for band in 0..<16 { #expect(listener.slow[band] == first[band]) }
        #expect(listener.loudness == first.reduce(0, +) && listener.frames == 1 && listener.hasHistory)
        hear(listener, quiet)
        listener.analyse(plan)
        let second = directLevels(quiet).map { pow(10, Double($0) / 10) }
        for band in 0..<16 { #expect(listener.slow[band] == 0.9 * first[band] + (1 - 0.9) * second[band]) }
        #expect(listener.loudness == 0.8 * first.reduce(0, +) + (1 - 0.8) * second.reduce(0, +))
        listener.reset()
        #expect(listener.heard == 0 && !listener.hasHistory && listener.frames == 0 && listener.slow[3] == 0)
    }

    @Test func aListenerPutBackGoesOnAsTheOneItWasSavedFrom() {
        let signal = TestSignal.noise(frames: 6 * hop + size, amplitude: 0.3, seed: 35)
        let whole = makeListener()
        let cut = 4 * hop + size
        hear(whole, Array(signal.prefix(cut)))
        whole.analyse(plan)
        var recent = [Float](repeating: 0, count: size)
        recent.withUnsafeMutableBufferPointer { whole.recent(into: $0.baseAddress!) }
        let slow = (0..<16).map { whole.slow[$0] }
        let resumed = makeListener()
        slow.withUnsafeBufferPointer { s in recent.withUnsafeBufferPointer { r in resumed.restore(slow: s.baseAddress!, loudness: whole.loudness, recent: r.baseAddress!, heard: cut) } }
        let rest = Array(signal.suffix(from: cut))
        hear(whole, rest)
        hear(resumed, rest)
        whole.analyse(plan)
        resumed.analyse(plan)
        #expect(levels(resumed) == levels(whole))
        for band in 0..<16 { #expect(resumed.slow[band] == whole.slow[band]) }
        #expect(resumed.loudness == whole.loudness && resumed.heard == whole.heard)
    }

    @Test func theLevelHoldKeepsTheSummedPower() {
        let power: [Double] = (0..<32).map { pow(10, -Double($0) / 12) }
        let curve: [Float] = (0..<16).map { Float($0 % 5) - 2 }
        let hold = LevelHold(limitDB: 12)
        let trim = curve.withUnsafeBufferPointer { c in power.withUnsafeBufferPointer { hold.trim(curve: c.baseAddress!, amount: 0.7, bands: 16, power: $0.baseAddress!, perBand: 2) } }
        let before = power.reduce(0, +)
        let after = (0..<16).reduce(0.0) { $0 + (power[2 * $1] + power[2 * $1 + 1]) * pow(10, Double(curve[$1] * 0.7 + trim) / 10) }
        #expect(abs(10 * log10(after / before)) < 1e-4)
        // Within its limit, and nothing to go by without power.
        let steep = [Float](repeating: 40, count: 16)
        let limited = steep.withUnsafeBufferPointer { c in power.withUnsafeBufferPointer { hold.trim(curve: c.baseAddress!, amount: 1, bands: 16, power: $0.baseAddress!, perBand: 2) } }
        #expect(limited == -12)
        let none = [Double](repeating: 0, count: 32)
        let nothing = curve.withUnsafeBufferPointer { c in none.withUnsafeBufferPointer { hold.trim(curve: c.baseAddress!, amount: 1, bands: 16, power: $0.baseAddress!, perBand: 2) } }
        #expect(nothing == 0)
    }

    @Test func theMatchOverMemoryIsTheMatchOverArrays() {
        let power: [Double] = (0..<16).map { pow(10, -Double($0) / 10) * (1 + 0.3 * sin(Double($0))) }
        let reference = BandMatch.shape((0..<16).map { 1 + Double($0 % 3) })
        for match in [BandMatch(), BandMatch(amount: 0.6, limitDB: 4, smooth: 0, holdsLevel: false), BandMatch(amount: 1.3, smooth: 2.5)] {
            for wanted in [reference, nil] {
                let arrays = match.curve(power: power, reference: wanted)
                var gains = [Double](repeating: 0, count: 16), scratch = [Double](repeating: 0, count: match.scratchCount(bands: 16))
                let hold = power.withUnsafeBufferPointer { p in
                    gains.withUnsafeMutableBufferPointer { g in
                        scratch.withUnsafeMutableBufferPointer { s in
                            if let wanted {
                                wanted.withUnsafeBufferPointer { match.curve(power: p.baseAddress!, reference: $0.baseAddress!, bands: 16, into: g.baseAddress!, scratch: s.baseAddress!) }
                            } else {
                                match.curve(power: p.baseAddress!, reference: nil, bands: 16, into: g.baseAddress!, scratch: s.baseAddress!)
                            }
                        }
                    }
                }
                #expect(gains == arrays.gainsDB && hold == arrays.holdDB)
            }
        }
    }

    /// Runs a stereo signal through a reference EQ in uneven blocks; the left side back.
    func run(_ eq: borrowing ReferenceEQ, _ signal: [Float], isOn: Bool = true, amount: Float = 1, source: ReferenceCurveSource, blocks: [Int] = [300, 512, 77, 1_000]) -> [Float] {
        var left = signal, right = signal
        var done = 0, turn = 0
        while done < signal.count {
            let count = min(blocks[turn % blocks.count], signal.count - done)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in eq.process(l.baseAddress! + done, r.baseAddress! + done, frames: count, isOn: isOn, amount: amount, source: source, plan: plan) }
            }
            done += count
            turn += 1
        }
        return left
    }

    @Test func aGivenCurveIsAppliedAsTheFilterAppliesItOnceAFrameHasBeenHeard() {
        let signal = TestSignal.noise(frames: 12 * hop, amplitude: 0.3, seed: 36)
        let given: [Float] = (0..<16).map { $0 < 8 ? 4 : -3 }
        let eq = ReferenceEQ(listener: makeListener(), filter: makeFilter())
        // In whole hops: the filter's arithmetic depends on how a hop is split.
        let out = given.withUnsafeBufferPointer { run(eq, signal, amount: 0.5, source: .given($0.baseAddress!), blocks: [hop]) }
        // The same by hand: the filter turned to the curve at the end of each hop from the one where a frame has been heard.
        let filter = makeFilter()
        var left = signal, right = signal
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                given.withUnsafeBufferPointer { g in
                    for hop in 0..<12 {
                        _ = filter.pass(l.baseAddress! + hop * self.hop, r.baseAddress! + hop * self.hop, frames: self.hop)
                        filter.turn(to: (hop + 1) * self.hop >= size ? g.baseAddress! : nil, amount: 0.5)
                    }
                }
            }
        }
        #expect(out == left)
        #expect(eq.listener.frames == 12 - 3 && eq.trim.pointee == 0)
    }

    @Test func holdingTheLevelPutsTheHoldInTheCurveApplied() {
        let signal = TestSignal.noise(frames: 16 * hop, amplitude: 0.3, seed: 37)
        let tilt: [Float] = (0..<16).map { Float($0) - 7.5 }
        let held = ReferenceEQ(listener: makeListener(), filter: makeFilter(), hold: LevelHold(limitDB: 12))
        let out = tilt.withUnsafeBufferPointer { run(held, signal, source: .given($0.baseAddress!)) }
        #expect(held.trim.pointee != 0)
        // Over the last hops the curve stands still: what passes keeps the level it came in at, near enough.
        let tail = (12 * hop)..<(16 * hop)
        let level = 20 * log10(Measure.rms(Array(out[tail])) / Measure.rms(Array(signal[tail])))
        #expect(abs(level) < 1.5)
    }

    @Test func theMatchSourceMovesTheSignalTowardTheReference() {
        // A bright signal toward a dark reference: the top bands come down.
        let signal = TestSignal.noise(frames: 16 * hop, amplitude: 0.3, seed: 38)
        let dark = BandMatch.shape((0..<16).map { pow(10, -Double($0) / 5) })
        let match = BandMatch(amount: 1, limitDB: 6, smooth: 1, holdsLevel: true)
        let eq = ReferenceEQ(listener: makeListener(), filter: makeFilter())
        var scratch = [Double](repeating: 0, count: eq.scratchCount(for: match))
        _ = dark.withUnsafeBufferPointer { d in scratch.withUnsafeMutableBufferPointer { s in run(eq, signal, source: .match(match, reference: d.baseAddress!, scratch: s.baseAddress!)) } }
        #expect(eq.curve[15] < -3 && eq.curve[0] > 0)
    }

    @Test func offItFadesToAWireAndForgets() {
        let signal = TestSignal.noise(frames: 8 * hop, amplitude: 0.3, seed: 39)
        let given = [Float](repeating: 3, count: 16)
        let eq = ReferenceEQ(listener: makeListener(), filter: makeFilter())
        given.withUnsafeBufferPointer { g in
            _ = run(eq, signal, source: .given(g.baseAddress!))
            #expect(eq.filter.isFiltering && eq.listener.heard > 0)
            // Off: a hop to fade, a hop for the older filter to go, then nothing is kept.
            let tail = Array(signal.prefix(3 * hop))
            _ = run(eq, tail, isOn: false, source: .given(g.baseAddress!))
            #expect(!eq.filter.isFiltering && eq.listener.heard == 0)
            // Off and at rest it leaves the signal alone.
            #expect(run(eq, tail, isOn: false, source: .given(g.baseAddress!)) == tail)
        }
    }

    @Test func aRestoredMemoryIsInForceFromTheFirstSample() {
        let signal = TestSignal.noise(frames: 6 * hop, amplitude: 0.3, seed: 40)
        let curve = [Float](repeating: -4, count: 16)
        let recent = TestSignal.noise(frames: size, amplitude: 0.3, seed: 41)
        let slow = [Double](repeating: 1, count: 16)
        let eq = ReferenceEQ(listener: makeListener(), filter: makeFilter())
        slow.withUnsafeBufferPointer { s in recent.withUnsafeBufferPointer { r in curve.withUnsafeBufferPointer { c in
            eq.restore(slow: s.baseAddress!, loudness: 16, recent: r.baseAddress!, heard: 10 * hop, curve: c.baseAddress!, phase: 100)
        } } }
        #expect(eq.room == hop - 100 && eq.listener.isFull)
        let out = curve.withUnsafeBufferPointer { run(eq, signal, source: .given($0.baseAddress!)) }
        // 4 dB down from the start, near enough, where a cold start would pass the first hops untouched.
        let first = 0..<hop
        #expect(abs(20 * log10(Measure.rms(Array(out[first])) / Measure.rms(Array(signal[first]))) + 4) < 1)
    }

    @Test func runningTouchesNoHeap() {
        let eq = ReferenceEQ(listener: makeListener(), filter: makeFilter(), hold: LevelHold(limitDB: 12))
        let match = BandMatch()
        var left = TestSignal.noise(frames: 8 * hop, amplitude: 0.3, seed: 42), right = left
        let given = [Float](repeating: 2, count: 16)
        let reference = BandMatch.shape([Double](repeating: 1, count: 16))
        var scratch = [Double](repeating: 0, count: eq.scratchCount(for: match))
        let frames = left.count
        let report = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                given.withUnsafeBufferPointer { g in
                    reference.withUnsafeBufferPointer { d in
                        scratch.withUnsafeMutableBufferPointer { s in
                            RealtimeProbe.measure {
                                eq.process(l.baseAddress!, r.baseAddress!, frames: frames / 2, isOn: true, amount: 0.8, source: .given(g.baseAddress!), plan: plan)
                                eq.process(l.baseAddress! + frames / 2, r.baseAddress! + frames / 2, frames: frames / 2, isOn: true, amount: 1,
                                           source: .match(match, reference: d.baseAddress!, scratch: s.baseAddress!), plan: plan)
                                eq.process(l.baseAddress!, r.baseAddress!, frames: frames, isOn: false, amount: 1, source: .given(g.baseAddress!), plan: plan)
                            }
                        }
                    }
                }
            }
        }
        #expect(report.isClean, "\(report)")
    }
}
