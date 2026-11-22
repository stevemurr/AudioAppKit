import AudioAppKit
import AudioAppPlugin
import AudioAppTesting
import AudioToolbox
import AVFoundation
import Foundation
import Testing

/// Pulls one block through an Audio Unit the way a host does.
private struct HostCall {
    let block: AURenderBlock
    let output: UnsafeMutableAudioBufferListPointer
    let outputSamples: [UnsafeMutablePointer<Float>]
    let frames: Int
    let pull: AURenderPullInputBlock

    /// - Parameter suppliesOutput: false leaves the output pointers empty, which asks the
    ///   unit to hand back its own buffers.
    init(_ unit: AUAudioUnit, input: [[Float]], suppliesOutput: Bool = true) {
        block = unit.renderBlock
        frames = input[0].count
        output = AudioBufferList.allocate(maximumBuffers: input.count)
        outputSamples = input.map { _ in
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: 4_096)
            samples.initialize(repeating: 99, count: 4_096)
            return samples
        }
        let source = input.map { channel in
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: channel.count)
            samples.initialize(from: channel, count: channel.count)
            return samples
        }
        nonisolated(unsafe) let held = source
        pull = { _, _, count, _, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            var channel = 0
            while channel < buffers.count {
                if let target = buffers[channel].mData { memcpy(target, held[channel], Int(count) * 4) }
                channel += 1
            }
            return noErr
        }
        reset(suppliesOutput: suppliesOutput)
    }

    func reset(suppliesOutput: Bool = true) {
        for channel in 0..<output.count {
            output[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                                          mData: suppliesOutput ? UnsafeMutableRawPointer(outputSamples[channel]) : nil)
        }
    }

    @discardableResult func render() -> AUAudioUnitStatus {
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid
        return block(&flags, &time, AUAudioFrameCount(frames), 0, output.unsafeMutablePointer, pull)
    }

    func samples(channel: Int) -> [Float] {
        guard let data = output[channel].mData else { return [] }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames))
    }
}

/// Each test gives its render resources back before letting the unit go, as a host does. A
/// unit released with resources still allocated can be torn down on a system thread that is
/// part-way through delivering a scheduled parameter change, which the system does not survive.
@Suite(.serialized) struct PluginTests {
    private static let description = PluginDescription(name: "Test Gain", manufacturerName: "AudioAppKit Tests",
                                                       subtype: "tgai", manufacturer: "AAKt", version: 3, tailSeconds: 0.25)

    private func makeUnit(_ level: Parameter? = nil) throws -> (AudioUnitAdapter<Gain>, Parameter) {
        let level = level ?? Parameter(id: "level", name: "Level", default: 0, in: -60...12, unit: .decibels)
        let cutoff = Parameter(id: "eq.cutoff hz", name: "Cutoff", default: 1_000, in: 20...20_000, taper: .logarithmic, unit: .hertz)
        let tree = ParameterTree([.parameter(level), .group(.init(id: "eq", name: "EQ", [cutoff]))])
        let unit = try AudioUnitAdapter<Gain>(Self.description, instance: PluginInstance(processor: Gain(level: level, glideSeconds: 0), parameters: tree))
        return (unit, level)
    }

    @Test func describesItselfToHosts() {
        #expect(PluginDescription.fourCharCode("aufx") == kAudioUnitType_Effect)
        #expect(PluginDescription.fourCharCode("ab") == PluginDescription.fourCharCode("ab  "))
        let component = Self.description.componentDescription
        #expect(component.componentType == kAudioUnitType_Effect)
        #expect(component.componentSubType == PluginDescription.fourCharCode("tgai"))
        #expect(Self.description.componentName == "AudioAppKit Tests: Test Gain")
        #expect(PluginDescription.hostIdentifier("eq.cutoff hz") == "eq_cutoff_hz")
        #expect(PluginDescription.hostIdentifier("1st") == "_1st")
    }

