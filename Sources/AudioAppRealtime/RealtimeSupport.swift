import CAudioAppSupport
import Darwin

/// Math the compiler's real-time checks cannot see into.
///
/// `exp`, `log`, `sin` and `cos` compile to instructions the checks understand. These call
/// the system math library, which the checks reject only because its code is out of sight.
/// They are plain arithmetic: no allocation, no locks.
public enum RealtimeMath {
    @inlinable @inline(never) @_semantics("no_performance_analysis")
    public static func sqrt(_ x: Double) -> Double { x.squareRoot() }

    @inlinable @inline(never) @_semantics("no_performance_analysis")
    public static func sqrt(_ x: Float) -> Float { x.squareRoot() }

    @inlinable @inline(never) @_semantics("no_performance_analysis")
    public static func tan(_ x: Double) -> Double { Darwin.tan(x) }

    @inlinable @inline(never) @_semantics("no_performance_analysis")
    public static func pow(_ base: Double, _ exponent: Double) -> Double { Darwin.pow(base, exponent) }

    @inlinable @inline(never) @_semantics("no_performance_analysis")
    public static func log10(_ x: Double) -> Double { Darwin.log10(x) }

    @inlinable @inline(never) @_semantics("no_performance_analysis")
    public static func log10(_ x: Float) -> Float { Darwin.log10f(x) }
}

/// Settings for a thread that renders audio.
public enum RealtimeThread {
    /// Makes the calling thread treat denormal floats as zero. Filter and reverb tails
    /// otherwise decay into values that are many times slower to compute. Call once when the
    /// thread starts.
    public static func flushDenormals(_ flush: Bool = true) {
        aak_set_flush_denormals(flush)
    }
}
