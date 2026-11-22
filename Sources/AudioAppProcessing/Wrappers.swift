import AudioAppCore

/// Audio memory a processor reserves in `prepare` to work in.
public struct ScratchBuffer: ~Copyable {
    public let channelCount: Int
    public let frameCapacity: Int
    @usableFromInline let samples: UnsafeMutablePointer<Float>
    @usableFromInline let channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    public init(channelCount: Int, frameCapacity: Int) {
        self.channelCount = max(1, channelCount)
        self.frameCapacity = max(1, frameCapacity)
        samples = .allocate(capacity: self.channelCount * self.frameCapacity)
        samples.initialize(repeating: 0, count: self.channelCount * self.frameCapacity)
        channels = .allocate(capacity: self.channelCount)
        for channel in 0..<self.channelCount { (channels + channel).initialize(to: samples + channel * self.frameCapacity) }
    }

    deinit {
        samples.deallocate()
        channels.deallocate()
    }

    /// A view of the first `frames` frames.
    @inlinable public func block(frames: Int) -> AudioBlock {
        AudioBlock(channels: UnsafePointer(channels), channelCount: channelCount, frameCount: min(frames, frameCapacity))
    }
}

/// Holds audio back by a whole number of frames, to line it up with something slower.
public struct LatencyDelay: ~Copyable {
    public let frames: Int
    public let channelCount: Int
    @usableFromInline let ring: UnsafeMutablePointer<Float>
    @usableFromInline var position = 0

    public init(frames: Int, channelCount: Int) {
        self.frames = max(0, frames)
        self.channelCount = max(1, channelCount)
        ring = .allocate(capacity: max(1, self.frames * self.channelCount))
        ring.initialize(repeating: 0, count: max(1, self.frames * self.channelCount))
    }

    deinit { ring.deallocate() }

    /// Delays a block in place.
    @_noAllocation @_noLocks
    @inlinable public mutating func process(_ io: AudioBlock) {
        guard frames > 0 else { return }
        let start = position
        for channel in 0..<min(io.channelCount, channelCount) {
            let lane = ring + channel * frames
            let samples = io[channel]
            position = start
            for frame in 0..<io.frameCount {
                let held = lane[position]
                lane[position] = samples[frame]
                samples[frame] = held
                position += 1
                if position == frames { position = 0 }
            }
        }
    }

    @inlinable public mutating func reset() {
        ring.initialize(repeating: 0, count: max(1, frames * channelCount))
        position = 0
    }
}

/// Blends a processor's output with its untouched input. The dry signal is held back by the
/// processor's latency, so the two stay in step at any blend.
public struct DryWet<Wrapped: Processor & ~Copyable>: Processor, ~Copyable {
    public var wrapped: Wrapped
    /// 0 is all dry, 1 is all processed.
    public let mix: Parameter
    @usableFromInline var blend = Smoothed(1)
    @usableFromInline var dry: ScratchBuffer?
    @usableFromInline var delay: LatencyDelay?
    @usableFromInline let glideSeconds: Double

    public init(_ wrapped: consuming Wrapped, mix: Parameter? = nil, glideSeconds: Double = 0.02) {
        self.wrapped = wrapped
        self.mix = mix ?? Parameter(id: "mix", name: "Mix", default: 1, in: 0...1, unit: .percent)
        self.glideSeconds = glideSeconds
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        wrapped.prepare(format, maxFrames: maxFrames)
        dry = ScratchBuffer(channelCount: format.channelCount, frameCapacity: maxFrames)
        delay = LatencyDelay(frames: wrapped.latencyFrames, channelCount: format.channelCount)
        blend.configure(sampleRate: format.sampleRate, seconds: glideSeconds)
        blend.snap(to: mix.value)
    }

    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        run(&io, sidechain: nil, context)
    }

    @inlinable public mutating func process(_ io: inout AudioBlock, sidechain: AudioBlock, _ context: borrowing RenderContext) {
        run(&io, sidechain: sidechain, context)
    }

    @inlinable mutating func run(_ io: inout AudioBlock, sidechain: AudioBlock?, _ context: borrowing RenderContext) {
        guard dry != nil else { return }
        let held = dry!.block(frames: io.frameCount)
        held.copy(from: io)
        delay!.process(held)
        if let sidechain {
            wrapped.process(&io, sidechain: sidechain, context)
        } else {
            wrapped.process(&io, context)
        }
        blend.set(mix.value)
        let start = blend
        for channel in 0..<min(io.channelCount, held.channelCount) {
            var glide = start
            let wet = io[channel], kept = held[channel]
            for frame in 0..<min(io.frameCount, held.frameCount) {
                let amount = glide.next()
                wet[frame] = kept[frame] + (wet[frame] - kept[frame]) * amount
            }
        }
        blend.advance(by: io.frameCount)
    }

    public mutating func reset() {
        wrapped.reset()
        delay?.reset()
        blend.snap(to: mix.value)
    }

    @inlinable public var latencyFrames: Int { wrapped.latencyFrames }
}

/// Switches a processor in and out without a click and without a jump in timing: the bypassed
/// signal is held back by the processor's latency and the change is a short crossfade. The
/// processor keeps running while bypassed, so it comes back mid-flow.
public struct Bypassable<Wrapped: Processor & ~Copyable>: Processor, ~Copyable {
    @usableFromInline var inner: DryWet<Wrapped>
    /// Above one half means bypassed.
    public let bypassed: Parameter

