import Accelerate
import AudioAppCore
import AudioAppRealtime
import Darwin

/// The shape a stretch of audio is faded with before its spectrum is taken.
@frozen public enum Window: Hashable, Sendable {
    /// No fade.
    case rectangular
    case hann
    case hamming
    /// Very low leakage between distant frequencies, at the cost of a wider peak.
    case blackmanHarris
    /// The square root of a Hann window. Used once before and once after a spectral change,
    /// overlapping frames add back to the original.
    case sqrtHann

    /// The window's value at `index` of `count`. The window is periodic: the value that
    /// would follow the last one is the first, which is what overlapping frames need.
    public func value(at index: Int, count: Int) -> Float {
        let x = 2 * Double.pi * Double(index) / Double(max(1, count))
        switch self {
        case .rectangular: return 1
        case .hann: return Float(0.5 - 0.5 * cos(x))
        case .hamming: return Float(0.54 - 0.46 * cos(x))
        case .blackmanHarris:
            return Float(0.35875 - 0.48829 * cos(x) + 0.14128 * cos(2 * x) - 0.01168 * cos(3 * x))
        case .sqrtHann: return Float((0.5 - 0.5 * cos(x)).squareRoot())
        }
    }

    public func values(count: Int) -> [Float] {
        (0..<count).map { value(at: $0, count: count) }
    }
}

/// One spectrum: a level and phase for each frequency from zero to half the sample rate,
/// held as real and imaginary parts. Bin `k` of a frame from an FFT of size `n` is the
/// frequency `k * sampleRate / n`.
///
/// Memory is reserved when the frame is made, so make it away from the audio thread.
public struct SpectralFrame: ~Copyable {
    /// Half the FFT size, plus one.
    public let binCount: Int
    @usableFromInline let realStorage: UnsafeMutablePointer<Float>
    @usableFromInline let imaginaryStorage: UnsafeMutablePointer<Float>

    public init(fftSize: Int) {
        binCount = fftSize / 2 + 1
        realStorage = Memory.floats(binCount)
        imaginaryStorage = Memory.floats(binCount)
    }

    deinit {
        realStorage.deallocate()
        imaginaryStorage.deallocate()
    }

    @inlinable public var real: UnsafeMutableBufferPointer<Float> {
        UnsafeMutableBufferPointer(start: realStorage, count: binCount)
    }

    @inlinable public var imaginary: UnsafeMutableBufferPointer<Float> {
        UnsafeMutableBufferPointer(start: imaginaryStorage, count: binCount)
    }

    /// The squared magnitude of a bin.
    @_noAllocation @_noLocks
    @inlinable public func power(_ bin: Int) -> Float {
        realStorage[bin] * realStorage[bin] + imaginaryStorage[bin] * imaginaryStorage[bin]
    }

    @_noAllocation @_noLocks
    @inlinable public func magnitude(_ bin: Int) -> Float { RealtimeMath.sqrt(power(bin)) }

    /// Multiplies a bin by a gain, leaving its phase alone.
    @_noAllocation @_noLocks
    @inlinable public func scale(_ bin: Int, by gain: Float) {
        realStorage[bin] *= gain
        imaginaryStorage[bin] *= gain
    }

    @_noAllocation @_noLocks
    @inlinable public func clear() {
        Memory.zero(realStorage, binCount)
        Memory.zero(imaginaryStorage, binCount)
    }
}

/// Turns a stretch of audio into its spectrum and back.
///
/// Setting one up is slow and reserves memory, so do it away from the audio thread. Using it
/// is safe on the audio thread. One FFT serves one thread at a time.
public struct FFT: ~Copyable {
    /// The number of samples transformed, a power of two.
    public let size: Int
    @usableFromInline let log2Size: Int
    @usableFromInline let setup: FFTSetup
    /// The packed form the system routine works in, and its scratch space.
    @usableFromInline let packedReal: UnsafeMutablePointer<Float>
    @usableFromInline let packedImaginary: UnsafeMutablePointer<Float>
    @usableFromInline let scratchReal: UnsafeMutablePointer<Float>
    @usableFromInline let scratchImaginary: UnsafeMutablePointer<Float>

