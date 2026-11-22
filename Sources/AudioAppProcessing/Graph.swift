import AudioAppCore
import AudioAppRealtime

/// Names a node in a graph.
@frozen public struct NodeID: Hashable, Sendable {
    public let raw: Int
    @inlinable init(_ raw: Int) { self.raw = raw }
}

/// One end of a connection: the graph's own input or output, or a node.
@frozen public enum Endpoint: Hashable, Sendable {
    case input
    case node(NodeID)
    case output
}

public enum GraphError: Error, Equatable {
    /// The connections form a loop, so there is no order to run the nodes in.
    case cycle
    /// A connection names a node that is not in the graph.
    case unknownNode(NodeID)
    /// Nothing can be sent into the graph's input or taken from its output.
    case invalidConnection
}

/// A signal path that is built and rewired while the app runs.
///
/// `Node` is the app's own closed set of processors, normally an enum with one case per kind.
/// Because the set is known when the app is built, the compiler can check the whole audio
/// path, through the graph and into every processor.
///
/// Every node has one input and one output with the graph's channel layout. A node's input
/// is the sum of everything connected to it, each through its own gain, so a connection is
/// also a send.
///
/// Edit from one control thread, then `commit`. The audio thread picks the new routing up at
/// its next block and never sees a half-made change. Removed nodes are destroyed on the
/// control thread, never the audio thread.
public final class Graph<Node: Processor & ~Copyable> {
    public let format: Format
    public let maxFrames: Int
    /// The handle the audio thread renders through.
    public let renderer: GraphRenderer<Node>

    private var slots: [NodeID: NodeSlot<Node>] = [:]
    private var order: [NodeID] = []
    private var connections: [Connection] = []
    private var nextID = 0

    private struct Connection: Equatable {
        var from: Endpoint
        var to: Endpoint
        var gain: Float
    }

    /// - Parameter maxFrames: the longest block any node will be handed. The renderer accepts
    ///   longer blocks and renders them in pieces.
    public init(format: Format, maxFrames: Int) {
        self.format = format
        self.maxFrames = max(1, maxFrames)
        let empty = ScheduleStorage<Node>(slots: [], steps: [], sources: [], outputs: 0..<0,
                                          channelCount: format.channelCount, maxFrames: self.maxFrames)
        renderer = GraphRenderer(Swapped(Schedule(empty)))
    }

    /// Adds a node, preparing it for the graph's format. It makes no sound until connected
    /// and committed.
    @discardableResult public func add(_ node: consuming Node) -> NodeID {
        node.prepare(format, maxFrames: maxFrames)
        let id = NodeID(nextID)
        nextID += 1
        slots[id] = NodeSlot(node)
        order.append(id)
        return id
    }

    /// Removes a node and every connection to or from it.
    public func remove(_ id: NodeID) {
        slots[id] = nil
        order.removeAll { $0 == id }
        connections.removeAll { $0.from == .node(id) || $0.to == .node(id) }
    }

    /// Connects one endpoint to another, or changes the gain of a connection already made.
    public func connect(_ from: Endpoint, to: Endpoint, gain: Float = 1) throws {
        guard from != .output, to != .input else { throw GraphError.invalidConnection }
        for case .node(let id) in [from, to] where slots[id] == nil { throw GraphError.unknownNode(id) }
        if case .node(let a) = from, case .node(let b) = to, a == b { throw GraphError.cycle }
        if let index = connections.firstIndex(where: { $0.from == from && $0.to == to }) {
            connections[index].gain = gain
        } else {
            connections.append(Connection(from: from, to: to, gain: gain))
        }
    }

    public func disconnect(_ from: Endpoint, to: Endpoint) {
        connections.removeAll { $0.from == from && $0.to == to }
    }

    public var nodeIDs: [NodeID] { order }

