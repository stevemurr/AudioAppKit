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

/// Which of a node's inputs a connection feeds.
@frozen public enum NodeInput: Hashable, Sendable {
    /// The audio the node processes.
    case main
    /// A second signal the node listens to: what a compressor ducks to.
    case sidechain
}

public enum GraphError: Error, Equatable {
    /// The connections form a loop, so there is no order to run the nodes in.
    case cycle
    /// A connection names a node that is not in the graph.
    case unknownNode(NodeID)
    /// Nothing can be sent into the graph's input or taken from its output, and only a node
    /// has a side-chain.
    case invalidConnection
}

/// A signal path that is built and rewired while the app runs.
///
/// `Node` is the app's own closed set of processors, normally an enum with one case per kind.
/// Because the set is known when the app is built, the compiler can check the whole audio
/// path, through the graph and into every processor.
///
/// Every node has a main input and an output with the graph's channel layout, and may have a
/// side-chain input. An input is the sum of everything connected to it, each through its own
/// gain, so a connection is also a send.
///
/// When paths of different latency meet, the earlier ones are delayed so they arrive
/// together. `latencyFrames` is how late the graph's output is as a whole.
///
/// Edit from one control thread, then `commit`. The audio thread picks the new routing up at
/// its next block and never sees a half-made change. Removed nodes are destroyed on the
/// control thread, never the audio thread.
public final class Graph<Node: Processor & ~Copyable> {
    public let format: Format
    public let maxFrames: Int
    /// The handle the audio thread renders through.
    public let renderer: GraphRenderer<Node>
    /// How many frames late the output is against the input, as of the last commit.
    public private(set) var latencyFrames = 0

    private var slots: [NodeID: NodeSlot<Node>] = [:]
    private var order: [NodeID] = []
    private var connections: [Connection] = []
    private var nextID = 0

    private struct Connection: Equatable {
        var from: Endpoint
        var to: Endpoint
        var input: NodeInput
        var gain: Float
    }

    /// - Parameter maxFrames: the longest block any node will be handed. The renderer accepts
    ///   longer blocks and renders them in pieces.
    public init(format: Format, maxFrames: Int) {
        self.format = format
        self.maxFrames = max(1, maxFrames)
        let empty = ScheduleStorage<Node>(slots: [], steps: [], sources: [], outputs: 0..<0, laneCount: 0,
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
    public func connect(_ from: Endpoint, to: Endpoint, input: NodeInput = .main, gain: Float = 1) throws {
        guard from != .output, to != .input else { throw GraphError.invalidConnection }
        if input == .sidechain, to == .output { throw GraphError.invalidConnection }
        for case .node(let id) in [from, to] where slots[id] == nil { throw GraphError.unknownNode(id) }
        if case .node(let a) = from, case .node(let b) = to, a == b { throw GraphError.cycle }
        if let index = connections.firstIndex(where: { $0.from == from && $0.to == to && $0.input == input }) {
            connections[index].gain = gain
        } else {
            connections.append(Connection(from: from, to: to, input: input, gain: gain))
        }
    }

    public func disconnect(_ from: Endpoint, to: Endpoint, input: NodeInput = .main) {
        connections.removeAll { $0.from == from && $0.to == to && $0.input == input }
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

        // Each node's main output gets a lane; a node with side-chain connections gets one more.
        var lane = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element, $0.offset) })
        var laneCount = sorted.count
        // How late each node's output is against the graph's input.
        var lateness: [NodeID: Int] = [:]

        func arrivals(into endpoint: Endpoint, _ input: NodeInput) -> [(lane: Int, gain: Float, late: Int)] {
            connections.filter { $0.to == endpoint && $0.input == input }.compactMap { connection in
                switch connection.from {
                case .input: return (-1, connection.gain, 0)
                case .node(let id): return (lane[id]!, connection.gain, lateness[id]!)
                case .output: return nil
                }
            }
        }
        var flat: [ScheduleSource] = []
        // Delays the earlier arrivals so everything reaches an input at the same moment.
        func aligned(_ arrivals: [(lane: Int, gain: Float, late: Int)], to latest: Int) -> Range<Int> {
            let start = flat.count
            flat += arrivals.map { ScheduleSource(lane: $0.lane, gain: $0.gain, delay: latest - $0.late) }
            return start..<flat.count
        }

