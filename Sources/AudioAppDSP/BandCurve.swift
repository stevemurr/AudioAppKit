import Accelerate
import AudioAppCore
import AudioAppRealtime
import Darwin

/// Where the bands of a curve sit, and how a frequency between two of them takes from each.
///
/// A curve is one gain in decibels per band. Between two bands' centres the gain is read off a straight line in
/// decibels along the layout's own axis; below the first centre and above the last it holds their values.
public struct BandCurveLayout: Sendable {
    /// An axis that bands can be spaced evenly along.
    @frozen public enum Scale: Hashable, Sendable {
        /// The ERB-rate scale, which follows the ear's own filters.
        case erb
        case mel
        /// Equal ratios of frequency.
        case octave

        public func position(of hertz: Double) -> Double {
            switch self {
            case .erb: 21.4 * log10(1 + 0.00437 * hertz)
            case .mel: 2595 * log10(1 + hertz / 700)
            case .octave: log2(hertz)
            }
        }

        public func hertz(at position: Double) -> Double {
            switch self {
            case .erb: (pow(10, position / 21.4) - 1) / 0.00437
            case .mel: 700 * (pow(10, position / 2595) - 1)
            case .octave: pow(2, position)
            }
        }
    }

    enum Placement: Sendable {
        case spaced(Scale, low: Double, high: Double)
        case centred([Double])
    }

    public let bandCount: Int
    let placement: Placement

    /// Bands of equal width on a scale between two frequencies, each centred in the middle of its width.
    public static func spaced(_ scale: Scale, bands: Int, from low: Double, to high: Double) -> BandCurveLayout {
        BandCurveLayout(bandCount: max(2, bands), placement: .spaced(scale, low: low, high: high))
    }

    /// Bands of equal width on the ERB-rate scale.
    public static func erb(bands: Int, from low: Double = 20, to high: Double = 20_000) -> BandCurveLayout {
        spaced(.erb, bands: bands, from: low, to: high)
    }

    /// Bands with the given centres in hertz, lowest first and at least two; between them the gain is read off a
    /// straight line in decibels against the logarithm of frequency.
    public init(centres: [Double]) {
        let sorted = centres.sorted()
        precondition(sorted.count >= 2, "a band curve needs two bands at least")
        self.init(bandCount: sorted.count, placement: .centred(sorted))
    }

    init(bandCount: Int, placement: Placement) {
        self.bandCount = bandCount
        self.placement = placement
    }

    /// Each band's centre in hertz.
    public var centres: [Double] {
        switch placement {
        case .centred(let centres): return centres
        case .spaced(let scale, let low, let high):
            let a = scale.position(of: low), b = scale.position(of: high)
            let width = (b - a) / Double(bandCount)
            return (0..<bandCount).map { scale.hertz(at: a + width * (Double($0) + 0.5)) }
        }
    }

    /// Where each band begins and the last one ends, in hertz: one more than the band count. Bands given by their
    /// centres meet half-way between them on a logarithmic axis.
    public var edges: [Double] {
        switch placement {
        case .spaced(let scale, let low, let high):
            let a = scale.position(of: low), b = scale.position(of: high)
            return (0...bandCount).map { $0 == bandCount ? high : scale.hertz(at: a + (b - a) * Double($0) / Double(bandCount)) }
        case .centred(let centres):
            let between = (1..<bandCount).map { (centres[$0 - 1] * centres[$0]).squareRoot() }
            return [centres[0] * centres[0] / between[0]] + between + [centres[bandCount - 1] * centres[bandCount - 1] / between[bandCount - 2]]
        }
    }

    /// For each band, the bins of an FFT whose power is the band's: those from its lower edge up to its upper one.
    /// A band narrower than a bin takes the bin nearest its middle. Each band's bins are given as runs, to be summed
    /// a run at a time.
    public func bins(fftSize size: Int, sampleRate: SampleRate) -> [[Range<Int>]] {
        let edges = edges, count = size / 2 + 1, perBin = sampleRate.hertz / Double(size)
        return (0..<bandCount).map { band in
            let inside = (0..<count).filter { Double($0) * perBin >= edges[band] && Double($0) * perBin < edges[band + 1] }
            if let first = inside.first { return [first..<(first + inside.count)] }
            let nearest = min(max(Int(((edges[band] + edges[band + 1]) / 2 / perBin).rounded()), 0), count - 1)
            return [nearest..<(nearest + 1)]
        }
    }

