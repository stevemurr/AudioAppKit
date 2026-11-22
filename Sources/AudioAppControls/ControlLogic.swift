import AudioAppKit
import CoreGraphics
import Foundation

/// How a control's travel maps onto values: a range, a taper and an optional step. Faders,
/// knobs and sliders all do their arithmetic through this, so they agree with each other and
/// with the parameter they drive.
public struct ControlMapping: Equatable, Sendable {
    public var range: ClosedRange<Float>
    public var taper: Taper
    /// Values snap to multiples of this. Zero for no snapping.
    public var step: Float

    public init(range: ClosedRange<Float>, taper: Taper = .linear, step: Float = 0) {
        self.range = range
        self.taper = taper
        self.step = max(0, step)
    }

    public init(_ parameter: Parameter, step: Float = 0) {
        self.init(range: parameter.range, taper: parameter.taper, step: step)
    }

    /// Where a value sits along the control, from 0 to 1.
    public func position(of value: Float) -> Float { taper.position(of: value, in: range) }

    /// The value at a position from 0 to 1, snapped and kept in range.
    public func value(at position: Float) -> Float { snapped(taper.value(at: position, in: range)) }

    public func snapped(_ value: Float) -> Float {
        let stepped = step > 0 ? (value / step).rounded() * step : value
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    /// The value after a number of key presses or wheel notches. With a step, each one moves a
    /// step (a tenth of one when fine); without, a hundredth of the travel (a thousandth when fine).
    public func nudged(_ value: Float, by notches: Float, fine: Bool = false) -> Float {
        if step > 0 {
            let amount = notches * step * (fine ? 0.1 : 1)
            return min(max(value + amount, range.lowerBound), range.upperBound)
        }
        let moved = position(of: value) + notches * (fine ? 0.001 : 0.01)
        return taper.value(at: min(max(moved, 0), 1), in: range)
    }
}

/// Turns a drag into a position. The control moves with the pointer from wherever it was
/// grabbed, never jumping to it, and moves a tenth as far while the fine modifier is held.
/// Switching fine on or off mid-drag carries on from the current position.
public struct DragTracker: Equatable, Sendable {
    /// How much slower the control moves in fine mode.
    public var fineScale: Float
    private var anchorPosition: Float = 0
    private var anchorOffset: CGFloat = 0
    private var wasFine = false
    public private(set) var position: Float = 0

    public init(fineScale: Float = 0.1) { self.fineScale = fineScale }

    /// Call when the drag starts, with the control's position from 0 to 1.
    public mutating func begin(at position: Float) {
        anchorPosition = position
        anchorOffset = 0
        wasFine = false
        self.position = position
    }

    /// Call as the pointer moves.
    /// - Parameters:
    ///   - offset: how far the pointer is from where the drag began, positive towards the
    ///     control's high end.
    ///   - travel: the length of the control's travel in the same units.
    /// - Returns: the new position from 0 to 1.
    public mutating func update(offset: CGFloat, travel: CGFloat, fine: Bool) -> Float {
        if fine != wasFine {
            anchorPosition = position
            anchorOffset = offset
            wasFine = fine
        }
        let moved = Float((offset - anchorOffset) / max(travel, 1)) * (fine ? fineScale : 1)
        position = min(max(anchorPosition + moved, 0), 1)
        return position
    }
}

/// A stretch of a fader's travel that means something, such as "boost" above unity.
public struct FaderZone: Identifiable, Equatable, Sendable {
    public var name: String
    public var range: ClosedRange<Float>
    public var tint: ControlStyle.Tint

    public var id: String { "\(name) \(range.lowerBound) \(range.upperBound)" }

    public init(_ name: String, _ range: ClosedRange<Float>, tint: ControlStyle.Tint = .accent) {
        self.name = name
        self.range = range
        self.tint = tint
    }

    /// The zone a value falls in. A value on the boundary between two zones belongs to the
    /// lower one, so a fader resting at unity is not yet in the zone above it.
    public static func zone(at value: Float, in zones: [FaderZone]) -> FaderZone? {
        zones.first { value > $0.range.lowerBound && value <= $0.range.upperBound }
            ?? zones.first { $0.range.contains(value) }
    }
}

/// Where decibel values sit along a meter or a fader scale.
public struct MeterScale: Equatable, Sendable {
    public var range: ClosedRange<Float>
    /// The levels that get a mark.
    public var marks: [Float]

    public init(range: ClosedRange<Float> = -60...6, marks: [Float] = [0, -6, -12, -24, -36, -48]) {
        self.range = range
        self.marks = marks.filter { range.contains($0) }
    }

    /// Position from 0 at the bottom of the range to 1 at the top.
    public func position(of decibels: Float) -> Float {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((decibels - range.lowerBound) / span, 0), 1)
    }

    public func label(for mark: Float) -> String {
        mark == 0 ? "0" : String(format: "%.0f", abs(mark))
    }
}

/// How a level meter moves: it jumps up to a new peak at once, falls back at a steady rate,
/// remembers the highest recent peak for a moment, and latches a clip light until cleared.
public struct MeterBallistics: Equatable, Sendable {
    /// How fast the bar falls, in decibels per second.
    public var fallRate: Float
    /// How long the peak-hold line stays before it falls.
    public var holdSeconds: Double
    /// The level at or above which the clip light comes on.
    public var clipLevel: Float

    /// The bar, in decibels.
    public private(set) var level: Float = -200
    /// The peak-hold line, in decibels.
    public private(set) var held: Float = -200
    public private(set) var isClipped = false
    private var heldFor: Double = 0

