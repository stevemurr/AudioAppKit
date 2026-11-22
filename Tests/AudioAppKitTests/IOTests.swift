import AudioAppKit
import AudioAppTesting
import Foundation
import Synchronization
import Testing

/// A place for one test's files, removed when the test is done.
private final class Scratch {
    let folder: URL
    init() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AudioAppKitTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: folder) }
    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
}

/// A file whose samples say which frame they are, so a seek can be checked exactly.
private func countingFile(_ url: URL, frames: Int, rate: SampleRate = 48_000) throws {
    let left = (0..<frames).map { Float($0 + 1) / 1_048_576 }
    try AudioBuffer([left, left.map { -$0 }]).write(to: url, sampleRate: rate)
}

private func counting(from frame: Int, count: Int) -> [Float] { (0..<count).map { Float(frame + $0 + 1) / 1_048_576 } }

@_noAllocation @_noLocks
private func checkedOffset(_ output: AudioBlock, _ context: RenderContext) {
    // Writes each frame's timeline position, so the engine's bookkeeping can be read back.
    for channel in 0..<output.channelCount {
        let samples = output[channel]
        for frame in 0..<output.frameCount { samples[frame] = Float(Int(context.position.frames) + frame + 1) }
    }
}

struct IntegerCase: Sendable, CustomStringConvertible {
    let type: String
    let format: AudioFileWriter.SampleFormat
    var description: String { "\(type) \(format)" }
}

private let integerCases: [IntegerCase] = [
    IntegerCase(type: "wav", format: .int16), IntegerCase(type: "wav", format: .int24),
    IntegerCase(type: "aiff", format: .int16), IntegerCase(type: "aiff", format: .int24),
    IntegerCase(type: "caf", format: .int24)
]

@Suite struct IOTests {
    @Test(arguments: ["wav", "caf"])
    func floatFilesRoundTripExactly(type: String) throws {
        let scratch = Scratch()
        let url = scratch.file("noise.\(type)")
        let left = TestSignal.noise(frames: 10_000, amplitude: 0.9), right = TestSignal.noise(frames: 10_000, amplitude: 0.9, seed: 7)
        try AudioBuffer([left, right]).write(to: url, sampleRate: 44_100)

        let reader = try AudioFileReader(url: url)
        #expect(reader.format == Format(sampleRate: 44_100, layout: .stereo))
        #expect(reader.frameCount == 10_000)
        #expect(close(reader.seconds, 10_000 / 44_100, within: 1e-9))
        let audio = try reader.readAll()
        #expect(audio.samples(channel: 0) == left)
        #expect(audio.samples(channel: 1) == right)
    }

    @Test(arguments: integerCases)
    func integerFilesRoundTripToWithinOneStep(testCase: IntegerCase) throws {
        let type = testCase.type, format = testCase.format
        let step: Float = format == .int16 ? 1.0 / 32_768 : 1.0 / 8_388_608
        let scratch = Scratch()
        let url = scratch.file("tone.\(type)")
        let tone = TestSignal.sine(frequency: 440, sampleRate: 48_000, frames: 4_800, amplitude: 0.8)
        try AudioBuffer([tone]).write(to: url, sampleRate: 48_000, sampleFormat: format)
        let reader = try AudioFileReader(url: url)
        #expect(reader.format == Format(sampleRate: 48_000, layout: .mono))
        let back = try reader.readAll().samples(channel: 0)
        #expect(back.count == 4_800)
        #expect(zip(back, tone).allSatisfy { abs($0 - $1) <= step })
        #expect(back != [Float](repeating: 0, count: 4_800))
    }

