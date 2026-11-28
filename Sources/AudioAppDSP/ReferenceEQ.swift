import Accelerate
import AudioAppCore
import AudioAppRealtime
import Darwin

// An equaliser that listens to what it shapes: it hears a signal's band spectrum as it plays, makes a curve from it,
// holds the level and applies the curve with no delay. Four pieces, each usable alone: the listener (`BandAnalyser`
// for one frame, `BandListener` for a stream with memory), a curve source (`ReferenceCurveSource`), the level hold
// (`LevelHold`) and `BandCurveFilter`. `ReferenceEQ` puts them together.

/// How a frame's band powers become levels, and how a listener's running spectrum follows them: what a listener is
/// handed each time it analyses a frame.
@frozen public struct BandListenerPlan: BitwiseCopyable, Sendable {
    /// Power added to each band before its level is taken, so that silence has a level.
    public var floor: Float
    /// Whether each level is rounded to half precision before anything is made of it, as a model trained from levels
    /// stored that way expects.
    public var roundsToHalf: Bool
    /// What the running spectrum and the running loudness keep of themselves each frame.
    public var slowKeep: Double
    public var loudnessKeep: Double

    @inlinable public init(floor: Float = 1e-12, roundsToHalf: Bool = false, slowKeep: Double, loudnessKeep: Double) {
        self.floor = floor
        self.roundsToHalf = roundsToHalf
        self.slowKeep = slowKeep
        self.loudnessKeep = loudnessKeep
    }

    /// - Parameters:
    ///   - slowSeconds, loudnessSeconds: the time constants of the running spectrum and loudness.
    ///   - hop, sampleRate: how often a frame is analysed, which turns the time constants into what is kept a frame.
    public init(floor: Float = 1e-12, roundsToHalf: Bool = false, slowSeconds: Double, loudnessSeconds: Double, hop: Int, sampleRate: SampleRate) {
        let framesPerSecond = sampleRate.hertz / Double(hop)
        self.init(floor: floor, roundsToHalf: roundsToHalf, slowKeep: exp(-1 / (slowSeconds * framesPerSecond)), loudnessKeep: exp(-1 / (loudnessSeconds * framesPerSecond)))
    }
}

/// Calls the listener makes into the system's libraries. Plain arithmetic over memory the caller supplies; marked
/// trusted because the compiler's real-time checks cannot see into them.
@usableFromInline enum BandListenerKernel {
    /// `out = a * b`
    @inlinable @inline(never) @_semantics("no_performance_analysis")
    static func multiply(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>, _ count: Int) {
        vDSP_vmul(a, 1, b, 1, out, 1, vDSP_Length(count))
    }

    /// A value rounded to half precision and back.
    @inlinable @inline(never) @_semantics("no_performance_analysis")
    static func half(_ value: Float) -> Float {
        #if arch(arm64)
        return Float(Float16(value))
        #else
        // Half precision keeps 11 significant bits down to 2^-14, and steps of 2^-24 below; past 65504 it is infinite.
        guard value.isFinite else { return value }
        let size = abs(value)
        if size >= 65_520 { return value < 0 ? -.infinity : .infinity }
        let quantum: Float = size < 0x1p-14 ? 0x1p-24 : Float(sign: .plus, exponent: size.exponent - 10, significand: 1)
        return (value / quantum).rounded(.toNearestOrEven) * quantum
        #endif
    }
}

/// The level in each band of one frame of a signal: the frame under a window, its spectrum, and the power of the bins
/// each band takes, in decibels.
///
/// Setting one up reserves memory, so do it away from the audio thread. Analysing is safe on the audio thread. One
/// analyser serves one thread at a time.
public struct BandAnalyser: ~Copyable {
    /// The frame analysed, in samples: a power of two.
    public let frameSize: Int
    public let bandCount: Int
    @usableFromInline let fft: FFT
    @usableFromInline let frame: SpectralFrame
    @usableFromInline let window: UnsafeMutablePointer<Float>
    /// The runs of bins each band sums: band `b` has the runs from `bandRuns[b]` up to `bandRuns[b + 1]`.
    @usableFromInline let bandRuns: UnsafeMutablePointer<Int32>
    @usableFromInline let runFirst: UnsafeMutablePointer<Int32>
    @usableFromInline let runCount: UnsafeMutablePointer<Int32>
    /// The frame under its window.
    @usableFromInline let scratch: UnsafeMutablePointer<Float>

