import Accelerate
import AudioAppCore
import AudioAppProcessing
import AudioAppRealtime
import Darwin

// A unit captured as a small causal network (a TCN): no threshold or ratio to set, only weights, and what it does
// depends on how hard it is driven. Such a network is usually run a window at a time, which costs latency. Here the
// forward pass is a streaming convolution: every layer keeps the last few samples it needs, so any number of samples
// can be put through at any time and the output is not late at all.

/// A causal network's weights as the audio thread reads them: pointers and numbers. Whoever makes them owns the
/// memory; `CausalNetworkModel` is one that does.
///
/// The network is sixteen channels wide. Block `b` has dilation `2^b`: a convolution over its input at the current
/// sample and at 1, 2 ... `kernel - 1` steps of the dilation back, through tanh; plus its input one sample back
/// through a gain per channel. After the last block a weighted sum of the sixteen channels, through tanh, is the
/// output sample.
@frozen public struct CausalNetworkWeights: @unchecked Sendable {
    public var blocks: Int
    public var kernel: Int
    /// Per block: the convolution's weights as columns, one per tap and input channel, the sixteen outputs' weights
    /// in each. The first block has one input channel, the rest sixteen.
    public var layers: UnsafeMutablePointer<UnsafeMutablePointer<SIMD16<Float>>>
    /// Per block its bias and the skip path's sixteen gains; then, last, the output's sixteen weights.
    public var extras: UnsafeMutablePointer<SIMD16<Float>>
    public var outputBias: Float

    @inlinable public init(blocks: Int, kernel: Int, layers: UnsafeMutablePointer<UnsafeMutablePointer<SIMD16<Float>>>, extras: UnsafeMutablePointer<SIMD16<Float>>,
                           outputBias: Float) {
        self.blocks = blocks
        self.kernel = kernel
        self.layers = layers
        self.extras = extras
        self.outputBias = outputBias
    }
}

/// Owns a causal network's weights, laid out for the audio thread from the tensors a training run exports.
public final class CausalNetworkModel: @unchecked Sendable {
    public static let width = 16
    public let weights: CausalNetworkWeights

    /// - Parameters:
    ///   - convolution: per block, the convolution's weights, row-major `[16, inputs, kernel]`: one input for the
    ///     first block, sixteen for the rest.
    ///   - bias, skip: per block, sixteen values each.
    ///   - output: the sixteen weights of the output sum.
    public init(kernel: Int, convolution: [[Float]], bias: [[Float]], skip: [[Float]], output: [Float], outputBias: Float) {
        let outputs = Self.width, count = convolution.count
        precondition(bias.count == count && skip.count == count && output.count == outputs, "a causal network's tensors do not fit together")
        let table = UnsafeMutablePointer<UnsafeMutablePointer<SIMD16<Float>>>.allocate(capacity: max(1, count))
        let extras = UnsafeMutablePointer<SIMD16<Float>>.allocate(capacity: 2 * count + 1)
        for block in 0..<count {
            let inputs = block == 0 ? 1 : outputs
            let weight = convolution[block]
            precondition(weight.count == outputs * inputs * kernel && bias[block].count == outputs && skip[block].count == outputs, "a causal network's tensors do not fit together")
            // Each weight is kept as a column: the sixteen outputs' weights for one input channel at one tap, so that a
            // block's convolution is a run of "column times a number" added up.
            let columns = UnsafeMutablePointer<SIMD16<Float>>.allocate(capacity: kernel * inputs)
            for tap in 0..<kernel {
                for input in 0..<inputs {
                    columns[tap * inputs + input] = SIMD16((0..<outputs).map { weight[($0 * inputs + input) * kernel + tap] })
                }
            }
            table[block] = columns
            extras[2 * block] = SIMD16(bias[block])
            extras[2 * block + 1] = SIMD16(skip[block])
        }
        extras[2 * count] = SIMD16(output)
        weights = CausalNetworkWeights(blocks: count, kernel: kernel, layers: table, extras: extras, outputBias: outputBias)
    }

    deinit {
        for block in 0..<weights.blocks { weights.layers[block].deallocate() }
        weights.layers.deallocate()
        weights.extras.deallocate()
    }
}

