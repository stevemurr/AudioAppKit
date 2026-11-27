import AudioAppCore
import AudioAppProcessing
import AudioAppRealtime
import Darwin

// A compressor whose character is data. `DynamicsCore` is the plain case: one gain that moves at one attack and one
// release. The units people know by name move in ways that does not hold: an optical cell whose attack quickens as
// it works and whose release has a slow tail, a FET stage that settles into held compression, a console channel that
// follows the level before its ratio. Here those are numbers in a `CompressorCharacter`, and one recursion runs all of
// them, over arrays away from the audio thread and a block at a time on it.
//
// It sits beside `DynamicsCore` and is not built on it. The two keep their gain differently (this one as two stages
// of reduction above nothing, that one as a single gain below it, with an expander's mode this has no use for), and
// folding one into the other would change the arithmetic of whichever gave way; renders made on either are matched
// against references sample for sample.

/// How the level a compressor works from is measured.
@frozen public struct CompressorDetector: BitwiseCopyable, Equatable, Sendable {
    /// The louder channel's sample as it stands; otherwise the channels' mean power through a one-pole average.
    public var isPeak: Bool
    /// The average's coefficient per sample: what the running power keeps of itself.
    public var average: Double

    @inlinable public init(isPeak: Bool, average: Double) {
        self.isPeak = isPeak
        self.average = average
    }

    public static var peak: CompressorDetector { CompressorDetector(isPeak: true, average: 0) }

    /// Mean power averaged over a time constant in milliseconds.
    public static func rms(ms: Double, sampleRate: SampleRate) -> CompressorDetector {
        CompressorDetector(isPeak: false, average: exp(-1.0 / (ms * 1e-3 * sampleRate.hertz)))
    }

    /// The level of one frame in decibels re full scale, the channels linked.
    /// - Parameters:
    ///   - right: the same sample as `left` for a mono signal.
    ///   - power: the running mean power, which an rms detector keeps between frames.
    @_noAllocation @_noLocks
    @inlinable @inline(__always) public func levelDB(_ left: Float, _ right: Float, stereo: Bool, power: inout Double) -> Float {
        if isPeak {
            let toDecibels: Float = 4.342_944_8  // 10 / ln(10)
            return 2 * toDecibels * log(max(abs(left), abs(right)) + 1e-9)
        }
        let square = stereo ? (Double(left) * Double(left) + Double(right) * Double(right)) * 0.5 : Double(left) * Double(left)
        power = (1 - average) * square + average * power
        return Float(4.342_944_819_032_518 * log(power + 1e-18))
    }

    /// The level per frame of a whole signal, one or two channels: what `levelDB` gives frame by frame.
    public func levels(_ channels: [[Float]]) -> [Float] {
        guard let left = channels.first else { return [] }
        let stereo = channels.count > 1, right = stereo ? channels[1] : left
        var power = 0.0
        var out = [Float](repeating: 0, count: left.count)
        for index in 0..<min(left.count, right.count) { out[index] = levelDB(left[index], right[index], stereo: stereo, power: &power) }
        return out
    }
}

/// How a compressor's gain reduction moves, as the recursion reads it: coefficients per sample.
///
/// The reduction is kept in decibels above nothing, in two stages. In the usual order the level over the threshold
/// goes through the ratio and knee, and the fast stage follows the result: up at the attack (quicker the more it
/// already holds, for an optical cell), down at the release. A slow stage can carry a share of the reduction: it
/// follows the same result and lets go at the tail (an optical cell), or follows the fast stage, charging at the
/// settle time (a FET unit: a brief peak gets the fast share and lets go quickly, held compression settles to all
/// of it). With a floor the order is a console channel's: the level over the threshold, held from falling further
/// under it than the floor, is followed (up at once, down at the release), smoothed by the attack, and only then
/// put through the ratio and knee; after a gap the next note has to climb back before any reduction starts.
@frozen public struct CompressorMovement: BitwiseCopyable, Equatable, Sendable {
    /// 1 - 1 / ratio: the decibels taken off for each decibel over the threshold.
    public var slope: Double
    /// The full width of the soft knee in decibels; 0 is a hard knee.
    public var knee: Double
    public var attack: Double
    public var release: Double
    /// The slow stage's release, and the share of the reduction it carries; a share of 0 is no slow stage.
    public var tail: Double
    public var tailMix: Double
    /// What the attack gains per sample for each decibel of reduction held; 0 is a plain attack.
    public var quicken: Double
    /// How far under the threshold the level is followed from, in decibels; 0 is the usual order.
    public var floor: Double
    /// The coefficient at which the slow stage charges from the fast one; 0 has it follow the level.
    public var settle: Double

