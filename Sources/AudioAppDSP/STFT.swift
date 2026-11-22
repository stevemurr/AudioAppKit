import AudioAppCore
import AudioAppProcessing
import Darwin

/// Something that changes audio one spectrum at a time: a spectral gate, a per-band
/// equaliser, a noise reducer. Put it in an `STFTHost` to use it as a processor.
public protocol SpectralProcessor: ~Copyable {
    /// Gets ready. Called away from the audio thread.
    /// - Parameters:
    ///   - fftSize: bin `k` of each frame is the frequency `k * sampleRate / fftSize`.
    ///   - hop: how many samples pass between one frame and the next.
    mutating func prepare(fftSize: Int, hop: Int, format: Format)

    /// Changes one channel's spectrum in place, on the audio thread.
    mutating func process(_ frame: inout SpectralFrame, channel: Int, _ context: borrowing RenderContext)

    mutating func reset()
}

extension SpectralProcessor where Self: ~Copyable {
    @inlinable public mutating func reset() {}
}

/// Runs a spectral processor inside an ordinary stream of blocks of any length.
///
/// It cuts the audio into overlapping frames, hands each frame's spectrum to the processor,
/// and adds the results back together. With a processor that changes nothing, what comes out
/// is what went in, `latencyFrames` later.
public struct STFTHost<P: SpectralProcessor & ~Copyable>: Processor, ~Copyable {
    public var processor: P
    @usableFromInline var core: STFTCore

    /// - Parameters:
    ///   - fftSize: rounded up to a power of two. Larger separates frequencies better and
    ///     adds latency.
    ///   - overlap: frames per `fftSize` samples, 2 or 4. Four is the safer choice when the
    ///     processor changes the spectrum a lot.
    public init(_ processor: consuming P, fftSize: Int = 1_024, overlap: Int = 4) {
        self.processor = processor
        core = STFTCore(fftSize: fftSize, overlap: overlap)
    }

    public var fftSize: Int { core.size }
    public var hop: Int { core.hop }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        core.prepare(channelCount: format.channelCount)
        processor.prepare(fftSize: core.size, hop: core.hop, format: format)
    }

    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        let channels = min(io.channelCount, core.channelCount)
        var channel = 0
        while channel < channels {
            let samples = io[channel].baseAddress!
            var done = 0
            while done < io.frameCount {
                done += core.exchange(channel: channel, samples + done, count: io.frameCount - done)
                if core.frameIsFull(channel: channel) {
                    core.analyse(channel: channel)
                    processor.process(&core.frame, channel: channel, context)
                    core.synthesise(channel: channel)
                }
            }
            channel += 1
        }
    }

    public mutating func reset() {
        core.reset()
        processor.reset()
    }

    @inlinable public var latencyFrames: Int { core.size }
}

/// The framing, windowing and adding-back of an `STFTHost`, kept apart from the host so it
/// does not depend on the kind of processor inside.
@usableFromInline struct STFTCore: ~Copyable {
    @usableFromInline let size: Int
    @usableFromInline let hop: Int
    @usableFromInline let fft: FFT
    @usableFromInline var frame: SpectralFrame
    @usableFromInline let analysis: UnsafeMutablePointer<Float>
    @usableFromInline let synthesis: UnsafeMutablePointer<Float>
    @usableFromInline let scratch: UnsafeMutablePointer<Float>
    /// Per channel: the last `size` samples in, the sum of frames on their way out, and how
    /// much of the current hop has been taken.
    @usableFromInline var input: UnsafeMutablePointer<Float>
    @usableFromInline var output: UnsafeMutablePointer<Float>
    @usableFromInline var fill: UnsafeMutablePointer<Int>
    @usableFromInline var channelCount = 0

    @usableFromInline init(fftSize: Int, overlap: Int) {
        fft = FFT(size: max(fftSize, 16))
        size = fft.size
        hop = size / (overlap <= 2 ? 2 : 4)
        frame = SpectralFrame(fftSize: size)
        analysis = Memory.floats(size)
        synthesis = Memory.floats(size)
        scratch = Memory.floats(size)
        input = Memory.floats(0)
        output = Memory.floats(0)
        fill = .allocate(capacity: 1)
        for index in 0..<size { analysis[index] = Window.sqrtHann.value(at: index, count: size) }
        // Each output sample is the sum of several frames, each windowed twice. Dividing by
        // that sum makes an unchanged spectrum come back at the level it went in.
        for index in 0..<size {
            var sum: Float = 0
            var position = index % hop
            while position < size {
                sum += analysis[position] * analysis[position]
                position += hop
            }
            synthesis[index] = analysis[index] / sum
        }
    }

    deinit {
        analysis.deallocate()
        synthesis.deallocate()
        scratch.deallocate()
        input.deallocate()
        output.deallocate()
        fill.deallocate()
    }

    @usableFromInline mutating func prepare(channelCount count: Int) {
        if count != channelCount {
            input.deallocate()
            output.deallocate()
            fill.deallocate()
            channelCount = count
            input = Memory.floats(count * size)
            output = Memory.floats(count * size)
            fill = .allocate(capacity: max(1, count))
        }
        reset()
    }

    @usableFromInline mutating func reset() {
        Memory.zero(input, channelCount * size)
        Memory.zero(output, channelCount * size)
        for channel in 0..<channelCount { fill[channel] = 0 }
    }

    /// Takes samples in and gives finished samples back in their place, up to the end of the
    /// current hop. Returns how many it exchanged.
    @_noAllocation @_noLocks
    @inlinable mutating func exchange(channel: Int, _ samples: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let taken = fill[channel]
        let frames = min(count, hop - taken)
        let incoming = input + channel * size + (size - hop) + taken
        let outgoing = output + channel * size + taken
        for index in 0..<frames {
            incoming[index] = samples[index]
            samples[index] = outgoing[index]
        }
        fill[channel] = taken + frames
        return frames
    }

    @inlinable func frameIsFull(channel: Int) -> Bool { fill[channel] == hop }

    /// Takes the spectrum of the channel's last `size` samples into `frame`.
    @_noAllocation @_noLocks
    @inlinable mutating func analyse(channel: Int) {
        let source = input + channel * size
        for index in 0..<size { scratch[index] = source[index] * analysis[index] }
        fft.forward(scratch, into: frame)
    }

    /// Turns `frame` back into audio, adds it to what is on its way out, and moves both of
    /// the channel's buffers on by one hop.
    @_noAllocation @_noLocks
    @inlinable mutating func synthesise(channel: Int) {
        fft.inverse(frame, into: scratch)
        let target = output + channel * size
        Memory.shiftDown(target, by: hop, count: size - hop)
        Memory.zero(target + (size - hop), hop)
        for index in 0..<size { target[index] += scratch[index] * synthesis[index] }
        Memory.shiftDown(input + channel * size, by: hop, count: size - hop)
        fill[channel] = 0
    }
}
