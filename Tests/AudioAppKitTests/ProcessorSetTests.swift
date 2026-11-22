import AudioAppKit
import AudioAppTesting
import Testing

@Suite struct ProcessorSetTests {
    @Test func theMacroForwardsEveryRequirement() throws {
        let graph = Graph<MacroNode>(format: stereo48, maxFrames: 64)
        let level = Parameter(id: "level", default: -6.0206, in: -60...12, unit: .decibels)
        let gain = graph.add(.gain(Gain(level: level)))
        let late = graph.add(.late(Late(frames: 3)))
        let ducker = graph.add(.ducker(Ducker()))
        try graph.connect(.input, to: .node(gain))
        try graph.connect(.node(gain), to: .node(late))
        try graph.connect(.node(late), to: .node(ducker))
        try graph.connect(.input, to: .node(ducker), input: .sidechain, gain: 0.5)
        try graph.connect(.node(ducker), to: .output)
        try graph.commit()
        // latencyFrames reached the graph through the enum.
        #expect(graph.latencyFrames == 3)

        var impulse = [Float](repeating: 0, count: 16)
        impulse[1] = 1
        let input = SampleBuffer([impulse, impulse])
        let output = SampleBuffer(channelCount: 2, frameCapacity: 16)
        let renderer = graph.renderer
        let report = RealtimeProbe.measure {
            MacroNode.render(renderer, input: input.block, output: output.block, context: offline48)
        }
        #expect(report.isClean, "\(report)")
        // Halved by the gain, three frames late, then ducked by the aligned key of 0.5.
        var expected = [Float](repeating: 0, count: 16)
        expected[4] = 0.25
        #expect(zip(output.samples(channel: 0), expected).allSatisfy { close($0, $1, within: 1e-4) })
    }

    @Test func resetReachesTheHeldProcessor() {
        var node = MacroNode.filter(Biquad(.lowPass, frequency: 200))
        node.prepare(Format(sampleRate: 48_000, layout: .mono), maxFrames: 64)
        let loud = SampleBuffer([[Float](repeating: 1, count: 64)])
        var block = loud.block
        node.process(&block, offline48)
        node.reset()
        let quiet = SampleBuffer([[Float](repeating: 0, count: 64)])
        block = quiet.block
        node.process(&block, offline48)
        #expect(quiet.samples(channel: 0).allSatisfy { $0 == 0 })
        #expect(node.latencyFrames == 0)
    }
}
