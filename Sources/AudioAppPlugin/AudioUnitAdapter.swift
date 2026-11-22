import AudioAppKit
import AudioToolbox
import AVFoundation
import CoreAudioTypes
import Darwin
import Synchronization

/// Factories for registered plug-ins, by component.
private struct RegistryKey: Hashable {
    let type, subtype, manufacturer: FourCharCode
    init(_ description: AudioComponentDescription) {
        type = description.componentType
        subtype = description.componentSubType
        manufacturer = description.componentManufacturer
    }
}

private let registry = Mutex<[RegistryKey: any Sendable]>([:])

/// What the render block reads. It lives at a fixed address for the life of the Audio Unit
/// and holds only plain values and pointers, so the audio thread touches no Swift objects.
struct AudioUnitKernel<P: Processor & ~Copyable>: ~Copyable {
    var processor: UnsafeMutablePointer<P>
    var parameters: UnsafeMutablePointer<Unmanaged<Parameter>>
    var parameterCount: Int
    var bypassed: UnsafeMutablePointer<Atomic<Bool>>
    var channelCount = 0
    var maxFrames = 0
    var sampleRate = 44_100.0
    var position: Int64 = 0
    /// The list handed to the host when pulling input, pointing at `inputSamples`.
    var inputList: UnsafeMutablePointer<AudioBufferList>?
    var inputSamples: UnsafeMutablePointer<Float>?
    var channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    /// Where the host's events for the block are copied for the processor to read.
    var events: UnsafeMutablePointer<Event>?
    /// Where the packet list sits inside a MIDI event, worked out once away from the audio
    /// thread because asking for it allocates.
    var midiListOffset = 0
}

/// How many host events one block can carry through to the processor.
let eventCapacity = 512

/// Presents one `Processor` and its parameters to hosts as an Audio Unit (AUv3) effect.
///
/// The host's parameter list is built from the `ParameterTree`: a change the host makes sets
/// the parameter at once, and `syncHostParameters()` reports the app's own changes back. The
/// processor is prepared when the host allocates render resources, and audio is processed in
/// place with nothing allocated on the audio thread.
///
/// As with any Audio Unit, call `deallocateRenderResources()` before letting go of one whose
/// resources are allocated.
///
///     AudioUnitAdapter<MyEffect>.register(description) {
///         let effect = MyEffect()
///         return PluginInstance(processor: effect, parameters: ParameterTree([...]))
///     }
public final class AudioUnitAdapter<P: Processor & ~Copyable>: AUAudioUnit {
    /// The processor's parameters. Setting one here is heard at once; call
    /// `syncHostParameters()` for the host to see it.
    public let parameters: ParameterTree
    private let kernel: UnsafeMutablePointer<AudioUnitKernel<P>>
    private let hostTree: AUParameterTree
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var inputBusArray: AUAudioUnitBusArray?
    private var outputBusArray: AUAudioUnitBusArray?
    private let tailSeconds: Double
    private let saveData: (@Sendable () -> Data?)?
    private let restoreData: (@Sendable (Data) -> Void)?
    private static var stateKey: String { "AudioAppKit.state" }

    /// Makes this plug-in available to hosts in this process, including `AVAudioEngine`.
    /// - Parameter make: called for each new copy of the plug-in.
    public static func register(_ description: PluginDescription, make: @escaping @Sendable () -> PluginInstance<P>) {
        let entry = Registration(description: description, make: make)
        registry.withLock { $0[RegistryKey(description.componentDescription)] = entry }
        AUAudioUnit.registerSubclass(AudioUnitAdapter<P>.self, as: description.componentDescription,
                                     name: description.componentName, version: description.version)
    }

    private struct Registration: Sendable {
        let description: PluginDescription
        let make: @Sendable () -> PluginInstance<P>
    }

