import AudioAppCore
import AudioAppRealtime
import Darwin

// An equaliser of a few parametric sections with fixed centres, driven by a curve: the gains that best give the
// curve are found by least squares, and the sections are run as a cascade whose gains glide. Where a
// `BandCurveFilter` gives a curve exactly, this gives what a console channel would make of it.

/// One section of such an equaliser: a bell or a shelf at a fixed frequency and sharpness. Only its gain moves.
@frozen public struct EQSection: Hashable, Sendable {
    public var response: FilterResponse
    public var frequency: Double
    public var q: Double

    @inlinable public init(_ response: FilterResponse, frequency: Double, q: Double) {
        self.response = response
        self.frequency = frequency
        self.q = q
    }

    /// The section at a gain in decibels.
    @_noAllocation @_noLocks
    @inlinable public func coefficients(gainDB: Double, sampleRate: SampleRate) -> BiquadCoefficients {
        .design(response, frequency: frequency, amplitude: SectionMath.tenTo(gainDB / 40), q: max(q, 1e-3), sampleRate: sampleRate)
    }
}

@usableFromInline enum SectionMath {
    /// Ten to a power, the square root taken as one.
    @_noAllocation @_noLocks
    @inlinable static func tenTo(_ exponent: Double) -> Double { exponent == 0.5 ? RealtimeMath.sqrt(10) : RealtimeMath.pow(10, exponent) }
}

/// Finds the gains of sections with fixed centres that best give a curve in decibels: least squares over the
/// frequencies the curve is given at, each section's response in decibels taken as its shape at a reference gain
/// times its gain.
public struct SectionFit: Sendable {
    public let sections: [EQSection]
    /// The frequencies a curve is given at, in hertz.
    public let frequencies: [Double]
    public let sampleRate: SampleRate
    /// No section is given more than this, either way.
    public let maxGainDB: Double
    /// sections x frequencies: each section's decibels at a gain of one decibel.
    let basis: [[Double]]
    /// sections x frequencies: what a curve is multiplied by to give the gains, before they are limited.
    public let inverse: [Double]
    /// Whether the fit has a level of its own to set, which is then thrown away.
    public let hasFreeOffset: Bool

    /// - Parameters:
    ///   - referenceGainDB: the gain at which a section's shape is taken for the fit.
    ///   - freeOffset: fit the curve's shape and leave its overall level alone. The sections are fitted together with
    ///     a gain on the whole, and that gain is dropped: for a curve whose level is set some other way, so that the
    ///     sections need not spend themselves on it.
    public init(sections: [EQSection], at frequencies: [Double], sampleRate: SampleRate, referenceGainDB: Double = 6, maxGainDB: Double = 12, freeOffset: Bool = false) {
        hasFreeOffset = freeOffset
        self.sections = sections
        self.frequencies = frequencies
        self.sampleRate = sampleRate
        self.maxGainDB = maxGainDB
        let hz = frequencies
        basis = sections.map { section in
            let c = section.coefficients(gainDB: referenceGainDB, sampleRate: sampleRate)
            return hz.map { Self.magnitudeDB(c, at: $0, sampleRate: sampleRate) / referenceGainDB }
        } + (freeOffset ? [[Double](repeating: 1, count: hz.count)] : [])
        // One solve per frequency: the gains a curve that is 1 there and 0 elsewhere asks for.
        var inverse = [Double](repeating: 0, count: sections.count * hz.count)
        for k in hz.indices {
            var unit = [Double](repeating: 0, count: hz.count)
            unit[k] = 1
            let g = Self.fit(basis, unit)
            for b in sections.indices { inverse[b * hz.count + k] = g[b] }
        }
        self.inverse = inverse
    }

    /// The gains for a curve given at `frequencies`, limited either way.
    /// - Parameter maxGainDB: another limit than the fit's own.
    public func solve(_ target: [Double], maxGainDB limit: Double? = nil) -> [Double] {
        let most = limit ?? maxGainDB
        return Self.fit(basis, target).prefix(sections.count).map { min(max($0, -most), most) }
    }

    /// A section's magnitude in decibels at a frequency.
    public static func magnitudeDB(_ c: BiquadCoefficients, at hz: Double, sampleRate: SampleRate) -> Double {
        let w = 2 * Double.pi * hz / sampleRate.hertz
        return c.magnitudeDB(cosine: cos(w), sine: sin(w), cosine2: cos(2 * w), sine2: sin(2 * w))
    }

