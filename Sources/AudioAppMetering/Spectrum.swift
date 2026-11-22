import AudioAppCore
import AudioAppDSP
import Darwin
import Synchronization

/// A spectrum that the audio thread writes and the interface reads: one level in decibels
/// for each band or bin.
///
/// Neither side waits for the other, and a reader never sees part of one spectrum and part of
/// the next. It works the way `MeterReadout` does, with three copies.
public final class SpectrumReadout: @unchecked Sendable {
    /// How many levels there are.
    public let count: Int
    /// The audio thread's side: pointers only, so writing involves no reference counting.
    @usableFromInline let writer: SpectrumWriter
    /// Which copy readers hold. Readers take turns; they never hold up the audio thread.
    private let front = Mutex(0)

    init(count: Int, floor: Float) {
        self.count = count
        let slots = UnsafeMutablePointer<Float>.allocate(capacity: max(1, 3 * count))
        slots.initialize(repeating: floor, count: max(1, 3 * count))
        let middle = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
        middle.initialize(to: Atomic(1))
        let published = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
        published.initialize(to: Atomic(0))
        let back = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        back.initialize(to: 2)
        writer = SpectrumWriter(slots: slots, middle: middle, published: published, back: back, count: count)
    }

    deinit {
        writer.slots.deallocate()
        writer.middle.deinitialize(count: 1)
        writer.middle.deallocate()
        writer.published.deinitialize(count: 1)
        writer.published.deallocate()
        writer.back.deallocate()
    }

    /// Copies the latest levels into an array, resizing it if needed. Call from any thread
    /// but the audio thread.
    public func read(into levels: inout [Float]) {
        if levels.count != count { levels = [Float](repeating: 0, count: count) }
        front.withLock { front in
            if writer.middle.pointee.load(ordering: .sequentiallyConsistent) & SpectrumWriter.fresh != 0 {
                front = writer.middle.pointee.exchange(front, ordering: .sequentiallyConsistent) & 3
            }
            for index in 0..<count { levels[index] = writer.slots[front * count + index] }
        }
    }

    /// The latest levels, in decibels.
    public var levels: [Float] {
        var levels: [Float] = []
        read(into: &levels)
        return levels
    }

    /// How many spectra have been stored. A display can skip redrawing when this is unchanged.
    public var publishCount: Int { writer.published.pointee.load(ordering: .sequentiallyConsistent) }
}

/// The audio thread's side of a `SpectrumReadout`: pointers into memory the readout owns.
@usableFromInline struct SpectrumWriter: @unchecked Sendable {
    @usableFromInline let slots: UnsafeMutablePointer<Float>
    /// The copy in between, with the `fresh` bit set when it is newer than the readers' copy.
    @usableFromInline let middle: UnsafeMutablePointer<Atomic<Int>>
    @usableFromInline let published: UnsafeMutablePointer<Atomic<Int>>
    /// The copy the audio thread writes next. Only the audio thread touches this.
    @usableFromInline let back: UnsafeMutablePointer<Int>
    @usableFromInline let count: Int
    @inlinable static var fresh: Int { 4 }

    @usableFromInline init(slots: UnsafeMutablePointer<Float>, middle: UnsafeMutablePointer<Atomic<Int>>,
                           published: UnsafeMutablePointer<Atomic<Int>>, back: UnsafeMutablePointer<Int>, count: Int) {
        self.slots = slots
        self.middle = middle
        self.published = published
        self.back = back
        self.count = count
    }

    @_noAllocation @_noLocks
    @inlinable func publish(_ levels: UnsafePointer<Float>) {
        let target = slots + back.pointee * count
        for index in 0..<count { target[index] = levels[index] }
        back.pointee = middle.pointee.exchange(back.pointee | Self.fresh, ordering: .sequentiallyConsistent) & 3
        published.pointee.wrappingAdd(1, ordering: .relaxed)
    }
}

/// Measures how a signal's level is spread across frequency, for a display.
///
/// Give it a `FilterBank` for a level per band (third-octaves, for instance), or none for a
/// level per FFT bin. Levels rise quickly and fall slowly, so peaks are easy to see. A
/// full-scale sine reads 0 dB in the band that holds it. All channels are measured together.
///
/// The levels are read through `readout`. The meter's own `reading` only counts the spectra
/// measured so far.
public struct SpectrumAnalyzer: Meter, ~Copyable {
    public let readout: SpectrumReadout
    @usableFromInline let writer: SpectrumWriter
    /// How many spectra have been measured.
    @inlinable public var reading: Int { spectra }
    /// The centre of each band, or the frequency of each bin, in hertz. Set by `prepare`.
    public private(set) var frequencies: [Double] = []
    public var fftSize: Int { fft.size }