/// The memory a causal network runs in: each block's recent input, for any number of audio channels run apart.
///
/// Memory is reserved when it is made, so make it away from the audio thread.
public struct CausalNetwork: ~Copyable {
    @usableFromInline static var width: Int { @_noAllocation @_noLocks get { 16 } }
    public let channelCount: Int
    /// The most blocks, and the longest kernel, a network run in it may have.
    public let maxBlocks: Int
    public let maxKernel: Int
    /// The most samples that can be put through in one call.
    public let chunk: Int
    /// Rows of sixteen a block's history has room for: as far as the last block looks back, and a chunk.
    @usableFromInline let planeLength: Int
    /// Per audio channel and block: `planeLength` rows of sixteen, the block's recent input, oldest first.
    @usableFromInline let history: UnsafeMutablePointer<Float>
    /// A chunk of rows of sixteen: a block's output.
    @usableFromInline let layer: UnsafeMutablePointer<Float>
    @usableFromInline let quiet: UnsafeMutablePointer<Float>

    public init(channelCount: Int = 2, maxBlocks: Int, maxKernel: Int, chunk: Int = 256) {
        self.channelCount = max(1, channelCount)
        self.maxBlocks = max(1, maxBlocks)
        self.maxKernel = max(1, maxKernel)
        self.chunk = max(1, chunk)
        planeLength = (self.maxKernel - 1) * (1 << (self.maxBlocks - 1)) + self.chunk
        history = Memory.floats(self.channelCount * self.maxBlocks * Self.width * planeLength)
        layer = Memory.floats(Self.width * self.chunk)
        quiet = Memory.floats(self.chunk)
    }

    deinit {
        history.deallocate()
        layer.deallocate()
        quiet.deallocate()
    }

    /// Whether a network fits this memory.
    @_noAllocation @_noLocks
    @inlinable public func fits(_ weights: CausalNetworkWeights) -> Bool { weights.blocks <= maxBlocks && weights.kernel <= maxKernel }

    /// Forgets the audio heard so far, leaving the network as it is after a long silence. That is not all zeros
    /// inside: each layer has a bias, so silence in is not silence in the layers. Three chunks of silence are run
    /// through to put every layer's memory there. With no network the memory is only emptied.
    @_noAllocation @_noLocks
    @inlinable public func reset(_ weights: CausalNetworkWeights?) {
        Memory.zero(history, channelCount * maxBlocks * Self.width * planeLength)
        guard let weights else { return }
        for channel in 0..<channelCount {
            for _ in 0..<3 {
                Memory.zero(quiet, chunk)
                forward(weights, channel: channel, quiet, into: quiet, count: chunk)
            }
        }
    }

    /// The network over `count` samples of one channel (no more than a chunk), from `input` into `output`, which
    /// may be the same memory.
    ///
    /// Written out by hand, sixteen outputs at a time, and not handed to the system's matrix product: that one is
    /// several times faster on blocks this size but reserves memory on each call, which the audio thread may not do.
    @_noAllocation @_noLocks
    @inlinable public func forward(_ weights: CausalNetworkWeights, channel: Int, _ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>, count: Int) {
        let width = Self.width, kernel = weights.kernel
        var inputs = 1
        var source = input
        for block in 0..<weights.blocks {
            let dilation = 1 << block
            let past = (kernel - 1) * dilation
            let rows = history + ((channel * maxBlocks + block) * planeLength) * width
            // The block's input goes on the end of what it remembers.
            for index in 0..<(count * inputs) { rows[past * inputs + index] = source[index] }
            let columns = weights.layers[block]
            let bias = weights.extras[2 * block], skip = weights.extras[2 * block + 1]
            // Each output sample is its input now and at the steps of the dilation back, every one of them weighted
            // into the sixteen outputs. Four running sums, so that one multiply-add does not have to wait for the
            // one before it.
            for time in 0..<count {
                var a = bias, b = SIMD16<Float>.zero, c = SIMD16<Float>.zero, d = SIMD16<Float>.zero
                for tap in 0..<kernel {
                    let row = rows + (time + tap * dilation) * inputs
                    let weight = columns + tap * inputs
                    if inputs == 1 {
                        a.addProduct(weight[0], SIMD16(repeating: row[0]))
                    } else {
                        var index = 0
                        while index < 16 {
                            a.addProduct(weight[index], SIMD16(repeating: row[index]))
                            b.addProduct(weight[index + 1], SIMD16(repeating: row[index + 1]))
                            c.addProduct(weight[index + 2], SIMD16(repeating: row[index + 2]))
                            d.addProduct(weight[index + 3], SIMD16(repeating: row[index + 3]))
                            index += 4
                        }
                    }
                }
                let sum = (a + b) + (c + d)
                let target = layer + time * width
                for index in 0..<width { target[index] = sum[index] }
            }
            CausalNetworkKernel.tanh(layer, count * width)
            // The skip path: this block's input, one sample back, through a gain per channel.
            for time in 0..<count {
                let earlier = rows + (past + time - 1) * inputs
                let target = layer + time * width
                for index in 0..<width { target[index] += skip[index] * earlier[inputs == 1 ? 0 : index] }
            }
            // Keep what the next call will look back at.
            for index in 0..<(past * inputs) { rows[index] = rows[index + count * inputs] }
            source = UnsafePointer(layer)
            inputs = width
        }
        let weight = weights.extras[2 * weights.blocks]
        for time in 0..<count {
            let row = layer + time * width
            var sum = weights.outputBias
            for index in 0..<width { sum += weight[index] * row[index] }
            output[time] = sum
        }
        CausalNetworkKernel.tanh(output, count)
    }
}