    /// A cascade's magnitude in decibels at each of some frequencies, for a gain per section.
    public static func response(_ sections: [EQSection], gainsDB: [Double], at hz: [Double], sampleRate: SampleRate) -> [Double] {
        var out = [Double](repeating: 0, count: hz.count)
        for (section, gain) in zip(sections, gainsDB) where gain != 0 {
            let c = section.coefficients(gainDB: gain, sampleRate: sampleRate)
            for (index, f) in hz.enumerated() { out[index] += magnitudeDB(c, at: f, sampleRate: sampleRate) }
        }
        return out
    }

    /// The one gain in decibels that keeps a signal at its level under a response: with `power` the signal's power
    /// in each band and `responseDB` what is done to each, the gain that leaves the summed power where it was.
    public static func levelHold(power: [Double], responseDB: [Double]) -> Double {
        let total = power.reduce(0, +)
        let after = zip(power, responseDB).reduce(0.0) { $0 + $1.0 * pow(10, $1.1 / 10) }
        return total > 0 ? -10 * log10(max(after, 1e-30) / total) : 0
    }

    /// Least squares by the normal equations, a little weight on the diagonal, solved by elimination.
    static func fit(_ basis: [[Double]], _ target: [Double]) -> [Double] {
        let count = basis.count
        var a = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
        var y = [Double](repeating: 0, count: count)
        for i in 0..<count {
            for j in 0..<count { for k in target.indices { a[i][j] += basis[i][k] * basis[j][k] } }
            for k in target.indices { y[i] += basis[i][k] * target[k] }
        }
        for i in 0..<count { a[i][i] += 1e-6 }
        // Gaussian elimination with partial pivoting.
        for column in 0..<count {
            var pivot = column
            for row in (column + 1)..<max(count, column + 1) where abs(a[row][column]) > abs(a[pivot][column]) { pivot = row }
            a.swapAt(pivot, column)
            y.swapAt(pivot, column)
            let d = a[column][column]
            if abs(d) < 1e-18 { continue }
            for row in 0..<count where row != column {
                let f = a[row][column] / d
                for c in column..<count { a[row][c] -= f * a[column][c] }
                y[row] -= f * y[column]
            }
        }
        return (0..<count).map { abs(a[$0][$0]) < 1e-18 ? 0 : y[$0] / a[$0][$0] }
    }
}

/// Cascades of the same sections for a whole mixer: one set of gains per curve, and each track's own filter memory,
/// so that several tracks can share a curve.
///
/// A curve's gains are moved toward what is wanted of them a little at a time (at most `step` decibels each time
/// `update` is called), and a section is designed again only when its gain has moved; the filters' memories are
/// never cleared for a change of gain. A section at 0 dB is not run. With each curve goes a trim: one gain on the
/// whole, which glides the same way.
///
/// Memory is reserved when it is made, so make it away from the audio thread.
public struct SectionBank: ~Copyable {
    public let sectionCount: Int
    public let curveCount: Int
    public let trackCount: Int
    /// The largest move of a gain in one update, in decibels.
    public let step: Double
    public let sampleRate: SampleRate
    @usableFromInline let sections: UnsafeMutablePointer<EQSection>
    /// Per curve and section: the gain in force; then per curve the trim in force, in decibels.
    @usableFromInline let gains: UnsafeMutablePointer<Double>
    @usableFromInline let trims: UnsafeMutablePointer<Double>
    @usableFromInline let coefficients: UnsafeMutablePointer<BiquadCoefficients>
    /// Per curve: whether anything is to be done at all; and whether it has been given gains since the reset.
    @usableFromInline let active: UnsafeMutablePointer<Bool>
    @usableFromInline let started: UnsafeMutablePointer<Bool>
    /// Per track, channel and section: what the section remembers.
    @usableFromInline let memory: UnsafeMutablePointer<BiquadState>
    @usableFromInline let scratch: UnsafeMutablePointer<Double>
    @usableFromInline let chunk: Int

