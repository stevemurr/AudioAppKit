import AudioAppKit
import AudioAppTesting
import Foundation
import Synchronization
import Testing

/// Makes audio whose every sample says which frame it is: frame + 1 on the first channel
/// and its negative on the second, so silence can never pass for audio. The count wraps at
/// about a million frames so that it is always an exact float.
private struct Ramp: AheadProducer {
    let produced = Counter()
    let seeks = Counter()
    var delayMicroseconds: UInt32 = 0
    /// Where the next block should start if blocks are coming in order.
    var expected: Int64 = -1
    let outOfOrder = Counter()

    mutating func produce(at position: FramePosition, into output: AudioBlock) {
        if delayMicroseconds > 0 { usleep(delayMicroseconds) }
        if position.frames != expected { outOfOrder.bump() }
        expected = position.frames + Int64(output.frameCount)
        // Scratch memory, as a real producer might use.
        let scratch = [Float](repeating: 1, count: output.frameCount)
        for channel in 0..<output.channelCount {
            let samples = output[channel]
            let sign: Float = channel == 0 ? 1 : -1
            for frame in 0..<output.frameCount { samples[frame] = sign * scratch[frame] * Float((Int(position.frames) + frame) % rampLength + 1) }
        }
        produced.bump()
    }

    mutating func seek(to position: FramePosition) {
        expected = position.frames
        seeks.bump()
    }
}

private let rampLength = 1 << 20
private func ramp(from frame: Int, count: Int) -> [Float] { (0..<count).map { Float((frame + $0) % rampLength + 1) } }

/// The node set of an app that plays a lane through a level control.
private enum LaneNode: Processor, ~Copyable {
    case source(AheadSource)
    case gain(Gain)

    mutating func prepare(_ format: Format, maxFrames: Int) {
        switch consume self {
        case .source(var node): node.prepare(format, maxFrames: maxFrames); self = .source(node)
        case .gain(var node): node.prepare(format, maxFrames: maxFrames); self = .gain(node)
        }
    }

    @_noAllocation @_noLocks
    mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        switch consume self {
        case .source(var node): node.process(&io, context); self = .source(node)
        case .gain(var node): node.process(&io, context); self = .gain(node)
        }
    }
}

@_noAllocation @_noLocks
private func checkedRender(_ renderer: borrowing GraphRenderer<LaneNode>, _ output: AudioBlock, _ context: RenderContext) {
    renderer.render(input: nil, output: output, context: context)
}

/// The audio thread's whole job with a lane, as the compiler checks it.
@_noAllocation @_noLocks
private func checkedRead(_ reader: AheadReader, _ output: AudioBlock) -> Int {
    reader.read(into: output)
}

@Suite struct RenderAheadTests {
    private func lane(block: Int = 64, ahead: Int = 256, frames: Int? = nil, delay: UInt32 = 0) -> AheadLane<Ramp> {
        var producer = Ramp()
        producer.delayMicroseconds = delay
        return AheadLane(producer, format: stereo48, blockFrames: block, aheadFrames: ahead, frameCount: frames)
    }

    /// Fills, then reads, the way an offline render does.
    private func pull(_ lane: AheadLane<Ramp>, _ frames: Int) -> (left: [Float], right: [Float], real: Int) {
        let buffer = AudioBuffer(channelCount: 2, frameCapacity: frames)
        lane.fill()
        let real = checkedRead(lane.reader, buffer.block)
        return (buffer.samples(channel: 0), buffer.samples(channel: 1), real)
    }

    @Test func aFilledLaneReadsBackExactlyWhatWasProduced() {
        let lane = lane()
        var frame = 0
        // Reads of every awkward length, crossing block and slot boundaries many times.
        for size in [1, 63, 64, 65, 200, 7, 256, 129, 31] + Array(repeating: 100, count: 30) {
            let read = pull(lane, size)
            #expect(read.real == size)
            #expect(read.left == ramp(from: frame, count: size))
            #expect(read.right == ramp(from: frame, count: size).map { -$0 })
            frame += size
        }
        #expect(lane.position == FramePosition(Int64(frame)))
        #expect(lane.diagnostics.underruns == 0)
        lane.withProducer { producer in
            #expect(producer.outOfOrder.value == 0)
            #expect(producer.seeks.value == 1)
        }
    }

