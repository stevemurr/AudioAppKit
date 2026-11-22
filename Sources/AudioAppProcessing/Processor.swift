import AudioAppCore

/// Something that turns a block of audio into another, in place.
///
/// The rule every processor keeps: `prepare` may do anything; `process` may not allocate,
/// lock or wait, because it runs on the audio thread against a deadline. Reserve every buffer
/// in `prepare`. Mark `process` with `@_noAllocation @_noLocks` and the compiler holds you
/// to the rule.
///
/// Processors are usually structs, and may be non-copyable so they can own memory outright.
public protocol Processor: ~Copyable {
    /// Gets ready to render at a format. Called away from the audio thread, before the first
    /// `process` and again whenever the format changes.
    /// - Parameter maxFrames: the longest block `process` will ever be handed.
    mutating func prepare(_ format: Format, maxFrames: Int)

    /// Renders one block in place, on the audio thread.
    mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext)

    /// Renders one block in place while listening to a second signal, the side-chain: what a
    /// compressor ducks to, what a gate opens for. A graph calls this instead of `process`
    /// for a node that has side-chain connections. The default ignores the side-chain.
    mutating func process(_ io: inout AudioBlock, sidechain: AudioBlock, _ context: borrowing RenderContext)

    /// Forgets everything heard so far: filter state, delay contents, envelopes.
    mutating func reset()

    /// How many frames late the output is against the input.
    var latencyFrames: Int { get }
}

extension Processor where Self: ~Copyable {
    @inlinable public mutating func process(_ io: inout AudioBlock, sidechain: AudioBlock, _ context: borrowing RenderContext) {
        process(&io, context)
    }

    @inlinable public mutating func reset() {}
    @inlinable public var latencyFrames: Int { 0 }
}

/// Two processors run one after the other, as one. The pair is fixed when the app is built,
/// so the compiler sees straight through it.
public struct Chain<First: Processor & ~Copyable, Second: Processor & ~Copyable>: Processor, ~Copyable {
    public var first: First
    public var second: Second

    @inlinable public init(_ first: consuming First, _ second: consuming Second) {
        self.first = first
        self.second = second
    }

    @inlinable public mutating func prepare(_ format: Format, maxFrames: Int) {
        first.prepare(format, maxFrames: maxFrames)
        second.prepare(format, maxFrames: maxFrames)
    }

    @inlinable public mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        first.process(&io, context)
        second.process(&io, context)
    }

    /// Both processors hear the side-chain.
    @inlinable public mutating func process(_ io: inout AudioBlock, sidechain: AudioBlock, _ context: borrowing RenderContext) {
        first.process(&io, sidechain: sidechain, context)
        second.process(&io, sidechain: sidechain, context)
    }

    @inlinable public mutating func reset() {
        first.reset()
        second.reset()
    }

    @inlinable public var latencyFrames: Int { first.latencyFrames + second.latencyFrames }
}