    public init(fallRate: Float = 24, holdSeconds: Double = 1.5, clipLevel: Float = 0) {
        self.fallRate = fallRate
        self.holdSeconds = holdSeconds
        self.clipLevel = clipLevel
    }

    /// Feeds the newest reading.
    /// - Parameters:
    ///   - decibels: the peak level since the last update.
    ///   - elapsed: seconds since the last update.
    public mutating func update(_ decibels: Float, elapsed: Double) {
        let fallen = level - fallRate * Float(max(elapsed, 0))
        level = max(decibels, fallen, -200)
        if decibels >= held {
            held = decibels
            heldFor = 0
        } else {
            heldFor += max(elapsed, 0)
            if heldFor > holdSeconds { held = max(level, held - fallRate * Float(max(elapsed, 0))) }
        }
        if decibels >= clipLevel { isClipped = true }
    }

    public mutating func clearClip() { isClipped = false }

    public mutating func reset() {
        level = -200
        held = -200
        heldFor = 0
        isClipped = false
    }
}

/// What one channel of a level meter shows.
public struct MeterReading: Equatable, Sendable {
    /// Peak level in decibels.
    public var peak: Float
    /// Average level in decibels, or nil to draw peak only.
    public var rms: Float?
    /// Peak-hold line in decibels, or nil for none.
    public var held: Float?
    public var isClipped: Bool

    public init(peak: Float, rms: Float? = nil, held: Float? = nil, isClipped: Bool = false) {
        self.peak = peak
        self.rms = rms
        self.held = held
        self.isClipped = isClipped
    }

    public init(_ ballistics: MeterBallistics, rms: Float? = nil) {
        self.init(peak: ballistics.level, rms: rms, held: ballistics.held, isClipped: ballistics.isClipped)
    }
}

/// Where a knob's pointer sits. Angles are in degrees clockwise from straight up.
public struct KnobGeometry: Equatable, Sendable {
    public var startAngle: Double
    public var sweep: Double

    public init(startAngle: Double = -135, sweep: Double = 270) {
        self.startAngle = startAngle
        self.sweep = sweep
    }

    public func angle(at position: Float) -> Double {
        startAngle + sweep * Double(min(max(position, 0), 1))
    }

    /// The point at an angle on a circle, in a coordinate space where y grows downwards.
    public func point(angle: Double, radius: CGFloat, centre: CGPoint) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(x: centre.x + radius * CGFloat(sin(radians)), y: centre.y - radius * CGFloat(cos(radians)))
    }
}

/// Where the bars of a spectrum go.
public struct SpectrumLayout: Equatable, Sendable {
    public var frequencies: ClosedRange<Double>
    public var levels: ClosedRange<Float>

    public init(frequencies: ClosedRange<Double> = 20...20_000, levels: ClosedRange<Float> = -90...0) {
        self.frequencies = frequencies
        self.levels = levels
    }

    /// Horizontal position of a frequency from 0 to 1, on a logarithmic axis.
    public func x(of frequency: Double) -> Double {
        let clamped = min(max(frequency, frequencies.lowerBound), frequencies.upperBound)
        return log(clamped / frequencies.lowerBound) / log(frequencies.upperBound / frequencies.lowerBound)
    }

    /// Height of a level from 0 to 1.
    public func height(of decibels: Float) -> Float {
        min(max((decibels - levels.lowerBound) / (levels.upperBound - levels.lowerBound), 0), 1)
    }

    /// One rectangle per level, in a unit square with the origin at the bottom left. With
    /// centre frequencies the bars sit on the logarithmic axis, each reaching halfway to its
    /// neighbours; without, they are spread evenly.
    public func bars(levels values: [Float], centres: [Double]? = nil) -> [CGRect] {
        guard !values.isEmpty else { return [] }
        guard let centres, centres.count == values.count, centres.count > 1 else {
            let width = 1 / Double(values.count)
            return values.enumerated().map { CGRect(x: Double($0.offset) * width, y: 0, width: width, height: Double(height(of: $0.element))) }
        }
        let positions = centres.map(x(of:))
        return values.indices.map { index in
            let left = index == 0 ? max(0, positions[0] - (positions[1] - positions[0]) / 2) : (positions[index - 1] + positions[index]) / 2
            let right = index == values.count - 1 ? min(1, positions[index] + (positions[index] - positions[index - 1]) / 2) : (positions[index] + positions[index + 1]) / 2
            return CGRect(x: left, y: 0, width: max(0, right - left), height: Double(height(of: values[index])))
        }
    }
}

/// Where a waveform view's frames fall across its width.
public struct WaveformLayout: Equatable, Sendable {
    /// The frames on show.
    public var frames: Range<Int>
    public var width: CGFloat

    public init(frames: Range<Int>, width: CGFloat) {
        self.frames = frames
        self.width = width
    }

    public func x(of frame: Int) -> CGFloat {
        guard !frames.isEmpty else { return 0 }
        return CGFloat(frame - frames.lowerBound) / CGFloat(frames.count) * width
    }

    public func frame(at x: CGFloat) -> Int {
        guard width > 0 else { return frames.lowerBound }
        let fraction = min(max(x / width, 0), 1)
        return frames.lowerBound + Int((fraction * CGFloat(frames.count)).rounded())
    }

    /// The horizontal extent of a selection, clipped to the view, or nil when none of it shows.
    public func span(of selection: Range<Int>) -> ClosedRange<CGFloat>? {
        let shown = selection.clamped(to: frames)
        guard !shown.isEmpty else { return nil }
        return x(of: shown.lowerBound)...x(of: shown.upperBound)
    }
}
