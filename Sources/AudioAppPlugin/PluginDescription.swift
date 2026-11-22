import AudioAppKit
import AudioToolbox
import Foundation

/// What a plug-in tells a host about itself.
public struct PluginDescription: Sendable {
    public var name: String
    public var manufacturerName: String
    /// Four characters naming this plug-in, unique within the manufacturer.
    public var subtype: String
    /// Four characters naming the manufacturer.
    public var manufacturer: String
    public var version: UInt32
    /// The kind of Audio Unit. Effects take audio in and give audio out.
    public var type: FourCharCode
    public var channelCount: Int
    /// How long the output carries on after the input stops, such as a reverb's decay.
    public var tailSeconds: Double

    public init(name: String, manufacturerName: String, subtype: String, manufacturer: String, version: UInt32 = 1,
                type: FourCharCode = kAudioUnitType_Effect, channelCount: Int = 2, tailSeconds: Double = 0) {
        self.name = name
        self.manufacturerName = manufacturerName
        self.subtype = subtype
        self.manufacturer = manufacturer
        self.version = version
        self.type = type
        self.channelCount = max(1, channelCount)
        self.tailSeconds = tailSeconds
    }

    /// A four-character code from a string. Short strings are padded with spaces.
    public static func fourCharCode(_ string: String) -> FourCharCode {
        var code: FourCharCode = 0
        let bytes = Array(string.utf8.prefix(4)) + [UInt8](repeating: 0x20, count: max(0, 4 - string.utf8.count))
        for byte in bytes { code = code << 8 | FourCharCode(byte) }
        return code
    }

    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: Self.fourCharCode(subtype),
                                  componentManufacturer: Self.fourCharCode(manufacturer), componentFlags: 0, componentFlagsMask: 0)
    }

    /// A parameter or group id in the form hosts accept: letters, digits and underscores,
    /// not starting with a digit.
    public static func hostIdentifier(_ id: String) -> String {
        let cleaned = String(id.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        return cleaned.first.map(\.isNumber) == true || cleaned.isEmpty ? "_" + cleaned : cleaned
    }

    /// The name hosts list the plug-in under.
    public var componentName: String { "\(manufacturerName): \(name)" }
}

/// Everything a host saves for a plug-in and hands back later: the parameter values, and
/// whatever else the processor needs that is not a parameter.
public struct PluginState: Codable, Equatable, Sendable {
    public var parameters: ParameterSnapshot
    public var processorData: Data?

    public init(parameters: ParameterSnapshot, processorData: Data? = nil) {
        self.parameters = parameters
        self.processorData = processorData
    }
}

/// One running copy of a plug-in: the processor, and the parameters it reads.
public struct PluginInstance<P: Processor & ~Copyable>: ~Copyable {
    public var processor: P
    public let parameters: ParameterTree
    /// Returns state beyond the parameters for the host to save, such as a loaded file's name.
    public var saveData: (@Sendable () -> Data?)?
    /// Takes back what `saveData` returned.
    public var restoreData: (@Sendable (Data) -> Void)?

    public init(processor: consuming P, parameters: ParameterTree,
                saveData: (@Sendable () -> Data?)? = nil, restoreData: (@Sendable (Data) -> Void)? = nil) {
        self.processor = processor
        self.parameters = parameters
        self.saveData = saveData
        self.restoreData = restoreData
    }
}