    /// - Parameters:
    ///   - frameSize: rounded up to a power of two.
    ///   - window: the frame's window, `frameSize` values; a Hann window when not given.
    ///   - bandBins: for each band the runs of bins whose power is the band's, as `BandCurveLayout.bins` gives them.
    public init(frameSize: Int, window: [Float]? = nil, bandBins: [[Range<Int>]]) {
        fft = FFT(size: frameSize)
        let size = fft.size
        self.frameSize = size
        frame = SpectralFrame(fftSize: size)
        self.window = Memory.floats(size)
        let shape = window ?? Window.hann.values(count: size)
        for index in 0..<min(size, shape.count) { self.window[index] = shape[index] }
        bandCount = bandBins.count
        let runs = bandBins.map { list in list.map { $0.clamped(to: 0..<(size / 2 + 1)) } }
        let total = max(1, runs.reduce(0) { $0 + $1.count })
        bandRuns = .allocate(capacity: bandCount + 1)
        runFirst = .allocate(capacity: total)
        runCount = .allocate(capacity: total)
        var next = 0
        for (band, list) in runs.enumerated() {
            bandRuns[band] = Int32(next)
            for run in list {
                runFirst[next] = Int32(run.lowerBound)
                runCount[next] = Int32(run.count)
                next += 1
            }
        }
        bandRuns[bandCount] = Int32(next)
        scratch = Memory.floats(size)
    }

    /// The bands of a layout, each taking the bins between its edges.
    public init(layout: BandCurveLayout, sampleRate: SampleRate, frameSize: Int, window: [Float]? = nil) {
        var size = 4
        while size < frameSize { size *= 2 }
        self.init(frameSize: size, window: window, bandBins: layout.bins(fftSize: size, sampleRate: sampleRate))
    }

    deinit {
        window.deallocate()
        bandRuns.deallocate()
        runFirst.deallocate()
        runCount.deallocate()
        scratch.deallocate()
    }

    /// Each band's level in decibels, of a frame given in two pieces: its first `older` samples at `first`, the rest at
    /// `second`. A ring of the last frame's samples is read this way without being moved.
    @_noAllocation @_noLocks
    @inlinable public func levels(_ first: UnsafePointer<Float>, older: Int, _ second: UnsafePointer<Float>, into level: UnsafeMutablePointer<Float>, floor: Float, roundsToHalf: Bool) {
        let size = frameSize
        if older > 0 { BandListenerKernel.multiply(first, window, into: scratch, older) }
        if older < size { BandListenerKernel.multiply(second, window + older, into: scratch + older, size - older) }
        fft.forward(scratch, into: frame)
        let real = frame.realStorage, imaginary = frame.imaginaryStorage
        for band in 0..<bandCount {
            var sum: Float = 0
            for run in Int(bandRuns[band])..<Int(bandRuns[band + 1]) {
                let first = Int(runFirst[run])
                var part: Float = 0
                for bin in first..<(first + Int(runCount[run])) { part += real[bin] * real[bin] + imaginary[bin] * imaginary[bin] }
                sum += part
            }
            let decibels = 10 * RealtimeMath.log10(sum + floor)
            level[band] = roundsToHalf ? BandListenerKernel.half(decibels) : decibels
        }
    }

    /// Each band's level in decibels, of a frame of `frameSize` samples.
    @_noAllocation @_noLocks
    @inlinable public func levels(of samples: UnsafePointer<Float>, into level: UnsafeMutablePointer<Float>, floor: Float, roundsToHalf: Bool) {
        levels(samples, older: 0, samples, into: level, floor: floor, roundsToHalf: roundsToHalf)
    }

