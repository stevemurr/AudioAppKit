import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

/// A unit captured as a small causal network, run as a streaming convolution, and the stage round it.
@Suite struct CausalNetworkTests {
    /// A small network with weights from a seeded generator: three blocks, a kernel of five.
    func makeModel(blocks: Int = 3, kernel: Int = 5, scale: Float = 0.2) -> (model: CausalNetworkModel, tensors: (conv: [[Float]], bias: [[Float]], skip: [[Float]], out: [Float], outBias: Float)) {
        func values(_ count: Int, seed: UInt64) -> [Float] { TestSignal.noise(frames: count, amplitude: scale, seed: seed) }
        let conv = (0..<blocks).map { values(16 * ($0 == 0 ? 1 : 16) * kernel, seed: UInt64(100 + $0)) }
        let bias = (0..<blocks).map { values(16, seed: UInt64(200 + $0)) }
        let skip = (0..<blocks).map { values(16, seed: UInt64(300 + $0)) }
        let out = values(16, seed: 400)
        let model = CausalNetworkModel(kernel: kernel, convolution: conv, bias: bias, skip: skip, output: out, outputBias: 0.01)
        return (model, (conv, bias, skip, out, 0.01))
    }

    /// The network written out the slow way, over the whole signal at once, from silence before it.
    func reference(_ input: [Float], kernel: Int, _ t: (conv: [[Float]], bias: [[Float]], skip: [[Float]], out: [Float], outBias: Float)) -> [Float] {
        var rows = input.map { [$0] }
        for block in 0..<t.conv.count {
            let inputs = block == 0 ? 1 : 16, dilation = 1 << block
            func at(_ time: Int) -> [Float] { time >= 0 ? rows[time] : [Float](repeating: 0, count: inputs) }
            var next: [[Float]] = []
            for time in 0..<rows.count {
                var row = [Float](repeating: 0, count: 16)
                for output in 0..<16 {
                    var sum = Double(t.bias[block][output])
                    for tap in 0..<kernel {
                        // Tap `kernel - 1` is the current sample; earlier taps reach back by steps of the dilation.
                        let then = at(time - (kernel - 1 - tap) * dilation)
                        for channel in 0..<inputs { sum += Double(t.conv[block][(output * inputs + channel) * kernel + tap]) * Double(then[channel]) }
                    }
                    let earlier = at(time - 1)
                    row[output] = Float(tanh(sum) + Double(t.skip[block][output]) * Double(earlier[inputs == 1 ? 0 : output]))
                }
                next.append(row)
            }
            rows = next
        }
        return rows.map { row in Float(tanh(Double(t.outBias) + (0..<16).reduce(0.0) { $0 + Double(t.out[$1]) * Double(row[$1]) })) }
    }

    @Test func theStreamIsTheNetworkWrittenOutPlainlyHoweverItIsCut() {
        let made = makeModel()
        let network = CausalNetwork(channelCount: 2, maxBlocks: 4, maxKernel: 5, chunk: 64)
        let fits = network.fits(made.model.weights)
        #expect(fits)
        let frames = 700
        let input = TestSignal.noise(frames: frames, amplitude: 0.5, seed: 7)
        let wanted = reference(input, kernel: 5, made.tensors)
        for blocks in [[64], [1, 17, 64, 5]] {
            // Emptied with no network the memory is all silence, as the reference's past is.
            network.reset(nil)
            var out = input
            var done = 0, turn = 0
            while done < frames {
                let count = min(blocks[turn % blocks.count], frames - done)
                out.withUnsafeMutableBufferPointer { network.forward(made.model.weights, channel: 1, $0.baseAddress! + done, into: $0.baseAddress! + done, count: count) }
                done += count
                turn += 1
            }
            var worst: Float = 0
            for index in 0..<frames { worst = max(worst, abs(out[index] - wanted[index])) }
            #expect(worst < 1e-5)
        }
        // A network too deep or too long for the memory does not fit.
        let deep = makeModel(blocks: 5).model, long = makeModel(kernel: 7).model
        let tooDeep = network.fits(deep.weights), tooLong = network.fits(long.weights)
        #expect(!tooDeep && !tooLong)
    }

    @Test func resetLeavesTheNetworkAsItIsAfterALongSilence() {
        let made = makeModel()
        let network = CausalNetwork(channelCount: 1, maxBlocks: 3, maxKernel: 5, chunk: 128)
        // Run on silence for long enough, the output settles to a steady value: reset goes straight there.
        network.reset(nil)
        var settled = [Float](repeating: 0, count: 128)
        for _ in 0..<4 {
            settled = [Float](repeating: 0, count: 128)
            settled.withUnsafeMutableBufferPointer { network.forward(made.model.weights, channel: 0, $0.baseAddress!, into: $0.baseAddress!, count: 128) }
        }
        #expect(settled[127] != 0)
        var noise = TestSignal.noise(frames: 128, seed: 3)
        noise.withUnsafeMutableBufferPointer { network.forward(made.model.weights, channel: 0, $0.baseAddress!, into: $0.baseAddress!, count: 128) }
        network.reset(made.model.weights)
        var after = [Float](repeating: 0, count: 8)
        after.withUnsafeMutableBufferPointer { network.forward(made.model.weights, channel: 0, $0.baseAddress!, into: $0.baseAddress!, count: 8) }
        #expect(after.allSatisfy { $0 == settled[127] })
    }

