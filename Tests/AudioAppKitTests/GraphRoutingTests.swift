import AudioAppKit
import AudioAppTesting
import Testing

/// Side-chains, latency alignment and events.
@Suite struct GraphRoutingTests {
    private func render(_ graph: Graph<TestNode>, input: [Float], events: EventList = .empty) -> [Float] {
        let output = SampleBuffer(channelCount: 2, frameCapacity: input.count)
        let source = SampleBuffer([input, input])
        var context = offline48
        context.events = events
        withExtendedLifetime(source) {
            checkedRender(graph.renderer, input: source.block, output.block, context)
        }
        return output.samples(channel: 0)
    }

    @Test func aSideChainReachesOnlyTheNodeItIsConnectedTo() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 64)
        let key = graph.add(.offset(Offset(value: 0.25)))
        let ducker = graph.add(.ducker(Ducker()))
        try graph.connect(.input, to: .node(ducker))
        try graph.connect(.node(key), to: .node(ducker), input: .sidechain)
        try graph.connect(.node(ducker), to: .output)
        try graph.commit()
        // The key is a steady 0.25, so the input comes out at three quarters; the key itself
        // is not heard.
        #expect(render(graph, input: [1, 2, 4, 8]) == [0.75, 1.5, 3, 6])

        try graph.connect(.node(key), to: .node(ducker), input: .sidechain, gain: 2)
        try graph.commit()
        #expect(render(graph, input: [1, 2, 4, 8]) == [0.5, 1, 2, 4])

        graph.disconnect(.node(key), to: .node(ducker), input: .sidechain)
        try graph.commit()
        #expect(render(graph, input: [1, 2, 4, 8]) == [1, 2, 4, 8])
        #expect(throws: GraphError.invalidConnection) { try graph.connect(.node(key), to: .output, input: .sidechain) }
    }

    @Test func parallelPathsOfDifferentLatencyArriveTogether() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 16)
        let slow = graph.add(.late(Late(frames: 5)))
        let slower = graph.add(.late(Late(frames: 3)))
        try graph.connect(.input, to: .node(slow))
        try graph.connect(.node(slow), to: .node(slower))
        try graph.connect(.node(slower), to: .output)
        // A dry path straight across, which would arrive 8 frames early without alignment.
        try graph.connect(.input, to: .output)
        try graph.commit()
        #expect(graph.latencyFrames == 8)

        var impulse = [Float](repeating: 0, count: 40)
        impulse[2] = 1
        let out = render(graph, input: impulse)
        var expected = [Float](repeating: 0, count: 40)
        expected[10] = 2
        #expect(out == expected)
    }

    @Test func aSideChainIsAlignedWithTheMainInput() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 16)
        let late = graph.add(.late(Late(frames: 4)))
        let ducker = graph.add(.ducker(Ducker()))
        try graph.connect(.input, to: .node(late))
        try graph.connect(.node(late), to: .node(ducker))
        // The key comes from the undelayed input, so it must be held back four frames to
        // land on the same moment of the main signal.
        try graph.connect(.input, to: .node(ducker), input: .sidechain, gain: 0.5)
        try graph.connect(.node(ducker), to: .output)
        try graph.commit()
        var impulse = [Float](repeating: 0, count: 24)
        impulse[3] = 1
        let out = render(graph, input: impulse)
        var expected = [Float](repeating: 0, count: 24)
        expected[7] = 0.5
        #expect(out == expected)
        #expect(graph.latencyFrames == 4)
    }

    @Test func latencyIsZeroWithoutLateNodesAndAlignmentCostsNothing() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 64)
        let a = graph.add(.offset(Offset(value: 1)))
        try graph.connect(.input, to: .node(a))
        try graph.connect(.node(a), to: .output)
        try graph.connect(.input, to: .output)
        try graph.commit()
        #expect(graph.latencyFrames == 0)
        #expect(render(graph, input: [1, 2]) == [3, 5])
    }

    @Test func alignedRenderingStaysOffTheHeap() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 64)
        let late = graph.add(.late(Late(frames: 100)))
        let ducker = graph.add(.ducker(Ducker()))
        try graph.connect(.input, to: .node(late))
        try graph.connect(.node(late), to: .node(ducker))
        try graph.connect(.input, to: .node(ducker), input: .sidechain, gain: 0.1)
        try graph.connect(.node(ducker), to: .output)
        try graph.connect(.input, to: .output)
        try graph.commit()
        let input = SampleBuffer([TestSignal.noise(frames: 64, amplitude: 0.5), TestSignal.noise(frames: 64, amplitude: 0.5, seed: 3)])
        let output = SampleBuffer(channelCount: 2, frameCapacity: 64)
        let renderer = graph.renderer
        let report = RealtimeProbe.measure {
            var block = 0
            while block < 100 {
                checkedRender(renderer, input: input.block, output.block, offline48)
                block += 1
            }
        }
        #expect(report.isClean, "\(report)")
        #expect(Measure.isFinite(output.samples(channel: 0)))
    }

    @Test func eventsLandOnTheirFrameEvenWhenTheBlockIsRenderedInPieces() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 8)
        let stepper = graph.add(.stepper(Stepper()))
        try graph.connect(.node(stepper), to: .output)
        try graph.commit()

        let events = EventBuffer(capacity: 8)
        // Added out of order; the buffer keeps time order.
        events.append(Event(offset: 20, .custom(0, 3)))
        events.append(Event(offset: 3, .custom(0, 1)))
        events.append(Event(offset: 8, .custom(0, 2)))
        events.append(Event(offset: 20, .custom(0, 4)))
        let out = render(graph, input: [Float](repeating: 0, count: 24), events: events.list)
        let expected: [Float] = [0, 0, 0] + [1, 1, 1, 1, 1] + [Float](repeating: 2, count: 12) + [4, 4, 4, 4]
        #expect(out == expected)
    }

    @Test func eventBufferKeepsOrderRefusesWhenFullAndSlices() {
        let events = EventBuffer(capacity: 3)
        #expect(events.append(Event(offset: 9, .midi(0x90, 60, 100))))
        #expect(events.append(Event(offset: 2, .midi(0x80, 60, 0))))
        #expect(events.append(Event(offset: 9, .parameter(address: 7, value: 0.5))))
        #expect(!events.append(Event(offset: 0, .custom(0, 0))))
        let list = events.list
        #expect((0..<3).map { list[$0].offset } == [2, 9, 9])
        #expect(list[1].kind == .midi(0x90, 60, 100))
        #expect(list[2].kind == .parameter(address: 7, value: 0.5))

        let tail = list.slice(from: 8, count: 4)
        #expect(tail.count == 2)
        #expect(tail[0].offset == 1)
        #expect(tail.slice(from: 1, count: 1).count == 2)
        #expect(list.slice(from: 3, count: 6).isEmpty)
        events.clear()
        #expect(events.list.isEmpty)
    }
}