    /// For each bin of an FFT, the lower of the two bands it takes from and how far it leans to the upper one: a
    /// bin's gain in decibels is `(1 - lean) * curve[band] + lean * curve[band + 1]`.
    public func weights(fftSize size: Int, sampleRate: SampleRate) -> (band: [Int32], lean: [Float]) {
        let bins = size / 2 + 1, bands = bandCount
        var band = [Int32](repeating: 0, count: bins)
        var lean = [Float](repeating: 0, count: bins)
        switch placement {
        case .spaced(let scale, let lowHz, let highHz):
            let low = scale.position(of: lowHz), high = scale.position(of: highHz)
            let width = (high - low) / Double(bands)
            let first = low + width / 2  // the first band's centre on the scale
            for bin in 0..<bins {
                let frequency = Double(bin) * sampleRate.hertz / Double(size)
                let position = min(max((scale.position(of: frequency) - first) / width, 0), Double(bands - 1))
                let lower = min(max(Int(position.rounded(.down)), 0), bands - 2)
                band[bin] = Int32(lower)
                lean[bin] = Float(position - Double(lower))
            }
        case .centred(let centres):
            let places = centres.map { log2($0) }
            for bin in 1..<bins {
                let x = log2(Double(bin) * sampleRate.hertz / Double(size))
                var lower = 0
                while lower < bands - 2, places[lower + 1] <= x { lower += 1 }
                band[bin] = Int32(lower)
                lean[bin] = Float(min(max((x - places[lower]) / (places[lower + 1] - places[lower]), 0), 1))
            }
        }
        return (band, lean)
    }
}

/// Turns a curve of band gains into a filter that delays nothing.
///
/// The curve is read onto the bins of an FFT and made into a minimum-phase impulse response by the homomorphic
/// method: the log of the magnitude is taken back to the cepstrum, the half of the cepstrum that would put energy
/// before time zero is folded onto the other half, and the result is taken forward, exponentiated and back. What
/// comes out has the wanted magnitude and all of its energy as early as possible.
///
/// Setting one up reserves memory, so do it away from the audio thread. Designing is safe on the audio thread. One
/// design serves one thread at a time.
public struct BandCurveDesign: ~Copyable {
    public let bandCount: Int
    @usableFromInline let fft: FFT
    @usableFromInline let frame: SpectralFrame
    /// For each bin: the lower of the two bands it takes from, and how far it leans to the upper.
    @usableFromInline let band: UnsafeMutablePointer<Int32>
    @usableFromInline let lean: UnsafeMutablePointer<Float>
    @usableFromInline let scratch: UnsafeMutablePointer<Float>

    /// - Parameter size: the FFT the response is worked out on, rounded up to a power of two. The response is as
    ///   long; make it several times the taps that will be kept, so that what is cut off is small.
    public init(layout: BandCurveLayout, sampleRate: SampleRate, size: Int) {
        bandCount = layout.bandCount
        fft = FFT(size: size)
        frame = SpectralFrame(fftSize: fft.size)
        let bins = fft.size / 2 + 1
        let weights = layout.weights(fftSize: fft.size, sampleRate: sampleRate)
        band = .allocate(capacity: bins)
        band.initialize(from: weights.band, count: bins)
        lean = Memory.floats(bins)
        lean.update(from: weights.lean, count: bins)
        scratch = Memory.floats(fft.size)
    }

    deinit {
        band.deallocate()
        lean.deallocate()
        scratch.deallocate()
    }

    /// How long the response is: the size of the FFT it is worked out on.
    @inlinable public var size: Int { fft.size }