        var steps: [ScheduleStep<Node>] = []
        for id in sorted {
            let main = arrivals(into: .node(id), .main), side = arrivals(into: .node(id), .sidechain)
            let latest = (main + side).map(\.late).max() ?? 0
            let mainRange = aligned(main, to: latest), sideRange = aligned(side, to: latest)
            var sideLane = -1
            if !side.isEmpty {
                sideLane = laneCount
                laneCount += 1
            }
            steps.append(ScheduleStep(node: slots[id]!.pointer, firstSource: mainRange.lowerBound, sourceCount: mainRange.count,
                                      firstSide: sideRange.lowerBound, sideCount: sideRange.count, sideLane: sideLane))
            lateness[id] = latest + slots[id]!.latencyFrames
        }
        let toOutput = arrivals(into: .output, .main)
        let total = toOutput.map(\.late).max() ?? 0
        let outputs = aligned(toOutput, to: total)
        lane = [:]

        let storage = ScheduleStorage(slots: sorted.map { slots[$0]! }, steps: steps, sources: flat, outputs: outputs,
                                      laneCount: laneCount, channelCount: format.channelCount, maxFrames: maxFrames)
        renderer.swapped.publish(Schedule(storage))
        latencyFrames = total
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
        let events = context.events
        var context = context
        var done = 0
        while done < output.frameCount {
            let frames = min(limit, output.frameCount - done)
            context.events = events.slice(from: done, count: frames)
            Self.render(schedule, input: input?.slice(from: done, count: frames),
                        output: output.slice(from: done, count: frames), context: context)
            context.position += frames
            done += frames
        }
    }

    @inlinable static func render(_ schedule: UnsafeMutablePointer<Schedule<Node>>, input: AudioBlock?,
                                  output: AudioBlock, context: RenderContext) {
        let channelCount = schedule.pointee.channelCount
        let lanes = schedule.pointee.lanes
        let steps = schedule.pointee.steps
        let frames = output.frameCount

        for index in 0..<schedule.pointee.stepCount {
            var block = AudioBlock(channels: UnsafePointer(lanes + index * channelCount),
                                   channelCount: channelCount, frameCount: frames)
            block.clear()
            Self.sum(schedule, from: steps[index].firstSource, count: steps[index].sourceCount, into: block, input: input)
            let sideLane = steps[index].sideLane
            if sideLane >= 0 {
                let side = AudioBlock(channels: UnsafePointer(lanes + sideLane * channelCount),
                                      channelCount: channelCount, frameCount: frames)
                side.clear()
                Self.sum(schedule, from: steps[index].firstSide, count: steps[index].sideCount, into: side, input: input)
                steps[index].node.pointee.process(&block, sidechain: side, context)
            } else {
                steps[index].node.pointee.process(&block, context)
            }
        }

        output.clear()
        Self.sum(schedule, from: schedule.pointee.outputs.lowerBound, count: schedule.pointee.outputs.count,
                 into: output, input: input)
    }

    /// Adds a run of sources into a block, each through its gain and its aligning delay.
    @inlinable static func sum(_ schedule: UnsafeMutablePointer<Schedule<Node>>, from first: Int, count: Int,
                               into block: AudioBlock, input: AudioBlock?) {
        let channelCount = schedule.pointee.channelCount
        let lanes = schedule.pointee.lanes
        let sources = schedule.pointee.sources
        let frames = block.frameCount
        for index in first..<(first + count) {
            let source = sources[index]
            let audio: AudioBlock? = source.lane >= 0
                ? AudioBlock(channels: UnsafePointer(lanes + source.lane * channelCount), channelCount: channelCount, frameCount: frames)
                : input
            guard source.delay > 0 else {
                if let audio { block.add(audio, gain: source.gain) }
                continue
            }
            // A ring exactly as long as the delay: what comes out is what went in that many
            // frames ago. Every channel starts from the same place in its own ring.
            let start = sources[index].position
            var position = start
            for channel in 0..<min(block.channelCount, channelCount) {
                let ring = schedule.pointee.delays + source.ring + channel * source.delay
                let out = block[channel]
                position = start
                if let audio, channel < audio.channelCount || audio.channelCount == 1 {
                    let samples = audio[audio.channelCount == 1 ? 0 : channel]
                    for frame in 0..<frames {
                        out[frame] += ring[position] * source.gain
                        ring[position] = samples[frame]
                        position += 1
                        if position == source.delay { position = 0 }
                    }
                } else {
                    for frame in 0..<frames {
                        out[frame] += ring[position] * source.gain
                        ring[position] = 0
                        position += 1
                        if position == source.delay { position = 0 }
                    }
                }
            }
            sources[index].position = position
        }
    }
}

// MARK: - What the audio thread reads