    /// A network that is a wire with a gain: one block whose skip path passes its input on, and an output that reads it.
    func wire(gain: Float) -> CausalNetworkModel {
        var skip = [Float](repeating: 0, count: 16), out = skip
        skip[0] = 1
        out[0] = gain
        return CausalNetworkModel(kernel: 3, convolution: [[Float](repeating: 0, count: 16 * 3)], bias: [[Float](repeating: 0, count: 16)], skip: [skip], output: out, outputBias: 0)
    }

    @Test func theStageBlendsTheNetworkWithTheSignalHeldBackToMatchIt() {
        // This network's output is its input one sample late (the skip path), turned over, and squeezed by tanh.
        let model = wire(gain: -1)
        let stage = NetworkCompressor(sampleRate: 48_000, maxBlocks: 2, maxKernel: 3, chunk: 64, maxDelay: 8, glideSeconds: 0.001)
        let frames = 4_800
        let input = TestSignal.sine(frequency: 300, sampleRate: 48_000, frames: frames, amplitude: 0.5)
        var left = input, right = input
        stage.reset(model.weights)
        var last: NetworkCompressor.Reading?
        var done = 0
        while done < frames {
            let count = min(100, frames - done)
            last = left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    stage.process(l.baseAddress! + done, r.baseAddress! + done, frames: count, model.weights, delay: 1, polarity: -1, isOn: true, reference: 1, driveDB: 6, mix: 1)
                }
            }
            done += count
        }
        // Past the fade in: the input a sample late, driven 6 dB into tanh and the drive taken out again.
        let drive = Float(exp(6 * 0.115_129_255))
        for index in 2_400..<frames { #expect(abs(left[index] - tanh(input[index - 1] * drive) / drive) < 1e-5) }
        #expect(left == right)
        let reading = try! #require(last)
        #expect(reading.isWorking && reading.reductionDB > 0.5 && reading.reductionDB < 6)

        // Half mixed, it is half-way between that and the input held back by the same sample.
        stage.reset(model.weights)
        var half = input, other = input
        _ = half.withUnsafeMutableBufferPointer { l in
            other.withUnsafeMutableBufferPointer { r in
                stage.process(l.baseAddress!, r.baseAddress!, frames: frames, model.weights, delay: 1, polarity: -1, isOn: true, reference: 1, driveDB: 6, mix: 0.5)
            }
        }
        for index in 2_400..<frames { #expect(abs(half[index] - 0.5 * (input[index - 1] + left[index])) < 1e-5) }

        // Switched off it fades back to the signal as it arrived, then says so once and does nothing.
        var off = input, offRight = input
        var said: [Bool] = []
        for block in 0..<4 {
            let reading = off.withUnsafeMutableBufferPointer { l in
                offRight.withUnsafeMutableBufferPointer { r in
                    stage.process(l.baseAddress! + block * 480, r.baseAddress! + block * 480, frames: 480, model.weights, delay: 1, polarity: -1, isOn: false, reference: 1, driveDB: 6, mix: 1)
                }
            }
            said.append(reading.map { !$0.isWorking } ?? false)
        }
        #expect(Array(off[480..<1_920]) == Array(input[480..<1_920]))
        #expect(said.filter { $0 }.count == 1 && said.last == false)
    }

    @Test func theStageTouchesNoHeap() {
        let made = makeModel()
        let stage = NetworkCompressor(sampleRate: 48_000, maxBlocks: 3, maxKernel: 5)
        let weights = made.model.weights
        var left = TestSignal.noise(frames: 1_000, amplitude: 0.3, seed: 1), right = TestSignal.noise(frames: 1_000, amplitude: 0.3, seed: 2)
        let report = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                RealtimeProbe.measure {
                    stage.reset(weights)
                    _ = stage.process(l.baseAddress!, r.baseAddress!, frames: 1_000, weights, delay: 2, polarity: 1, isOn: true, reference: 1, driveDB: 0, mix: 0.8)
                    _ = stage.process(l.baseAddress!, r.baseAddress!, frames: 1_000, weights, delay: 2, polarity: 1, isOn: false, reference: 1, driveDB: 0, mix: 0.8)
                }
            }
        }
        #expect(report.isClean, "\(report)")
    }
}
