import Accelerate
import AudioAppCore
import AudioAppRealtime
import Darwin

// A small network that is stepped once a frame, run on the audio thread: its layers are data, its weights are handed
// in, and the runner owns the memory of every stream it serves (a recurrent layer's state) and the room to work in.
// Several streams can be stepped together, each its own column of the matrices through every layer, which is cheaper
// off the audio thread; with one column the products are matrix times vector.

/// One layer of a network as the audio thread reads it: what is done to the values coming through, and the weights it
/// is done with. The values are `width` rows, one column per stream stepped; a layer may change the width.
///
/// A condition (a profile, a target) is chosen per stream; a conditioned layer reads the row of its table for it.
@frozen public enum NetworkLayer: BitwiseCopyable, @unchecked Sendable {
    /// `out = weight * in`, with `weight` row-major, `rows x width`: the width becomes `rows`.
    case linear(weight: UnsafePointer<Float>, rows: Int)
    /// `in += bias`, one value per row.
    case bias(UnsafePointer<Float>)
    /// `in = in * scale + shift`, the two read from tables of a row of `width` values per condition.
    case modulate(scale: UnsafePointer<Float>, shift: UnsafePointer<Float>)
    /// `in += table`, a row of `width` values per condition.
    case addConditioned(UnsafePointer<Float>)
    /// The condition's row of `count` values, from a table of such rows, put after the values: the width grows by `count`.
    case appendConditioned(UnsafePointer<Float>, count: Int)
    /// PyTorch's GELU, `x * 0.5 * (1 + erf(x / sqrt(2)))`.
    case gelu
    case tanh
    case sigmoid
    /// `in *= gain`
    case scale(Float)
    /// One step of a GRU layer, PyTorch's: `size` units, with the stream's memory in slot `memory`. The gates' weights
    /// are row-major `3 size x width` (input) and `3 size x size` (memory), reset, update and new in that order, with
    /// their biases. The width becomes `size`: the new memory.
    case gru(input: UnsafePointer<Float>, memory: UnsafePointer<Float>, inputBias: UnsafePointer<Float>, memoryBias: UnsafePointer<Float>, size: Int, slot: Int)
}

/// Calls the runner makes into the system's vector library. Plain arithmetic over memory the caller supplies; marked
/// trusted because the compiler's real-time checks cannot see into them.
@usableFromInline enum NetworkKernel {
    /// `out (rows x wide) = matrix (rows x columns) * x (columns x wide)`
    @inlinable @inline(never) @_semantics("no_performance_analysis")
    static func multiply(_ matrix: UnsafePointer<Float>, rows: Int, columns: Int, _ x: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>, wide: Int) {
        vDSP_mmul(matrix, 1, x, 1, out, 1, vDSP_Length(rows), vDSP_Length(wide), vDSP_Length(columns))
    }

    /// `values = 1 / (1 + exp(-values))`
    @inlinable @inline(never) @_semantics("no_performance_analysis")
    static func sigmoid(_ values: UnsafeMutablePointer<Float>, _ count: Int) {
        var length = Int32(count), one: Float = 1
        vDSP_vneg(values, 1, values, 1, vDSP_Length(count))
        vvexpf(values, values, &length)
        vDSP_vsadd(values, 1, &one, values, 1, vDSP_Length(count))
        vvrecf(values, values, &length)
    }

    @inlinable @inline(never) @_semantics("no_performance_analysis")
    static func tanh(_ values: UnsafeMutablePointer<Float>, _ count: Int) {
        var length = Int32(count)
        vvtanhf(values, values, &length)
    }

    @inlinable @inline(never) @_semantics("no_performance_analysis")
    static func gelu(_ values: UnsafeMutablePointer<Float>, _ count: Int) {
        for index in 0..<count { values[index] = values[index] * 0.5 * (1 + erff(values[index] * 0.707_106_781_186_547_6)) }
    }
}

/// Runs a network of `NetworkLayer`s a step at a time for a number of streams, each with its own memory.
///
/// A stream's memory is `memories` slots of `memoryWidth` values, one per recurrent layer; it can be read and written
/// (`memory(of:)`), to save it and to put it back for playback that starts in the middle.
///
/// Memory is reserved when it is made, so make it away from the audio thread. One runner serves one thread at a time.
public struct NetworkRunner: ~Copyable {
    public let streamCount: Int
    /// The widest the values may be anywhere in a network run here.
    public let maxWidth: Int
    /// The most columns stepped together.
    public let maxColumns: Int
    /// Per stream: this many slots of memory, each `memoryWidth` values.
    public let memories: Int
    public let memoryWidth: Int
    @usableFromInline let state: UnsafeMutablePointer<Float>
    /// The values going through, and the next layer's, `maxWidth x maxColumns` each.
    @usableFromInline let current: UnsafeMutablePointer<Float>
    @usableFromInline let next: UnsafeMutablePointer<Float>
    /// A recurrent layer's gates, from its input and from its memory, `3 maxWidth x maxColumns` each, and its memory
    /// gathered, `maxWidth x maxColumns`.
    @usableFromInline let fromInput: UnsafeMutablePointer<Float>
    @usableFromInline let fromMemory: UnsafeMutablePointer<Float>
    @usableFromInline let gathered: UnsafeMutablePointer<Float>

