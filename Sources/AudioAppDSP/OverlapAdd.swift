import Accelerate
import AudioAppCore
import AudioAppRealtime
import Darwin

// A filterbank that shapes a signal frame by frame: each frame under a window, its spectrum scaled bin by bin by gains
// read off curves of band gains, back under the window and added to its neighbours. The pieces are the gains
// (`BandGains`) and the frames (`OverlapAddFrames`); where the frames come from, which curve rows they take and how far
// ahead of playback they are read is the caller's.

/// Calls the filterbank makes into the system's vector library. Plain arithmetic over memory the caller supplies;
/// marked trusted because the compiler's real-time checks cannot see into them.
@usableFromInline enum OverlapAddKernel {
    /// `out = a * b`
    @inlinable @inline(never) @_semantics("no_performance_analysis")
    static func multiply(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>, _ count: Int) {
        vDSP_vmul(a, 1, b, 1, out, 1, vDSP_Length(count))
    }

    /// `sum += a * b`
    @inlinable @inline(never) @_semantics("no_performance_analysis")
    static func multiplyAdd(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into sum: UnsafeMutablePointer<Float>, _ count: Int) {
        vDSP_vma(a, 1, b, 1, sum, 1, sum, 1, vDSP_Length(count))
    }

    /// `values = exp(values)`
    @inlinable @inline(never) @_semantics("no_performance_analysis")
    static func exp(_ values: UnsafeMutablePointer<Float>, _ count: Int) {
        var length = Int32(count)
        vvexpf(values, values, &length)
    }
}

/// A gain for every bin of a spectrum, from one or more curves of band gains added in decibels.
///
/// Each curve is read onto the bins as `BandCurveLayout.weights` says: a bin's gain in decibels is
/// `(1 - lean) * curve[band] + lean * curve[band + 1]`. The curves are summed as natural-log factors, and `finish` turns
/// the sum into the factors themselves.
///
/// Memory is reserved when it is made, so make it away from the audio thread. One serves one thread at a time.
public struct BandGains: ~Copyable {
    /// Decibels to a natural-log factor: `ln(10) / 20`. Scale a curve by this, and by its amount, when adding it.
    public static var decibels: Float { @_noAllocation @_noLocks get { 0.115_129_254_649_702_28 } }

    public let binCount: Int
    public let bandCount: Int
    @usableFromInline let band: UnsafeMutablePointer<Int32>
    @usableFromInline let leanLow: UnsafeMutablePointer<Float>
    @usableFromInline let leanHigh: UnsafeMutablePointer<Float>
    /// The gain per bin: a natural-log factor while curves are being added, the factor after `finish`.
    public let gains: UnsafeMutablePointer<Float>
    @usableFromInline let added: UnsafeMutablePointer<Bool>

    public init(layout: BandCurveLayout, sampleRate: SampleRate, fftSize: Int) {
        let weights = layout.weights(fftSize: fftSize, sampleRate: sampleRate)
        binCount = weights.band.count
        bandCount = layout.bandCount
        band = .allocate(capacity: binCount)
        band.initialize(from: weights.band, count: binCount)
        leanLow = Memory.floats(binCount)
        leanHigh = Memory.floats(binCount)
        for bin in 0..<binCount {
            leanLow[bin] = 1 - weights.lean[bin]
            leanHigh[bin] = weights.lean[bin]
        }
        gains = Memory.floats(binCount)
        added = .allocate(capacity: 1)
        added.initialize(to: false)
    }

    deinit {
        band.deallocate()
        leanLow.deallocate()
        leanHigh.deallocate()
        gains.deallocate()
        added.deallocate()
    }

    /// Whether any curve has been added since `clear`: without one the spectrum is to be left alone.
    @inlinable public var isShaping: Bool { @_noAllocation @_noLocks get { added.pointee } }

    /// Starts again with no curve.
    @_noAllocation @_noLocks
    @inlinable public func clear() { added.pointee = false }

    /// Adds a curve: `bandCount` gains in decibels, times `scale` (`decibels` times the curve's amount).
    @_noAllocation @_noLocks
    @inlinable public func add(_ row: UnsafePointer<Float>, scale: Float) {
        if added.pointee {
            for bin in 0..<binCount {
                let lower = Int(band[bin])
                gains[bin] += scale * (row[lower] * leanLow[bin] + row[lower + 1] * leanHigh[bin])
            }
        } else {
            for bin in 0..<binCount {
                let lower = Int(band[bin])
                gains[bin] = scale * (row[lower] * leanLow[bin] + row[lower + 1] * leanHigh[bin])
            }
        }
        added.pointee = true
    }

    /// Turns the summed curves into a factor per bin. Call once, after the last `add`.
    @_noAllocation @_noLocks
    @inlinable public func finish() { if added.pointee { OverlapAddKernel.exp(gains, binCount) } }

    /// Scales a spectrum by the factors, bin by bin.
    @_noAllocation @_noLocks
    @inlinable public func apply(to frame: borrowing SpectralFrame) {
        OverlapAddKernel.multiply(frame.realStorage, gains, into: frame.realStorage, binCount)
        OverlapAddKernel.multiply(frame.imaginaryStorage, gains, into: frame.imaginaryStorage, binCount)
    }
}