    /// Called by the system for a registered plug-in.
    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let found = registry.withLock { $0[RegistryKey(componentDescription)] }
        guard let entry = found as? Registration else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidElement))
        }
        let instance = entry.make()
        (parameters, kernel, hostTree, inputBus, outputBus, saveData, restoreData) = try Self.assemble(instance, entry.description)
        tailSeconds = entry.description.tailSeconds
        try super.init(componentDescription: componentDescription, options: options)
        finishSetup()
    }

    /// Makes one copy directly, without registering it, for an app that hosts its own effect.
    public init(_ description: PluginDescription, instance: consuming PluginInstance<P>) throws {
        (parameters, kernel, hostTree, inputBus, outputBus, saveData, restoreData) = try Self.assemble(instance, description)
        tailSeconds = description.tailSeconds
        try super.init(componentDescription: description.componentDescription, options: [])
        finishSetup()
    }

    private typealias Parts = (ParameterTree, UnsafeMutablePointer<AudioUnitKernel<P>>, AUParameterTree, AUAudioUnitBus, AUAudioUnitBus,
                               (@Sendable () -> Data?)?, (@Sendable (Data) -> Void)?)

    private static func assemble(_ instance: consuming PluginInstance<P>, _ description: PluginDescription) throws -> Parts {
        let parameters = instance.parameters
        let save = instance.saveData, restore = instance.restoreData
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: AVAudioChannelCount(description.channelCount)) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        let inputBus = try AUAudioUnitBus(format: format), outputBus = try AUAudioUnitBus(format: format)

        let processor = UnsafeMutablePointer<P>.allocate(capacity: 1)
        processor.initialize(to: instance.processor)
        let list = parameters.parameters
        let references = UnsafeMutablePointer<Unmanaged<Parameter>>.allocate(capacity: max(1, list.count))
        for (index, parameter) in list.enumerated() { (references + index).initialize(to: .passUnretained(parameter)) }
        let bypassed = UnsafeMutablePointer<Atomic<Bool>>.allocate(capacity: 1)
        bypassed.initialize(to: Atomic(false))
        let kernel = UnsafeMutablePointer<AudioUnitKernel<P>>.allocate(capacity: 1)
        kernel.initialize(to: AudioUnitKernel(processor: processor, parameters: references, parameterCount: list.count, bypassed: bypassed))
        return (parameters, kernel, Self.hostTree(for: parameters), inputBus, outputBus, save, restore)
    }

    private func finishSetup() {
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4_096
    }

    deinit {
        releaseBuffers()
        kernel.pointee.processor.deinitialize(count: 1)
        kernel.pointee.processor.deallocate()
        kernel.pointee.parameters.deallocate()
        kernel.pointee.bypassed.deinitialize(count: 1)
        kernel.pointee.bypassed.deallocate()
        kernel.deinitialize(count: 1)
        kernel.deallocate()
    }

    // MARK: Parameters

    private static func hostTree(for parameters: ParameterTree) -> AUParameterTree {
        let all = parameters.parameters
        var address: AUParameterAddress = 0
        func nodes(_ children: [ParameterTree.Node]) -> [AUParameterNode] {
            children.map { child in
                switch child {
                case .group(let group):
                    return AUParameterTree.createGroup(withIdentifier: PluginDescription.hostIdentifier(group.id), name: group.name, children: nodes(group.children))
                case .parameter(let parameter):
                    defer { address += 1 }
                    var unitName: String?
                    let unit: AudioUnitParameterUnit
                    switch parameter.unit {
                    case .generic: unit = .generic
                    case .decibels: unit = .decibels
                    case .hertz: unit = .hertz
                    case .seconds: unit = .seconds
                    case .percent: unit = .percent
                    case .ratio: unit = .ratio
                    case .custom(let name): unit = .customUnit; unitName = name
                    }
                    var flags: AudioUnitParameterOptions = [.flag_IsReadable, .flag_IsWritable]
                    if parameter.taper == .logarithmic { flags.insert(.flag_DisplayLogarithmic) }
                    return AUParameterTree.createParameter(withIdentifier: PluginDescription.hostIdentifier(parameter.id), name: parameter.name, address: address,
                                                           min: parameter.range.lowerBound, max: parameter.range.upperBound, unit: unit,
                                                           unitName: unitName, flags: flags, valueStrings: nil, dependentParameters: nil)
                }
            }
        }
        let tree = AUParameterTree.createTree(withChildren: nodes(parameters.children))
        // The host's list has no values of its own: it reads and writes the parameters.
        tree.implementorValueObserver = { parameter, value in
            let index = Int(parameter.address)
            if index < all.count { all[index].value = value }
        }
        tree.implementorValueProvider = { parameter in
            let index = Int(parameter.address)
            return index < all.count ? all[index].value : 0
        }
        return tree
    }

    /// Tells the host about parameter changes the app made itself, such as from its own
    /// controls or an undo. The host keeps its own copy of each value and is not told
    /// otherwise. Call it after such a change, or from a display timer; it is cheap when
    /// nothing has changed. Not for the audio thread.
    public func syncHostParameters() {
        for (index, parameter) in parameters.parameters.enumerated() {
            guard let hosted = hostTree.parameter(withAddress: AUParameterAddress(index)) else { continue }
            let value = parameter.value
            if hosted.value != value { hosted.setValue(value, originator: nil) }
        }
    }

    public override var parameterTree: AUParameterTree? {
        get { hostTree }
        set {}
    }

    // MARK: Busses and resources

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray! }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArray! }
    public override var canProcessInPlace: Bool { true }

    public override var channelCapabilities: [NSNumber]? {
        let channels = NSNumber(value: inputBus.format.channelCount)
        return [channels, channels]
    }

    public override var latency: TimeInterval {
        Double(kernel.pointee.processor.pointee.latencyFrames) / max(1, kernel.pointee.sampleRate)
    }

    public override var tailTime: TimeInterval { tailSeconds }

    public override var shouldBypassEffect: Bool {
        get { kernel.pointee.bypassed.pointee.load(ordering: .relaxed) }
        set { kernel.pointee.bypassed.pointee.store(newValue, ordering: .relaxed) }
    }

    public override func allocateRenderResources() throws {
        let format = outputBus.format
        guard inputBus.format.channelCount == format.channelCount, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        releaseBuffers()
        let channelCount = Int(format.channelCount), maxFrames = Int(maximumFramesToRender)
        kernel.pointee.processor.pointee.prepare(Format(sampleRate: SampleRate(format.sampleRate), layout: .discrete(channelCount)),
                                                 maxFrames: maxFrames)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: channelCount * maxFrames)
        samples.initialize(repeating: 0, count: channelCount * maxFrames)
        let channels = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channelCount)
        for channel in 0..<channelCount { (channels + channel).initialize(to: samples + channel * maxFrames) }
        let list = AudioBufferList.allocate(maximumBuffers: channelCount)
        kernel.pointee.inputSamples = samples
        kernel.pointee.events = .allocate(capacity: eventCapacity)
        kernel.pointee.midiListOffset = MemoryLayout<AUMIDIEventList>.offset(of: \.eventList) ?? 0
        kernel.pointee.channels = channels
        kernel.pointee.inputList = list.unsafeMutablePointer
        kernel.pointee.channelCount = channelCount
        kernel.pointee.maxFrames = maxFrames
        kernel.pointee.sampleRate = format.sampleRate
        kernel.pointee.position = 0
    }

    public override func deallocateRenderResources() {
        super.deallocateRenderResources()
        releaseBuffers()
    }

    public override func reset() {
        super.reset()
        kernel.pointee.processor.pointee.reset()
        kernel.pointee.position = 0
    }

    private func releaseBuffers() {
        kernel.pointee.inputSamples?.deallocate()
        kernel.pointee.events?.deallocate()
        kernel.pointee.events = nil
        kernel.pointee.channels?.deallocate()
        if let list = kernel.pointee.inputList { free(list) }
        kernel.pointee.inputSamples = nil
        kernel.pointee.channels = nil
        kernel.pointee.inputList = nil
        kernel.pointee.maxFrames = 0
    }

    // MARK: Rendering

    public override var internalRenderBlock: AUInternalRenderBlock {
        // Only the kernel's address is captured: no Swift object is retained or released
        // while audio renders.
        nonisolated(unsafe) let kernel = kernel
        return { _, timestamp, frameCount, _, outputData, events, pullInput in
            AudioUnitAdapter<P>.render(kernel, timestamp, frameCount, outputData, events, pullInput)
        }
    }

    /// One block, on the audio thread. Loops are `while` loops because a `for` loop over a
    /// range allocates in a debug build.
    private static func render(_ kernel: UnsafeMutablePointer<AudioUnitKernel<P>>, _ timestamp: UnsafePointer<AudioTimeStamp>,
                               _ frameCount: AUAudioFrameCount, _ outputData: UnsafeMutablePointer<AudioBufferList>,
                               _ events: UnsafePointer<AURenderEvent>?, _ pullInput: AURenderPullInputBlock?) -> AUAudioUnitStatus {
        let frames = Int(frameCount), channelCount = kernel.pointee.channelCount
        guard let inputList = kernel.pointee.inputList, let samples = kernel.pointee.inputSamples, let channels = kernel.pointee.channels else {
            return kAudioUnitErr_Uninitialized
        }
        guard frames <= kernel.pointee.maxFrames else { return kAudioUnitErr_TooManyFramesToProcess }
        guard let pullInput else { return kAudioUnitErr_NoConnection }

        // Offer the host our own buffers to fill. It may fill them or point the list at its own.
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        inputList.pointee.mNumberBuffers = UInt32(channelCount)
        // (A key path to the list's buffers would be tidier, but making one allocates.)
        let input = UnsafeMutableAudioBufferListPointer(inputList)
        var channel = 0
        while channel < channelCount {
            input[channel] = CoreAudioTypes.AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: samples + channel * kernel.pointee.maxFrames)
            channel += 1
        }
        var pullFlags = AudioUnitRenderActionFlags()
        let status = pullInput(&pullFlags, timestamp, frameCount, 0, inputList)
        guard status == noErr else { return status }

        // Parameter changes the host scheduled for this block set the parameter from the
        // block's start. They and the host's MIDI are also passed on, each at its own frame,
        // for a processor that wants to act on the exact moment. The host's list is already
        // in time order.
        var event = events
        var passed = 0
        let start = Int64(timestamp.pointee.mSampleTime)
        while let current = event {
            let type = current.pointee.head.eventType
            let offset = min(max(Int(current.pointee.head.eventSampleTime - start), 0), max(frames - 1, 0))
            if type == .parameter || type == .parameterRamp {
                let change = current.pointee.parameter
                let index = Int(change.parameterAddress)
                if index < kernel.pointee.parameterCount {
                    kernel.pointee.parameters[index]._withUnsafeGuaranteedRef { $0.value = change.value }
                }
                if let store = kernel.pointee.events, passed < eventCapacity {
                    (store + passed).initialize(to: Event(offset: offset, .parameter(address: change.parameterAddress, value: change.value)))
                    passed += 1
                }
            } else if type == .MIDI, current.pointee.MIDI.length >= 1, current.pointee.MIDI.length <= 3 {
                let midi = current.pointee.MIDI
                if let store = kernel.pointee.events, passed < eventCapacity {
                    (store + passed).initialize(to: Event(offset: offset, .midi(midi.data.0, midi.length > 1 ? midi.data.1 : 0,
                                                                                 midi.length > 2 ? midi.data.2 : 0)))
                    passed += 1
                }
            } else if type == .midiEventList {
                // Newer systems deliver MIDI as Universal MIDI Packets. Pass on the MIDI 1.0
                // channel messages (packet type 2: one word holding status and two data
                // bytes) and step over everything else by its length.
                let store = kernel.pointee.events
                do {
                    let list = UnsafeRawPointer(current).advanced(by: kernel.pointee.midiListOffset).assumingMemoryBound(to: MIDIEventList.self)
                    var packet = UnsafeRawPointer(list).advanced(by: 8).assumingMemoryBound(to: MIDIEventPacket.self)
                    var remaining = Int(list.pointee.numPackets)
                    while remaining > 0 {
                        let count = Int(packet.pointee.wordCount)
                        let words = UnsafeRawPointer(packet).advanced(by: 12).assumingMemoryBound(to: UInt32.self)
                        var index = 0
                        while index < count {
                            let word = words[index]
                            let kind = word >> 28
                            if kind == 2, let store, passed < eventCapacity {
                                (store + passed).initialize(to: Event(offset: offset, .midi(UInt8((word >> 16) & 0xFF), UInt8((word >> 8) & 0x7F),
                                                                                             UInt8(word & 0x7F))))
                                passed += 1
                            }
                            index += kind == 5 ? 4 : (kind == 3 || kind == 4 ? 2 : 1)
                        }
                        packet = UnsafeRawPointer(words + count).assumingMemoryBound(to: MIDIEventPacket.self)
                        remaining -= 1
                    }
                }
            }
            event = UnsafePointer(current.pointee.head.next)
        }

        // Work in the host's output buffers when it supplies them, in the input's when not.
        let output = UnsafeMutableAudioBufferListPointer(outputData)
        let outputCount = Int(outputData.pointee.mNumberBuffers)
        channel = 0
        while channel < channelCount {
            guard let source = input[channel].mData else { return kAudioUnitErr_NoConnection }
            var target = source
            if channel < outputCount {
                if let supplied = output[channel].mData {
                    if supplied != source { memcpy(supplied, source, Int(bytes)) }
                    target = supplied
                } else {
                    output[channel].mData = source
                }
                output[channel].mDataByteSize = bytes
            }
            channels[channel] = target.assumingMemoryBound(to: Float.self)
            channel += 1
        }

        if !kernel.pointee.bypassed.pointee.load(ordering: .relaxed) {
            var block = AudioBlock(channels: UnsafePointer(channels), channelCount: channelCount, frameCount: frames)
            let context = RenderContext(sampleRate: SampleRate(kernel.pointee.sampleRate), position: FramePosition(kernel.pointee.position),
                                        events: EventList(events: UnsafePointer(kernel.pointee.events), count: passed))
            kernel.pointee.processor.pointee.process(&block, context)
        }
        kernel.pointee.position += Int64(frames)
        return noErr
    }

    // MARK: State

    /// The plug-in's state as this library stores it.
    public var pluginState: PluginState {
        get { PluginState(parameters: parameters.snapshot(), processorData: saveData?()) }
        set {
            parameters.restore(newValue.parameters)
            if let data = newValue.processorData { restoreData?(data) }
        }
    }

    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            state[Self.stateKey] = try? JSONEncoder().encode(pluginState)
            return state
        }
        set {
            super.fullState = newValue
            if let data = newValue?[Self.stateKey] as? Data, let state = try? JSONDecoder().decode(PluginState.self, from: data) {
                pluginState = state
            }
        }
    }
}