    @Test func seekingPlaysTheNewPositionAndNeverTheOld() {
        let lane = lane()
        #expect(pull(lane, 100).left == ramp(from: 0, count: 100))

        lane.seek(to: 10_000)
        // Nothing has been made for the new position yet. The blocks made for the old one
        // are still in memory and must not be played.
        let stale = AudioBuffer(channelCount: 2, frameCapacity: 50)
        #expect(checkedRead(lane.reader, stale.block) == 0)
        #expect(stale.samples(channel: 0).allSatisfy { $0 == 0 })
        #expect(lane.position == 10_050)

        #expect(pull(lane, 100).left == ramp(from: 10_050, count: 100))
        // Back to where it started: the same block numbers as before, under a new seek count.
        lane.seek(to: 32)
        #expect(pull(lane, 250).left == ramp(from: 32, count: 250))
        lane.withProducer { #expect($0.outOfOrder.value == 0) }
    }

    @Test func missingAudioIsSilenceCountedAndSkipped() {
        let lane = lane(block: 64, ahead: 64)
        // Two blocks are kept ready: the one asked for, plus one for a part-used block.
        #expect(lane.depthBlocks == 2)
        let read = pull(lane, 200)
        #expect(read.real == 128)
        #expect(Array(read.left[..<128]) == ramp(from: 0, count: 128))
        #expect(read.left[128...].allSatisfy { $0 == 0 })
        let diagnostics = lane.diagnostics
        #expect(diagnostics.underruns == 1)
        #expect(diagnostics.missingFrames == 72)

        // The missing frames were skipped, not put off: playback stays on the timeline.
        #expect(lane.position == 200)
        #expect(pull(lane, 100).left == ramp(from: 200, count: 100))
        // The worker was overtaken, so it told the producer it was jumping ahead.
        lane.withProducer { producer in
            #expect(producer.seeks.value == 2)
            #expect(producer.outOfOrder.value == 0)
        }
    }

    @Test func theEndOfTheTimelineIsSilenceAndNotAnUnderrun() {
        let lane = lane(frames: 1_000)
        _ = pull(lane, 256)
        _ = pull(lane, 256)
        _ = pull(lane, 256)
        let last = pull(lane, 400)
        #expect(last.real == 400)
        #expect(Array(last.left[..<232]) == ramp(from: 768, count: 232))
        #expect(last.left[232...].allSatisfy { $0 == 0 })
        #expect(lane.position == 1_000)
        #expect(pull(lane, 64).left.allSatisfy { $0 == 0 })
        #expect(lane.position == 1_000)
        #expect(lane.diagnostics.underruns == 0)
        // Nothing is made past the end: 1000 frames is 16 blocks of 64.
        lane.withProducer { #expect($0.produced.value == 16) }
    }

    @Test func diagnosticsReportDepthAndLoad() {
        let lane = lane(block: 64, ahead: 256)
        #expect(lane.diagnostics == AheadDiagnostics(framesAhead: 0, underruns: 0, missingFrames: 0, producerLoad: nil))
        lane.fill()
        let filled = lane.diagnostics
        #expect(filled.framesAhead == lane.depthBlocks * 64)
        #expect(filled.framesAhead >= 256)
        #expect(filled.producerLoad != nil)
        _ = pull(lane, 10)
        #expect(lane.diagnostics.framesAhead == lane.depthBlocks * 64 - 10)
        lane.seek(to: 5_000)
        #expect(lane.diagnostics.framesAhead == 0)
    }

    @Test func aSlowProducerReportsItsLoad() {
        // 480 frames last 10 ms; making them takes at least 5 ms.
        let lane = lane(block: 480, ahead: 480, delay: 5_000)
        lane.fill()
        let load = lane.diagnostics.producerLoad ?? 0
        #expect(load > 0.4)
        #expect(load < 5)
    }

    @Test func readingStaysOffTheHeap() {
        let lane = lane(block: 64, ahead: 8_192)
        lane.fill()
        let buffer = AudioBuffer(channelCount: 2, frameCapacity: 100)
        let block = buffer.block
        let reader = lane.reader
        var real = 0
        let report = RealtimeProbe.measure {
            var reads = 0
            // 80 reads of 100 frames stay inside what was filled; the rest underrun.
            while reads < 120 {
                real += checkedRead(reader, block)
                reads += 1
            }
        }
        #expect(report.isClean, "\(report)")
        #expect(real > 8_000)
        #expect(lane.diagnostics.underruns > 0)
    }

    @Test func theWorkerKeepsAheadOfAPacedReader() {
        let lane = lane(block: 256, ahead: 2_048)
        lane.start()
        #expect(lane.isRunning)
        #expect(lane.waitUntilReady())
        let buffer = AudioBuffer(channelCount: 2, frameCapacity: 128)
        var frame = 0
        var exact = true
        var heapUse = 0
        for _ in 0..<200 {
            let block = buffer.block
            let reader = lane.reader
            let report = RealtimeProbe.measure { _ = checkedRead(reader, block) }
            heapUse += report.allocations + report.deallocations
            exact = exact && buffer.samples(channel: 0) == ramp(from: frame, count: 128)
            frame += 128
            usleep(500)
        }
        lane.stop()
        #expect(!lane.isRunning)
        #expect(exact)
        #expect(heapUse == 0)
        #expect(lane.diagnostics.underruns == 0)
        lane.withProducer { #expect($0.outOfOrder.value == 0) }
    }

    @Test func readsAndSeeksFromDifferentThreadsNeverTearABlock() {
        let lane = lane(block: 128, ahead: 1_024)
        lane.start()
        let stop = Atomic<Bool>(false)
        let torn = Counter(), reads = Counter(), real = Counter()
        let reader = lane.reader
        let audio = Thread {
            let buffer = AudioBuffer(channelCount: 2, frameCapacity: 200)
            var turn = 0
            while !stop.load(ordering: .relaxed) {
                let frames = [200, 1, 77, 128, 129][turn % 5]
                turn += 1
                let block = buffer.block(frames: frames)
                _ = checkedRead(reader, block)
                let left = block[0], right = block[1]
                // Within one read, real samples count up by one and the channels mirror each
                // other. Anything else is audio from two different places or a half-made block.
                var index = 0
                while index < frames {
                    if left[index] != 0 { real.bump() }
                    if right[index] != -left[index] { torn.bump() }
                    if index > 0, left[index] != 0, left[index - 1] != 0,
                       left[index] != left[index - 1] + 1, left[index] != 1 || left[index - 1] != Float(rampLength) { torn.bump() }
                    index += 1
                }
                reads.bump()
            }
        }
        audio.start()
        var generator = SystemRandomNumberGenerator()
        for round in 0..<400 {
            lane.seek(to: FramePosition(Int64.random(in: 0..<4_000_000, using: &generator)))
            if round % 8 == 0 { usleep(2_000) }
        }
        while reads.value < 2_000 { usleep(500) }
        stop.store(true, ordering: .relaxed)
        while !audio.isFinished { usleep(500) }
        lane.stop()
        #expect(torn.value == 0)
        #expect(real.value > 0)

        // After the dust settles the lane is exactly where the last seek and reads left it.
        lane.seek(to: 777)
        #expect(pull(lane, 300).left == ramp(from: 777, count: 300))
    }

    @Test func aLaneCanBeDroppedWhileItsWorkerRuns() {
        let produced: Counter
        do {
            let lane = lane()
            produced = lane.withProducer { $0.produced }
            lane.start()
            lane.waitUntilReady()
        }
        let count = produced.value
        #expect(count > 0)
        usleep(30_000)
        // The worker stopped with the lane.
        #expect(produced.value == count)
    }

    @Test func aLaneIsASourceNodeInAGraph() throws {
        let lane = lane(block: 64, ahead: 1_024)
        let graph = Graph<LaneNode>(format: stereo48, maxFrames: 256)
        let source = graph.add(.source(AheadSource(lane)))
        let level = Parameter(id: "level", default: -6.0206, in: -60...12, unit: .decibels)
        let gain = graph.add(.gain(Gain(level: level)))
        try graph.connect(.node(source), to: .node(gain))
        try graph.connect(.node(gain), to: .output)
        try graph.commit()

        lane.fill()
        let output = AudioBuffer(channelCount: 2, frameCapacity: 256)
        let block = output.block
        let renderer = graph.renderer
        let report = RealtimeProbe.measure { checkedRender(renderer, block, offline48) }
        #expect(report.isClean, "\(report)")
        let expected = ramp(from: 0, count: 256).map { $0 * Decibels(-6.0206).gain }
        #expect(zip(output.samples(channel: 0), expected).allSatisfy { close($0, $1, within: 1e-3) })
        #expect(zip(output.samples(channel: 1), expected).allSatisfy { close($0, -$1, within: 1e-3) })
    }
}