    public init(sections: [EQSection], curves: Int, tracks: Int, sampleRate: SampleRate, step: Double = 0.2) {
        sectionCount = sections.count
        curveCount = max(0, curves)
        trackCount = max(0, tracks)
        self.step = step
        self.sampleRate = sampleRate
        chunk = 1_024
        self.sections = .allocate(capacity: max(1, sectionCount))
        self.sections.initialize(from: sections, count: sectionCount)
        gains = Memory.doubles(curveCount * sectionCount)
        trims = Memory.doubles(curveCount)
        coefficients = .allocate(capacity: max(1, curveCount * sectionCount))
        coefficients.initialize(repeating: .identity, count: max(1, curveCount * sectionCount))
        active = .allocate(capacity: max(1, curveCount))
        active.initialize(repeating: false, count: max(1, curveCount))
        started = .allocate(capacity: max(1, curveCount))
        started.initialize(repeating: false, count: max(1, curveCount))
        memory = .allocate(capacity: max(1, trackCount * 2 * sectionCount))
        memory.initialize(repeating: BiquadState(), count: max(1, trackCount * 2 * sectionCount))
        scratch = Memory.doubles(chunk)
    }

    deinit {
        sections.deallocate()
        gains.deallocate()
        trims.deallocate()
        coefficients.deallocate()
        active.deallocate()
        started.deallocate()
        memory.deallocate()
        scratch.deallocate()
    }

    /// The gain a curve's section has now, in decibels, and the curve's trim: where the glides have got to.
    @inlinable public func gainDB(curve: Int, section: Int) -> Double { gains[curve * sectionCount + section] }
    @inlinable public func trimDB(curve: Int) -> Double { trims[curve] }

    /// Nothing in any filter, and every curve takes the next gains it is given at once.
    @_noAllocation @_noLocks
    @inlinable public func reset() {
        for index in 0..<(trackCount * 2 * sectionCount) { memory[index] = BiquadState() }
        for curve in 0..<curveCount {
            started[curve] = false
            active[curve] = false
            trims[curve] = 0
            for section in 0..<sectionCount {
                gains[curve * sectionCount + section] = 0
                coefficients[curve * sectionCount + section] = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
            }
        }
    }

    /// Moves a curve's gains toward `wanted`: a gain in decibels for each section and then the trim; nil is nothing
    /// at all. The first gains after a reset are taken at once.
    @_noAllocation @_noLocks
    @inlinable public func update(_ curve: Int, wanted: UnsafePointer<Float>?) {
        guard curve >= 0, curve < curveCount else { return }
        let snap = !started[curve]
        started[curve] = true
        var any = false
        for section in 0...sectionCount {
            let target = wanted.map { Double($0[section]) } ?? 0
            let slot = section < sectionCount ? gains + (curve * sectionCount + section) : trims + curve
            var value = slot.pointee
            if value != target {
                let apart = target - value
                value = snap || abs(apart) <= step ? target : value + (apart > 0 ? step : -step)
                slot.pointee = value
                if section < sectionCount {
                    coefficients[curve * sectionCount + section] = value == 0 ? BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
                        : sections[section].coefficients(gainDB: value, sampleRate: sampleRate)
                }
            }
            if value != 0 { any = true }
        }
        active[curve] = any
    }

    /// Runs a track through a curve's cascade in place.
    /// - Parameter right: nil for a mono track.
    @_noAllocation @_noLocks
    @inlinable public func process(track: Int, curve: Int, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, frames: Int) {
        guard curve >= 0, curve < curveCount, track >= 0, track < trackCount, active[curve] else { return }
        let trim = trims[curve] == 0 ? 1 : SectionMath.tenTo(trims[curve] / 20)
        var done = 0
        while done < frames {
            let count = min(chunk, frames - done)
            for channel in 0..<(right == nil ? 1 : 2) {
                let samples = (channel == 0 ? left : right!) + done
                let kept = memory + (track * 2 + channel) * sectionCount
                // In double precision from one end of the cascade to the other.
                for frame in 0..<count { scratch[frame] = Double(samples[frame]) }
                for section in 0..<sectionCount where gains[curve * sectionCount + section] != 0 {
                    let c = coefficients[curve * sectionCount + section]
                    var state = kept[section]
                    for frame in 0..<count { scratch[frame] = state.step(scratch[frame], c) }
                    kept[section] = state
                }
                for frame in 0..<count { samples[frame] = Float(scratch[frame] * trim) }
            }
            done += count
        }
    }
}
