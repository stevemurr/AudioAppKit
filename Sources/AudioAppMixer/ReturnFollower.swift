import AudioAppCore
import AudioAppDSP
import AudioAppRealtime
import Darwin

/// How a return is kept under what it is added to: the follower's numbers, as the audio thread reads them.
@frozen public struct ReturnFollowerPlan: BitwiseCopyable, Sendable {
    /// Off, the return passes untouched (it is still listened to): for hearing a return by itself.
    public var clears: Bool
    /// The return may be this many decibels against the dry signal in a band before it is turned down, and by this
    /// much at most.
    public var margin: Double
    public var most: Double
    /// The key's rule: this much more where the key is the band, between these two shares of the dry signal's power.
    public var key: Double
    public var shareLow: Double
    public var shareHigh: Double
    /// What a cut keeps of itself each hop.
    public var keep: Double
    /// A return whose power in a band is under this is no return: nothing is turned down there.
    public var silent: Double

    /// - Parameters:
    ///   - keyShare: the shares of the dry signal's power between which the key's cut comes in.
    ///   - releaseSeconds: a cut is made at once and let go over this long.
    ///   - hop, sampleRate: the follower's own, which turn the release into what a cut keeps each hop.
    ///   - silent: the band power under which there is no return to turn down.
    public init(clears: Bool = true, marginDB: Double, mostDB: Double, keyDB: Double = 0, keyShare: (Double, Double) = (0.25, 0.75), releaseSeconds: Double,
                hop: Int, sampleRate: SampleRate, silent: Double = 0) {
        self.clears = clears
        margin = marginDB
        most = mostDB
        key = keyDB
        shareLow = keyShare.0
        shareHigh = keyShare.1
        keep = exp(-Double(hop) / (releaseSeconds * sampleRate.hertz))
        self.silent = silent
    }
}

/// Keeps a return under the mix it is added to, band by band, and further where a key signal holds the band: a
/// reverb that stays out of the way of the dry mix, and most of all out of the way of the lead.
///
/// Every hop it measures the return, the dry mix and the key over the last frame, in the bands of its layout, and
/// makes a row of cuts: where the return stands more than the margin over the dry mix it is turned down by the
/// excess, and by more where the key has most of the dry mix's power. A cut is made at once and let go slowly. The
/// row is applied to the return with no delay, by a `BandCurveFilter`.
///
/// Memory is reserved when it is made, so make it away from the audio thread.
public struct ReturnFollower: ~Copyable {
    @usableFromInline struct State {
        /// Samples into the current hop of the timeline.
        @usableFromInline var hopPhase = 0
        /// Samples heard since the start, up to a frame's worth; where the frames' rings are written next.
        @usableFromInline var filled = 0
        @usableFromInline var write = 0
        @usableFromInline var hasRow = false
        /// Rows made since the start.
        @usableFromInline var rows = 0

        @inlinable init(hopPhase: Int = 0) { self.hopPhase = hopPhase }
    }

    public let bandCount: Int
    /// The frame each row is measured over, in samples: a power of two.
    public let frameSize: Int
    public let hop: Int
    /// The row in force: `bandCount` gains in decibels, none above nothing.
    public let row: UnsafeMutablePointer<Float>
    @usableFromInline let state: UnsafeMutablePointer<State>
    /// The last frame of the return before its cuts, the dry mix and the key, each side.
    @usableFromInline let rings: UnsafeMutablePointer<Float>
    @usableFromInline let window: UnsafeMutablePointer<Float>
    /// The runs of bins each band sums: band `b` has the runs from `bandRuns[b]` up to `bandRuns[b + 1]`.
    @usableFromInline let bandRuns: UnsafeMutablePointer<Int32>
    @usableFromInline let runFirst: UnsafeMutablePointer<Int32>
    @usableFromInline let runCount: UnsafeMutablePointer<Int32>
    @usableFromInline let power: UnsafeMutablePointer<Double>
    @usableFromInline let scratch: UnsafeMutablePointer<Float>
    @usableFromInline let fft: FFT
    @usableFromInline let frame: SpectralFrame
    @usableFromInline let filter: BandCurveFilter

