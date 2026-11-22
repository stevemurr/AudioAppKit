import AudioAppCore
@preconcurrency import AVFoundation

public enum AudioFileError: Error, Equatable {
    case cannotOpen(String)
    case cannotCreate(String)
    case readFailed(String)
    case writeFailed(String)
    case unsupportedFormat(String)
}

/// The processing format Core Audio uses for a rate and channel count: 32-bit float, one
/// buffer per channel. More than two channels are declared as discrete, not as speakers.
func standardFormat(sampleRate: Double, channels: Int) -> AVAudioFormat? {
    if channels <= 2 { return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) }
    guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) else { return nil }
    return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
}

/// Reads audio from a file in any format Core Audio can open, as 32-bit float at the file's
/// own sample rate. Not for the audio thread: use `StreamingFileSource` to play a file.
public final class AudioFileReader {
    public let url: URL
    public let format: Format
    /// The file's length in frames.
    public let frameCount: Int
    private let file: AVAudioFile
    private var scratch: AVAudioPCMBuffer?

    public init(url: URL) throws {
        self.url = url
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioFileError.cannotOpen("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        format = Format(sampleRate: SampleRate(file.processingFormat.sampleRate),
                        layout: .discrete(Int(file.processingFormat.channelCount)))
        frameCount = Int(file.length)
    }

    /// The frame the next read starts from.
    public var position: Int { Int(file.framePosition) }

    /// Moves to a frame, clamped to the file.
    public func seek(to frame: Int) {
        file.framePosition = AVAudioFramePosition(min(max(frame, 0), frameCount))
    }

    public var seconds: Double { Double(frameCount) / format.sampleRate.hertz }

    /// Reads the next frames into a block, filling what the file cannot supply with silence.
    /// - Returns: how many frames came from the file.
    @discardableResult public func read(into block: AudioBlock) throws -> Int {
        let wanted = min(block.frameCount, frameCount - position)
        guard wanted > 0 else {
            block.clear()
            return 0
        }
        if scratch == nil || Int(scratch!.frameCapacity) < wanted {
            scratch = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(wanted, 4_096)))
        }
        guard let scratch, let channels = scratch.floatChannelData else { throw AudioFileError.readFailed(url.lastPathComponent) }
        var done = 0
        // A read may return fewer frames than asked, so keep going until the request is met.
        while done < wanted {
            do {
                try file.read(into: scratch, frameCount: AVAudioFrameCount(wanted - done))
            } catch {
                throw AudioFileError.readFailed("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            let got = Int(scratch.frameLength)
            guard got > 0 else { break }
            for channel in 0..<block.channelCount {
                let target = block[channel]
                if channel < format.channelCount {
                    for frame in 0..<got { target[done + frame] = channels[channel][frame] }
                } else {
                    for frame in 0..<got { target[done + frame] = 0 }
                }
            }
            done += got
        }
        block.slice(from: done, count: block.frameCount - done).clear()
        return done
    }

    /// Reads frames into a new buffer, from the current position.
    public func read(frames: Int) throws -> SampleBuffer {
        let buffer = SampleBuffer(channelCount: format.channelCount, frameCapacity: max(0, min(frames, frameCount - position)))
        try read(into: buffer.block)
        return buffer
    }

    /// Reads the whole file into a new buffer.
    public func readAll() throws -> SampleBuffer {
        seek(to: 0)
        return try read(frames: frameCount)
    }
}

/// Writes audio to a WAV, AIFF or CAF file. Not for the audio thread.
public final class AudioFileWriter {
    public enum FileType: Sendable {
        case wav, aiff, caf

        /// The type a file extension names, if it is one of these.
        public init?(pathExtension: String) {
            switch pathExtension.lowercased() {
            case "wav", "wave": self = .wav
            case "aif", "aiff": self = .aiff
            case "caf": self = .caf
            default: return nil
            }
        }
    }

    public enum SampleFormat: Sendable {
        case int16, int24, float32

        var bits: Int {
            switch self {
            case .int16: return 16
            case .int24: return 24
            case .float32: return 32
            }
        }
    }

    public let url: URL
    public let format: Format
    public private(set) var framesWritten = 0
    private var file: AVAudioFile?
    private let processing: AVAudioFormat
    private var scratch: AVAudioPCMBuffer?

    /// Creates the file, replacing one already there. The container follows the URL's
    /// extension unless `type` says otherwise.
    public init(url: URL, format: Format, sampleFormat: SampleFormat = .float32, type: FileType? = nil) throws {
        guard let type = type ?? FileType(pathExtension: url.pathExtension) else {
            throw AudioFileError.unsupportedFormat("\(url.lastPathComponent): use .wav, .aiff or .caf")
        }
        guard let processing = standardFormat(sampleRate: format.sampleRate.hertz, channels: format.channelCount) else {
            throw AudioFileError.unsupportedFormat("\(format.channelCount) channels")
        }
        if type == .aiff, sampleFormat == .float32 {
            throw AudioFileError.unsupportedFormat("AIFF holds 16-bit or 24-bit audio; use WAV or CAF for float")
        }
        self.url = url
        self.format = format
        self.processing = processing
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate.hertz,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: sampleFormat.bits,
            AVLinearPCMIsFloatKey: sampleFormat == .float32,
            AVLinearPCMIsBigEndianKey: type == .aiff,
            AVLinearPCMIsNonInterleaved: false
        ]
        if format.channelCount > 2, let layout = processing.channelLayout {
            settings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioFileError.cannotCreate("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Appends a block. Channels the block lacks are written as silence.
    public func write(_ block: AudioBlock) throws {
        guard let file else { throw AudioFileError.writeFailed("\(url.lastPathComponent) is closed") }
        guard block.frameCount > 0 else { return }
        if scratch == nil || Int(scratch!.frameCapacity) < block.frameCount {
            scratch = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: AVAudioFrameCount(max(block.frameCount, 4_096)))
        }
        guard let scratch, let channels = scratch.floatChannelData else { throw AudioFileError.writeFailed(url.lastPathComponent) }
        scratch.frameLength = AVAudioFrameCount(block.frameCount)
        for channel in 0..<format.channelCount {
            if channel < block.channelCount {
                let source = block[channel]
                for frame in 0..<block.frameCount { channels[channel][frame] = source[frame] }
            } else {
                for frame in 0..<block.frameCount { channels[channel][frame] = 0 }
            }
        }
        do {
            try file.write(from: scratch)
        } catch {
            throw AudioFileError.writeFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        framesWritten += block.frameCount
    }

    /// Appends a whole buffer.
    public func write(_ buffer: SampleBuffer) throws {
        try write(buffer.block)
    }

    /// Finishes the file. Writing after this throws. Also happens when the writer goes away.
    public func close() {
        file?.close()
        file = nil
    }

    deinit { file?.close() }
}

extension SampleBuffer {
    /// Writes the buffer to a new file.
    public func write(to url: URL, sampleRate: SampleRate, sampleFormat: AudioFileWriter.SampleFormat = .float32) throws {
        let writer = try AudioFileWriter(url: url, format: Format(sampleRate: sampleRate, layout: .discrete(channelCount)),
                                         sampleFormat: sampleFormat)
        try writer.write(self)
        writer.close()
    }
}
