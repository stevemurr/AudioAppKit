/// Where playback is and whether it is moving.
@frozen public struct Transport: Hashable, Sendable {
    public var isPlaying: Bool
    public var position: FramePosition
    /// Beats per minute, or zero when the app has no tempo.
    public var tempo: Double

    @inlinable public init(isPlaying: Bool = false, position: FramePosition = 0, tempo: Double = 0) {
        self.isPlaying = isPlaying
        self.position = position
        self.tempo = tempo
    }
}

/// What a processor is told about the block it is asked to render.
@frozen public struct RenderContext: Sendable {
    /// What happens during the block, timed to the frame. Empty unless the host supplies any.
    public var events: EventList
    public var sampleRate: SampleRate
    /// The timeline position of the block's first frame.
    public var position: FramePosition
    public var transport: Transport
    /// True when rendering faster or slower than real time, to a file or a test.
    public var isOffline: Bool

    @inlinable public init(sampleRate: SampleRate, position: FramePosition = 0, transport: Transport = Transport(),
                           isOffline: Bool = false, events: EventList = .empty) {
        self.events = events
        self.sampleRate = sampleRate
        self.position = position
        self.transport = transport
        self.isOffline = isOffline
    }
}