    @inlinable public init(slope: Double, knee: Double = 0, attack: Double = 0, release: Double = 0, tail: Double = 0, tailMix: Double = 0, quicken: Double = 0,
                           floor: Double = 0, settle: Double = 0) {
        self.slope = slope
        self.knee = knee
        self.attack = attack
        self.release = release
        self.tail = tail
        self.tailMix = tailMix
        self.quicken = quicken
        self.floor = floor
        self.settle = settle
    }

    /// The one-pole coefficient for a time constant in milliseconds; 0 for no smoothing.
    @inlinable public static func coefficient(ms: Double, sampleRate: SampleRate) -> Double { ms > 0 ? exp(-1.0 / (ms * 1e-3 * sampleRate.hertz)) : 0 }

    /// What an attack gains per sample for each decibel of reduction held, from a quickening in milliseconds times
    /// decibels; 0 for none.
    @inlinable public static func quickening(_ attackQ: Double, sampleRate: SampleRate) -> Double { attackQ > 0 ? 1 / (attackQ * 1e-3 * sampleRate.hertz) : 0 }

    /// The static curve: how many decibels to take off at this many over the threshold.
    @_noAllocation @_noLocks
    @inlinable @inline(__always) public static func staticReduction(over: Double, slope: Double, knee: Double) -> Double {
        if knee > 0, 2 * abs(over) <= knee { return slope * (over + knee / 2) * (over + knee / 2) / (2 * knee) }
        return over > 0 ? slope * over : 0
    }

    /// One sample of the recursion: the detector's level in, the gain reduction out, in decibels above nothing.
    /// - Parameter fast, slow: the two stages, kept by the caller between samples; both start at nothing.
    @_noAllocation @_noLocks
    @inlinable @inline(__always) public func step(levelDB: Float, thresholdDB: Double, fast: inout Double, slow: inout Double) -> Float {
        if floor > 0 {
            // A follower of the level over the threshold, measured up from the floor (`slow`), smoothed by the attack
            // (`fast`), and the ratio and knee last.
            let c = max(Double(levelDB) - thresholdDB + floor, 0)
            slow = c > slow ? c : release * slow + (1 - release) * c
            fast = attack * fast + (1 - attack) * slow
            return Float(Self.staticReduction(over: fast - floor, slope: slope, knee: knee))
        }
        let c = Self.staticReduction(over: Double(levelDB) - thresholdDB, slope: slope, knee: knee)
        // With no quickening this is the plain one-pole attack.
        if c > fast { fast += (c - fast) * min(1, (1 - attack) + quicken * fast) } else { fast = release * fast + (1 - release) * c }
        guard tailMix > 0 else { return Float(fast) }
        if settle > 0 {
            slow = fast > slow ? settle * slow + (1 - settle) * fast : tail * slow + (1 - tail) * fast
        } else {
            slow = c > slow ? attack * slow + (1 - attack) * c : tail * slow + (1 - tail) * c
        }
        return Float((1 - tailMix) * fast + tailMix * slow)
    }

    /// The gain reduction per sample for a whole signal's levels, from rest.
    /// - Parameter out: as long as `levels`.
    public func reduction(levels: [Float], thresholdDB: Double, into out: inout [Float]) {
        var fast = 0.0, slow = 0.0
        let count = min(levels.count, out.count)
        levels.withUnsafeBufferPointer { levels in
            out.withUnsafeMutableBufferPointer { out in
                for index in 0..<count { out[index] = step(levelDB: levels[index], thresholdDB: thresholdDB, fast: &fast, slow: &slow) }
            }
        }
    }