    /// Moves a running spectrum and loudness on by one frame of levels: the power each level stands for, followed by
    /// a one-pole average, and their total by another. The first frame, `fresh`, sets both where it is.
    /// - Parameters:
    ///   - slow: the running power per band, `bands` values.
    ///   - loudness: the running total power.
    @_noAllocation @_noLocks
    @inlinable public static func follow(_ level: UnsafePointer<Float>, bands: Int, slow: UnsafeMutablePointer<Double>, loudness: inout Double,
                                         fresh: Bool, slowKeep: Double, loudnessKeep: Double) {
        var total = 0.0
        for band in 0..<bands {
            let power = RealtimeMath.pow(10, Double(level[band]) / 10)
            total += power
            slow[band] = fresh ? power : slowKeep * slow[band] + (1 - slowKeep) * power
        }
        loudness = fresh ? total : loudnessKeep * loudness + (1 - loudnessKeep) * total
    }
}

/// Hears a signal as it plays and keeps its band spectrum: the level of each band in the newest frame, and a running
/// spectrum and loudness that remember the song so far.
///
/// What it remembers can be read out and put back (`restore`), so that playback can start in the middle of a song
/// with the listener as it would be had it heard everything before.
///
/// Memory is reserved when it is made, so make it away from the audio thread.
public struct BandListener: ~Copyable {
    @usableFromInline struct State {
        /// Samples heard since the last reset.
        @usableFromInline var heard = 0
        /// Where the ring is written next.
        @usableFromInline var write = 0
        @usableFromInline var hasHistory = false
        @usableFromInline var loudness = 0.0
        /// Frames analysed since the last reset.
        @usableFromInline var frames = 0

        @inlinable init() {}
    }

    public let analyser: BandAnalyser
    /// The newest frame's level per band in decibels, as of the last `analyse`.
    public let level: UnsafeMutablePointer<Float>
    /// The running power per band.
    public let slow: UnsafeMutablePointer<Double>
    /// The last frame's samples, oldest at `write`.
    @usableFromInline let ring: UnsafeMutablePointer<Float>
    @usableFromInline let state: UnsafeMutablePointer<State>

    public init(analyser: consuming BandAnalyser) {
        let size = analyser.frameSize, bands = analyser.bandCount
        self.analyser = analyser
        level = Memory.floats(bands)
        slow = Memory.doubles(bands)
        ring = Memory.floats(size)
        state = .allocate(capacity: 1)
        state.initialize(to: State())
    }

    deinit {
        level.deallocate()
        slow.deallocate()
        ring.deallocate()
        state.deallocate()
    }

    @inlinable public var frameSize: Int { analyser.frameSize }
    @inlinable public var bandCount: Int { analyser.bandCount }
    /// Samples heard since the last reset.
    @inlinable public var heard: Int { @_noAllocation @_noLocks get { state.pointee.heard } }
    /// Whether a whole frame has been heard since the last reset.
    @inlinable public var isFull: Bool { @_noAllocation @_noLocks get { state.pointee.heard >= analyser.frameSize } }
    /// Whether the running spectrum holds anything: it has analysed a frame, or had a memory put back.
    @inlinable public var hasHistory: Bool { @_noAllocation @_noLocks get { state.pointee.hasHistory } }
    /// The running total power.
    @inlinable public var loudness: Double { @_noAllocation @_noLocks get { state.pointee.loudness } }
    /// Frames analysed since the last reset.
    @inlinable public var frames: Int { @_noAllocation @_noLocks get { state.pointee.frames } }

    /// Forgets everything heard.
    @_noAllocation @_noLocks
    @inlinable public func reset() {
        state.pointee = State()
        Memory.zero(ring, analyser.frameSize)
        Memory.zero(slow, analyser.bandCount)
        Memory.zero(level, analyser.bandCount)
    }

    /// Hears a stretch of a signal: one channel, or the mean of two.
    @_noAllocation @_noLocks
    @inlinable public func hear(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>?, frames: Int) {
        let mask = analyser.frameSize - 1, write = state.pointee.write
        if let right {
            for index in 0..<frames { ring[(write + index) & mask] = 0.5 * (left[index] + right[index]) }
        } else {
            for index in 0..<frames { ring[(write + index) & mask] = left[index] }
        }
        state.pointee.write = (write + frames) & mask
        state.pointee.heard += frames
    }