/// One node's home in memory. It never moves, so routings can point straight at it, and the
/// node is destroyed when the last routing that used it is collected.
final class NodeSlot<Node: Processor & ~Copyable> {
    let pointer: UnsafeMutablePointer<Node>
    /// Read once, after the node is prepared, so the control thread never reads a node the
    /// audio thread may be running.
    let latencyFrames: Int

    init(_ node: consuming Node) {
        latencyFrames = max(0, node.latencyFrames)
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: node)
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
}

@usableFromInline struct ScheduleSource {
    /// A node's lane, or -1 for the graph's input.
    @usableFromInline var lane: Int
    @usableFromInline var gain: Float
    /// Frames to hold this source back so it lines up with later arrivals.
    @usableFromInline var delay: Int
    /// Where this source's delay memory starts, and where in it the next frame goes.
    @usableFromInline var ring = 0
    @usableFromInline var position = 0

    init(lane: Int, gain: Float, delay: Int) {
        self.lane = lane
        self.gain = gain
        self.delay = delay
    }
}

@usableFromInline struct ScheduleStep<Node: Processor & ~Copyable> {
    @usableFromInline var node: UnsafeMutablePointer<Node>
    @usableFromInline var firstSource: Int
    @usableFromInline var sourceCount: Int
    @usableFromInline var firstSide: Int
    @usableFromInline var sideCount: Int
    /// The lane the side-chain is summed into, or -1 when the node has none.
    @usableFromInline var sideLane: Int
}

/// Owns the memory of one routing and keeps its nodes alive.
final class ScheduleStorage<Node: Processor & ~Copyable> {
    let slots: [NodeSlot<Node>]
    let steps: UnsafeMutablePointer<ScheduleStep<Node>>
    let stepCount: Int
    let sources: UnsafeMutablePointer<ScheduleSource>
    let outputs: Range<Int>
    /// One channel pointer per lane per channel, each to `maxFrames` samples.
    let lanes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    let samples: UnsafeMutablePointer<Float>
    let delays: UnsafeMutablePointer<Float>
    let channelCount: Int
    let maxFrames: Int

    init(slots: [NodeSlot<Node>], steps: [ScheduleStep<Node>], sources: [ScheduleSource], outputs: Range<Int>,
         laneCount: Int, channelCount: Int, maxFrames: Int) {
        self.slots = slots
        self.outputs = outputs
        self.channelCount = channelCount
        self.maxFrames = maxFrames
        stepCount = steps.count
        self.steps = .allocate(capacity: max(1, steps.count))
        for (index, step) in steps.enumerated() { (self.steps + index).initialize(to: step) }

        self.sources = .allocate(capacity: max(1, sources.count))
        var delayed = 0
        for (index, source) in sources.enumerated() {
            var source = source
            source.ring = delayed
            delayed += source.delay * channelCount
            (self.sources + index).initialize(to: source)
        }
        delays = .allocate(capacity: max(1, delayed))
        delays.initialize(repeating: 0, count: max(1, delayed))

        let channels = max(1, laneCount * channelCount)
        samples = .allocate(capacity: channels * maxFrames)
        samples.initialize(repeating: 0, count: channels * maxFrames)
        lanes = .allocate(capacity: channels)
        for channel in 0..<channels { (lanes + channel).initialize(to: samples + channel * maxFrames) }
    }

    deinit {
        steps.deallocate()
        sources.deallocate()
        lanes.deallocate()
        samples.deallocate()
        delays.deallocate()
    }
}

/// A routing as the audio thread sees it: plain pointers and counts, read field by field so
/// nothing is reference counted on the audio thread.
@usableFromInline struct Schedule<Node: Processor & ~Copyable> {
    @usableFromInline let steps: UnsafeMutablePointer<ScheduleStep<Node>>
    @usableFromInline let stepCount: Int
    @usableFromInline let sources: UnsafeMutablePointer<ScheduleSource>
    @usableFromInline let outputs: Range<Int>
    @usableFromInline let lanes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    @usableFromInline let delays: UnsafeMutablePointer<Float>
    @usableFromInline let channelCount: Int
    @usableFromInline let maxFrames: Int
    let storage: ScheduleStorage<Node>

    init(_ storage: ScheduleStorage<Node>) {
        self.storage = storage
        steps = storage.steps
        stepCount = storage.stepCount
        sources = storage.sources
        outputs = storage.outputs
        lanes = storage.lanes
        delays = storage.delays
        channelCount = storage.channelCount
        maxFrames = storage.maxFrames
    }
}
