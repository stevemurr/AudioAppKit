import AudioAppKit
import Foundation
import Synchronization

/// Counts things from any thread.
final class Counter: Sendable {
    private let count = Atomic<Int>(0)
    var value: Int { count.load(ordering: .sequentiallyConsistent) }
    func bump() { count.wrappingAdd(1, ordering: .sequentiallyConsistent) }
}

/// Adds a fixed value to every sample, so routing can be checked with exact arithmetic.
struct Offset: Processor, ~Copyable {
    let value: Float
    mutating func prepare(_ format: Format, maxFrames: Int) {}

    @_noAllocation @_noLocks
    mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        for channel in 0..<io.channelCount {
            let samples = io[channel]
            for frame in 0..<io.frameCount { samples[frame] += value }
        }
    }
}

/// Does nothing to audio and reports when it is destroyed.
struct Tracked: Processor, ~Copyable {
    let destroyed: Counter
    deinit { destroyed.bump() }
    mutating func prepare(_ format: Format, maxFrames: Int) {}

    @_noAllocation @_noLocks
    mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {}
}

/// Reports a latency and really is that late.
struct Late: Processor, ~Copyable {
    let frames: Int
    var delay: LatencyDelay?
    init(frames: Int) { self.frames = frames }
    mutating func prepare(_ format: Format, maxFrames: Int) { delay = LatencyDelay(frames: frames, channelCount: format.channelCount) }

    @_noAllocation @_noLocks
    mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) { delay?.process(io) }
    var latencyFrames: Int { frames }
}

/// Turns its input down by however loud the side-chain is, and leaves it alone without one.
struct Ducker: Processor, ~Copyable {
    mutating func prepare(_ format: Format, maxFrames: Int) {}

    @_noAllocation @_noLocks
    mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {}

    @_noAllocation @_noLocks
    mutating func process(_ io: inout AudioBlock, sidechain: AudioBlock, _ context: borrowing RenderContext) {
        for channel in 0..<io.channelCount {
            let samples = io[channel], key = sidechain[min(channel, sidechain.channelCount - 1)]
            for frame in 0..<io.frameCount { samples[frame] *= 1 - abs(key[frame]) }
        }
    }
}

/// Outputs a level that changes at the exact frame of each custom event.
struct Stepper: Processor, ~Copyable {
    var level: Float = 0
    mutating func prepare(_ format: Format, maxFrames: Int) {}

    @_noAllocation @_noLocks
    mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        var next = 0
        for frame in 0..<io.frameCount {
            while next < context.events.count, context.events[next].offset <= frame {
                if case .custom(_, let value) = context.events[next].kind { level = value }
                next += 1
            }
            for channel in 0..<io.channelCount { io[channel][frame] = level }
        }
    }
}

/// The closed set of processors these tests put in a graph: what an app would declare.
enum TestNode: Processor, ~Copyable {
    case gain(Gain)
    case filter(Biquad)
    case offset(Offset)
    case tracked(Tracked)
    case late(Late)
    case ducker(Ducker)
    case stepper(Stepper)

    mutating func prepare(_ format: Format, maxFrames: Int) {
        switch consume self {
        case .gain(var node): node.prepare(format, maxFrames: maxFrames); self = .gain(node)
        case .filter(var node): node.prepare(format, maxFrames: maxFrames); self = .filter(node)
        case .offset(var node): node.prepare(format, maxFrames: maxFrames); self = .offset(node)
        case .tracked(var node): node.prepare(format, maxFrames: maxFrames); self = .tracked(node)
        case .late(var node): node.prepare(format, maxFrames: maxFrames); self = .late(node)
        case .ducker(var node): node.prepare(format, maxFrames: maxFrames); self = .ducker(node)
        case .stepper(var node): node.prepare(format, maxFrames: maxFrames); self = .stepper(node)
        }
    }

    @_noAllocation @_noLocks
    mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        switch consume self {
        case .gain(var node): node.process(&io, context); self = .gain(node)
        case .filter(var node): node.process(&io, context); self = .filter(node)
        case .offset(var node): node.process(&io, context); self = .offset(node)
        case .tracked(var node): node.process(&io, context); self = .tracked(node)
        case .late(var node): node.process(&io, context); self = .late(node)
        case .ducker(var node): node.process(&io, context); self = .ducker(node)
        case .stepper(var node): node.process(&io, context); self = .stepper(node)
        }
    }

    @_noAllocation @_noLocks
    mutating func process(_ io: inout AudioBlock, sidechain: AudioBlock, _ context: borrowing RenderContext) {
        switch consume self {
        case .gain(var node): node.process(&io, sidechain: sidechain, context); self = .gain(node)
        case .filter(var node): node.process(&io, sidechain: sidechain, context); self = .filter(node)
        case .offset(var node): node.process(&io, sidechain: sidechain, context); self = .offset(node)
        case .tracked(var node): node.process(&io, sidechain: sidechain, context); self = .tracked(node)
        case .late(var node): node.process(&io, sidechain: sidechain, context); self = .late(node)
        case .ducker(var node): node.process(&io, sidechain: sidechain, context); self = .ducker(node)
        case .stepper(var node): node.process(&io, sidechain: sidechain, context); self = .stepper(node)
        }
    }

    var latencyFrames: Int {
        switch self {
        case .gain(let node): node.latencyFrames
        case .filter(let node): node.latencyFrames
        case .offset(let node): node.latencyFrames
        case .tracked(let node): node.latencyFrames
        case .late(let node): node.latencyFrames
        case .ducker(let node): node.latencyFrames
        case .stepper(let node): node.latencyFrames
        }
    }
}

/// The audio callback an app would write: it names the node type, so the compiler checks the
/// whole path through the graph and into every processor. If anything on that path could
/// allocate or lock, this file does not compile.
@_noAllocation @_noLocks
func checkedRender(_ renderer: borrowing GraphRenderer<TestNode>, _ output: AudioBlock, _ context: RenderContext) {
    renderer.render(input: nil, output: output, context: context)
}

@_noAllocation @_noLocks
func checkedRender(_ renderer: borrowing GraphRenderer<TestNode>, input: AudioBlock, _ output: AudioBlock, _ context: RenderContext) {
    renderer.render(input: input, output: output, context: context)
}

// Checked calls through the library's generic wrappers. In a debug build each file is compiled
// alone, and the compiler can only see through a wrapper to a processor whose conformance is
// in the file being compiled. `Late` is declared above, so these live here.
@_noAllocation @_noLocks
func checked(_ processor: inout DryWet<Chain<Late, Gain>>, _ io: inout AudioBlock, _ context: RenderContext) {
    processor.process(&io, context)
}

@_noAllocation @_noLocks
func checked(_ processor: inout Bypassable<Biquad>, _ io: inout AudioBlock, _ context: RenderContext) {
    processor.process(&io, context)
}

@_noAllocation @_noLocks
func checked(_ processor: inout MidSide<Gain>, _ io: inout AudioBlock, _ context: RenderContext) {
    processor.process(&io, context)
}

@_noAllocation @_noLocks
func checked(_ processor: inout PerChannel<Biquad>, _ io: inout AudioBlock, _ context: RenderContext) {
    processor.process(&io, context)
}

let stereo48 = Format(sampleRate: 48_000, layout: .stereo)
let offline48 = RenderContext(sampleRate: 48_000, isOffline: true)

func close(_ a: Float, _ b: Float, within tolerance: Float = 1e-5) -> Bool { abs(a - b) <= tolerance }
func close(_ a: Double, _ b: Double, within tolerance: Double) -> Bool { abs(a - b) <= tolerance }