/// The frames of an overlap-add filterbank: each frame of a signal under the window, shaped in its spectrum, under the
/// window again and added into a running sum, which is read out divided by the summed squared windows that cover it.
///
/// The running sum is the caller's: `frameSize` samples starting at the beginning of a hop, holding every frame that
/// covers that hop. A frame that starts `skip` samples before the sum adds its samples from `skip` on.
///
/// Memory is reserved when it is made, so make it away from the audio thread. One serves one thread at a time.
public struct OverlapAddFrames: ~Copyable {
    public let frameSize: Int
    public let hop: Int
    @usableFromInline let fft: FFT
    @usableFromInline let frame: SpectralFrame
    @usableFromInline let window: UnsafeMutablePointer<Float>
    @usableFromInline let windowSquared: UnsafeMutablePointer<Float>
    /// For each place in a hop, one over the summed squared windows of the frames that cover it.
    @usableFromInline let inverseNorm: UnsafeMutablePointer<Float>
    @usableFromInline let scratch: UnsafeMutablePointer<Float>

    /// - Parameters:
    ///   - window: the analysis and synthesis window, as many values as the frame; its length, a power of two, is the frame's.
    ///   - hop: how far apart the frames start; a whole fraction of the frame.
    public init(window shape: [Float], hop: Int) {
        fft = FFT(size: shape.count)
        frameSize = fft.size
        self.hop = max(1, hop)
        frame = SpectralFrame(fftSize: frameSize)
        window = Memory.floats(frameSize)
        windowSquared = Memory.floats(frameSize)
        for index in 0..<min(frameSize, shape.count) {
            window[index] = shape[index]
            windowSquared[index] = shape[index] * shape[index]
        }
        inverseNorm = Memory.floats(self.hop)
        let overlap = frameSize / self.hop
        for offset in 0..<self.hop {
            var sum: Float = 0
            for part in 0..<overlap { sum += window[offset + part * self.hop] * window[offset + part * self.hop] }
            inverseNorm[offset] = 1 / max(sum, 1e-6)
        }
        scratch = Memory.floats(frameSize)
    }

    deinit {
        window.deallocate()
        windowSquared.deallocate()
        inverseNorm.deallocate()
        scratch.deallocate()
    }

    /// The frames that overlap at any one place: `frameSize / hop`.
    @inlinable public var overlap: Int { frameSize / hop }

    /// Adds a frame whose spectrum is left alone: windowed twice is all it contributes.
    /// - Parameters:
    ///   - samples: the frame's first sample; only those from `first` up to `last` are read, the rest are silence.
    ///   - skip: how far into the frame the sum starts.
    @_noAllocation @_noLocks
    @inlinable public func addUnchanged(_ samples: UnsafePointer<Float>, first: Int, last: Int, skip: Int, into sum: UnsafeMutablePointer<Float>) {
        let from = max(first, skip)
        if last > from { OverlapAddKernel.multiplyAdd(samples + from, windowSquared + from, into: sum + (from - skip), last - from) }
    }

    /// Adds a frame shaped by gains: under the window, into its spectrum, scaled bin by bin, back and under the window again.
    /// - Parameters:
    ///   - samples: the frame's first sample; only those from `first` up to `last` are read, the rest are silence.
    ///   - skip: how far into the frame the sum starts.
    @_noAllocation @_noLocks
    @inlinable public func addShaped(_ samples: UnsafePointer<Float>, first: Int, last: Int, skip: Int, gains: borrowing BandGains, into sum: UnsafeMutablePointer<Float>) {
        let size = frameSize
        for index in 0..<first { scratch[index] = 0 }
        if last > first { OverlapAddKernel.multiply(samples + first, window + first, into: scratch + first, last - first) }
        for index in last..<size { scratch[index] = 0 }
        fft.forward(scratch, into: frame)
        gains.apply(to: frame)
        fft.inverse(frame, into: scratch)
        OverlapAddKernel.multiplyAdd(scratch + skip, window + skip, into: sum, size - skip)
    }

    /// Reads `count` finished samples from `within` a hop of the sum.
    @_noAllocation @_noLocks
    @inlinable public func read(_ sum: UnsafePointer<Float>, within: Int, count: Int, into out: UnsafeMutablePointer<Float>) {
        OverlapAddKernel.multiply(sum + within, inverseNorm + within, into: out, count)
    }

    /// Moves a sum on by a hop: the frames that end in the hop just finished are dropped, and room is made for the next.
    @_noAllocation @_noLocks
    @inlinable public func advance(_ sum: UnsafeMutablePointer<Float>) {
        for index in 0..<(frameSize - hop) { sum[index] = sum[index + hop] }
        for index in (frameSize - hop)..<frameSize { sum[index] = 0 }
    }

    /// Empties a sum.
    @_noAllocation @_noLocks
    @inlinable public func clear(_ sum: UnsafeMutablePointer<Float>) {
        for index in 0..<frameSize { sum[index] = 0 }
    }
}
