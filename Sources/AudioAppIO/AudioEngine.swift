import AudioAppCore
import AudioAppProcessing
import AudioAppRealtime
@preconcurrency import AVFoundation
import Synchronization

public enum AudioEngineError: Error, Equatable {
    case noOutputDevice
    case cannotUseDevice(String)
    case cannotStart(String)
}

/// Plays audio through a device by calling a render function of yours from the device's
/// audio thread.
///
/// ```swift
/// let engine = AudioEngine()
/// try engine.start { input, output, context in
///     render(renderer, output, context)      // your @_noAllocation @_noLocks function
/// }
/// ```
///
/// The render function runs on the audio thread, so it must keep the real-time rule: write
/// it as a call to a function of your own that carries `@_noAllocation @_noLocks`.
public final class AudioEngine: @unchecked Sendable {
    /// Called for every block the device asks for.
    /// - Parameters:
    ///   - input: audio from the input device, when the engine was configured with one.
    ///   - output: the block to fill. It arrives silent.
    public typealias Render = @Sendable (_ input: AudioBlock?, _ output: AudioBlock, _ context: RenderContext) -> Void

    public struct Configuration: Sendable {
        #if os(macOS)
        /// The device to play through, or nil for the system's default output.
        public var outputDevice: AudioDevice?
        #endif
        /// The rate to render at, or nil for the device's own. When set, the system converts
        /// what is rendered to the device's rate and channel count, so an app that works at
        /// one fixed rate can play through any device.
        public var sampleRate: SampleRate?
        /// How many channels to render. Without a `sampleRate`, the engine uses fewer if the
        /// device has fewer.
        public var outputChannels = 2
        /// How many input channels to capture, or zero for none. Capturing asks the user for
        /// microphone access.
        public var inputChannels = 0
        /// The longest block the render function is ever handed. A device asking for more is
        /// served in pieces.
        public var maxFrames = 4_096

        public init() {}
    }

    public let configuration: Configuration
    /// How much of its deadline the render function is using.
    public let loadMonitor = LoadMonitor()

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var sink: AVAudioSinkNode?
    private var core: EngineCore?
    private var started = false

    public init(_ configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    deinit { stop() }

    public var isRunning: Bool { started && engine.isRunning }

    /// The format being rendered, once started.
    public private(set) var format: Format?

    /// The most frames the device has asked for in one callback so far.
    public var bufferFrames: Int { core?.largestPull.load(ordering: .relaxed) ?? 0 }

    /// How many frames have been rendered since the engine started.
    public var position: FramePosition { FramePosition(Int64(core?.position.load(ordering: .relaxed) ?? 0)) }

    /// Opens the device and starts calling `render`. Throws if there is no device to play
    /// through or it cannot be started.
    public func start(render: @escaping Render) throws {
        stop()
        #if os(macOS)
        if let device = configuration.outputDevice, let unit = engine.outputNode.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw AudioEngineError.cannotUseDevice("\(device.name): error \(status)") }
        }
        #endif
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw AudioEngineError.noOutputDevice }
        // At the device's own rate the source feeds the output directly. At a rate of the
        // app's choosing it goes through the system's mixer, which converts rate and channels.
        let converting = configuration.sampleRate != nil
        let rate = configuration.sampleRate?.hertz ?? hardware.sampleRate
        let channels = converting ? max(1, configuration.outputChannels)
                                  : max(1, min(configuration.outputChannels, Int(hardware.channelCount)))
        guard let rendering = standardFormat(sampleRate: rate, channels: channels) else {
            throw AudioEngineError.cannotStart("no format for \(channels) channels at \(rate) Hz")
        }
        let format = Format(sampleRate: SampleRate(rate), layout: .discrete(channels))
        let core = EngineCore(format: format, maxFrames: configuration.maxFrames, inputChannels: configuration.inputChannels,
                              monitor: loadMonitor, render: render)

        let source = AVAudioSourceNode(format: rendering) { _, _, frames, buffers in
            core.render(buffers, frames: Int(frames))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: converting ? engine.mainMixerNode : engine.outputNode, format: rendering)

        if configuration.inputChannels > 0 {
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            if inputFormat.sampleRate > 0, inputFormat.channelCount > 0 {
                let sink = AVAudioSinkNode { _, frames, buffers in
                    core.capture(buffers, frames: Int(frames))
                    return noErr
                }
                engine.attach(sink)
                engine.connect(engine.inputNode, to: sink, format: inputFormat)
                self.sink = sink
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.detach(source)
            if let sink { engine.detach(sink) }
            sink = nil
            throw AudioEngineError.cannotStart(error.localizedDescription)
        }
        self.source = source
        self.core = core
        self.format = format
        started = true
    }

    /// Renders a graph. For a compiler-checked audio path, prefer `start(render:)` with a
    /// function of your own that names your node type.
    public func start<Node: Processor & SendableMetatype & ~Copyable>(_ renderer: GraphRenderer<Node>) throws {
        try start { input, output, context in
            renderer.render(input: input, output: output, context: context)
        }
    }

    public func stop() {
        guard started else { return }
        engine.stop()
        if let source { engine.detach(source) }
        if let sink { engine.detach(sink) }
        source = nil
        sink = nil
        started = false
    }
}

