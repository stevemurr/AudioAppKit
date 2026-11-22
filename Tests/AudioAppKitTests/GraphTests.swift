import AudioAppKit
import AudioAppTesting
import Foundation
import Synchronization
import Testing

@Suite struct GraphTests {
    /// Renders one block through the compiler-checked callback.
    private func render(_ graph: Graph<TestNode>, frames: Int = 64, input: [Float]? = nil) -> SampleBuffer {
        let output = SampleBuffer(channelCount: 2, frameCapacity: frames)
        if let input {
            // A block does not keep its buffer alive, so hold the buffer for the whole call.
            let source = SampleBuffer([input, input])
            withExtendedLifetime(source) {
                checkedRender(graph.renderer, input: source.block, output.block, offline48)
            }
        } else {
            checkedRender(graph.renderer, output.block, offline48)
        }
        return output
    }

    @Test func anEmptyGraphIsSilent() {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 64)
        let output = SampleBuffer([[9, 9], [9, 9]])
        checkedRender(graph.renderer, output.block, offline48)
        #expect(output.samples(channel: 0) == [0, 0])
    }

    @Test func nodesInSeriesRunInOrder() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 64)
        // Added out of order on purpose: the connections decide the order, not the adding.
        let halve = graph.add(.gain(Gain()))
        let one = graph.add(.offset(Offset(value: 1)))
        let three = graph.add(.offset(Offset(value: 3)))
        try graph.connect(.node(one), to: .node(halve), gain: 0.5)
        try graph.connect(.node(halve), to: .node(three))
        try graph.connect(.node(three), to: .output)
        try graph.commit()
        // (0 + 1) * 0.5, unity gain, + 3
        #expect(render(graph).samples(channel: 0).allSatisfy { $0 == 3.5 })
        #expect(render(graph).samples(channel: 1).allSatisfy { $0 == 3.5 })
    }

    @Test func aNodeHearsTheSumOfItsSendsAndTheOutputSumsToo() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 64)
        let a = graph.add(.offset(Offset(value: 1)))
        let b = graph.add(.offset(Offset(value: 10)))
        let bus = graph.add(.offset(Offset(value: 0)))
        try graph.connect(.node(a), to: .node(bus), gain: 2)
        try graph.connect(.node(b), to: .node(bus), gain: 0.5)
        try graph.connect(.node(bus), to: .output)
        try graph.connect(.node(a), to: .output)
        try graph.commit()
        // bus = 1*2 + 10*0.5 = 7; output = bus + a = 8
        #expect(render(graph).samples(channel: 0).allSatisfy { $0 == 8 })

        // Connecting again changes the send level instead of adding a second send.
        try graph.connect(.node(b), to: .node(bus), gain: 1)
        try graph.commit()
        #expect(render(graph).samples(channel: 0).allSatisfy { $0 == 13 })
    }

    @Test func graphInputReachesNodesAndCanPassStraightThrough() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 64)
        let lift = graph.add(.offset(Offset(value: 1)))
        try graph.connect(.input, to: .node(lift))
        try graph.connect(.node(lift), to: .output)
        try graph.connect(.input, to: .output, gain: 0.25)
        try graph.commit()
        let output = render(graph, frames: 4, input: [4, 8, 12, 16])
        #expect(output.samples(channel: 0) == [6, 11, 16, 21])
    }

    @Test func changesWaitForCommit() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 64)
        let a = graph.add(.offset(Offset(value: 2)))
        try graph.connect(.node(a), to: .output)
        #expect(render(graph).samples(channel: 0).allSatisfy { $0 == 0 })
        try graph.commit()
        #expect(render(graph).samples(channel: 0).allSatisfy { $0 == 2 })
        graph.disconnect(.node(a), to: .output)
        #expect(render(graph).samples(channel: 0).allSatisfy { $0 == 2 })
        try graph.commit()
        #expect(render(graph).samples(channel: 0).allSatisfy { $0 == 0 })
    }

    @Test func aLoopIsRefusedAndTheOldRoutingKeepsPlaying() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 64)
        let a = graph.add(.offset(Offset(value: 1)))
        let b = graph.add(.offset(Offset(value: 1)))
        try graph.connect(.node(a), to: .node(b))
        try graph.connect(.node(b), to: .output)
        try graph.commit()

        try graph.connect(.node(b), to: .node(a))
        #expect(throws: GraphError.cycle) { try graph.commit() }
        #expect(throws: GraphError.cycle) { try graph.connect(.node(a), to: .node(a)) }
        #expect(render(graph).samples(channel: 0).allSatisfy { $0 == 2 })
    }

    @Test func badConnectionsAreRefused() {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 64)
        let a = graph.add(.offset(Offset(value: 1)))
        graph.remove(a)
        #expect(throws: GraphError.unknownNode(a)) { try graph.connect(.node(a), to: .output) }
        #expect(throws: GraphError.invalidConnection) { try graph.connect(.output, to: .input) }
    }

    @Test func blocksLongerThanTheLimitRenderInPieces() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 16)
        let filter = graph.add(.filter(Biquad(.lowPass, frequency: 500)))
        try graph.connect(.input, to: .node(filter))
        try graph.connect(.node(filter), to: .output)
        try graph.commit()
        let noise = TestSignal.noise(frames: 1_000, amplitude: 0.5)
        let output = render(graph, frames: 1_000, input: noise)

        var reference = Biquad(.lowPass, frequency: 500)
        let expected = ProcessorHarness.run(&reference, input: SampleBuffer([noise, noise]), sampleRate: 48_000, blockSizes: [1_000])
        #expect(output.samples(channel: 0) == expected.samples(channel: 0))
    }

    @Test func aRemovedNodeIsDestroyedOnTheControlThreadAfterTheAudioThreadLetsGo() throws {
        let destroyed = Counter()
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 64)
        let tracked = graph.add(.tracked(Tracked(destroyed: destroyed)))
        try graph.connect(.node(tracked), to: .output)
        try graph.commit()
        _ = render(graph)

        graph.remove(tracked)
        try graph.commit()
        // The audio thread has not rendered since, so it may still be using the node.
        #expect(destroyed.value == 0)

        let output = SampleBuffer(channelCount: 2, frameCapacity: 64)
        let report = RealtimeProbe.measure { checkedRender(graph.renderer, output.block, offline48) }
        // Picking up the new routing frees nothing on the audio thread.
        #expect(report.isClean, "\(report)")
        #expect(destroyed.value == 0)

        graph.collect()
        #expect(destroyed.value == 1)
    }

    @Test func nodesAreDestroyedWithTheGraph() throws {
        let destroyed = Counter()
        do {
            let graph = Graph<TestNode>(format: stereo48, maxFrames: 64)
            let a = graph.add(.tracked(Tracked(destroyed: destroyed)))
            graph.add(.tracked(Tracked(destroyed: destroyed)))
            try graph.connect(.node(a), to: .output)
            try graph.commit()
            _ = render(graph)
        }
        #expect(destroyed.value == 2)
    }

    @Test func renderingStaysOffTheHeap() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 512)
        let filter = graph.add(.filter(Biquad(.peak, frequency: 2_000, gain: 4)))
        let level = Parameter(id: "level", default: -6, in: -60...12, unit: .decibels)
        let gain = graph.add(.gain(Gain(level: level)))
        try graph.connect(.input, to: .node(filter))
        try graph.connect(.node(filter), to: .node(gain))
        try graph.connect(.node(gain), to: .output)
        try graph.commit()

        let input = SampleBuffer([TestSignal.noise(frames: 512, amplitude: 0.5), TestSignal.noise(frames: 512, amplitude: 0.5, seed: 2)])
        let output = SampleBuffer(channelCount: 2, frameCapacity: 512)
        let renderer = graph.renderer
        let report = RealtimeProbe.measure {
            var block = 0
            while block < 200 {
                // A fader move in the middle of rendering.
                if block == 100 { level.value = 3 }
                checkedRender(renderer, input: input.block, output.block, offline48)
                block += 1
            }
        }
        #expect(report.isClean, "\(report)")
        #expect(Measure.isFinite(output.samples(channel: 0)))
        #expect(Measure.peak(output.samples(channel: 0)) > 0.1)
    }

    @Test func rewiringWhileAnotherThreadRendersNeverGlitches() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 64)
        let base = graph.add(.offset(Offset(value: 1)))
        try graph.connect(.node(base), to: .output)
        try graph.commit()

        let renderer = graph.renderer
        let stop = Atomic<Bool>(false)
        let blocks = Counter(), wrong = Counter(), heapUse = Counter()
        let audio = Thread {
            let output = SampleBuffer(channelCount: 2, frameCapacity: 64)
            while !stop.load(ordering: .relaxed) {
                let report = RealtimeProbe.measure { checkedRender(renderer, output.block, offline48) }
                if !report.isClean { heapUse.bump() }
                // Every routing this test commits gives a whole number from 1 to 5, the same
                // on every frame. Anything else is a half-applied change.
                let samples = output.samples(channel: 0)
                let first = samples[0]
                if first < 1 || first > 5 || first != first.rounded() || samples.contains(where: { $0 != first }) { wrong.bump() }
                blocks.bump()
            }
        }
        audio.start()

        var extras: [NodeID] = []
        for round in 0..<2_000 {
            if extras.count < 4, round % 2 == 0 {
                let id = graph.add(.offset(Offset(value: 1)))
                try graph.connect(.node(extras.last ?? base), to: .node(id))
                graph.disconnect(.node(extras.last ?? base), to: .output)
                try graph.connect(.node(id), to: .output)
                extras.append(id)
            } else if let last = extras.popLast() {
                graph.remove(last)
                try graph.connect(.node(extras.last ?? base), to: .output)
            }
            try graph.commit()
        }
        while blocks.value < 100 { usleep(1_000) }
        stop.store(true, ordering: .relaxed)
        while !audio.isFinished { usleep(1_000) }
        #expect(wrong.value == 0)
        #expect(heapUse.value == 0)
    }
}