    /// Analyses the last frame heard: its levels, and the running spectrum and loudness moved on by them.
    @_noAllocation @_noLocks
    @inlinable public func analyse(_ plan: BandListenerPlan) {
        let size = analyser.frameSize, oldest = state.pointee.write
        analyser.levels(ring + oldest, older: size - oldest, ring, into: level, floor: plan.floor, roundsToHalf: plan.roundsToHalf)
        BandAnalyser.follow(level, bands: analyser.bandCount, slow: slow, loudness: &state.pointee.loudness, fresh: !state.pointee.hasHistory,
                            slowKeep: plan.slowKeep, loudnessKeep: plan.loudnessKeep)
        state.pointee.hasHistory = true
        state.pointee.frames += 1
    }

    /// The last frame heard, oldest sample first, into `frameSize` values.
    @_noAllocation @_noLocks
    @inlinable public func recent(into destination: UnsafeMutablePointer<Float>) {
        let size = analyser.frameSize, oldest = state.pointee.write
        for index in 0..<(size - oldest) { destination[index] = ring[oldest + index] }
        for index in 0..<oldest { destination[size - oldest + index] = ring[index] }
    }

    /// Puts a frame in place as the last one heard, oldest sample first; what has been heard is otherwise left as it is.
    @_noAllocation @_noLocks
    @inlinable public func load(recent samples: UnsafePointer<Float>) {
        for index in 0..<analyser.frameSize { ring[index] = samples[index] }
        state.pointee.write = 0
    }

    /// Puts a running spectrum and loudness in place, as saved from a listener that heard the song up to here.
    @_noAllocation @_noLocks
    @inlinable public func restore(slow saved: UnsafePointer<Double>, loudness: Double) {
        for band in 0..<analyser.bandCount { slow[band] = saved[band] }
        state.pointee.loudness = loudness
        state.pointee.hasHistory = true
    }

    /// Puts back everything a listener remembers: the running spectrum and loudness, the last frame heard and how
    /// much it has heard.
    @_noAllocation @_noLocks
    @inlinable public func restore(slow saved: UnsafePointer<Double>, loudness: Double, recent samples: UnsafePointer<Float>, heard: Int) {
        restore(slow: saved, loudness: loudness)
        load(recent: samples)
        state.pointee.heard = heard
    }
}

/// Keeps a signal at its own level under a curve: one gain added to every band, worked out in the power domain from
/// a spectrum of the signal, that leaves the spectrum's summed power where it was. With `P` the power in each band and
/// `g` the curve as applied, the gain is `-10 log10(sum(P 10^(g/10)) / sum(P))`, held within a limit.
@frozen public struct LevelHold: BitwiseCopyable, Sendable {
    /// The gain goes no further than this either way, in decibels.
    public var limitDB: Double

    @inlinable public init(limitDB: Double) { self.limitDB = limitDB }

    /// The gain for a curve.
    /// - Parameters:
    ///   - curve: `bands` gains in decibels, scaled by `amount`.
    ///   - power: the signal's power, `perBand` values for each band of the curve, summed for it.
    /// - Returns: 0 when there is no power to go by.
    @_noAllocation @_noLocks
    @inlinable public func trim(curve: UnsafePointer<Float>, amount: Float, bands: Int, power: UnsafePointer<Double>, perBand: Int) -> Float {
        var before = 0.0, after = 0.0
        for band in 0..<bands {
            var sum = power[perBand * band]
            for part in 1..<max(perBand, 1) { sum += power[perBand * band + part] }
            before += sum
            after += sum * RealtimeMath.pow(10, Double(curve[band] * amount) / 10)
        }
        guard before > 0, after > 0 else { return 0 }
        return Float(min(max(-10 * RealtimeMath.log10(after / before), -limitDB), limitDB))
    }
}

/// Where a reference EQ's curve comes from each time it makes one. A closed choice, so the audio thread's code is
/// known in full.
@frozen public enum ReferenceCurveSource {
    /// A curve handed in: `bandCount` gains in decibels, read each time a curve is made.
    case given(UnsafePointer<Float>)
    /// The match toward a reference shape (`BandMatch`), made from the listener's running spectrum.
    /// - Parameters:
    ///   - reference: the shape wanted, a level-free value per band of the curve in decibels.
    ///   - scratch: working space, `ReferenceEQ.scratchCount(for:)` values.
    case match(BandMatch, reference: UnsafePointer<Double>, scratch: UnsafeMutablePointer<Double>)
}