    public func reduction(levels: [Float], thresholdDB: Double) -> [Float] {
        var out = [Float](repeating: 0, count: levels.count)
        reduction(levels: levels, thresholdDB: thresholdDB, into: &out)
        return out
    }

    /// The threshold at which the gain reduction reaches a wanted amount on the loud parts: the one where a
    /// percentile of the reduction, over the samples that count, is `targetDB`. Found by halving a range.
    /// - Parameters:
    ///   - levels: the detector's level per sample for the whole signal.
    ///   - indices: the samples whose reduction counts: those that carry signal, thinned as the caller likes.
    ///   - percentile: which percentile of the reduction is the loud parts'.
    ///   - range: the thresholds to look between, in decibels.
    ///   - iterations: each halves the range.
    /// - Returns: the middle of the range left, or nil if it was cancelled.
    public func threshold(reaching targetDB: Double, levels: [Float], indices: [Int], percentile: Double = 95, range: (Double, Double) = (-90, 0),
                          iterations: Int = 18, isCancelled: () -> Bool = { false }) -> Double? {
        var (lo, hi) = range
        var scratch = [Float](repeating: 0, count: levels.count)
        var sampled = [Float](repeating: 0, count: indices.count)
        for _ in 0..<iterations {
            if isCancelled() { return nil }
            let mid = (lo + hi) / 2
            reduction(levels: levels, thresholdDB: mid, into: &scratch)
            for (slot, index) in indices.enumerated() { sampled[slot] = scratch[index] }
            if SampleStatistics.percentile(&sampled, percentile) > targetDB {
                lo = mid  // too much reduction: raise the threshold
            } else {
                hi = mid
            }
        }
        return (lo + hi) / 2
    }
}

/// A unit's colour: harmonics added to the compressed signal, growing with its level and with the gain reduction.
///
/// The signal after the reduction and before the make-up is measured against a reference amplitude. A second
/// harmonic (its steady part taken out by a one-pole high-pass) and a third are added; `d2` and `d3` are always
/// there, `r2` and `r3` come in with the reduction, in full at `fullReductionDB`.
@frozen public struct CompressorColour: BitwiseCopyable, Equatable, Sendable {
    public var d2: Double
    public var d3: Double
    public var r2: Double
    public var r3: Double
    /// The amplitude the signal is measured against, such as a sine just reaching the threshold.
    public var amplitude: Double
    /// The shaper sees the signal clipped to this many times the reference.
    public var clip: Double
    /// One over the gain reduction at which `r2` and `r3` apply in full, and the most reduction that counts.
    public var perDecibel: Double
    public var mostReductionDB: Float
    /// The pole of the high-pass that takes the second harmonic's steady part out.
    public var dcPole: Double

    @inlinable public init(d2: Double = 0, d3: Double = 0, r2: Double = 0, r3: Double = 0, amplitude: Double = 1, clip: Double = 4, fullReductionDB: Double = 8,
                           mostReductionDB: Double = 16, dcHz: Double = 5, sampleRate: SampleRate) {
        self.d2 = d2
        self.d3 = d3
        self.r2 = r2
        self.r3 = r3
        self.amplitude = amplitude
        self.clip = clip
        perDecibel = 1 / fullReductionDB
        self.mostReductionDB = Float(mostReductionDB)
        dcPole = exp(-2 * Double.pi * dcHz / sampleRate.hertz)
    }

    /// Whether it adds any harmonics at all.
    @inlinable public var hasTone: Bool { d2 != 0 || d3 != 0 || r2 != 0 || r3 != 0 }
}

