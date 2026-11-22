import Darwin

/// Plain loops for the memory chores the audio thread needs. The standard library's bulk
/// pointer operations do not pass the compiler's real-time checks; these do.
@usableFromInline enum Memory {
    /// Zeroed storage. Call away from the audio thread.
    @inlinable static func floats(_ count: Int) -> UnsafeMutablePointer<Float> {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, count))
        pointer.initialize(repeating: 0, count: max(1, count))
        return pointer
    }

    /// Zeroed storage. Call away from the audio thread.
    @inlinable static func doubles(_ count: Int) -> UnsafeMutablePointer<Double> {
        let pointer = UnsafeMutablePointer<Double>.allocate(capacity: max(1, count))
        pointer.initialize(repeating: 0, count: max(1, count))
        return pointer
    }

    @_noAllocation @_noLocks
    @inlinable static func zero(_ pointer: UnsafeMutablePointer<Float>, _ count: Int) {
        for index in 0..<count { pointer[index] = 0 }
    }

    @_noAllocation @_noLocks
    @inlinable static func zero(_ pointer: UnsafeMutablePointer<Double>, _ count: Int) {
        for index in 0..<count { pointer[index] = 0 }
    }

    @_noAllocation @_noLocks
    @inlinable static func copy(_ source: UnsafePointer<Float>, to target: UnsafeMutablePointer<Float>, _ count: Int) {
        for index in 0..<count { target[index] = source[index] }
    }

    /// Moves a run of samples toward the start of the same buffer.
    @_noAllocation @_noLocks
    @inlinable static func shiftDown(_ pointer: UnsafeMutablePointer<Float>, by offset: Int, count: Int) {
        for index in 0..<count { pointer[index] = pointer[index + offset] }
    }
}

/// A sinc-based low-pass design shared by the resampler, the oversampler and the true-peak
/// meter. Design happens away from the audio thread.
@usableFromInline enum SincDesign {
    /// A Kaiser window's value at `position` from -1 to 1.
    @usableFromInline static func kaiser(_ position: Double, beta: Double) -> Double {
        let inside = 1 - position * position
        guard inside > 0 else { return position.magnitude <= 1 ? 1 / bessel(beta) : 0 }
        return bessel(beta * inside.squareRoot()) / bessel(beta)
    }

    /// The zeroth-order modified Bessel function of the first kind.
    @usableFromInline static func bessel(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        var k = 1.0
        while term > 1e-12 * sum {
            term *= (x / (2 * k)) * (x / (2 * k))
            sum += term
            k += 1
        }
        return sum
    }

    /// The value at `time` (in samples from the centre) of a low-pass whose cutoff is
    /// `cutoff` cycles per sample and which spans `halfWidth` samples each side.
    @usableFromInline static func lowPass(at time: Double, cutoff: Double, halfWidth: Double, beta: Double) -> Double {
        guard time.magnitude < halfWidth else { return 0 }
        let x = 2 * cutoff * time
        let sinc = x.magnitude < 1e-9 ? 1 : sin(Double.pi * x) / (Double.pi * x)
        return 2 * cutoff * sinc * kaiser(time / halfWidth, beta: beta)
    }
}
