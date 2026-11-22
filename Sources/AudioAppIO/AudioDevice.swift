#if os(macOS)
import AudioAppCore
import CoreAudio
import Foundation

/// An audio input or output attached to the Mac.
public struct AudioDevice: Hashable, Sendable, Identifiable {
    /// Core Audio's number for the device. It changes when the device is reconnected.
    public let id: AudioDeviceID
    /// A name for the device that survives reconnection and restarts. Store this, not `id`.
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let sampleRate: SampleRate
    public let availableSampleRates: [SampleRate]
    /// How many frames the device asks for at a time.
    public let bufferFrames: Int
    public let bufferFrameRange: ClosedRange<Int>

    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }

    /// Reads a device's details as they are now, or nil if it has gone.
    public init?(id: AudioDeviceID) {
        guard let uid: String = HAL.string(id, kAudioDevicePropertyDeviceUID),
              let name: String = HAL.string(id, kAudioObjectPropertyName) else { return nil }
        self.id = id
        self.uid = uid
        self.name = name
        inputChannels = HAL.channels(id, scope: kAudioObjectPropertyScopeInput)
        outputChannels = HAL.channels(id, scope: kAudioObjectPropertyScopeOutput)
        sampleRate = SampleRate(HAL.value(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 0)
        let ranges = HAL.array(id, kAudioDevicePropertyAvailableNominalSampleRates, of: AudioValueRange.self)
        let common: [Double] = [8_000, 11_025, 16_000, 22_050, 32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
        // A device lists single rates, or spans within which the usual rates are offered.
        var rates = Set<Double>()
        for range in ranges {
            if range.mMinimum == range.mMaximum { rates.insert(range.mMinimum) }
            else { for rate in common where rate >= range.mMinimum && rate <= range.mMaximum { rates.insert(rate) } }
        }
        availableSampleRates = rates.sorted().map { SampleRate($0) }
        bufferFrames = Int(HAL.value(id, kAudioDevicePropertyBufferFrameSize, as: UInt32.self) ?? 0)
        let range = HAL.value(id, kAudioDevicePropertyBufferFrameSizeRange, as: AudioValueRange.self)
        bufferFrameRange = Int(range?.mMinimum ?? 0)...Int(max(range?.mMaximum ?? 0, range?.mMinimum ?? 0))
    }

    /// Asks the device to run at another sample rate. Other apps using the device are
    /// affected too. The change is not instant; read the device again to see it.
    public func setSampleRate(_ rate: SampleRate) throws {
        try HAL.set(id, kAudioDevicePropertyNominalSampleRate, Float64(rate.hertz))
    }

    /// Asks the device for another buffer size, clamped to what it allows. Smaller means
    /// less delay and less time for each callback.
    public func setBufferFrames(_ frames: Int) throws {
        let clamped = min(max(frames, bufferFrameRange.lowerBound), bufferFrameRange.upperBound)
        try HAL.set(id, kAudioDevicePropertyBufferFrameSize, UInt32(clamped))
    }
}

public struct AudioDeviceError: Error, Equatable {
    public let status: OSStatus
    public let action: String
}

/// The audio devices attached to the Mac, and notice when they change.
public final class DeviceList: @unchecked Sendable {
    /// Every device, inputs and outputs together.
    public static func all() -> [AudioDevice] {
        HAL.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioDeviceID.self)
            .compactMap(AudioDevice.init(id:))
    }

    public static func outputs() -> [AudioDevice] { all().filter(\.hasOutput) }
    public static func inputs() -> [AudioDevice] { all().filter(\.hasInput) }

    /// The device the system plays through, if there is one.
    public static var defaultOutput: AudioDevice? {
        HAL.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioDeviceID.self)
            .flatMap { $0 == kAudioObjectUnknown ? nil : AudioDevice(id: $0) }
    }

    /// The device the system records from, if there is one.
    public static var defaultInput: AudioDevice? {
        HAL.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, as: AudioDeviceID.self)
            .flatMap { $0 == kAudioObjectUnknown ? nil : AudioDevice(id: $0) }
    }

    /// Finds a device by the name that survives reconnection.
    public static func device(uid: String) -> AudioDevice? { all().first { $0.uid == uid } }

    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "AudioAppKit.DeviceList")
    private var listener: AudioObjectPropertyListenerBlock?
    private static let watched = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                                  kAudioHardwarePropertyDefaultInputDevice]

    /// Watches for devices arriving, leaving, or the default changing. `onChange` is called
    /// on a background queue; read the list again from there. Watching stops when this
    /// object goes away.
    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        listener = block
        for selector in Self.watched {
            var address = HAL.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
    }

    deinit {
        guard let listener else { return }
        for selector in Self.watched {
            var address = HAL.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }
}

/// Reading and writing Core Audio device properties.
enum HAL {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as type: T.Type,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage) == noErr,
              size == UInt32(MemoryLayout<T>.size) else { return nil }
        return storage.move()
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, of type: T.Type,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let storage = UnsafeMutablePointer<T>.allocate(capacity: max(1, count))
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: storage, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var result: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    /// How many channels a device has in one direction, across all its streams.
    static func channels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) throws {
        var address = address(selector)
        let status = withUnsafePointer(to: value) {
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), UnsafeRawPointer($0))
        }
        guard status == noErr else { throw AudioDeviceError(status: status, action: "set property \(selector)") }
    }
}
#endif