    /// The curve's minimum-phase impulse response, `size` samples. They are this design's own memory, good until
    /// it is next used.
    /// - Parameters:
    ///   - curve: `bandCount` gains in decibels.
    ///   - amount: scales the curve in decibels.
    ///   - offsetDB: one gain added to every band, after the amount.
    @_noAllocation @_noLocks
    @inlinable @discardableResult public func response(of curve: UnsafePointer<Float>, amount: Float = 1, offsetDB: Float = 0) -> UnsafeMutablePointer<Float> {
        let size = fft.size, bins = size / 2 + 1
        let real = frame.realStorage, imaginary = frame.imaginaryStorage
        // ln|H| per bin: dB * ln(10) / 20
        let scale = amount * 0.115_129_254_649_702_28
        for bin in 0..<bins {
            let lower = Int(band[bin])
            real[bin] = scale * (curve[lower] * (1 - lean[bin]) + curve[lower + 1] * lean[bin])
            imaginary[bin] = 0
        }
        if offsetDB != 0 {
            let level = offsetDB * 0.115_129_254_649_702_28
            for bin in 0..<bins { real[bin] += level }
        }
        let cepstrum = scratch
        fft.inverse(frame, into: cepstrum)
        for index in 1..<(size / 2) { cepstrum[index] *= 2 }
        for index in (size / 2 + 1)..<size { cepstrum[index] = 0 }
        fft.forward(cepstrum, into: frame)
        BandCurveKernel.exponential(real: real, imaginary: imaginary, scratch: cepstrum, bins)
        // The bottom and top bins of a real signal's spectrum have no imaginary part.
        imaginary[0] = 0
        imaginary[bins - 1] = 0
        fft.inverse(frame, into: cepstrum)
        return cepstrum
    }

    /// The response cut to its first `taps` samples, the last `fade` of them faded out: an FIR filter.
    /// - Parameter destination: room for `taps` samples; it may be the response's own memory.
    @_noAllocation @_noLocks
    @inlinable public func filter(of curve: UnsafePointer<Float>, amount: Float = 1, offsetDB: Float = 0, into destination: UnsafeMutablePointer<Float>, taps: Int, fade: Int) {
        let whole = response(of: curve, amount: amount, offsetDB: offsetDB)
        let kept = min(taps, fft.size), faded = min(max(fade, 0), kept)
        for index in 0..<kept { destination[index] = whole[index] }
        for index in 0..<faded {
            let weight = 0.5 * (1 + cos(Float.pi * Float(index + 1) / Float(faded + 1)))
            destination[kept - faded + index] *= weight
        }
    }
}

/// Calls into the system's vector library for the band-curve filter. Plain arithmetic over memory the caller
/// supplies; marked trusted because the compiler's real-time checks cannot see into them.
@usableFromInline enum BandCurveKernel {
    /// Turns a log spectrum (`real` the log magnitude, `imaginary` the phase) into the spectrum itself, in place.
    @inlinable @inline(never) @_semantics("no_performance_analysis")
    static func exponential(real: UnsafeMutablePointer<Float>, imaginary: UnsafeMutablePointer<Float>, scratch: UnsafeMutablePointer<Float>, _ count: Int) {
        var length = Int32(count)
        vvexpf(real, real, &length)
        vvsincosf(scratch, imaginary, imaginary, &length)   // scratch = sin, imaginary = cos
        vDSP_vmul(real, 1, scratch, 1, scratch, 1, vDSP_Length(count))       // magnitude * sin
        vDSP_vmul(real, 1, imaginary, 1, real, 1, vDSP_Length(count))        // magnitude * cos
        for index in 0..<count { imaginary[index] = scratch[index] }
    }

    /// `out[n] = sum over q of filter[q] * input[n + taps - 1 - q]`: an FIR filter over `count` samples, where
    /// `input` starts `taps - 1` samples before the first one wanted.
    @inlinable @inline(never) @_semantics("no_performance_analysis")
    static func filter(_ input: UnsafePointer<Float>, _ filter: UnsafePointer<Float>, taps: Int, into out: UnsafeMutablePointer<Float>, _ count: Int) {
        vDSP_conv(input, 1, filter + (taps - 1), -1, out, 1, vDSP_Length(count), vDSP_Length(taps))
    }
}

/// Applies a curve of band gains to a stereo signal with no delay: an equaliser whose curve can change all the
/// time, for a place in a mix that cannot wait.
///
/// Every `hop` samples a minimum-phase FIR filter is designed from the curve that will be wanted when the fade to
/// it ends, and the signal is crossfaded from the filter before to that one. While the curve is nothing it is a
/// wire and costs nothing.
///
/// There are two ways to drive it. `process` takes rows of a curve laid out along a timeline (or one standing row)
/// and does everything. A caller that works its curve out as it goes uses the steps `process` is made of: `pass` up
/// to the end of a hop, then `turn` with the next curve.
///
/// Memory is reserved when it is made, so make it away from the audio thread.
public struct BandCurveFilter: ~Copyable {
    @usableFromInline struct State {
        /// How far through the current hop it is.
        @usableFromInline var phase = 0
        /// Which of the two filters is the newer.
        @usableFromInline var newer = 0
        @usableFromInline var isFlat = (true, true)
        /// Whether either of its two filters is anything but a wire.
        @usableFromInline var isFiltering = false
        @usableFromInline var isFresh = true

