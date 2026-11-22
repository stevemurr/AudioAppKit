import AudioAppCore
import AudioAppDSP
import Darwin

/// The filter that makes a level measurement follow how loud something sounds: a lift of
/// about 4 dB for the upper mids and highs, where the ear is keenest, and a roll-off of the
/// deep bass. Defined by the loudness standard, ITU-R BS.1770.
///
/// The standard lists its numbers for 48 kHz only. This derives them for any sample rate
/// from the same underlying curves, and gives the standard's own numbers at 48 kHz.
///
/// One filter serves one channel.
@frozen public struct KWeighting: Sendable {
    public let shelf: BiquadCoefficients
    public let highPass: BiquadCoefficients
    @usableFromInline var s1 = 0.0, s2 = 0.0, h1 = 0.0, h2 = 0.0

    public init(sampleRate: SampleRate) {
        // The high shelf.
        var k = tan(Double.pi * 1_681.974_450_955_533 / sampleRate.hertz)
        var q = 0.707_175_236_955_419_6
        let top = pow(10, 3.999_843_853_973_347 / 20)
        let middle = pow(top, 0.499_666_774_154_541_6)
        var a0 = 1 + k / q + k * k
        shelf = BiquadCoefficients(b0: (top + middle * k / q + k * k) / a0, b1: 2 * (k * k - top) / a0,
                                   b2: (top - middle * k / q + k * k) / a0,
                                   a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        // The high-pass.
        k = tan(Double.pi * 38.135_470_876_024_44 / sampleRate.hertz)
        q = 0.500_327_037_323_877_3
        a0 = 1 + k / q + k * k
        highPass = BiquadCoefficients(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }

    /// Filters one sample.
    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ sample: Float) -> Double {
        let x = Double(sample)
        let y = shelf.b0 * x + s1
        s1 = shelf.b1 * x - shelf.a1 * y + s2
        s2 = shelf.b2 * x - shelf.a2 * y
        let z = highPass.b0 * y + h1
        h1 = highPass.b1 * y - highPass.a1 * z + h2
        h2 = highPass.b2 * y - highPass.a2 * z
        return z
    }

    /// What the filter does to a steady tone, in decibels.
    public func magnitudeDB(at frequency: Double, sampleRate: SampleRate) -> Double {
        shelf.magnitudeDB(at: frequency, sampleRate: sampleRate) + highPass.magnitudeDB(at: frequency, sampleRate: sampleRate)
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func reset() {
        s1 = 0
        s2 = 0
        h1 = 0
        h2 = 0
    }
}

/// What a `LoudnessMeter` reports, in LUFS. A value of -200 means nothing has been measured.
@frozen public struct LoudnessReading: Sendable, BitwiseCopyable {
    /// Loudness over the last 0.4 seconds.
    public var momentary: Float
    /// Loudness over the last 3 seconds.
    public var shortTerm: Float
    /// Loudness of everything since the reset, leaving out silence and quiet passages.
    public var integrated: Float
    /// How far apart the quiet and loud passages are, in LU.
    public var range: Float

    @inlinable public init(momentary: Float = -200, shortTerm: Float = -200, integrated: Float = -200, range: Float = 0) {
        self.momentary = momentary
        self.shortTerm = shortTerm
        self.integrated = integrated
        self.range = range
    }
}

/// Measures loudness the way broadcast and streaming services do (ITU-R BS.1770-4 and
/// EBU R 128): momentary, short-term, integrated with gating, and loudness range.
///
/// The integrated figure and the range are kept as tallies in 0.1 LU steps, so the meter
/// can run for any length of time in fixed memory.
public struct LoudnessMeter: Meter, ~Copyable {
    @inlinable public var reading: LoudnessReading { current }
    @usableFromInline var current = LoudnessReading()

    /// The tallies cover -70 to +30 LUFS in 0.1 LU steps.
    @inlinable static var steps: Int { 1_000 }
    @inlinable static var floorLUFS: Double { -70 }
    /// Three seconds of tenth-of-a-second pieces.
    @inlinable static var pieces: Int { 30 }

    @usableFromInline var channelCount = 0
    @usableFromInline var pieceFrames = 4_800
    @usableFromInline var filters: UnsafeMutablePointer<KWeighting>
    @usableFromInline var weights: UnsafeMutablePointer<Double>
    /// The weighted power of each of the last thirty pieces.
    @usableFromInline var recent: UnsafeMutablePointer<Double>
    @usableFromInline var recentIndex = 0
    @usableFromInline var recentCount = 0
    @usableFromInline var gathered = 0.0
    @usableFromInline var gatheredFrames = 0
    @usableFromInline var piecesSeen = 0
    /// For the integrated figure: how many 0.4-second blocks landed in each step, and their power.
    @usableFromInline var blockCount: UnsafeMutablePointer<Int>
    @usableFromInline var blockPower: UnsafeMutablePointer<Double>
    /// For the range: the same for 3-second windows, taken once a second.
    @usableFromInline var windowCount: UnsafeMutablePointer<Int>
    @usableFromInline var windowPower: UnsafeMutablePointer<Double>

    public init() {
        filters = .allocate(capacity: 1)
        weights = .allocate(capacity: 1)
        recent = .allocate(capacity: Self.pieces)
        blockCount = .allocate(capacity: Self.steps)
        blockPower = .allocate(capacity: Self.steps)
        windowCount = .allocate(capacity: Self.steps)
        windowPower = .allocate(capacity: Self.steps)
    }

    deinit {
        filters.deallocate()
        weights.deallocate()
        recent.deallocate()
        blockCount.deallocate()
        blockPower.deallocate()
        windowCount.deallocate()
        windowPower.deallocate()
    }

    /// - Parameter channelWeights: how much each channel counts. Leave nil for the standard's
    ///   values: 1 for every channel, except that in a six-channel layout (L R C LFE Ls Rs)
    ///   the LFE is left out and the surrounds count 1.41.
    public mutating func prepare(_ format: Format, maxFrames: Int, channelWeights: [Double]?) {
        filters.deallocate()
        weights.deallocate()
        channelCount = format.channelCount
        filters = .allocate(capacity: max(1, channelCount))
        weights = .allocate(capacity: max(1, channelCount))
        let standard: [Double] = channelCount == 6 ? [1, 1, 1, 0, 1.41, 1.41] : []
        for channel in 0..<channelCount {
            (filters + channel).initialize(to: KWeighting(sampleRate: format.sampleRate))
            if let channelWeights, channel < channelWeights.count {
                weights[channel] = channelWeights[channel]
            } else {
                weights[channel] = channel < standard.count ? standard[channel] : 1
            }
        }
        pieceFrames = max(1, format.sampleRate.frames(in: 0.1))
        reset()
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        prepare(format, maxFrames: maxFrames, channelWeights: nil)
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func measure(_ block: AudioBlock) {
        var done = 0
        while done < block.frameCount {
            let frames = min(block.frameCount - done, pieceFrames - gatheredFrames)
            for channel in 0..<min(block.channelCount, channelCount) {
                let samples = block[channel]
                var filter = filters[channel]
                var sum = 0.0
                for frame in done..<(done + frames) {
                    let weighted = filter.process(samples[frame])
                    sum += weighted * weighted
                }
                filters[channel] = filter
                gathered += weights[channel] * sum
            }
            gatheredFrames += frames
            done += frames
            if gatheredFrames == pieceFrames { finishPiece() }
        }
    }

    @inlinable static func loudness(_ power: Double) -> Double {
        power > 1e-20 ? -0.691 + 10 * log10(power) : -200
    }

    @inlinable static func step(for loudness: Double) -> Int {
        min(max(Int((loudness - floorLUFS) * 10), 0), steps - 1)
    }

    /// The mean power of the most recent pieces.
    @inlinable func mean(last count: Int) -> Double {
        var sum = 0.0
        for back in 0..<count {
            sum += recent[(recentIndex + Self.pieces - 1 - back) % Self.pieces]
        }
        return sum / Double(count)
    }

    /// Closes a tenth of a second and brings every figure up to date.
    @_noAllocation @_noLocks
    @inlinable mutating func finishPiece() {
        recent[recentIndex] = gathered / Double(pieceFrames)
        recentIndex = (recentIndex + 1) % Self.pieces
        recentCount = min(recentCount + 1, Self.pieces)
        piecesSeen += 1
        gathered = 0
        gatheredFrames = 0

        current.momentary = Float(Self.loudness(mean(last: min(recentCount, 4))))
        current.shortTerm = Float(Self.loudness(mean(last: recentCount)))

        // A new 0.4-second block ends every tenth of a second: three-quarters overlap.
        if recentCount >= 4 {
            let power = mean(last: 4)
            let level = Self.loudness(power)
            if level >= Self.floorLUFS {
                let step = Self.step(for: level)
                blockCount[step] += 1
                blockPower[step] += power
            }
            current.integrated = Float(Self.gated(blockCount, blockPower, relativeGate: -10).loudness)
        }
        // A new 3-second window is taken every second.
        if recentCount == Self.pieces, piecesSeen % 10 == 0 {
            let power = mean(last: Self.pieces)
            let level = Self.loudness(power)
            if level >= Self.floorLUFS {
                let step = Self.step(for: level)
                windowCount[step] += 1
                windowPower[step] += power
            }
            current.range = Float(Self.range(windowCount, windowPower))
        }
    }

    /// The loudness of everything in a tally that is within `relativeGate` LU of the tally's
    /// own average, and the step that gate falls in.
    @inlinable static func gated(_ counts: UnsafeMutablePointer<Int>, _ powers: UnsafeMutablePointer<Double>,
                                 relativeGate: Double) -> (loudness: Double, firstStep: Int) {
        var total = 0.0, number = 0
        for step in 0..<steps {
            total += powers[step]
            number += counts[step]
        }
        guard number > 0 else { return (-200, 0) }
        let gate = loudness(total / Double(number)) + relativeGate
        let first = gate > floorLUFS ? step(for: gate) : 0
        total = 0
        number = 0
        for step in first..<steps {
            total += powers[step]
            number += counts[step]
        }
        guard number > 0 else { return (-200, first) }
        return (loudness(total / Double(number)), first)
    }

    /// The spread between the 10th and 95th percentile of the gated 3-second windows.
    @inlinable static func range(_ counts: UnsafeMutablePointer<Int>, _ powers: UnsafeMutablePointer<Double>) -> Double {
        let first = gated(counts, powers, relativeGate: -20).firstStep
        var number = 0
        for step in first..<steps { number += counts[step] }
        guard number > 1 else { return 0 }
        let lowRank = Int(Double(number - 1) * 0.10 + 0.5)
        let highRank = Int(Double(number - 1) * 0.95 + 0.5)
        var seen = 0, low = first, high = first
        var foundLow = false
        for step in first..<steps where counts[step] > 0 {
            seen += counts[step]
            if !foundLow, seen > lowRank {
                low = step
                foundLow = true
            }
            if seen > highRank {
                high = step
                break
            }
        }
        return Double(high - low) / 10
    }

    public mutating func reset() {
        for channel in 0..<channelCount { filters[channel].reset() }
        for index in 0..<Self.pieces { recent[index] = 0 }
        for step in 0..<Self.steps {
            blockCount[step] = 0
            blockPower[step] = 0
            windowCount[step] = 0
            windowPower[step] = 0
        }
        recentIndex = 0
        recentCount = 0
        piecesSeen = 0
        gathered = 0
        gatheredFrames = 0
        current = LoudnessReading()
    }
}
