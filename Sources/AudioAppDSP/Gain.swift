import AudioAppCore
import AudioAppProcessing

/// Changes level. A new level is reached over a short glide, so moving it never clicks.
public struct Gain: Processor, ~Copyable {
    /// The level in decibels.
    public let level: Parameter
    @usableFromInline var gain = Smoothed(1)
    @usableFromInline let glideSeconds: Double

    /// - Parameter level: the parameter to follow, or nil to make one from -60 to +12 dB.
    public init(level: Parameter? = nil, glideSeconds: Double = 0.02) {
        self.level = level ?? Parameter(id: "level", name: "Level", default: 0, in: -60...12, unit: .decibels)
        self.glideSeconds = glideSeconds
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        gain.configure(sampleRate: format.sampleRate, seconds: glideSeconds)
        gain.snap(to: Decibels(level.value).gain)
    }

    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        gain.set(Decibels(level.value).gain)
        guard gain.isRamping else {
            if gain.target != 1 { io.scale(by: gain.target) }
            return
        }
        // Every channel follows the same glide, so step through it once per channel from the
        // same starting point.
        let start = gain
        for channel in 0..<io.channelCount {
            var glide = start
            let samples = io[channel]
            for frame in 0..<io.frameCount { samples[frame] *= glide.next() }
        }
        gain.advance(by: io.frameCount)
    }

    @inlinable public mutating func reset() {
        gain.snap(to: Decibels(level.value).gain)
    }
}