    /// Levels are never reported below this, in decibels.
    @inlinable static var floorDB: Float { -120 }
    @usableFromInline let fft: FFT
    @usableFromInline var frame: SpectralFrame
    @usableFromInline var bank: FilterBank
    @usableFromInline let banded: Bool
    @usableFromInline let count: Int
    @usableFromInline let riseSeconds: Double
    @usableFromInline let fallSeconds: Double
    @usableFromInline let window: UnsafeMutablePointer<Float>
    /// The last `fftSize` samples of the channels' sum.
    @usableFromInline let gathered: UnsafeMutablePointer<Float>
    @usableFromInline let scratch: UnsafeMutablePointer<Float>
    @usableFromInline let powers: UnsafeMutablePointer<Float>
    @usableFromInline let levels: UnsafeMutablePointer<Float>
    @usableFromInline var filled = 0
    @usableFromInline var spectra = 0
    @usableFromInline var rise: Float = 1
    @usableFromInline var fall: Float = 1
    /// Turns a band's or a bin's power into the power of the sine that would produce it.
    @usableFromInline var scale: Float = 1

    /// - Parameters:
    ///   - fftSize: rounded up to a power of two. Larger tells low notes apart better and
    ///     responds more slowly.
    ///   - bands: the bands to report, or nil for every FFT bin.
    ///   - riseSeconds: how fast a level climbs.
    ///   - fallSeconds: how fast a level drops back.
    public init(fftSize: Int = 4_096, bands: consuming FilterBank? = nil, riseSeconds: Double = 0.01, fallSeconds: Double = 0.3) {
        fft = FFT(size: fftSize)
        frame = SpectralFrame(fftSize: fft.size)
        if let bands {
            bank = bands
            banded = true
            count = bank.bandCount
        } else {
            bank = FilterBank(edges: [])
            banded = false
            count = fft.size / 2 + 1
        }
        self.riseSeconds = riseSeconds
        self.fallSeconds = fallSeconds
        let size = fft.size
        window = .allocate(capacity: size)
        var sum = 0.0, squares = 0.0
        for index in 0..<size {
            window[index] = Window.hann.value(at: index, count: size)
            sum += Double(window[index])
            squares += Double(window[index]) * Double(window[index])
        }
        // A sine of amplitude A puts A² · size · Σw² / 4 into the bins around it in total,
        // and A² · (Σw)² / 4 into the one bin it lands on.
        scale = Float(banded ? 4 / (Double(size) * squares) : 4 / (sum * sum))
        gathered = .allocate(capacity: size)
        gathered.initialize(repeating: 0, count: size)
        scratch = .allocate(capacity: size)
        scratch.initialize(repeating: 0, count: size)
        powers = .allocate(capacity: max(1, count))
        powers.initialize(repeating: 0, count: max(1, count))
        levels = .allocate(capacity: max(1, count))
        levels.initialize(repeating: Self.floorDB, count: max(1, count))
        readout = SpectrumReadout(count: count, floor: Self.floorDB)
        writer = readout.writer
    }

    deinit {
        window.deallocate()
        gathered.deallocate()
        scratch.deallocate()
        powers.deallocate()
        levels.deallocate()
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        let size = fft.size
        if banded {
            bank.prepare(fftSize: size, sampleRate: format.sampleRate)
            frequencies = bank.centres
        } else {
            frequencies = (0..<count).map { Double($0) * format.sampleRate.hertz / Double(size) }
        }
        // A new spectrum is taken every half frame.
        let interval = Double(size / 2) / format.sampleRate.hertz
        rise = riseSeconds > 0 ? Float(1 - exp(-interval / riseSeconds)) : 1
        fall = fallSeconds > 0 ? Float(1 - exp(-interval / fallSeconds)) : 1
        reset()
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func measure(_ block: AudioBlock) {
        let size = fft.size, hop = size / 2
        guard block.channelCount > 0 else { return }
        var done = 0
        while done < block.frameCount {
            let frames = min(block.frameCount - done, hop - filled)
            let target = gathered + (size - hop) + filled
            for frame in 0..<frames { target[frame] = 0 }
            for channel in 0..<block.channelCount {
                let samples = block[channel]
                for frame in 0..<frames { target[frame] += samples[done + frame] }
            }
            filled += frames
            done += frames
            if filled == hop { takeSpectrum() }
        }
    }

    @_noAllocation @_noLocks
    @inlinable mutating func takeSpectrum() {
        let size = fft.size, hop = size / 2
        for index in 0..<size { scratch[index] = gathered[index] * window[index] }
        fft.forward(scratch, into: frame)
        if banded {
            bank.powers(of: frame, into: powers)
        } else {
            for bin in 0..<count { powers[bin] = frame.power(bin) }
        }
        for index in 0..<count {
            let power = powers[index] * scale
            let level = power > 1e-12 ? 10 * log10(power) : Self.floorDB
            levels[index] += (level > levels[index] ? rise : fall) * (level - levels[index])
        }
        writer.publish(levels)
        spectra += 1
        for index in 0..<(size - hop) { gathered[index] = gathered[index + hop] }
        filled = 0
    }

    public mutating func reset() {
        for index in 0..<fft.size { gathered[index] = 0 }
        for index in 0..<count { levels[index] = Self.floorDB }
        filled = 0
        writer.publish(levels)
    }
}