    /// - Parameter size: rounded up to a power of two, at least 4.
    public init(size: Int) {
        var log2 = 2
        while (1 << log2) < size { log2 += 1 }
        log2Size = log2
        self.size = 1 << log2
        setup = vDSP_create_fftsetup(vDSP_Length(log2), FFTRadix(kFFTRadix2))!
        packedReal = Memory.floats(self.size / 2)
        packedImaginary = Memory.floats(self.size / 2)
        scratchReal = Memory.floats(self.size / 2)
        scratchImaginary = Memory.floats(self.size / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        packedReal.deallocate()
        packedImaginary.deallocate()
        scratchReal.deallocate()
        scratchImaginary.deallocate()
    }

    /// Takes the spectrum of `size` samples. A full-scale sine that fits the frame exactly
    /// gives a bin magnitude of `size / 2`.
    @_noAllocation @_noLocks
    @inlinable public func forward(_ samples: UnsafePointer<Float>, into frame: borrowing SpectralFrame) {
        FFTKernel.forward(setup, log2Size, samples, packedReal, packedImaginary, scratchReal, scratchImaginary)
        let half = size / 2
        let real = frame.realStorage, imaginary = frame.imaginaryStorage
        // The system routine returns twice the transform, with the top bin stored where the
        // bottom bin's (always zero) imaginary part would go.
        real[0] = 0.5 * packedReal[0]
        imaginary[0] = 0
        real[half] = 0.5 * packedImaginary[0]
        imaginary[half] = 0
        for bin in 1..<half {
            real[bin] = 0.5 * packedReal[bin]
            imaginary[bin] = 0.5 * packedImaginary[bin]
        }
    }

    /// Turns a spectrum back into `size` samples, undoing `forward` exactly.
    @_noAllocation @_noLocks
    @inlinable public func inverse(_ frame: borrowing SpectralFrame, into samples: UnsafeMutablePointer<Float>) {
        let half = size / 2
        let real = frame.realStorage, imaginary = frame.imaginaryStorage
        packedReal[0] = real[0]
        packedImaginary[0] = real[half]
        for bin in 1..<half {
            packedReal[bin] = real[bin]
            packedImaginary[bin] = imaginary[bin]
        }
        FFTKernel.inverse(setup, log2Size, packedReal, packedImaginary, scratchReal, scratchImaginary, samples)
        let scale = 1 / Float(size)
        for index in 0..<size { samples[index] *= scale }
    }
}

/// The calls into the system's FFT. The compiler's real-time checks cannot see into them, so
/// they are marked as trusted. They are safe on the audio thread because the variants used
/// here take their scratch memory from the caller instead of reserving their own, and the
/// setup they read was built beforehand.
@usableFromInline enum FFTKernel {
    @inlinable @inline(never) @_semantics("no_performance_analysis")
    static func forward(_ setup: FFTSetup, _ log2Size: Int, _ samples: UnsafePointer<Float>,
                        _ real: UnsafeMutablePointer<Float>, _ imaginary: UnsafeMutablePointer<Float>,
                        _ scratchReal: UnsafeMutablePointer<Float>, _ scratchImaginary: UnsafeMutablePointer<Float>) {
        var packed = DSPSplitComplex(realp: real, imagp: imaginary)
        var scratch = DSPSplitComplex(realp: scratchReal, imagp: scratchImaginary)
        let half = vDSP_Length(1 << (log2Size - 1))
        samples.withMemoryRebound(to: DSPComplex.self, capacity: Int(half)) {
            vDSP_ctoz($0, 2, &packed, 1, half)
        }
        vDSP_fft_zript(setup, &packed, 1, &scratch, vDSP_Length(log2Size), FFTDirection(kFFTDirection_Forward))
    }

    @inlinable @inline(never) @_semantics("no_performance_analysis")
    static func inverse(_ setup: FFTSetup, _ log2Size: Int,
                        _ real: UnsafeMutablePointer<Float>, _ imaginary: UnsafeMutablePointer<Float>,
                        _ scratchReal: UnsafeMutablePointer<Float>, _ scratchImaginary: UnsafeMutablePointer<Float>,
                        _ samples: UnsafeMutablePointer<Float>) {
        var packed = DSPSplitComplex(realp: real, imagp: imaginary)
        var scratch = DSPSplitComplex(realp: scratchReal, imagp: scratchImaginary)
        let half = vDSP_Length(1 << (log2Size - 1))
        vDSP_fft_zript(setup, &packed, 1, &scratch, vDSP_Length(log2Size), FFTDirection(kFFTDirection_Inverse))
        samples.withMemoryRebound(to: DSPComplex.self, capacity: Int(half)) {
            vDSP_ztoc(&packed, 1, $0, 2, half)
        }
    }
}

/// Groups the bins of a spectrum into bands, such as third-octaves for a display or bands
/// spaced the way the ear separates frequencies.
///
/// A band takes the bins between its edges, with a part share of the bins its edges cut
/// through, so bands never overlap and never leave a gap.
public struct FilterBank: ~Copyable {
    /// Where each band begins and the last one ends, in hertz: one more than the band count.
    public let edges: [Double]
    public var bandCount: Int { edges.count - 1 }
    /// Each band's centre, in hertz: the geometric middle of its edges.
    public var centres: [Double] { zip(edges, edges.dropFirst()).map { ($0 * $1).squareRoot() } }