    /// Works out the order to run the nodes in and hands the new routing to the audio thread.
    /// Throws, changing nothing, if the connections form a loop.
    public func commit() throws {
        // Order the nodes so each runs after everything that feeds it.
        var waiting = Dictionary(uniqueKeysWithValues: order.map { ($0, 0) })
        for connection in connections {
            if case .node = connection.from, case .node(let to) = connection.to { waiting[to, default: 0] += 1 }
        }
        var ready = order.filter { waiting[$0] == 0 }
        var sorted: [NodeID] = []
        while let id = ready.first {
            ready.removeFirst()
            sorted.append(id)
            for connection in connections where connection.from == .node(id) {
                guard case .node(let to) = connection.to else { continue }
                waiting[to]! -= 1
                if waiting[to] == 0 { ready.append(to) }
            }
        }
        guard sorted.count == order.count else { throw GraphError.cycle }

        let bufferOf = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element, $0.offset) })
        func sources(into endpoint: Endpoint) -> [ScheduleSource] {
            connections.filter { $0.to == endpoint }.compactMap { connection in
                switch connection.from {
                case .input: return ScheduleSource(buffer: -1, gain: connection.gain)
                case .node(let id): return ScheduleSource(buffer: bufferOf[id]!, gain: connection.gain)
                case .output: return nil
                }
            }
        }
        var steps: [ScheduleStep<Node>] = []
        var flat: [ScheduleSource] = []
        for id in sorted {
            let feeding = sources(into: .node(id))
            steps.append(ScheduleStep(node: slots[id]!.pointer, firstSource: flat.count, sourceCount: feeding.count))
            flat += feeding
        }
        let toOutput = sources(into: .output)
        let outputs = flat.count..<(flat.count + toOutput.count)
        flat += toOutput

        let storage = ScheduleStorage(slots: sorted.map { slots[$0]! }, steps: steps, sources: flat, outputs: outputs,
                                      channelCount: format.channelCount, maxFrames: maxFrames)
        renderer.swapped.publish(Schedule(storage))
    }

    /// Destroys nodes and routings the audio thread has finished with. `commit` does this
    /// too; call it yourself after the last commit if removed nodes should not linger.
    public func collect() {
        renderer.swapped.collect()
    }
}

/// Renders a graph. Hand this to the audio thread; it is a small value that is safe to copy
/// across threads. Only one thread may render at a time.
public struct GraphRenderer<Node: Processor & ~Copyable>: @unchecked Sendable {
    /// Keeps the routing alive for as long as any copy of the renderer exists.
    let swapped: Swapped<Schedule<Node>>
    /// The audio thread's way in: pointers only, so nothing is reference counted.
    @usableFromInline let reader: SwappedReader<Schedule<Node>>

    init(_ swapped: Swapped<Schedule<Node>>) {
        self.swapped = swapped
        reader = swapped.reader
    }

    /// Renders one block into `output`, replacing what was there.
    ///
    /// To have the compiler check the whole audio path, call this from a function of your
    /// own that names your node type and carries `@_noAllocation @_noLocks`.
    /// - Parameter input: the audio fed to nodes connected to the graph's input, if any.
    @inlinable public func render(input: AudioBlock?, output: AudioBlock, context: RenderContext) {
        let schedule = reader.current()
        let limit = schedule.pointee.maxFrames
        var context = context
        var done = 0
        while done < output.frameCount {
            let frames = min(limit, output.frameCount - done)
            Self.render(schedule, input: input?.slice(from: done, count: frames),
                        output: output.slice(from: done, count: frames), context: context)
            context.position += frames
            done += frames
        }
    }

    @inlinable static func render(_ schedule: UnsafeMutablePointer<Schedule<Node>>, input: AudioBlock?,
                                  output: AudioBlock, context: RenderContext) {
        let channelCount = schedule.pointee.channelCount
        let buffers = schedule.pointee.buffers
        let sources = schedule.pointee.sources
        let steps = schedule.pointee.steps
        let frames = output.frameCount

        for index in 0..<schedule.pointee.stepCount {
            var block = AudioBlock(channels: UnsafePointer(buffers + index * channelCount),
                                   channelCount: channelCount, frameCount: frames)
            block.clear()
            let first = steps[index].firstSource
            for offset in 0..<steps[index].sourceCount {
                let source = sources[first + offset]
                if source.buffer >= 0 {
                    block.add(AudioBlock(channels: UnsafePointer(buffers + source.buffer * channelCount),
                                         channelCount: channelCount, frameCount: frames), gain: source.gain)
                } else if let input {
                    block.add(input, gain: source.gain)
                }
            }
            steps[index].node.pointee.process(&block, context)
        }

        output.clear()
        for index in schedule.pointee.outputs {
            let source = sources[index]
            if source.buffer >= 0 {
                output.add(AudioBlock(channels: UnsafePointer(buffers + source.buffer * channelCount),
                                      channelCount: channelCount, frameCount: frames), gain: source.gain)
            } else if let input {
                output.add(input, gain: source.gain)
            }
        }
    }
}