/// An equaliser that listens to a signal as it plays and shapes it by a curve made from what it heard: the listener,
/// a source for the curve, the level hold and a `BandCurveFilter` to apply it with no delay.
///
/// Every hop of the filter, at the end of the hop, the listener analyses the last frame heard, a curve is made from it
/// and the filter begins its fade to that curve. The listener hears the signal as it arrives, before the filter.
///
/// There are two ways to drive it. `process` takes the curve from a `ReferenceCurveSource` and does everything. A
/// caller whose curve comes from elsewhere (a model of its own) uses the steps `process` is made of: `begin`, then
/// `pass` up to the end of each hop, then at the end of a hop `analyse` (or nothing) and `turn`, and `shouldRest` at
/// the end of the block.
///
/// Memory is reserved when it is made, so make it away from the audio thread.
public struct ReferenceEQ: ~Copyable {
    public let listener: BandListener
    public let filter: BandCurveFilter
    /// The curve last made, `bandCount` gains in decibels at full amount.
    public let curve: UnsafeMutablePointer<Float>
    /// The level hold's gain in force, in decibels; 0 without a hold.
    public let trim: UnsafeMutablePointer<Float>
    /// Keeps what passes at its own level, from the listener's running spectrum; nil leaves the level to the curve.
    public let hold: LevelHold?
    /// How many of the listener's bands make one of the curve's.
    public let listenerBandsPerBand: Int
    /// A memory was put in place (`restore`): the filter for its curve is designed at the next block.
    @usableFromInline let needsDesign: UnsafeMutablePointer<Bool>

    /// - Parameters:
    ///   - listener: its bands are the curve's, or each of the curve's bands is made of the same number of them in a
    ///     row.
    ///   - hold: keep what passes at its own level, within the hold's limit.
    public init(listener: consuming BandListener, filter: consuming BandCurveFilter, hold: LevelHold? = nil) {
        let bands = filter.bandCount
        precondition(listener.bandCount % bands == 0, "a reference EQ's listener has a whole number of bands for each of the curve's")
        listenerBandsPerBand = listener.bandCount / bands
        self.listener = listener
        self.filter = filter
        self.hold = hold
        curve = Memory.floats(bands)
        trim = Memory.floats(1)
        needsDesign = .allocate(capacity: 1)
        needsDesign.initialize(to: false)
    }

    deinit {
        curve.deallocate()
        trim.deallocate()
        needsDesign.deallocate()
    }

    @inlinable public var bandCount: Int { filter.bandCount }
    /// The working space a match source needs, in values: the match's own, and two rows of the curve's bands.
    @inlinable public func scratchCount(for match: BandMatch) -> Int { match.scratchCount(bands: filter.bandCount) + 2 * filter.bandCount }
    /// How many samples it can pass before the hop ends and the next curve is due.
    @inlinable public var room: Int { @_noAllocation @_noLocks get { filter.room } }

    /// Forgets everything heard and goes back to a wire.
    @_noAllocation @_noLocks
    @inlinable public func reset() {
        listener.reset()
        filter.reset()
        Memory.zero(curve, filter.bandCount)
        trim.pointee = 0
        needsDesign.pointee = false
    }

    /// Puts it where it would be had it heard its signal from the top: the listener's memory, the curve last made,
    /// and how far into the hop the place is. Call after `reset`; the filter starts with nothing in it, and the curve is
    /// in force from the first sample of the next block.
    @_noAllocation @_noLocks
    @inlinable public func restore(slow: UnsafePointer<Double>, loudness: Double, recent: UnsafePointer<Float>, heard: Int, curve last: UnsafePointer<Float>, phase: Int) {
        listener.restore(slow: slow, loudness: loudness, recent: recent, heard: max(heard, 1))
        for band in 0..<filter.bandCount { curve[band] = last[band] }
        filter.reset(phase: phase)
        needsDesign.pointee = true
    }