    public init(_ wrapped: consuming Wrapped, bypassed: Parameter? = nil, fadeSeconds: Double = 0.01) {
        inner = DryWet(wrapped, glideSeconds: fadeSeconds)
        self.bypassed = bypassed ?? Parameter(id: "bypassed", name: "Bypass", default: 0, in: 0...1)
    }

    public var isBypassed: Bool {
        get { bypassed.value >= 0.5 }
        nonmutating set { bypassed.value = newValue ? 1 : 0 }
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        inner.mix.value = bypassed.value >= 0.5 ? 0 : 1
        inner.prepare(format, maxFrames: maxFrames)
    }

    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        inner.mix.value = bypassed.value >= 0.5 ? 0 : 1
        inner.run(&io, sidechain: nil, context)
    }

    @inlinable public mutating func process(_ io: inout AudioBlock, sidechain: AudioBlock, _ context: borrowing RenderContext) {
        inner.mix.value = bypassed.value >= 0.5 ? 0 : 1
        inner.run(&io, sidechain: sidechain, context)
    }

    public mutating func reset() {
        inner.mix.value = bypassed.value >= 0.5 ? 0 : 1
        inner.reset()
    }

    @inlinable public var latencyFrames: Int { inner.latencyFrames }
}

/// Runs a processor on the middle and the sides of a stereo signal instead of its left and
/// right: channel 0 becomes what both sides share, channel 1 what differs. Signals that are
/// not stereo pass straight to the processor.
public struct MidSide<Wrapped: Processor & ~Copyable>: Processor, ~Copyable {
    public var wrapped: Wrapped

    public init(_ wrapped: consuming Wrapped) { self.wrapped = wrapped }

    public mutating func prepare(_ format: Format, maxFrames: Int) { wrapped.prepare(format, maxFrames: maxFrames) }

    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        guard io.channelCount == 2 else { return wrapped.process(&io, context) }
        Self.encode(io)
        wrapped.process(&io, context)
        Self.decode(io)
    }

    @inlinable public mutating func process(_ io: inout AudioBlock, sidechain: AudioBlock, _ context: borrowing RenderContext) {
        guard io.channelCount == 2 else { return wrapped.process(&io, sidechain: sidechain, context) }
        Self.encode(io)
        wrapped.process(&io, sidechain: sidechain, context)
        Self.decode(io)
    }

    @inlinable static func encode(_ io: AudioBlock) {
        let left = io[0], right = io[1]
        for frame in 0..<io.frameCount {
            let l = left[frame], r = right[frame]
            left[frame] = (l + r) * 0.5
            right[frame] = (l - r) * 0.5
        }
    }

    @inlinable static func decode(_ io: AudioBlock) {
        let mid = io[0], side = io[1]
        for frame in 0..<io.frameCount {
            let m = mid[frame], s = side[frame]
            mid[frame] = m + s
            side[frame] = m - s
        }
    }

    public mutating func reset() { wrapped.reset() }
    @inlinable public var latencyFrames: Int { wrapped.latencyFrames }
}

/// Runs a separate copy of a processor on each channel, each seeing one channel alone. Use it
/// to make a multichannel processor out of one written for mono, or to keep channels from
/// influencing each other.
public struct PerChannel<Wrapped: Processor & ~Copyable>: Processor, ~Copyable {
    @usableFromInline var units: UnsafeMutablePointer<Wrapped>?
    @usableFromInline var count = 0
    let make: (Int) -> Wrapped

    /// - Parameter make: builds the processor for a channel, given the channel's index.
    public init(_ make: @escaping (Int) -> Wrapped) { self.make = make }

    deinit {
        units?.deinitialize(count: count)
        units?.deallocate()
    }

    mutating func release() {
        units?.deinitialize(count: count)
        units?.deallocate()
        units = nil
        count = 0
    }

    public mutating func prepare(_ format: Format, maxFrames: Int) {
        if count != format.channelCount {
            release()
            count = format.channelCount
            let fresh = UnsafeMutablePointer<Wrapped>.allocate(capacity: count)
            for channel in 0..<count { (fresh + channel).initialize(to: make(channel)) }
            units = fresh
        }
        let mono = Format(sampleRate: format.sampleRate, layout: .mono)
        for channel in 0..<count { units![channel].prepare(mono, maxFrames: maxFrames) }
    }

    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        guard let units else { return }
        for channel in 0..<min(count, io.channelCount) {
            var one = io.channel(channel)
            units[channel].process(&one, context)
        }
    }

    @inlinable public mutating func process(_ io: inout AudioBlock, sidechain: AudioBlock, _ context: borrowing RenderContext) {
        guard let units else { return }
        for channel in 0..<min(count, io.channelCount) {
            var one = io.channel(channel)
            units[channel].process(&one, sidechain: sidechain.channel(min(channel, sidechain.channelCount - 1)), context)
        }
    }

    public mutating func reset() {
        for channel in 0..<count { units![channel].reset() }
    }

    /// The channels' processors are taken to share one latency.
    public var latencyFrames: Int { count > 0 ? units![0].latencyFrames : 0 }
}