/// A unit's character as a person would write it down: times in milliseconds, a ratio, the colour's coefficients.
/// Plain data, so a set of them can be kept in a file.
public struct CompressorCharacter: Codable, Equatable, Sendable {
    public var isPeak: Bool
    /// The averaging time of an rms detector.
    public var rmsMs: Double
    public var ratio: Double
    public var kneeDB: Double
    public var attackMs: Double
    public var releaseMs: Double
    /// A second, slow stage: its release and the share of the reduction it carries; 0 for none.
    public var tailMs: Double
    public var tailMix: Double
    /// An optical cell's quickening, in milliseconds times decibels: the fast stage's rate is
    /// `1 / attackMs + reduction / attackQ` per millisecond. 0 is a plain attack.
    public var attackQ: Double
    /// A console channel's floor in decibels; 0 is the usual order.
    public var floorDB: Double
    /// A FET unit's settle time: the slow stage follows the fast one, charging at this. 0 has it follow the level.
    public var settleMs: Double
    public var toneD2: Double
    public var toneD3: Double
    public var toneR2: Double
    public var toneR3: Double

    public init(isPeak: Bool, rmsMs: Double = 0, ratio: Double, kneeDB: Double = 0, attackMs: Double, releaseMs: Double, tailMs: Double = 0, tailMix: Double = 0,
                attackQ: Double = 0, floorDB: Double = 0, settleMs: Double = 0, toneD2: Double = 0, toneD3: Double = 0, toneR2: Double = 0, toneR3: Double = 0) {
        self.isPeak = isPeak
        self.rmsMs = rmsMs
        self.ratio = ratio
        self.kneeDB = kneeDB
        self.attackMs = attackMs
        self.releaseMs = releaseMs
        self.tailMs = tailMs
        self.tailMix = tailMix
        self.attackQ = attackQ
        self.floorDB = floorDB
        self.settleMs = settleMs
        self.toneD2 = toneD2
        self.toneD3 = toneD3
        self.toneR2 = toneR2
        self.toneR3 = toneR3
    }

    public func detector(sampleRate: SampleRate) -> CompressorDetector {
        isPeak ? .peak : .rms(ms: rmsMs, sampleRate: sampleRate)
    }

    public func movement(sampleRate: SampleRate) -> CompressorMovement {
        CompressorMovement(slope: 1 - 1 / ratio, knee: kneeDB, attack: CompressorMovement.coefficient(ms: attackMs, sampleRate: sampleRate),
                           release: CompressorMovement.coefficient(ms: releaseMs, sampleRate: sampleRate),
                           tail: CompressorMovement.coefficient(ms: tailMs, sampleRate: sampleRate), tailMix: tailMix,
                           quicken: CompressorMovement.quickening(attackQ, sampleRate: sampleRate), floor: max(floorDB, 0),
                           settle: CompressorMovement.coefficient(ms: settleMs, sampleRate: sampleRate))
    }

    /// The colour, measured against a sine just reaching the threshold.
    public func colour(thresholdDB: Double, sampleRate: SampleRate) -> CompressorColour {
        CompressorColour(d2: toneD2, d3: toneD3, r2: toneR2, r3: toneR3, amplitude: pow(10, thresholdDB / 20) * (isPeak ? 1 : 2.0.squareRoot()),
                         sampleRate: sampleRate)
    }
}

/// One compressor between blocks: the detector's running power, the two stages of the gain reduction, the glides
/// that switch it in and move its make-up and its colour, and the colour's high-pass.
///
/// A plain value with no memory of its own to reserve: keep one per channel strip and call `process` on it.
@frozen public struct ProfileCompressor: Sendable {
    /// What a compressor is told for a block.
    @frozen public struct Settings: BitwiseCopyable, Sendable {
        public var detector: CompressorDetector
        public var movement: CompressorMovement
        public var thresholdDB: Double
        /// Gain added after the reduction, in decibels.
        public var makeupDB: Float
        /// 0 to 1: how far the compressor is switched in. It scales the reduction and the make-up in decibels.
        public var mix: Float
        public var colour: CompressorColour
        /// 0 to 1: how much of the colour.
        public var tone: Float

        @inlinable public init(detector: CompressorDetector, movement: CompressorMovement, thresholdDB: Double, makeupDB: Float = 0, mix: Float = 1,
                               colour: CompressorColour, tone: Float = 1) {
            self.detector = detector
            self.movement = movement
            self.thresholdDB = thresholdDB
            self.makeupDB = makeupDB
            self.mix = mix
            self.colour = colour
            self.tone = tone
        }