        @inlinable init(phase: Int = 0) { self.phase = phase }
    }

    public let bandCount: Int
    /// How often a new filter is designed, in samples.
    public let hop: Int
    public let taps: Int
    /// How many of the last taps are faded out.
    public let fade: Int
    /// A timeline's rows are this many samples apart, and each is heard `rowCentre` samples after it starts.
    public let rowSpacing: Int
    public let rowCentre: Int
    @usableFromInline let design: BandCurveDesign
    @usableFromInline let state: UnsafeMutablePointer<State>
    /// Two filters: the one being faded from and the one being faded to.
    @usableFromInline let filters: UnsafeMutablePointer<Float>
    /// Per channel: the last `taps - 1` input samples, then room for a hop.
    @usableFromInline let history: UnsafeMutablePointer<Float>
    /// Two hops: through the older filter, through the newer.
    @usableFromInline let outputs: UnsafeMutablePointer<Float>

    /// - Parameters:
    ///   - designSize: the FFT each filter is worked out on, a power of two several times `taps`.
    ///   - fade: how many of the last taps are faded out; an eighth of them when not given.
    ///   - rowSpacing: for `process` with rows along a timeline: how far apart the rows are, a hop when not given.
    ///   - rowCentre: how far after a row's start it is heard: half the frame a row was measured over.
    public init(layout: BandCurveLayout, sampleRate: SampleRate, hop: Int, taps: Int, designSize: Int, fade: Int? = nil, rowSpacing: Int? = nil, rowCentre: Int = 0) {
        design = BandCurveDesign(layout: layout, sampleRate: sampleRate, size: max(designSize, taps))
        bandCount = layout.bandCount
        self.hop = max(1, hop)
        self.taps = max(2, taps)
        self.fade = min(max(fade ?? self.taps / 8, 0), self.taps)
        self.rowSpacing = max(1, rowSpacing ?? self.hop)
        self.rowCentre = rowCentre
        state = .allocate(capacity: 1)
        state.initialize(to: State())
        filters = Memory.floats(2 * self.taps)
        filters[0] = 1
        filters[self.taps] = 1
        history = Memory.floats(2 * (self.taps - 1 + self.hop))
        outputs = Memory.floats(2 * self.hop)
    }

    deinit {
        state.deallocate()
        filters.deallocate()
        history.deallocate()
        outputs.deallocate()
    }

    /// Forgets what it has heard and goes back to a wire: for the start of playback, a seek, a new session.
    /// - Parameter phase: how far into a hop it starts.
    @_noAllocation @_noLocks
    @inlinable public func reset(phase: Int = 0) {
        state.pointee = State(phase: min(max(phase, 0), hop - 1))
        Memory.zero(history, 2 * (taps - 1 + hop))
        Memory.zero(filters, 2 * taps)
        filters[0] = 1
        filters[taps] = 1
    }

    /// How many samples it can pass before the hop ends and the next curve is due.
    @inlinable public var room: Int { @_noAllocation @_noLocks get { hop - state.pointee.phase } }

    /// Whether either of its two filters is anything but a wire. While neither is, `pass` leaves the signal alone.
    @inlinable public var isFiltering: Bool { @_noAllocation @_noLocks get { state.pointee.isFiltering } }

    /// The row of a timeline that the filter should have arrived at by `time`.
    @_noAllocation @_noLocks
    @inlinable public func row(at time: Int, count: Int) -> Int { min(max((time - rowCentre) / rowSpacing, 0), count - 1) }

    /// Whether a curve asks for nothing at all, so that a wire will do.
    @_noAllocation @_noLocks
    @inlinable public func isNothing(_ curve: UnsafePointer<Float>, amount: Float = 1, offsetDB: Float = 0) -> Bool {
        var nothing = offsetDB == 0
        for band in 0..<bandCount where curve[band] * amount != 0 { nothing = false }
        return nothing
    }