/// The audio thread's call into the system's math library for the network.
@usableFromInline enum CausalNetworkKernel {
    /// `values = tanh(values)`
    @inlinable @inline(never) @_semantics("no_performance_analysis")
    static func tanh(_ values: UnsafeMutablePointer<Float>, _ count: Int) {
        var length = Int32(count)
        vvtanhf(values, values, &length)
    }
}

/// A stereo stage whose compression is a causal network's: the level into the network set by a reference gain and a
/// drive, taken out again after it, and the result blended with the signal as it arrived.
///
/// A captured unit's output can be a few samples late and upside down against its input. So that blending it with
/// the uncompressed signal means something, the output is turned the right way up and the uncompressed signal is
/// held back by the same few samples before the two are mixed. Switched off, the stage crossfades back to the
/// signal as it arrived, undelayed, and then does nothing and costs nothing. Left and right are run separately.
///
/// Memory is reserved when it is made, so make it away from the audio thread.
public struct NetworkCompressor: ~Copyable {
    /// What the stage is doing.
    @frozen public struct Reading: BitwiseCopyable, Sendable {
        /// An estimate of the gain reduction in decibels: how much quieter the output is than the input over the
        /// metering time, drive taken out. The network has no gain signal to read, so this is a measurement from
        /// outside, not its own figure.
        public var reductionDB: Float = 0
        public var isWorking = false

        @inlinable public init() {}
    }

    @usableFromInline struct State {
        /// 0 to 1: how far the stage is switched in.
        @usableFromInline var engage = Smoothed(0)
        @usableFromInline var mix = Smoothed(1)
        /// The gain into the network now: the reference level times the drive.
        @usableFromInline var gain: Float = 1
        /// Nothing has been through since the stage was made or reset: the gain starts where it is wanted, with no glide to it.
        @usableFromInline var isFresh = true
        @usableFromInline var inputPower = 0.0
        @usableFromInline var outputPower = 0.0

        @inlinable init() {}
    }

    /// The longest delay of a network's output that the uncompressed signal can be held back to match.
    public let maxDelay: Int
    @usableFromInline let network: CausalNetwork
    @usableFromInline let state: UnsafeMutablePointer<State>
    /// Two channels of a chunk.
    @usableFromInline let wet: UnsafeMutablePointer<Float>
    /// Per channel: the last `maxDelay` samples of the uncompressed signal, then room for a chunk.
    @usableFromInline let dry: UnsafeMutablePointer<Float>
    /// What the two running powers of the reading take of each new sample.
    @usableFromInline let average: Double

    /// - Parameters:
    ///   - glideSeconds: how long switching in and out and a change of mix take.
    ///   - meterSeconds: the time the reading's two powers are averaged over.
    public init(sampleRate: SampleRate, maxBlocks: Int, maxKernel: Int, chunk: Int = 256, maxDelay: Int = 16, glideSeconds: Double = 0.03, meterSeconds: Double = 0.1) {
        self.maxDelay = max(0, maxDelay)
        network = CausalNetwork(channelCount: 2, maxBlocks: maxBlocks, maxKernel: maxKernel, chunk: chunk)
        state = .allocate(capacity: 1)
        var fresh = State()
        fresh.mix.configure(sampleRate: sampleRate, seconds: glideSeconds)
        fresh.engage.configure(sampleRate: sampleRate, seconds: glideSeconds)
        state.initialize(to: fresh)
        wet = Memory.floats(2 * network.chunk)
        dry = Memory.floats(2 * (self.maxDelay + network.chunk))
        average = 1 - exp(-1 / (meterSeconds * sampleRate.hertz))
    }

    deinit {
        state.deallocate()
        wet.deallocate()
        dry.deallocate()
    }

    /// The most samples the network is given at a time.
    @inlinable public var chunk: Int { network.chunk }

    @_noAllocation @_noLocks
    @inlinable public func fits(_ weights: CausalNetworkWeights) -> Bool { network.fits(weights) }