        /// A character at a threshold, switched in.
        public init(_ character: CompressorCharacter, thresholdDB: Double, makeupDB: Double = 0, tone: Double = 1, sampleRate: SampleRate) {
            self.init(detector: character.detector(sampleRate: sampleRate), movement: character.movement(sampleRate: sampleRate), thresholdDB: thresholdDB,
                      makeupDB: Float(makeupDB), colour: character.colour(thresholdDB: thresholdDB, sampleRate: sampleRate), tone: Float(tone))
        }
    }

    /// What it did over a block: the detector's level and the gain reduction, each at its highest, in decibels.
    @frozen public struct Reading: BitwiseCopyable, Sendable {
        public var levelDB: Float
        public var reductionDB: Float

        @inlinable public init(levelDB: Float = -200, reductionDB: Float = 0) {
            self.levelDB = levelDB
            self.reductionDB = reductionDB
        }
    }

    public var power = 0.0
    public var fast = 0.0
    public var slow = 0.0
    public var mix = Smoothed(0)
    public var makeup = Smoothed(0)
    /// How much of the colour, gliding.
    public var tone = Smoothed(1)
    /// The high-pass on the second-harmonic term, per channel: its last input and output.
    public var dc = (0.0, 0.0, 0.0, 0.0)

    @inlinable public init() {}

    /// Sets how long switching in and out, and a change of make-up or colour, take.
    @inlinable public mutating func configure(sampleRate: SampleRate, glideSeconds: Double) {
        mix.configure(sampleRate: sampleRate, seconds: glideSeconds)
        makeup.configure(sampleRate: sampleRate, seconds: glideSeconds)
        tone.configure(sampleRate: sampleRate, seconds: glideSeconds)
    }

    /// Forgets the signal: the detector and both stages at rest. The glides stay where they are.
    @_noAllocation @_noLocks
    @inlinable public mutating func reset() {
        power = 0
        fast = 0
        slow = 0
        dc = (0, 0, 0, 0)
    }

    /// Puts the glides where the settings want them, with no fade: for the start of playback, and offline.
    @_noAllocation @_noLocks
    @inlinable public mutating func snap(to settings: Settings) {
        mix.snap(to: settings.mix)
        makeup.snap(to: settings.makeupDB)
        tone.snap(to: settings.tone)
    }