    /// Puts a curve in force at once, with no fade to it: both filters are designed from it.
    @_noAllocation @_noLocks
    @inlinable public func start(with curve: UnsafePointer<Float>, amount: Float = 1, offsetDB: Float = 0) {
        design.filter(of: curve, amount: amount, offsetDB: offsetDB, into: filters, taps: taps, fade: fade)
        for index in 0..<taps { filters[taps + index] = filters[index] }
        state.pointee.isFlat = (false, false)
        state.pointee.isFiltering = true
    }

    /// Runs a stretch of the signal through the two filters in place, fading from the older to the newer.
    /// - Parameter frames: no more than `room`.
    /// - Returns: whether the hop ended with this stretch. If it did, call `turn` before passing any more.
    @_noAllocation @_noLocks
    @inlinable @discardableResult public func pass(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        let phase = state.pointee.phase
        let count = min(frames, hop - phase)
        for channel in 0..<2 {
            let samples = channel == 0 ? left : right
            let past = history + channel * (taps - 1 + hop)
            for index in 0..<count { past[taps - 1 + index] = samples[index] }
            if state.pointee.isFiltering {
                let newer = state.pointee.newer, older = 1 - newer
                BandCurveKernel.filter(past, filters + older * taps, taps: taps, into: outputs, count)
                BandCurveKernel.filter(past, filters + newer * taps, taps: taps, into: outputs + hop, count)
                let step = 1 / Float(hop)
                for index in 0..<count {
                    let fade = Float(phase + index + 1) * step
                    samples[index] = outputs[index] + (outputs[hop + index] - outputs[index]) * fade
                }
            }
            for index in 0..<(taps - 1) { past[index] = past[index + count] }
        }
        state.pointee.phase = phase + count
        guard state.pointee.phase == hop else { return false }
        state.pointee.phase = 0
        return true
    }

    /// At the end of a hop: the filter that was being faded to becomes the one faded from, and the next is designed
    /// from `curve`.
    /// - Parameter curve: the curve wanted by the end of the hop now starting; nil for a wire.
    @_noAllocation @_noLocks
    @inlinable public func turn(to curve: UnsafePointer<Float>?, amount: Float = 1, offsetDB: Float = 0) {
        let target = 1 - state.pointee.newer
        let destination = filters + target * taps
        if let curve {
            design.filter(of: curve, amount: amount, offsetDB: offsetDB, into: destination, taps: taps, fade: fade)
        } else {
            for index in 0..<taps { destination[index] = 0 }
            destination[0] = 1
        }
        if target == 0 { state.pointee.isFlat.0 = curve == nil } else { state.pointee.isFlat.1 = curve == nil }
        state.pointee.newer = target
        state.pointee.isFiltering = !(state.pointee.isFlat.0 && state.pointee.isFlat.1)
    }

    /// Runs a stereo signal through the filter in place.
    /// - Parameters:
    ///   - rows: `rowCount` rows of `bandCount` gains in decibels; nil or none for no curve.
    ///   - position: where on the timeline the block starts, which chooses the rows. A curve of one row is a
    ///     standing curve: the row as it is when each filter is designed.
    ///   - amount: scales the curve in decibels. At nothing the filter fades to a wire and then does nothing.
    @_noAllocation @_noLocks
    @inlinable public func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int, rows: UnsafePointer<Float>?, rowCount: Int,
                                   position: Int, amount: Float) {
        let wanted = rows != nil && rowCount > 0 && amount != 0
        guard wanted || state.pointee.isFiltering else {
            state.pointee.isFresh = true
            return
        }
        if state.pointee.isFresh {
            // Nothing is sounding through it yet: start on the curve as it stands here, with no fade in from a wire.
            state.pointee.isFresh = false
            state.pointee.phase = 0
            if wanted, let rows { start(with: rows + row(at: position, count: rowCount) * bandCount, amount: amount) }
        }
        var done = 0
        while done < frames {
            let count = min(hop - state.pointee.phase, frames - done)
            let ended = pass(left + done, right + done, frames: count)
            done += count
            guard ended else { continue }
            // The next filter is designed for where the fade to it ends.
            var next: UnsafePointer<Float>?
            if wanted, let rows {
                let row = rows + row(at: position + done + hop, count: rowCount) * bandCount
                if !isNothing(row, amount: amount) { next = row }
            }
            turn(to: next, amount: amount)
        }
    }
}