    public init(streams: Int, maxWidth: Int, memories: Int, memoryWidth: Int, maxColumns: Int = 1) {
        streamCount = max(1, streams)
        self.maxWidth = max(1, maxWidth)
        self.maxColumns = max(1, maxColumns)
        self.memories = max(1, memories)
        self.memoryWidth = max(1, memoryWidth)
        state = Memory.floats(streamCount * self.memories * self.memoryWidth)
        current = Memory.floats(self.maxWidth * self.maxColumns)
        next = Memory.floats(self.maxWidth * self.maxColumns)
        fromInput = Memory.floats(3 * self.maxWidth * self.maxColumns)
        fromMemory = Memory.floats(3 * self.maxWidth * self.maxColumns)
        gathered = Memory.floats(self.maxWidth * self.maxColumns)
    }

    deinit {
        for pointer in [state, current, next, fromInput, fromMemory, gathered] { pointer.deallocate() }
    }

    /// A stream's memory: `memories` slots of `memoryWidth` values.
    @_noAllocation @_noLocks
    @inlinable public func memory(of stream: Int) -> UnsafeMutablePointer<Float> { state + stream * memories * memoryWidth }

    /// Forgets one stream's memory.
    @_noAllocation @_noLocks
    @inlinable public func reset(stream: Int) { Memory.zero(memory(of: stream), memories * memoryWidth) }

    /// Forgets every stream's memory.
    @_noAllocation @_noLocks
    @inlinable public func reset() { Memory.zero(state, streamCount * memories * memoryWidth) }

    /// One step of the network for `count` streams together (no more than `maxColumns`).
    /// - Parameters:
    ///   - layers: the network, `layerCount` layers.
    ///   - inputs: stream `s`'s `inputWidth` inputs are at `inputs + s * inputStride`.
    ///   - streams, conditions: per column, the stream and the row its conditioned layers read.
    ///   - outputs: stream `s`'s outputs go to `outputs + s * outputStride`, as many as the last layer leaves.
    /// - Returns: how many outputs each stream got.
    @_noAllocation @_noLocks
    @inlinable @discardableResult
    public func step(_ layers: UnsafePointer<NetworkLayer>, layerCount: Int, inputs: UnsafePointer<Float>, inputWidth: Int, inputStride: Int,
                     streams: UnsafePointer<Int32>, conditions: UnsafePointer<Int32>, count n: Int,
                     into outputs: UnsafeMutablePointer<Float>, outputStride: Int) -> Int {
        var x = current, spare = next
        var width = inputWidth
        for column in 0..<n {
            let source = inputs + Int(streams[column]) * inputStride
            for row in 0..<width { x[row * n + column] = source[row] }
        }
        for index in 0..<layerCount {
            switch layers[index] {
            case .linear(let weight, let rows):
                NetworkKernel.multiply(weight, rows: rows, columns: width, x, into: spare, wide: n)
                let was = x
                x = spare
                spare = was
                width = rows
            case .bias(let bias):
                for row in 0..<width {
                    let value = bias[row]
                    for column in 0..<n { x[row * n + column] += value }
                }
            case .modulate(let scale, let shift):
                for column in 0..<n {
                    let row = Int(conditions[column]) * width
                    for unit in 0..<width { x[unit * n + column] = x[unit * n + column] * scale[row + unit] + shift[row + unit] }
                }
            case .addConditioned(let table):
                for column in 0..<n {
                    let row = table + Int(conditions[column]) * width
                    for unit in 0..<width { x[unit * n + column] = row[unit] + x[unit * n + column] }
                }
            case .appendConditioned(let table, let count):
                for column in 0..<n {
                    let row = table + Int(conditions[column]) * count
                    for unit in 0..<count { x[(width + unit) * n + column] = row[unit] }
                }
                width += count
            case .gelu:
                NetworkKernel.gelu(x, width * n)
            case .tanh:
                NetworkKernel.tanh(x, width * n)
            case .sigmoid:
                NetworkKernel.sigmoid(x, width * n)
            case .scale(let gain):
                for value in 0..<(width * n) { x[value] *= gain }
            case .gru(let inputWeight, let memoryWeight, let inputBias, let memoryBias, let h, let slot):
                let memory = gathered
                for column in 0..<n {
                    let kept = self.memory(of: Int(streams[column])) + slot * memoryWidth
                    for unit in 0..<h { memory[unit * n + column] = kept[unit] }
                }
                NetworkKernel.multiply(inputWeight, rows: 3 * h, columns: width, x, into: fromInput, wide: n)
                NetworkKernel.multiply(memoryWeight, rows: 3 * h, columns: h, memory, into: fromMemory, wide: n)
                for row in 0..<(3 * h) {
                    let a = inputBias[row], b = memoryBias[row]
                    for column in 0..<n {
                        fromInput[row * n + column] += a
                        fromMemory[row * n + column] += b
                    }
                }
                // r and z, then n = tanh(gi_n + r * gh_n), then h = (1 - z) * n + z * h
                for value in 0..<(2 * h * n) { fromInput[value] += fromMemory[value] }
                NetworkKernel.sigmoid(fromInput, 2 * h * n)
                for value in 0..<(h * n) { fromInput[2 * h * n + value] += fromInput[value] * fromMemory[2 * h * n + value] }
                NetworkKernel.tanh(fromInput + 2 * h * n, h * n)
                for value in 0..<(h * n) {
                    let z = fromInput[h * n + value]
                    memory[value] = (1 - z) * fromInput[2 * h * n + value] + z * memory[value]
                }
                for column in 0..<n {
                    let kept = self.memory(of: Int(streams[column])) + slot * memoryWidth
                    for unit in 0..<h { kept[unit] = memory[unit * n + column] }
                }
                for value in 0..<(h * n) { x[value] = memory[value] }
                width = h
            }
        }
        for column in 0..<n {
            let target = outputs + Int(streams[column]) * outputStride
            for row in 0..<width { target[row] = x[row * n + column] }
        }
        return width
    }
}
