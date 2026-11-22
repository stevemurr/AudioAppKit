import CAudioAppSupport

/// Catches heap activity on a thread while a piece of code runs. Wrap what the audio thread
/// would do and check the report: anything other than zero would have risked a dropout.
///
/// This sees allocations and frees, which is how most real-time mistakes show up (a growing
/// array, a boxed value, a released object). It does not see locks; the compiler's
/// `@_noLocks` check covers those.
public enum RealtimeProbe {
    public struct Report: Equatable, Sendable, CustomStringConvertible {
        public var allocations: Int
        public var deallocations: Int

        /// True when the code neither allocated nor freed.
        public var isClean: Bool { allocations == 0 && deallocations == 0 }

        public var description: String {
            isClean ? "no heap activity" : "\(allocations) allocations, \(deallocations) frees"
        }
    }

    /// Runs `body` on the calling thread and reports what it did to the heap. Other threads
    /// are not counted. Probes do not nest.
    ///
    /// Keep `body` to the call under test. In a debug build, ordinary Swift around it can
    /// allocate where a release build would not: a `for` loop over a range does, for one. Use
    /// a `while` loop to repeat the call.
    public static func measure(_ body: () throws -> Void) rethrows -> Report {
        var counts = aak_probe_counts()
        try withUnsafeMutablePointer(to: &counts) { pointer in
            aak_probe_begin(pointer)
            defer { aak_probe_end() }
            try body()
        }
        return Report(allocations: Int(counts.allocations), deallocations: Int(counts.deallocations))
    }
}