    @Test func fourChannelsStayInOrder() throws {
        let scratch = Scratch()
        let url = scratch.file("four.wav")
        let channels = (0..<4).map { channel in (0..<1_000).map { Float($0) / 2_000 * Float(channel + 1) / 4 } }
        try AudioBuffer(channels).write(to: url, sampleRate: 96_000)
        let reader = try AudioFileReader(url: url)
        #expect(reader.format == Format(sampleRate: 96_000, layout: .discrete(4)))
        let audio = try reader.readAll()
        for channel in 0..<4 { #expect(audio.samples(channel: channel) == channels[channel]) }
    }

    @Test func seekingLandsOnTheExactFrame() throws {
        let scratch = Scratch()
        let url = scratch.file("count.wav")
        try countingFile(url, frames: 50_000)
        let reader = try AudioFileReader(url: url)
        for frame in [12_345, 0, 49_990, 1, 30_000] {
            reader.seek(to: frame)
            #expect(reader.position == frame)
            let audio = try reader.read(frames: 10)
            #expect(audio.samples(channel: 0) == counting(from: frame, count: 10))
            #expect(reader.position == frame + 10)
        }
        // Reads carry on from where the last one stopped.
        reader.seek(to: 100)
        _ = try reader.read(frames: 7)
        #expect(try reader.read(frames: 5).samples(channel: 0) == counting(from: 107, count: 5))
    }

    @Test func readingPastTheEndGivesSilence() throws {
        let scratch = Scratch()
        let url = scratch.file("short.wav")
        try countingFile(url, frames: 100)
        let reader = try AudioFileReader(url: url)
        reader.seek(to: 90)
        let buffer = AudioBuffer([[Float](repeating: 9, count: 32), [Float](repeating: 9, count: 32), [Float](repeating: 9, count: 32)])
        #expect(try reader.read(into: buffer.block) == 10)
        #expect(Array(buffer.samples(channel: 0)[..<10]) == counting(from: 90, count: 10))
        #expect(buffer.samples(channel: 0)[10...].allSatisfy { $0 == 0 })
        // A channel the file does not have is silent.
        #expect(buffer.samples(channel: 2).allSatisfy { $0 == 0 })
        #expect(try reader.read(into: buffer.block) == 0)
        #expect(buffer.samples(channel: 0).allSatisfy { $0 == 0 })
        reader.seek(to: 1_000)
        #expect(reader.position == 100)
    }

    @Test func aFileWrittenInPiecesIsWhole() throws {
        let scratch = Scratch()
        let url = scratch.file("pieces.caf")
        let noise = TestSignal.noise(frames: 9_000, amplitude: 0.5)
        let source = AudioBuffer([noise, noise])
        let writer = try AudioFileWriter(url: url, format: stereo48)
        var done = 0
        for size in [1, 4_096, 4_000, 903] {
            try writer.write(source.block(from: done, frames: size))
            done += size
        }
        #expect(writer.framesWritten == 9_000)
        writer.close()
        #expect(throws: AudioFileError.self) { try writer.write(source.block) }
        #expect(try AudioFileReader(url: url).readAll().samples(channel: 0) == noise)
    }

    @Test func filesThatCannotBeMadeOrOpenedSaySo() {
        let scratch = Scratch()
        #expect(throws: AudioFileError.self) { try AudioFileWriter(url: scratch.file("a.mp3"), format: stereo48) }
        #expect(throws: AudioFileError.self) { try AudioFileWriter(url: scratch.file("a.aiff"), format: stereo48, sampleFormat: .float32) }
        #expect(throws: AudioFileError.self) { try AudioFileReader(url: scratch.file("missing.wav")) }
        #expect(AudioFileWriter.FileType(pathExtension: "AIF") == .aiff)
        #expect(AudioFileWriter.FileType(pathExtension: "ogg") == nil)
    }

    // MARK: Offline rendering

    @Test func offlineRenderMatchesRunningTheProcessorByHand() {
        let noise = TestSignal.noise(frames: 5_000, amplitude: 0.5)
        let input = AudioBuffer([noise, noise])
        var filter = Biquad(.lowPass, frequency: 800)
        let rendered = OfflineRenderer.render(&filter, frames: 5_000, format: stereo48, blockSize: 333, input: input)
        var reference = Biquad(.lowPass, frequency: 800)
        let expected = ProcessorHarness.run(&reference, input: input, sampleRate: 48_000, blockSizes: [5_000])
        #expect(rendered.samples(channel: 0) == expected.samples(channel: 0))
        #expect(rendered.samples(channel: 1) == expected.samples(channel: 1))
    }

    @Test func offlineRenderTellsEachBlockWhereItIs() {
        let positions = Mutex<[Int64]>([])
        let output = OfflineRenderer.render(frames: 1_000, format: stereo48, blockSize: 300, start: 5_000) { input, output, context in
            #expect(input == nil)
            #expect(context.isOffline)
            #expect(context.transport.isPlaying)
            #expect(context.sampleRate == 48_000)
            positions.withLock { $0.append(context.position.frames) }
            checkedOffset(output, context)
        }
        #expect(positions.withLock { $0 } == [5_000, 5_300, 5_600, 5_900])
        #expect(output.samples(channel: 1) == (0..<1_000).map { Float(5_001 + $0) })
    }

    @Test func offlineRenderOfAGraphFeedsItsInput() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 128)
        let lift = graph.add(.offset(Offset(value: 1)))
        try graph.connect(.input, to: .node(lift))
        try graph.connect(.node(lift), to: .output)
        try graph.commit()
        let input = AudioBuffer([(0..<500).map(Float.init), (0..<500).map { -Float($0) }])
        let output = OfflineRenderer.render(graph.renderer, frames: 500, format: stereo48, blockSize: 128, input: input)
        #expect(output.samples(channel: 0) == (0..<500).map { Float($0) + 1 })
        #expect(output.samples(channel: 1) == (0..<500).map { 1 - Float($0) })
    }

    @Test func renderingToAFileMatchesRenderingToMemory() throws {
        let scratch = Scratch()
        let url = scratch.file("bounce.wav")
        let tone = TestSignal.sine(frequency: 300, sampleRate: 48_000, frames: 20_000, amplitude: 0.5)
        let input = AudioBuffer([tone, tone])
        var gain = Gain()
        gain.level.value = -6
        gain.prepare(stereo48, maxFrames: 4_096)
        let writer = try AudioFileWriter(url: url, format: stereo48)
        try OfflineRenderer.render(to: writer, frames: 20_000, input: input) { input, output, context in
            var block = output
            block.copy(from: input!)
            gain.process(&block, context)
        }
        writer.close()

        var reference = Gain()
        reference.level.value = -6
        let expected = OfflineRenderer.render(&reference, frames: 20_000, format: stereo48, blockSize: 4_096, input: input)
        let file = try AudioFileReader(url: url).readAll()
        #expect(file.frameCapacity == 20_000)
        #expect(file.samples(channel: 0) == expected.samples(channel: 0))
        #expect(Measure.peak(file.samples(channel: 0)) > 0.2)
    }

    // MARK: Streaming

    @Test func aStreamedFilePlaysBackExactlyAcrossSeeks() throws {
        let scratch = Scratch()
        let url = scratch.file("stream.wav")
        try countingFile(url, frames: 40_000)
        let source = try StreamingFileSource(url: url, blockFrames: 1_024, aheadFrames: 4_096)
        #expect(source.format == stereo48)
        #expect(source.frameCount == 40_000)

        // Not started, so the file is read on this thread: an offline render.
        func pull(_ frames: Int) -> [Float] {
            let buffer = AudioBuffer(channelCount: 2, frameCapacity: frames)
            source.lane.fill()
            source.reader.read(into: buffer.block)
            return buffer.samples(channel: 0)
        }
        #expect(pull(3_000) == counting(from: 0, count: 3_000))
        #expect(pull(777) == counting(from: 3_000, count: 777))
        source.seek(to: 31_234)
        #expect(pull(2_000) == counting(from: 31_234, count: 2_000))
        source.seek(to: 5)
        #expect(pull(100) == counting(from: 5, count: 100))
        // The last frames of the file, then silence.
        source.seek(to: 39_900)
        let tail = pull(300)
        #expect(Array(tail[..<100]) == counting(from: 39_900, count: 100))
        #expect(tail[100...].allSatisfy { $0 == 0 })
        #expect(source.isAtEnd)
        #expect(source.diagnostics.underruns == 0)
    }

    @Test func aStreamedFileKeepsUpWithPlaybackAndStaysOffTheHeap() throws {
        let scratch = Scratch()
        let url = scratch.file("live.wav")
        try countingFile(url, frames: 200_000)
        let source = try StreamingFileSource(url: url)
        source.start()
        defer { source.stop() }
        let buffer = AudioBuffer(channelCount: 2, frameCapacity: 512)
        let block = buffer.block
        let reader = source.reader
        var exact = true, heapUse = 0, frame = 0
        for round in 0..<150 {
            if round == 75 {
                source.seek(to: 150_000, wait: true)
                frame = 150_000
            }
            let report = RealtimeProbe.measure { reader.read(into: block) }
            heapUse += report.allocations + report.deallocations
            exact = exact && buffer.samples(channel: 0) == counting(from: frame, count: 512)
            frame += 512
            usleep(1_000)
        }
        #expect(exact)
        #expect(heapUse == 0)
        #expect(source.diagnostics.underruns == 0)
        #expect(source.position == frame)
    }

    // MARK: Sample rate conversion

    @Test func convertingTheRateKeepsTheToneAndScalesTheLength() throws {
        let tone = TestSignal.sine(frequency: 1_000, sampleRate: 48_000, frames: 48_000, amplitude: 0.5)
        let converted = try SampleRateConverter.convert(AudioBuffer([tone, tone]), from: 48_000, to: 44_100)
        #expect(converted.frameCapacity == 44_100)
        #expect(converted.channelCount == 2)
        let middle = Array(converted.samples(channel: 0)[11_025..<33_075])
        #expect(close(Measure.amplitude(of: 1_000, in: middle, sampleRate: 44_100), 0.5, within: 0.005))
        // Nothing else of note came out: the tone accounts for all the level.
        #expect(close(Double(Measure.rms(middle)), 0.5 / 2.0.squareRoot(), within: 0.005))
        #expect(converted.samples(channel: 1) == converted.samples(channel: 0))

        let up = try SampleRateConverter.convert(AudioBuffer([tone]), from: 48_000, to: 96_000, quality: .medium)
        #expect(up.frameCapacity == 96_000)
        #expect(close(Measure.amplitude(of: 1_000, in: Array(up.samples(channel: 0)[24_000..<72_000]), sampleRate: 96_000), 0.5, within: 0.005))
    }

    @Test func convertingToTheSameRateChangesNothing() throws {
        let noise = TestSignal.noise(frames: 1_000)
        #expect(try SampleRateConverter.convert(AudioBuffer([noise]), from: 48_000, to: 48_000).samples(channel: 0) == noise)
    }

    @Test func aFileCanBeConvertedToAnotherRate() throws {
        let scratch = Scratch()
        let source = scratch.file("in.wav"), target = scratch.file("out.wav")
        let tone = TestSignal.sine(frequency: 500, sampleRate: 44_100, frames: 22_050, amplitude: 0.25)
        try AudioBuffer([tone]).write(to: source, sampleRate: 44_100)
        try SampleRateConverter.convertFile(from: source, to: target, sampleRate: 48_000)
        let reader = try AudioFileReader(url: target)
        #expect(reader.format == Format(sampleRate: 48_000, layout: .mono))
        #expect(reader.frameCount == 24_000)
        let audio = try reader.readAll().samples(channel: 0)
        #expect(close(Measure.amplitude(of: 500, in: Array(audio[6_000..<18_000]), sampleRate: 48_000), 0.25, within: 0.005))
    }

    // MARK: Engine

    @Test func theEngineCoreRendersWhatTheDeviceAsksFor() {
        let monitor = LoadMonitor()
        let sizes = Mutex<[Int]>([])
        let core = EngineCore(format: stereo48, maxFrames: 256, monitor: monitor) { input, output, context in
            #expect(input == nil)
            #expect(!context.isOffline)
            #expect(context.transport.isPlaying)
            sizes.withLock { $0.append(output.frameCount) }
            checkedOffset(output, context)
        }
        let buffer = AudioBuffer([[Float](repeating: 9, count: 600), [Float](repeating: 9, count: 600)])
        // A pull longer than the limit is served in pieces, on one continuous timeline.
        core.render(into: buffer.block)
        core.render(into: buffer.block(frames: 100))
        #expect(sizes.withLock { $0 } == [256, 256, 88, 100])
        #expect(Array(buffer.samples(channel: 0)[..<100]) == (0..<100).map { Float(601 + $0) })
        #expect(Array(buffer.samples(channel: 1)[100...]) == (100..<600).map { Float($0 + 1) })
        #expect(monitor.callbacks == 2)
        #expect(monitor.load != nil)
    }

    @Test func theEngineCoreClearsTheBlockFirst() {
        let core = EngineCore(format: stereo48) { _, _, _ in }
        let buffer = AudioBuffer([[9, 9, 9], [9, 9, 9]])
        core.render(into: buffer.block)
        #expect(buffer.samples(channel: 0) == [0, 0, 0])
        #expect(buffer.samples(channel: 1) == [0, 0, 0])
    }

    @Test func theEngineCoreRendersAGraphWithoutTouchingTheHeap() throws {
        let graph = Graph<TestNode>(format: stereo48, maxFrames: 512)
        let source = graph.add(.offset(Offset(value: 0.25)))
        let level = Parameter(id: "level", default: 0, in: -60...12, unit: .decibels)
        let gain = graph.add(.gain(Gain(level: level)))
        try graph.connect(.node(source), to: .node(gain))
        try graph.connect(.node(gain), to: .output)
        try graph.commit()
        let renderer = graph.renderer
        let core = EngineCore(format: stereo48, maxFrames: 512) { _, output, context in
            checkedRender(renderer, output, context)
        }
        let buffer = AudioBuffer(channelCount: 2, frameCapacity: 512)
        let block = buffer.block
        core.render(into: block)
        let report = RealtimeProbe.measure {
            var pulls = 0
            while pulls < 100 {
                if pulls == 50 { level.value = -6 }
                core.render(into: block)
                pulls += 1
            }
        }
        #expect(report.isClean, "\(report)")
        #expect(close(buffer.samples(channel: 0)[511], 0.25 * Decibels(-6).gain, within: 1e-4))
    }

    @Test func theLoadMonitorCountsOverruns() {
        let monitor = LoadMonitor()
        #expect(monitor.load == nil)
        // 480 frames at 48 kHz last 10 ms.
        monitor.record(seconds: 0.002, frames: 480, sampleRate: 48_000)
        #expect(close(monitor.load ?? 0, 0.2, within: 1e-4))
        #expect(monitor.overruns == 0)
        monitor.record(seconds: 0.015, frames: 480, sampleRate: 48_000)
        #expect(monitor.overruns == 1)
        #expect(close(monitor.peakLoad, 1.5, within: 1e-4))
        #expect(monitor.callbacks == 2)
        monitor.reset()
        #expect(monitor.load == nil)
        #expect(monitor.overruns == 0)
    }

    #if os(macOS)
    @Test func devicesDescribeThemselves() {
        let devices = DeviceList.all()
        for device in devices {
            #expect(!device.uid.isEmpty)
            #expect(device.hasInput || device.hasOutput || device.inputChannels == 0)
            #expect(DeviceList.device(uid: device.uid)?.id == device.id)
        }
        // Machines without audio hardware have nothing more to check.
        guard let output = DeviceList.defaultOutput else { return }
        #expect(output.outputChannels > 0)
        #expect(output.sampleRate.hertz > 0)
        #expect(output.availableSampleRates.contains(output.sampleRate))
        #expect(output.bufferFrameRange.contains(output.bufferFrames))
        #expect(devices.contains(output))
        #expect(DeviceList.outputs().contains(output))
    }

    @Test func theEngineDrivesTheRenderFunctionFromARealDevice() throws {
        // Needs an output device. The render function writes nothing, so this is silent.
        guard DeviceList.defaultOutput != nil else { return }
        let engine = AudioEngine()
        let frames = Atomic<Int>(0)
        do {
            try engine.start { _, output, _ in
                frames.wrappingAdd(output.frameCount, ordering: .relaxed)
            }
        } catch {
            // A machine whose device cannot be opened (no session, in use) is not a failure.
            return
        }
        #expect(engine.isRunning)
        let deadline = Date().addingTimeInterval(3)
        while frames.load(ordering: .relaxed) < 4_800, Date() < deadline { usleep(5_000) }
        #expect(frames.load(ordering: .relaxed) >= 4_800)
        #expect((engine.format?.sampleRate.hertz ?? 0) > 0)
        #expect((engine.format?.channelCount ?? 0) >= 1)
        #expect(engine.bufferFrames > 0)
        #expect(engine.position.frames > 0)
        #expect(engine.loadMonitor.callbacks > 0)
        #expect((engine.loadMonitor.load ?? 1) < 0.5)
        engine.stop()
        #expect(!engine.isRunning)
        let after = frames.load(ordering: .relaxed)
        usleep(50_000)
        #expect(frames.load(ordering: .relaxed) == after)
    }
    #endif
}