    @Test func processesAudioIntoTheHostsBuffers() throws {
        let (unit, level) = try makeUnit()
        level.value = -6.0206
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }
        let call = HostCall(unit, input: [[1, 1, 1, 1], [-1, 0.5, 0, 2]])
        #expect(call.render() == noErr)
        #expect(call.samples(channel: 0).allSatisfy { close($0, 0.5, within: 1e-4) })
        #expect(zip(call.samples(channel: 1), [-0.5, 0.25, 0, 1]).allSatisfy { close($0, $1, within: 1e-4) })
        #expect(unit.canProcessInPlace)
    }

    @Test func handsBackItsOwnBuffersWhenTheHostSuppliesNone() throws {
        let (unit, level) = try makeUnit()
        level.value = 6.0206
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }
        let call = HostCall(unit, input: [[0.25, 0.5], [1, 1]], suppliesOutput: false)
        #expect(call.render() == noErr)
        #expect(zip(call.samples(channel: 0), [0.5, 1]).allSatisfy { close($0, $1, within: 1e-4) })
        #expect(zip(call.samples(channel: 1), [2, 2]).allSatisfy { close($0, $1, within: 1e-4) })
    }

    @Test func refusesToRenderBeforeResourcesOrPastTheFrameLimit() throws {
        let (unit, _) = try makeUnit()
        unit.maximumFramesToRender = 8
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }
        #expect(HostCall(unit, input: [[Float](repeating: 0, count: 8), [Float](repeating: 0, count: 8)]).render() == noErr)
        #expect(HostCall(unit, input: [[Float](repeating: 0, count: 9), [Float](repeating: 0, count: 9)]).render() != noErr)
    }

    @Test func parametersMirrorTheHostsListBothWays() throws {
        let (unit, level) = try makeUnit()
        let tree = try #require(unit.parameterTree)
        #expect(tree.allParameters.map(\.identifier) == ["level", "eq_cutoff_hz"])
        #expect(tree.allParameters.map(\.keyPath) == ["level", "eq.eq_cutoff_hz"])
        let hostLevel = try #require(tree.parameter(withAddress: 0))
        #expect(hostLevel.minValue == -60 && hostLevel.maxValue == 12 && hostLevel.unit == .decibels)
        let hostCutoff = try #require(tree.parameter(withAddress: 1))
        #expect(hostCutoff.unit == .hertz && hostCutoff.flags.contains(.flag_DisplayLogarithmic))

        hostLevel.value = -12                 // the host moves it
        #expect(level.value == -12)
        level.value = 3                       // the app moves it
        unit.syncHostParameters()
        #expect(hostLevel.value == 3)
        #expect(level.value == 3)
        hostLevel.value = 500                 // clamped like any other set
        #expect(level.value == 12)
    }

    @Test func aParameterChangeScheduledByTheHostIsHeardInThatBlock() throws {
        let (unit, level) = try makeUnit()
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }
        let call = HostCall(unit, input: [[1, 1, 1, 1], [1, 1, 1, 1]])
        unit.scheduleParameterBlock(AUEventSampleTimeImmediate, 0, 0, -6.0206)
        #expect(call.render() == noErr)
        #expect(close(level.value, -6.0206, within: 1e-4))
        #expect(call.samples(channel: 0).allSatisfy { close($0, 0.5, within: 1e-4) })
    }

    @Test func bypassPassesAudioThrough() throws {
        let (unit, level) = try makeUnit()
        level.value = -20
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }
        unit.shouldBypassEffect = true
        let call = HostCall(unit, input: [[1, 0.5], [0.25, -1]])
        call.render()
        #expect(call.samples(channel: 0) == [1, 0.5] && call.samples(channel: 1) == [0.25, -1])
        unit.shouldBypassEffect = false
        call.reset()
        call.render()
        #expect(close(call.samples(channel: 0)[0], 0.1, within: 1e-4))
    }

    @Test func reportsLatencyTailAndChannels() throws {
        let (unit, _) = try makeUnit()
        #expect(unit.tailTime == 0.25)
        #expect(unit.latency == 0)
        #expect(unit.channelCapabilities == [2, 2])
        #expect(unit.inputBusses.count == 1 && unit.outputBusses.count == 1)
        #expect(unit.outputBusses[0].format.channelCount == 2)
    }

    @Test func stateRoundTripsThroughTheHost() throws {
        let saved = Counter()
        let level = Parameter(id: "level", default: 0, in: -60...12)
        let note = Parameter(id: "note", default: 0, in: 0...127)
        let instance = PluginInstance(processor: Gain(level: level), parameters: ParameterTree([level, note]),
                                      saveData: { Data("extra".utf8) },
                                      restoreData: { if String(decoding: $0, as: UTF8.self) == "extra" { saved.bump() } })
        let unit = try AudioUnitAdapter<Gain>(Self.description, instance: instance)
        level.value = -9
        note.value = 64
        let state = try #require(unit.fullState)
        // What a host does: archive the dictionary, and hand it back another day.
        let archived = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
        level.value = 5
        note.value = 1
        let restored = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSString.self, NSData.self, NSNumber.self],
                                                                          from: archived) as? [String: Any])
        unit.fullState = restored
        #expect(level.value == -9 && note.value == 64)
        #expect(saved.value == 1)
        #expect(unit.pluginState == PluginState(parameters: ParameterSnapshot(values: ["level": -9, "note": 64]), processorData: Data("extra".utf8)))
    }

    @Test func renderingStaysOffTheHeap() throws {
        let (unit, level) = try makeUnit()
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }
        let call = HostCall(unit, input: [TestSignal.noise(frames: 512, amplitude: 0.5), TestSignal.noise(frames: 512, amplitude: 0.5, seed: 2)])
        call.render()
        // This measures the adapter's own render block. `renderBlock`, the wrapper the system
        // puts around it for in-process callers, allocates twice per call by itself.
        let render = unit.internalRenderBlock
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        let report = RealtimeProbe.measure {
            var block = 0
            while block < 100 {
                if block == 50 { level.value = -3 }
                _ = render(&flags, &time, 512, 0, call.output.unsafeMutablePointer, nil, call.pull)
                block += 1
            }
        }
        #expect(report.isClean, "\(report)")
        #expect(Measure.peak(call.samples(channel: 0)) > 0.1)
    }

    @Test func aRegisteredPluginIsFoundAndMadeByTheSystem() async throws {
        let description = PluginDescription(name: "Registered Gain", manufacturerName: "AudioAppKit Tests", subtype: "rgai", manufacturer: "AAKt")
        let made = Counter()
        AudioUnitAdapter<Gain>.register(description) {
            made.bump()
            let level = Parameter(id: "level", default: -6.0206, in: -60...12, unit: .decibels)
            return PluginInstance(processor: Gain(level: level, glideSeconds: 0), parameters: ParameterTree([level]))
        }
        let unit = try await AUAudioUnit.instantiate(with: description.componentDescription, options: [])
        #expect(made.value == 1)
        #expect(unit is AudioUnitAdapter<Gain>)
        #expect(unit.audioUnitName == "Registered Gain")
        #expect(unit.manufacturerName == "AudioAppKit Tests")
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }
        let call = HostCall(unit, input: [[1, 1], [1, 1]])
        #expect(call.render() == noErr)
        #expect(call.samples(channel: 0).allSatisfy { close($0, 0.5, within: 1e-4) })
    }

    @Test func nodesAreDestroyedWithTheUnit() throws {
        let destroyed = Counter()
        do {
            let unit = try AudioUnitAdapter<Tracked>(Self.description, instance: PluginInstance(processor: Tracked(destroyed: destroyed), parameters: ParameterTree([Parameter]())))
            try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }
        }
        #expect(destroyed.value == 1)
    }
}