    /// - Parameters:
    ///   - frameSize: the frame each row is measured over, rounded up to a power of two.
    ///   - hop: how often a row is made.
    ///   - window: the frame's window, `frameSize` values; a Hann window when not given.
    ///   - bandBins: for each band the runs of bins whose power is the band's; the layout's own when not given.
    ///   - taps, designSize, fade: the filter that applies the rows, as `BandCurveFilter` takes them.
    public init(layout: BandCurveLayout, sampleRate: SampleRate, frameSize: Int, hop: Int, window: [Float]? = nil, bandBins: [[Range<Int>]]? = nil,
                taps: Int, designSize: Int, fade: Int? = nil) {
        fft = FFT(size: frameSize)
        let size = fft.size
        frame = SpectralFrame(fftSize: size)
        bandCount = layout.bandCount
        self.frameSize = size
        self.hop = max(1, hop)
        filter = BandCurveFilter(layout: layout, sampleRate: sampleRate, hop: self.hop, taps: taps, designSize: designSize, fade: fade)
        state = .allocate(capacity: 1)
        state.initialize(to: State())
        func floats(_ count: Int) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
            return pointer
        }
        rings = floats(6 * size)
        self.window = floats(size)
        let shape = window ?? Window.hann.values(count: size)
        for index in 0..<min(size, shape.count) { self.window[index] = shape[index] }
        let bins = bandBins ?? layout.bins(fftSize: size, sampleRate: sampleRate)
        let runs = (0..<bandCount).map { band in band < bins.count ? bins[band].map { $0.clamped(to: 0..<(size / 2 + 1)) } : [] }
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
        row = floats(bandCount)
        power = .allocate(capacity: 3 * bandCount)
        power.initialize(repeating: 0, count: 3 * bandCount)
        scratch = floats(size)
    }

    deinit {
        state.deallocate()
        rings.deallocate()
        window.deallocate()
        bandRuns.deallocate()
        runFirst.deallocate()
        runCount.deallocate()
        row.deallocate()
        power.deallocate()
        scratch.deallocate()
    }

    /// How many rows it has made since the start.
    @inlinable public var rowCount: Int { state.pointee.rows }

    /// How many samples it can take before its next row is due: a caller that works in blocks of its own keeps
    /// within it.
    @inlinable public var room: Int { @_noAllocation @_noLocks get { hop - state.pointee.hopPhase } }

    /// Nothing heard, nothing turned down: for the start of playback, a jump, a new session.
    /// - Parameter position: where on the timeline it starts, which says where its hops fall.
    @_noAllocation @_noLocks
    @inlinable public func reset(at position: Int = 0) {
        state.pointee = State(hopPhase: ((position % hop) + hop) % hop)
        for index in 0..<(6 * frameSize) { rings[index] = 0 }
        for band in 0..<bandCount { row[band] = 0 }
        filter.reset()
    }

    /// Turns a return down in place, band by band, under what it is about to be added to.
    /// - Parameters:
    ///   - left, right: the return.
    ///   - heard: the gain the return still has to pass on its way into `dry`: it is measured as it will arrive.
    ///   - dry: the mix without the return.
    ///   - key: the part of that mix the return is to stay furthest out of the way of.
    @_noAllocation @_noLocks
    @inlinable public func follow(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, heard: Float,
                                  dry dryLeft: UnsafePointer<Float>, _ dryRight: UnsafePointer<Float>,
                                  key keyLeft: UnsafePointer<Float>, _ keyRight: UnsafePointer<Float>, frames: Int, _ plan: ReturnFollowerPlan) {
        let size = frameSize
        var done = 0
        while done < frames {
            let count = min(frames - done, hop - state.pointee.hopPhase)
            let write = state.pointee.write
            for side in 0..<2 {
                let from = (side == 0 ? left : right) + done, dry = (side == 0 ? dryLeft : dryRight) + done, key = (side == 0 ? keyLeft : keyRight) + done
                let wet = rings + side * size, mix = rings + (2 + side) * size, lead = rings + (4 + side) * size
                for frame in 0..<count {
                    let to = (write + frame) & (size - 1)
                    wet[to] = heard * from[frame]
                    mix[to] = dry[frame]
                    lead[to] = key[frame]
                }
            }
            state.pointee.write = (write + count) & (size - 1)
            state.pointee.filled = min(state.pointee.filled + count, size)
            filter.process(left + done, right + done, frames: count, rows: plan.clears ? UnsafePointer(row) : nil, rowCount: 1, position: 0, amount: 1)
            done += count
            state.pointee.hopPhase += count
            if state.pointee.hopPhase == hop {
                state.pointee.hopPhase = 0
                if state.pointee.filled >= size { makeRow(plan) }
            }
        }
    }

    /// The row for the frame that ends here: made from the return's, the dry mix's and the key's band power over
    /// the last frame, and from the row before.
    @_noAllocation @_noLocks
    @inlinable public func makeRow(_ plan: ReturnFollowerPlan) {
        let size = frameSize, bands = bandCount
        let oldest = state.pointee.write
        let real = frame.real.baseAddress!, imaginary = frame.imaginary.baseAddress!
        for signal in 0..<3 {
            let total = power + signal * bands
            for band in 0..<bands { total[band] = 0 }
            for side in 0..<2 {
                let kept = rings + (signal * 2 + side) * size
                for index in 0..<(size - oldest) { scratch[index] = kept[oldest + index] * window[index] }
                for index in 0..<oldest { scratch[size - oldest + index] = kept[index] * window[size - oldest + index] }
                fft.forward(scratch, into: frame)
                for band in 0..<bands {
                    var sum: Float = 0
                    for run in Int(bandRuns[band])..<Int(bandRuns[band + 1]) {
                        let first = Int(runFirst[run])
                        var part: Float = 0
                        for bin in first..<(first + Int(runCount[run])) { part += real[bin] * real[bin] + imaginary[bin] * imaginary[bin] }
                        sum += part
                    }
                    total[band] += Double(sum)
                }
            }
        }
        let keep = plan.keep
        for band in 0..<bands {
            let wet = power[band], dry = power[bands + band], lead = power[2 * bands + band]
            var gain = 0.0
            // No return in the band, nothing to turn down.
            if wet >= plan.silent, wet > 0 {
                let over = 10 * RealtimeMath.log10(max(wet, 1e-30) / max(dry, 1e-30)) - plan.margin
                gain = -min(max(over, 0), plan.most)
                let share = lead / max(dry, 1e-30)
                gain -= plan.key * min(max((share - plan.shareLow) / (plan.shareHigh - plan.shareLow), 0), 1)
            }
            // A cut is made at once and let go slowly.
            if state.pointee.hasRow {
                let before = Double(row[band])
                gain = min(gain, keep * before + (1 - keep) * gain)
            }
            row[band] = Float(gain)
        }
        state.pointee.hasRow = true
        state.pointee.rows += 1
    }
}
