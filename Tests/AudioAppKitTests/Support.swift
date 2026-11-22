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

/// The closed set of processors these tests put in a graph: what an app would declare.
enum TestNode: Processor, ~Copyable {
    case gain(Gain)
    case filter(Biquad)
    case offset(Offset)
    case tracked(Tracked)

    mutating func prepare(_ format: Format, maxFrames: Int) {
        switch consume self {
        case .gain(var node): node.prepare(format, maxFrames: maxFrames); self = .gain(node)
        case .filter(var node): node.prepare(format, maxFrames: maxFrames); self = .filter(node)
        case .offset(var node): node.prepare(format, maxFrames: maxFrames); self = .offset(node)
        case .tracked(var node): node.prepare(format, maxFrames: maxFrames); self = .tracked(node)
        }
    }

    @_noAllocation @_noLocks
    mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        switch consume self {
        case .gain(var node): node.process(&io, context); self = .gain(node)
        case .filter(var node): node.process(&io, context); self = .filter(node)
        case .offset(var node): node.process(&io, context); self = .offset(node)
        case .tracked(var node): node.process(&io, context); self = .tracked(node)
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

let stereo48 = Format(sampleRate: 48_000, layout: .stereo)
let offline48 = RenderContext(sampleRate: 48_000, isOffline: true)

func close(_ a: Float, _ b: Float, within tolerance: Float = 1e-5) -> Bool { abs(a - b) <= tolerance }
func close(_ a: Double, _ b: Double, within tolerance: Double) -> Bool { abs(a - b) <= tolerance }
