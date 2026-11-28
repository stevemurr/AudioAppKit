import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

/// A small network stepped a frame at a time, its layers as data and its memory owned by the runner.
@Suite struct NetworkRunnerTests {
    /// Weights that stay put while a test runs.
    final class Weights {
        var tensors: [UnsafeMutablePointer<Float>] = []
        func keep(_ values: [Float]) -> UnsafePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, values.count))
            pointer.initialize(from: values, count: values.count)
            tensors.append(pointer)
            return UnsafePointer(pointer)
        }
        func random(_ count: Int, seed: UInt64, scale: Float = 0.3) -> [Float] { TestSignal.noise(frames: count, amplitude: scale, seed: seed) }
        deinit { for pointer in tensors { pointer.deallocate() } }
    }

    func gelu(_ x: Float) -> Float { x * 0.5 * (1 + erff(x * 0.707_106_781_186_547_6)) }
    func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

    /// `rows x columns` row-major times a vector, the plain way.
    func times(_ m: [Float], _ x: [Float], rows: Int) -> [Float] {
        (0..<rows).map { row in (0..<x.count).reduce(Float(0)) { $0 + m[row * x.count + $1] * x[$1] } }
    }

    func step(_ runner: borrowing NetworkRunner, _ layers: [NetworkLayer], inputs: [Float], width: Int? = nil, streams: [Int32] = [0], conditions: [Int32] = [0], outputs: Int) -> [Float] {
        var out = [Float](repeating: 0, count: runner.streamCount * outputs)
        let width = width ?? inputs.count / runner.streamCount
        layers.withUnsafeBufferPointer { l in
            inputs.withUnsafeBufferPointer { i in
                streams.withUnsafeBufferPointer { s in
                    conditions.withUnsafeBufferPointer { c in
                        out.withUnsafeMutableBufferPointer { o in
                            _ = runner.step(l.baseAddress!, layerCount: l.count, inputs: i.baseAddress!, inputWidth: width, inputStride: width, streams: s.baseAddress!,
                                            conditions: c.baseAddress!, count: s.count, into: o.baseAddress!, outputStride: outputs)
                        }
                    }
                }
            }
        }
        return out
    }

    @Test func aFeedForwardNetworkIsItsLayersInOrder() {
        let w = Weights()
        let w1 = w.random(6 * 4, seed: 1), b1 = w.random(6, seed: 2), w2 = w.random(3 * 6, seed: 3)
        let scale = w.random(2 * 6, seed: 4).map { 1 + $0 }, shift = w.random(2 * 6, seed: 5), table = w.random(2 * 3, seed: 6)
        let layers: [NetworkLayer] = [.linear(weight: w.keep(w1), rows: 6), .bias(w.keep(b1)), .modulate(scale: w.keep(scale), shift: w.keep(shift)), .gelu,
                                      .linear(weight: w.keep(w2), rows: 3), .addConditioned(w.keep(table)), .tanh, .scale(10)]
        let runner = NetworkRunner(streams: 1, maxWidth: 8, memories: 1, memoryWidth: 1)
        let input: [Float] = [0.5, -0.25, 1, 0.1]
        for condition in 0..<2 {
            let got = step(runner, layers, inputs: input, conditions: [Int32(condition)], outputs: 3)
            var x = times(w1, input, rows: 6)
            x = (0..<6).map { gelu((x[$0] + b1[$0]) * scale[condition * 6 + $0] + shift[condition * 6 + $0]) }
            let y = times(w2, x, rows: 3)
            let want = (0..<3).map { Foundation.tanh(table[condition * 3 + $0] + y[$0]) * 10 }
            for index in 0..<3 { #expect(abs(got[index] - want[index]) < 1e-5) }
        }
    }

    @Test func aRecurrentLayerRemembersEachStreamApart() {
        let w = Weights()
        let h = 4, inputs = 3
        let wi = w.random(3 * h * inputs, seed: 7), wh = w.random(3 * h * h, seed: 8), bi = w.random(3 * h, seed: 9), bh = w.random(3 * h, seed: 10)
        let emb = w.random(2 * 2, seed: 11)
        let layers: [NetworkLayer] = [.gru(input: w.keep(wi), memory: w.keep(wh), inputBias: w.keep(bi), memoryBias: w.keep(bh), size: h, slot: 1),
                                      .appendConditioned(w.keep(emb), count: 2), .sigmoid]
        let runner = NetworkRunner(streams: 2, maxWidth: 8, memories: 2, memoryWidth: 4)
        // The same GRU the plain way.
        var memory = [Float](repeating: 0, count: h)
        func reference(_ x: [Float]) -> [Float] {
            let gi = zip(times(wi, x, rows: 3 * h), bi).map(+), gh = zip(times(wh, memory, rows: 3 * h), bh).map(+)
            for unit in 0..<h {
                let r = sigmoid(gi[unit] + gh[unit]), z = sigmoid(gi[h + unit] + gh[h + unit])
                let n = Foundation.tanh(gi[2 * h + unit] + r * gh[2 * h + unit])
                memory[unit] = (1 - z) * n + z * memory[unit]
            }
            return memory
        }
        for frame in 0..<5 {
            let x = (0..<inputs).map { Float(frame + 1) * 0.1 * Float($0 + 1) }
            // Stream 1 steps every frame; stream 0 only once, and must not pick up stream 1's memory.
            let got = step(runner, layers, inputs: [0, 0, 0] + x, streams: [1], conditions: [1], outputs: h + 2)
            let want = reference(x).map(sigmoid) + [sigmoid(emb[2]), sigmoid(emb[3])]
            for index in 0..<(h + 2) { #expect(abs(got[(h + 2) + index] - want[index]) < 1e-5) }
            for unit in 0..<h { #expect(abs(runner.memory(of: 1)[4 + unit] - memory[unit]) < 1e-5) }
        }
        #expect((0..<8).allSatisfy { runner.memory(of: 0)[$0] == 0 } && (0..<4).allSatisfy { runner.memory(of: 1)[$0] == 0 })
        runner.reset(stream: 1)
        #expect((0..<8).allSatisfy { runner.memory(of: 1)[$0] == 0 })
    }

    @Test func streamsSteppedTogetherAreEachAsAlone() {
        let w = Weights()
        let h = 8
        let layers: [NetworkLayer] = [.linear(weight: w.keep(w.random(h * 5, seed: 12)), rows: h), .bias(w.keep(w.random(h, seed: 13))), .gelu,
                                      .gru(input: w.keep(w.random(3 * h * h, seed: 14)), memory: w.keep(w.random(3 * h * h, seed: 15)), inputBias: w.keep(w.random(3 * h, seed: 16)),
                                           memoryBias: w.keep(w.random(3 * h, seed: 17)), size: h, slot: 0),
                                      .linear(weight: w.keep(w.random(2 * h, seed: 18)), rows: 2)]
        let alone = NetworkRunner(streams: 3, maxWidth: h, memories: 1, memoryWidth: h)
        let together = NetworkRunner(streams: 3, maxWidth: h, memories: 1, memoryWidth: h, maxColumns: 3)
        for frame in 0..<4 {
            let inputs = w.random(15, seed: 100 + UInt64(frame), scale: 1)
            var one: [Float] = []
            for stream in 0..<3 { one += Array(step(alone, layers, inputs: inputs, width: 5, streams: [Int32(stream)], conditions: [0], outputs: 2)[(2 * stream)...].prefix(2)) }
            let all = step(together, layers, inputs: inputs, width: 5, streams: [0, 1, 2], conditions: [0, 0, 0], outputs: 2)
            for index in 0..<6 { #expect(abs(one[index] - all[index]) < 1e-5) }
        }
    }

    @Test func steppingTouchesNoHeap() {
        let w = Weights()
        let h = 16
        let layers: [NetworkLayer] = [.linear(weight: w.keep(w.random(h * 4, seed: 19)), rows: h), .bias(w.keep(w.random(h, seed: 20))),
                                      .modulate(scale: w.keep(w.random(h, seed: 21)), shift: w.keep(w.random(h, seed: 22))), .gelu,
                                      .gru(input: w.keep(w.random(3 * h * h, seed: 23)), memory: w.keep(w.random(3 * h * h, seed: 24)), inputBias: w.keep(w.random(3 * h, seed: 25)),
                                           memoryBias: w.keep(w.random(3 * h, seed: 26)), size: h, slot: 0),
                                      .appendConditioned(w.keep(w.random(4, seed: 27)), count: 4), .linear(weight: w.keep(w.random(2 * (h + 4), seed: 28)), rows: 2),
                                      .addConditioned(w.keep(w.random(2, seed: 29))), .tanh, .sigmoid, .scale(2)]
        let runner = NetworkRunner(streams: 1, maxWidth: h + 4, memories: 1, memoryWidth: h)
        let inputs: [Float] = [0.1, 0.2, 0.3, 0.4]
        var outputs = [Float](repeating: 0, count: 2)
        let streams: [Int32] = [0], conditions: [Int32] = [0]
        let report = layers.withUnsafeBufferPointer { l in
            inputs.withUnsafeBufferPointer { i in
                streams.withUnsafeBufferPointer { s in
                    conditions.withUnsafeBufferPointer { c in
                        outputs.withUnsafeMutableBufferPointer { o in
                            RealtimeProbe.measure {
                                var frame = 0
                                while frame < 8 {
                                    runner.step(l.baseAddress!, layerCount: l.count, inputs: i.baseAddress!, inputWidth: 4, inputStride: 4, streams: s.baseAddress!,
                                                conditions: c.baseAddress!, count: 1, into: o.baseAddress!, outputStride: 2)
                                    frame += 1
                                }
                                runner.reset()
                            }
                        }
                    }
                }
            }
        }
        #expect(report.isClean, "\(report)")
    }
}