    /// The level hold's gain for the curve in force, put in `trim`: nothing without a hold, or when no curve is
    /// being made.
    @_noAllocation @_noLocks
    @inlinable public func holdLevel(amount: Float, working: Bool) {
        trim.pointee = 0
        guard let hold, working else { return }
        trim.pointee = hold.trim(curve: curve, amount: amount, bands: filter.bandCount, power: listener.slow, perBand: listenerBandsPerBand)
    }

    /// The start of a block. Returns false when there is nothing to do: off, a wire, and nothing heard. A memory put
    /// in place comes into force here, if it is on.
    @_noAllocation @_noLocks
    @inlinable public func begin(isOn: Bool, amount: Float) -> Bool {
        guard isOn || filter.isFiltering || listener.heard > 0 else { return false }
        if needsDesign.pointee {
            needsDesign.pointee = false
            if isOn {
                holdLevel(amount: amount, working: true)
                if !filter.isNothing(curve, amount: amount, offsetDB: trim.pointee) { filter.start(with: curve, amount: amount, offsetDB: trim.pointee) }
            }
        }
        return true
    }

    /// Lets the listener hear a stretch of the signal and runs it through the filter in place.
    /// - Parameter frames: no more than `room`.
    /// - Returns: whether the hop ended with this stretch. If it did, make the next curve and call `turn` before
    ///   passing any more.
    @_noAllocation @_noLocks
    @inlinable public func pass(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        listener.hear(left, right, frames: frames)
        return filter.pass(left, right, frames: frames)
    }

    /// At the end of a hop, with `curve` made (or zeroed when `working` is false): the level held and the fade to the
    /// curve begun. A curve of nothing is a wire.
    @_noAllocation @_noLocks
    @inlinable public func turn(amount: Float, working: Bool) {
        holdLevel(amount: amount, working: working)
        let flat = filter.isNothing(curve, amount: amount, offsetDB: trim.pointee)
        filter.turn(to: flat ? nil : UnsafePointer(curve), amount: amount, offsetDB: trim.pointee)
    }

    /// The end of a block: whether, off and faded out, it should forget everything so that switching on again starts
    /// afresh.
    @_noAllocation @_noLocks
    @inlinable public func shouldRest(isOn: Bool) -> Bool { !isOn && !filter.isFiltering }

    /// Makes the next curve from a source, into `curve`, once the listener has analysed the frame.
    @_noAllocation @_noLocks
    @inlinable public func makeCurve(_ source: ReferenceCurveSource) {
        let bands = filter.bandCount
        switch source {
        case .given(let given):
            for band in 0..<bands { curve[band] = given[band] }
        case .match(let match, let reference, let scratch):
            // The running spectrum on the curve's bands, then the match.
            let power = scratch, gains = scratch + bands
            for band in 0..<bands {
                var sum = listener.slow[listenerBandsPerBand * band]
                for part in 1..<max(listenerBandsPerBand, 1) { sum += listener.slow[listenerBandsPerBand * band + part] }
                power[band] = sum
            }
            _ = match.curve(power: power, reference: reference, bands: bands, into: gains, scratch: scratch + 2 * bands)
            for band in 0..<bands { curve[band] = Float(gains[band]) }
        }
    }

    /// Runs a stereo signal through it in place.
    /// - Parameters:
    ///   - isOn: off, the curve goes flat over the next hop, and then nothing is done and everything is forgotten.
    ///   - amount: scales the curve in decibels.
    ///   - source: where each curve comes from.
    ///   - plan: how the listener analyses each frame.
    @_noAllocation @_noLocks
    @inlinable public func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int, isOn: Bool, amount: Float,
                                   source: ReferenceCurveSource, plan: BandListenerPlan) {
        guard begin(isOn: isOn, amount: amount) else { return }
        var done = 0
        while done < frames {
            let count = min(room, frames - done)
            let ended = pass(left + done, right + done, frames: count)
            done += count
            guard ended else { continue }
            let working = isOn && listener.isFull
            if working {
                listener.analyse(plan)
                makeCurve(source)
            } else {
                Memory.zero(curve, filter.bandCount)
            }
            turn(amount: amount, working: working)
        }
        if shouldRest(isOn: isOn) { reset() }
    }
}
