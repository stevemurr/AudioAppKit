import Darwin

/// An equaliser driven by a reference: the curve of band gains that moves a signal's spectrum toward a reference
/// spectrum, by an amount and within a limit. Pass the signal's power in each band and the shape wanted of it; apply
/// the curve with a `BandCurveFilter`, or fit sections to it with a `SectionFit`.
///
/// Shapes are level-free: a spectrum's power in each band as a share of its total, in decibels. The gap between the
/// reference's shape and the signal's is clipped, faded out over the bands where the signal has next to nothing
/// (there is nothing there to lift), made level-free in its turn, smoothed across bands, scaled by the amount and
/// limited. Holding the level, the curve is then shifted so that the signal's summed power is what it was.
public struct BandMatch: Equatable, Sendable {
    /// How much of the gap is closed: 0 for none, 1 for all of it; above 1 overshoots, below 0 moves away.
    public var amount: Double
    /// No band is moved further than this, either way, in decibels.
    public var limitDB: Double
    /// The gap in a band counts for no more than this, in decibels.
    public var clipDB: Double
    /// A band this far under the signal's strongest gets nothing; from there the curve fades in over `fadeDB`.
    public var absentDB: Double
    public var fadeDB: Double
    /// The smoothing across bands: the width of a Gaussian, in bands. 0 for none.
    public var smooth: Double
    /// Shift the curve so that the signal keeps its level.
    public var holdsLevel: Bool

    public init(amount: Double = 1, limitDB: Double = 6, clipDB: Double = 20, absentDB: Double = 45, fadeDB: Double = 20, smooth: Double = 1, holdsLevel: Bool = true) {
        self.amount = amount
        self.limitDB = limitDB
        self.clipDB = clipDB
        self.absentDB = absentDB
        self.fadeDB = fadeDB
        self.smooth = smooth
        self.holdsLevel = holdsLevel
    }

    /// What a match asks for.
    public struct Curve: Equatable, Sendable {
        /// A gain per band in decibels, the level hold in it.
        public var gainsDB: [Double]
        /// The one gain the level hold put in every band, in decibels; 0 without it.
        public var holdDB: Double
    }

    /// A spectrum's shape: each band's share of the total power, in decibels.
    public static func shape(_ power: [Double]) -> [Double] {
        let total = power.reduce(0, +)
        return power.map { 10 * log10(max($0 / max(total, 1e-300), 1e-12)) }
    }

    /// The curve that moves a signal toward a reference.
    /// - Parameters:
    ///   - power: the signal's power in each band.
    ///   - reference: the shape wanted of it, a level-free value per band in decibels; nil asks for nothing, and
    ///     gives a curve of nothing.
    public func curve(power: [Double], reference: [Double]?) -> Curve {
        let bands = power.count
        let total = power.reduce(0, +)
        let share = power.map { $0 / max(total, 1e-300) }
        let shape = share.map { 10 * log10(max($0, 1e-12)) }
        let top = shape.max() ?? 0
        var gap = (0..<bands).map { band -> Double in
            let wanted = reference.map { $0[band] - shape[band] } ?? 0
            let present = min(max((shape[band] - top + absentDB) / fadeDB, 0), 1)
            return min(max(wanted, -clipDB), clipDB) * present
        }
        let mean = zip(share, gap).reduce(0) { $0 + $1.0 * $1.1 }
        gap = Self.smoothed(gap.map { $0 - mean }, sigma: smooth)
        var curve = gap.map { min(max(amount * $0, -limitDB), limitDB) }
        guard holdsLevel else { return Curve(gainsDB: curve, holdDB: 0) }
        let after = (0..<bands).reduce(0.0) { $0 + power[$1] * pow(10, curve[$1] / 10) }
        let shift = 10 * log10(max(after, 1e-30) / total)
        curve = curve.map { $0 - shift }
        return Curve(gainsDB: curve, holdDB: -shift)
    }

    /// The curve that puts a spectrum back where it was: with `before` and `after` the power in each band before
    /// and after something was done to it, what undoes the change, smoothed across bands and limited. For matching
    /// the tone of a sum whose parts have each been moved.
    public static func restoring(before: [Double], after: [Double], smooth: Double, limitDB: Double) -> [Double] {
        smoothed(before.indices.map { 10 * log10(max(before[$0], 1e-30) / max(after[$0], 1e-30)) }, sigma: smooth).map { min(max($0, -limitDB), limitDB) }
    }

    /// A row of band values smoothed by a Gaussian `sigma` bands wide, the ends held.
    public static func smoothed(_ x: [Double], sigma: Double) -> [Double] {
        guard sigma > 0, !x.isEmpty else { return x }
        let radius = Int(4 * sigma + 0.5)
        var kernel = (-radius...radius).map { exp(-0.5 * pow(Double($0) / sigma, 2)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        return x.indices.map { index in
            var sum = 0.0
            for (offset, weight) in kernel.enumerated() { sum += weight * x[min(max(index + offset - radius, 0), x.count - 1)] }
            return sum
        }
    }
}