    @usableFromInline let count: Int
    /// For each band: the first and last bin it touches and its share of each.
    @usableFromInline var firstBin: UnsafeMutablePointer<Int>
    @usableFromInline var lastBin: UnsafeMutablePointer<Int>
    @usableFromInline var firstShare: UnsafeMutablePointer<Float>
    @usableFromInline var lastShare: UnsafeMutablePointer<Float>
    @usableFromInline var binCount = 0

    /// Bands with the given edges, lowest first.
    public init(edges: [Double]) {
        self.edges = edges.sorted()
        count = max(0, edges.count - 1)
        firstBin = .allocate(capacity: max(1, count))
        lastBin = .allocate(capacity: max(1, count))
        firstShare = Memory.floats(count)
        lastShare = Memory.floats(count)
        firstBin.initialize(repeating: 0, count: max(1, count))
        lastBin.initialize(repeating: -1, count: max(1, count))
    }

    deinit {
        firstBin.deallocate()
        lastBin.deallocate()
        firstShare.deallocate()
        lastShare.deallocate()
    }

    /// Bands that each cover the same ratio of frequency: `perOctave` of them to the octave.
    public static func octave(perOctave: Int = 3, from low: Double = 20, to high: Double = 20_000) -> FilterBank {
        let ratio = pow(2, 1 / Double(max(1, perOctave)))
        var edges = [low]
        while edges.last! * ratio <= high * 1.0001 { edges.append(edges.last! * ratio) }
        return FilterBank(edges: edges)
    }

    /// Bands of equal width on the ERB scale, which follows the ear's own filters.
    public static func erb(bands: Int, from low: Double = 20, to high: Double = 20_000) -> FilterBank {
        spaced(bands, low, high, to: { 21.4 * log10(0.00437 * $0 + 1) }, from: { (pow(10, $0 / 21.4) - 1) / 0.00437 })
    }

    /// Bands of equal width on the mel scale, a common choice for analysis.
    public static func mel(bands: Int, from low: Double = 20, to high: Double = 20_000) -> FilterBank {
        spaced(bands, low, high, to: { 2595 * log10(1 + $0 / 700) }, from: { 700 * (pow(10, $0 / 2595) - 1) })
    }

    private static func spaced(_ bands: Int, _ low: Double, _ high: Double, to scale: (Double) -> Double,
                               from hertz: (Double) -> Double) -> FilterBank {
        let a = scale(low), b = scale(high)
        return FilterBank(edges: (0...max(1, bands)).map { hertz(a + (b - a) * Double($0) / Double(max(1, bands))) })
    }

    /// Works out which bins each band takes. Call when the FFT size or sample rate is known
    /// or changes, away from the audio thread.
    public mutating func prepare(fftSize: Int, sampleRate: SampleRate) {
        binCount = fftSize / 2 + 1
        let width = sampleRate.hertz / Double(fftSize)
        for band in 0..<count {
            // Bin k owns the frequencies half a bin either side of its centre.
            let low = min(max(edges[band] / width + 0.5, 0), Double(binCount))
            let high = min(max(edges[band + 1] / width + 0.5, 0), Double(binCount))
            let first = Int(low), last = min(Int(high), binCount - 1)
            firstBin[band] = first
            lastBin[band] = last
            guard high > low, first < binCount else {
                lastBin[band] = first - 1
                continue
            }
            if first == last {
                firstShare[band] = Float(high - low)
                lastShare[band] = 0
            } else {
                firstShare[band] = Float(Double(first + 1) - low)
                lastShare[band] = Float(high - Double(last))
            }
        }
    }

    /// Adds up the power in each band of a spectrum, writing `bandCount` values.
    @_noAllocation @_noLocks
    @inlinable public func powers(of frame: borrowing SpectralFrame, into bands: UnsafeMutablePointer<Float>) {
        let limit = min(binCount, frame.binCount)
        for band in 0..<count {
            let first = firstBin[band], last = min(lastBin[band], limit - 1)
            guard last >= first else {
                bands[band] = 0
                continue
            }
            var sum = firstShare[band] * frame.power(first)
            if last > first {
                for bin in (first + 1)..<last { sum += frame.power(bin) }
                sum += lastShare[band] * frame.power(last)
            }
            bands[band] = sum
        }
    }
}
