import Darwin
import Synchronization

/// Measures how much of its deadline the audio callback uses.
///
/// The callback has as long as its block of audio lasts. `load` is the share of that time
/// spent rendering; at 1 the callback has run out of time and the output drops out.
///
/// The clock is read by the engine around the render call, not inside it, because the
/// compiler's real-time checks reject clock calls.
public final class LoadMonitor: Sendable {
    private let loadBits = Atomic<UInt32>(Float.nan.bitPattern)
    private let peakBits = Atomic<UInt32>(Float(0).bitPattern)
    private let overrunCount = Atomic<Int>(0)
    private let callbackCount = Atomic<Int>(0)
    private let secondsPerTick: Double

    public init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// Call as the callback starts. Returns a time to pass to `end`.
    public func begin() -> UInt64 { mach_absolute_time() }

    /// Call as the callback finishes.
    public func end(_ began: UInt64, frames: Int, sampleRate: Double) {
        guard frames > 0, sampleRate > 0 else { return }
        record(seconds: Double(mach_absolute_time() &- began) * secondsPerTick, frames: frames, sampleRate: sampleRate)
    }

    /// Records one callback that took a known time.
    public func record(seconds: Double, frames: Int, sampleRate: Double) {
        let load = Float(seconds * sampleRate / Double(frames))
        let previous = Float(bitPattern: loadBits.load(ordering: .relaxed))
        loadBits.store((previous.isFinite ? previous + 0.1 * (load - previous) : load).bitPattern, ordering: .relaxed)
        if load > Float(bitPattern: peakBits.load(ordering: .relaxed)) { peakBits.store(load.bitPattern, ordering: .relaxed) }
        if load >= 1 { overrunCount.wrappingAdd(1, ordering: .relaxed) }
        callbackCount.wrappingAdd(1, ordering: .relaxed)
    }

    /// The recent average share of the deadline used, or nil before the first callback.
    public var load: Float? {
        let value = Float(bitPattern: loadBits.load(ordering: .relaxed))
        return value.isFinite ? value : nil
    }

    /// The largest share any one callback has used.
    public var peakLoad: Float { Float(bitPattern: peakBits.load(ordering: .relaxed)) }

    /// Callbacks that took longer than their block lasts.
    public var overruns: Int { overrunCount.load(ordering: .relaxed) }

    public var callbacks: Int { callbackCount.load(ordering: .relaxed) }

    public func reset() {
        loadBits.store(Float.nan.bitPattern, ordering: .relaxed)
        peakBits.store(Float(0).bitPattern, ordering: .relaxed)
        overrunCount.store(0, ordering: .relaxed)
        callbackCount.store(0, ordering: .relaxed)
    }
}