    /// Compresses a block in place, one gain for both channels.
    /// - Parameters:
    ///   - right: the same memory as `left` for a mono signal.
    /// - Returns: what it did, or nil when it is switched out and has faded out: the block is then untouched.
    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, stereo: Bool, frames: Int,
                                            _ settings: Settings) -> Reading? {
        mix.set(settings.mix)
        guard mix.isRamping || settings.mix != 0 else { return nil }
        makeup.set(settings.makeupDB)
        let detector = settings.detector, movement = settings.movement, threshold = settings.thresholdDB
        // The colour: skipped altogether for a character with none, or with the tone at nothing.
        let colour = settings.colour
        let hasTone = colour.hasTone
        tone.set(hasTone ? settings.tone : 0)
        let coloured = hasTone && (tone.isRamping || tone.target != 0)
        let amplitude = colour.amplitude, block = colour.dcPole, clip = colour.clip
        var dc = self.dc
        if !coloured { dc = (0, 0, 0, 0) }
        var power = self.power, fast = self.fast, slow = self.slow
        var highest: Float = -200, deepest: Float = 0
        for frame in 0..<frames {
            let l = left[frame], r = right[frame]
            let level = detector.levelDB(l, r, stereo: stereo, power: &power)
            let reduction = movement.step(levelDB: level, thresholdDB: threshold, fast: &fast, slow: &slow)
            // Decibels to a factor; the glide on `mix` is what switches the compressor in and out.
            let makeup = self.makeup.next(), mix = self.mix.next()
            let amount = coloured ? Double(tone.next() * mix) : 0
            if amount > 0 {
                // The compressed signal before make-up, measured against the reference, gains a second harmonic (its
                // steady part taken out) and a third, both growing with the gain reduction. In double precision.
                let k = Double(min(reduction, colour.mostReductionDB)) * colour.perDecibel
                let c2 = amount * (colour.d2 + colour.r2 * k), c3 = amount * (colour.d3 + colour.r3 * k)
                let squeeze = exp(-Double(reduction * mix) * 0.115_129_254_649_702_28) / amplitude
                let lift = Float(amplitude) * exp(makeup * mix * 0.115_129_255)
                let v = Double(l) * squeeze
                let s = min(max(v, -clip), clip)
                let square = c2 * s * s
                dc.1 = square - dc.0 + block * dc.1
                dc.0 = square
                left[frame] = Float(v + dc.1 - c3 * s * s * s) * lift
                if stereo {
                    let v = Double(r) * squeeze
                    let s = min(max(v, -clip), clip)
                    let square = c2 * s * s
                    dc.3 = square - dc.2 + block * dc.3
                    dc.2 = square
                    right[frame] = Float(v + dc.3 - c3 * s * s * s) * lift
                }
            } else {
                // No colour (or none left of it): the clean compressor, and the high-pass empty.
                let gain = exp((makeup - reduction) * mix * 0.115_129_255)
                left[frame] = l * gain
                if stereo { right[frame] = r * gain }
                dc = (0, 0, 0, 0)
            }
            if level > highest { highest = level }
            if reduction > deepest { deepest = reduction }
        }
        self.power = power
        self.fast = fast
        self.slow = slow
        self.dc = dc
        return Reading(levelDB: highest, reductionDB: deepest * mix.current)
    }

    /// A whole signal of one or two channels through a compressor from rest, switched in from the first sample: the
    /// arithmetic `process` does a block at a time.
    public static func render(_ channels: [[Float]], _ settings: Settings) -> [[Float]] {
        guard let first = channels.first, !first.isEmpty else { return channels }
        var unit = ProfileCompressor()
        unit.snap(to: settings)
        var left = first, right = channels.count > 1 ? channels[1] : []
        let stereo = right.count == left.count
        left.withUnsafeMutableBufferPointer { l in
            if stereo {
                right.withUnsafeMutableBufferPointer { r in _ = unit.process(l.baseAddress!, r.baseAddress!, stereo: true, frames: l.count, settings) }
            } else {
                _ = unit.process(l.baseAddress!, l.baseAddress!, stereo: false, frames: l.count, settings)
            }
        }
        return stereo ? [left, right] : [left]
    }
}

/// Order statistics of a run of samples.
public enum SampleStatistics {
    /// A percentile by linear interpolation between the two nearest ranks, as NumPy's `percentile` gives it. The
    /// values may be reordered.
    public static func percentile(_ values: inout [Float], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let position = Double(values.count - 1) * q / 100
        let lower = Int(position.rounded(.down))
        let fraction = position - Double(lower)
        let a = select(&values, lower)
        guard fraction > 0, lower + 1 < values.count else { return Double(a) }
        // After the selection everything to the right is no smaller: the next one up is their minimum.
        var b = Float.infinity
        for index in (lower + 1)..<values.count { b = min(b, values[index]) }
        return Double(a) + (Double(b) - Double(a)) * fraction
    }

    /// Puts the k-th smallest value at index k (smaller to its left, no smaller to its right) and returns it.
    @discardableResult public static func select(_ values: inout [Float], _ k: Int) -> Float {
        values.withUnsafeMutableBufferPointer { v in
            var low = 0, high = v.count - 1
            while low < high {
                let pivot = v[(low + high) / 2]
                var i = low, j = high
                while i <= j {
                    while v[i] < pivot { i += 1 }
                    while v[j] > pivot { j -= 1 }
                    if i <= j {
                        v.swapAt(i, j)
                        i += 1
                        j -= 1
                    }
                }
                if k <= j { high = j } else if k >= i { low = i } else { break }
            }
            return v[k]
        }
    }
}
