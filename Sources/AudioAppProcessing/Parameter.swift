import AudioAppCore
import Synchronization

/// A value a user or an app controls and a processor reads, such as a level or a frequency.
///
/// Any thread may set it. The audio thread reads it without waiting. A processor keeps a
/// reference to its parameters and the app keeps the same references, so nothing needs to be
/// looked up while audio is running.
public final class Parameter: Sendable {
    public let id: String
    public let name: String
    public let range: ClosedRange<Float>
    public let taper: Taper
    public let unit: Unit
    public let defaultValue: Float
    @usableFromInline let bits: Atomic<UInt32>

    public enum Unit: Hashable, Sendable {
        case generic, decibels, hertz, seconds, percent, ratio
        case custom(String)
    }

    public init(id: String, name: String? = nil, default value: Float, in range: ClosedRange<Float>,
                taper: Taper = .linear, unit: Unit = .generic) {
        self.id = id
        self.name = name ?? id
        self.range = range
        self.taper = taper
        self.unit = unit
        defaultValue = min(max(value, range.lowerBound), range.upperBound)
        bits = Atomic(defaultValue.bitPattern)
    }

    /// The current value. Setting it clamps to the range.
    @inlinable public var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(min(max(newValue, range.lowerBound), range.upperBound).bitPattern, ordering: .relaxed) }
    }

    /// The value as a control position from 0 to 1, through the taper.
    public var position: Float {
        get { taper.position(of: value, in: range) }
        set { value = taper.value(at: newValue, in: range) }
    }

    public func resetToDefault() { value = defaultValue }
}

/// A value that glides to its target over a set time, so a change is never heard as a click.
/// Lives inside a processor and is advanced on the audio thread.
@frozen public struct Smoothed: Sendable {
    @usableFromInline var _current: Float
    @usableFromInline var _target: Float
    @usableFromInline var step: Float = 0
    @usableFromInline var remaining = 0
    @usableFromInline var rampFrames = 1

    @inlinable public init(_ value: Float = 0) {
        _current = value
        _target = value
    }

    /// Where the glide is now.
    @inlinable public var current: Float { _current }
    /// Where the glide is heading.
    @inlinable public var target: Float { _target }

    /// Sets how long a glide takes.
    @inlinable public mutating func configure(sampleRate: SampleRate, seconds: Double) {
        rampFrames = max(1, sampleRate.frames(in: seconds))
    }

    /// Jumps to a value with no glide.
    @inlinable public mutating func snap(to value: Float) {
        _current = value
        _target = value
        remaining = 0
    }

    /// Starts gliding to a new target. Setting the target it already has does nothing.
    @inlinable public mutating func set(_ value: Float) {
        guard value != _target else { return }
        _target = value
        remaining = rampFrames
        step = (value - _current) / Float(rampFrames)
    }

    @inlinable public var isRamping: Bool { remaining > 0 }

    /// The value for the next frame.
    @inlinable public mutating func next() -> Float {
        guard remaining > 0 else { return _target }
        remaining -= 1
        _current = remaining == 0 ? _target : _current + step
        return _current
    }

    /// Moves on by a number of frames at once.
    @inlinable public mutating func advance(by frames: Int) {
        guard remaining > 0 else { return }
        if frames >= remaining {
            _current = _target
            remaining = 0
        } else {
            _current += step * Float(frames)
            remaining -= frames
        }
    }
}