// MARK: - What the audio thread reads

/// One node's home in memory. It never moves, so routings can point straight at it, and the
/// node is destroyed when the last routing that used it is collected.
final class NodeSlot<Node: Processor & ~Copyable> {
    let pointer: UnsafeMutablePointer<Node>

    init(_ node: consuming Node) {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: node)
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
}

@usableFromInline struct ScheduleSource {
    /// A node's buffer, or -1 for the graph's input.
    @usableFromInline var buffer: Int
    @usableFromInline var gain: Float
}

@usableFromInline struct ScheduleStep<Node: Processor & ~Copyable> {
    @usableFromInline var node: UnsafeMutablePointer<Node>
    @usableFromInline var firstSource: Int
    @usableFromInline var sourceCount: Int
}

/// Owns the memory of one routing and keeps its nodes alive.
final class ScheduleStorage<Node: Processor & ~Copyable> {
    let slots: [NodeSlot<Node>]
    let steps: UnsafeMutablePointer<ScheduleStep<Node>>
    let stepCount: Int
    let sources: UnsafeMutablePointer<ScheduleSource>
    let outputs: Range<Int>
    /// One channel pointer per node per channel, each to `maxFrames` samples.
    let buffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    let samples: UnsafeMutablePointer<Float>
    let channelCount: Int
    let maxFrames: Int

    init(slots: [NodeSlot<Node>], steps: [ScheduleStep<Node>], sources: [ScheduleSource], outputs: Range<Int>,
         channelCount: Int, maxFrames: Int) {
        self.slots = slots
        self.outputs = outputs
        self.channelCount = channelCount
        self.maxFrames = maxFrames
        stepCount = steps.count
        self.steps = .allocate(capacity: max(1, steps.count))
        for (index, step) in steps.enumerated() { (self.steps + index).initialize(to: step) }
        self.sources = .allocate(capacity: max(1, sources.count))
        for (index, source) in sources.enumerated() { (self.sources + index).initialize(to: source) }
        let lanes = max(1, steps.count * channelCount)
        samples = .allocate(capacity: lanes * maxFrames)
        samples.initialize(repeating: 0, count: lanes * maxFrames)
        buffers = .allocate(capacity: lanes)
        for lane in 0..<lanes { (buffers + lane).initialize(to: samples + lane * maxFrames) }
    }

    deinit {
        steps.deallocate()
        sources.deallocate()
        buffers.deallocate()
        samples.deallocate()
    }
}

/// A routing as the audio thread sees it: plain pointers and counts, read field by field so
/// nothing is reference counted on the audio thread.
@usableFromInline struct Schedule<Node: Processor & ~Copyable> {
    @usableFromInline let steps: UnsafeMutablePointer<ScheduleStep<Node>>
    @usableFromInline let stepCount: Int
    @usableFromInline let sources: UnsafeMutablePointer<ScheduleSource>
    @usableFromInline let outputs: Range<Int>
    @usableFromInline let buffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    @usableFromInline let channelCount: Int
    @usableFromInline let maxFrames: Int
    let storage: ScheduleStorage<Node>

    init(_ storage: ScheduleStorage<Node>) {
        self.storage = storage
        steps = storage.steps
        stepCount = storage.stepCount
        sources = storage.sources
        outputs = storage.outputs
        buffers = storage.buffers
        channelCount = storage.channelCount
        maxFrames = storage.maxFrames
    }
}