    /// Forgets the audio heard so far, leaving the network as it is after a long silence.
    @_noAllocation @_noLocks
    @inlinable public func reset(_ weights: CausalNetworkWeights?) {
        state.pointee.isFresh = true
        state.pointee.inputPower = 0
        state.pointee.outputPower = 0
        Memory.zero(dry, 2 * (maxDelay + network.chunk))
        network.reset(weights)
    }

    /// The network alone over `count` samples of one channel, no more than a chunk: for checking it.
    @_noAllocation @_noLocks
    @inlinable public func forward(_ weights: CausalNetworkWeights, channel: Int, _ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>, count: Int) {
        network.forward(weights, channel: channel, input, into: output, count: count)
    }

    /// Runs a stereo signal through the stage in place.
    /// - Parameters:
    ///   - delay: how many samples late the network's output is against its input, no more than `maxDelay`.
    ///   - polarity: -1 when the network's output has to be turned the right way up, otherwise 1.
    ///   - reference: the gain that brings the signal to the level the network expects. It goes in before the
    ///     network and comes out after.
    ///   - driveDB: more level into the network, taken out again after it.
    ///   - mix: 0 to 1, the compressed signal against the uncompressed.
    /// - Returns: what it is doing, when that is news: nil while it is switched off and at rest.
    @_noAllocation @_noLocks
    @inlinable public func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int, _ weights: CausalNetworkWeights,
                                   delay: Int, polarity: Float, isOn: Bool, reference: Float, driveDB: Float, mix: Float) -> Reading? {
        let chunk = network.chunk
        state.pointee.engage.set(isOn ? 1 : 0)
        guard state.pointee.engage.isRamping || isOn else {
            guard state.pointee.inputPower != 0 else { return nil }
            reset(weights)
            return Reading()
        }
        state.pointee.mix.set(min(max(mix, 0), 1))
        // The level into the network glides to where it is wanted, a chunk at a time, and the same glide is undone
        // after it, so a turn of the drive is not a step.
        let wanted = max(reference, 1e-6) * exp(driveDB * 0.115_129_255)
        if state.pointee.isFresh {
            state.pointee.isFresh = false
            state.pointee.gain = wanted
        }
        let room = maxDelay + chunk
        var done = 0
        while done < frames {
            let count = min(chunk, frames - done)
            let from = state.pointee.gain, to = abs(wanted - from) < 1e-3 * wanted ? wanted : from + (wanted - from) * 0.5
            let step = (to - from) / Float(count)
            for channel in 0..<2 {
                let samples = (channel == 0 ? left : right) + done
                let driven = wet + channel * chunk
                let held = dry + channel * room
                for index in 0..<count {
                    held[maxDelay + index] = samples[index]
                    driven[index] = samples[index] * (from + step * Float(index + 1))
                }
                network.forward(weights, channel: channel, driven, into: driven, count: count)
            }
            // Out of the network: the level put back and the polarity righted, then blended with the uncompressed
            // signal of the same moment.
            var inputPower = state.pointee.inputPower, outputPower = state.pointee.outputPower
            for index in 0..<count {
                let gain = polarity / (from + step * Float(index + 1))
                let blend = state.pointee.mix.next(), engaged = state.pointee.engage.next()
                let wetLeft = wet[index] * gain, wetRight = wet[chunk + index] * gain
                let dryLeft = dry[maxDelay - delay + index], dryRight = dry[room + maxDelay - delay + index]
                inputPower += average * (Double(dryLeft * dryLeft + dryRight * dryRight) - inputPower)
                outputPower += average * (Double(wetLeft * wetLeft + wetRight * wetRight) - outputPower)
                let mixedLeft = dryLeft + (wetLeft - dryLeft) * blend, mixedRight = dryRight + (wetRight - dryRight) * blend
                if engaged >= 1 {
                    left[done + index] = mixedLeft
                    right[done + index] = mixedRight
                } else {
                    // Switching in or out: across from the signal as it arrived, which is not held back.
                    let l = left[done + index], r = right[done + index]
                    left[done + index] = l + (mixedLeft - l) * engaged
                    right[done + index] = r + (mixedRight - r) * engaged
                }
            }
            for channel in 0..<2 {
                let held = dry + channel * room
                for index in 0..<maxDelay { held[index] = held[index + count] }
            }
            state.pointee.inputPower = inputPower + 1e-30
            state.pointee.outputPower = outputPower + 1e-30
            state.pointee.gain = to
            done += count
        }
        var reading = Reading()
        reading.isWorking = true
        if state.pointee.inputPower > 1e-9 {
            reading.reductionDB = Float(4.342_944_819 * log(state.pointee.inputPower / state.pointee.outputPower))
        }
        return reading
    }
}