/// What the device callback does, kept apart from the device so that it can be driven and
/// tested without one.
public final class EngineCore: @unchecked Sendable {
    public let format: Format
    public let maxFrames: Int
    let position = Atomic<Int>(0)
    let largestPull = Atomic<Int>(0)
    private let monitor: LoadMonitor
    private let render: AudioEngine.Render
    /// One pointer per output channel, pointed at the device's buffers for each callback.
    private let channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let inputChannels: Int
    /// Captured input on its way from the input callback to the render callback.
    private let inputRing: AudioRing?
    private let inputScratch: SampleBuffer?
    private let captureChannels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    private var denormalsFlushed = false

    /// - Parameter render: called for each block, on whichever thread calls `render`.
    public init(format: Format, maxFrames: Int = 4_096, inputChannels: Int = 0, monitor: LoadMonitor = LoadMonitor(),
                render: @escaping AudioEngine.Render) {
        self.format = format
        self.maxFrames = max(1, maxFrames)
        self.monitor = monitor
        self.render = render
        self.inputChannels = max(0, inputChannels)
        channels = .allocate(capacity: format.channelCount)
        if inputChannels > 0 {
            inputRing = AudioRing(channelCount: inputChannels, frameCapacity: 4 * self.maxFrames)
            inputScratch = SampleBuffer(channelCount: inputChannels, frameCapacity: self.maxFrames)
            captureChannels = .allocate(capacity: inputChannels)
        } else {
            inputRing = nil
            inputScratch = nil
            captureChannels = nil
        }
    }

    deinit {
        channels.deallocate()
        captureChannels?.deallocate()
    }

    /// Renders into the device's buffers. This is the output callback.
    func render(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        var channel = 0
        while channel < format.channelCount {
            guard channel < list.count, let data = list[channel].mData else { return }
            channels[channel] = data.assumingMemoryBound(to: Float.self)
            channel += 1
        }
        render(into: AudioBlock(channels: UnsafePointer(channels), channelCount: format.channelCount, frameCount: frames))
    }

    /// Takes in the input device's audio. This is the input callback.
    func capture(_ buffers: UnsafePointer<AudioBufferList>, frames: Int) {
        guard let inputRing, let captureChannels else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        var channel = 0
        while channel < inputChannels {
            // A device with fewer channels than asked for repeats its last one.
            let from = min(channel, list.count - 1)
            guard from >= 0, let data = list[from].mData else { return }
            captureChannels[channel] = data.assumingMemoryBound(to: Float.self)
            channel += 1
        }
        inputRing.write(frames: frames) { channel, frame in captureChannels[channel][frame] }
    }

    /// Renders one device pull into `output`, exactly as the device callback does: the block
    /// is cleared, split if it is longer than `maxFrames`, rendered, and timed. Call this
    /// directly to drive the engine's render path without a device.
    public func render(into output: AudioBlock) {
        if !denormalsFlushed {
            RealtimeThread.flushDenormals()
            denormalsFlushed = true
        }
        let began = monitor.begin()
        if output.frameCount > largestPull.load(ordering: .relaxed) { largestPull.store(output.frameCount, ordering: .relaxed) }
        output.clear()
        var done = 0
        while done < output.frameCount {
            let frames = min(maxFrames, output.frameCount - done)
            let start = position.load(ordering: .relaxed)
            let at = FramePosition(Int64(start))
            let context = RenderContext(sampleRate: format.sampleRate, position: at,
                                        transport: Transport(isPlaying: true, position: at))
            var input: AudioBlock?
            if let inputRing, let inputScratch {
                let block = inputScratch.block(frames: frames)
                block.clear()
                inputRing.read(frames: frames) { channel, frame, sample in block[channel][frame] = sample }
                input = block
            }
            render(input, output.slice(from: done, count: frames), context)
            position.store(start + frames, ordering: .relaxed)
            done += frames
        }
        monitor.end(began, frames: output.frameCount, sampleRate: format.sampleRate.hertz)
    }
}
