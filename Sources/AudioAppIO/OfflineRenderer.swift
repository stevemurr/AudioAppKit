import AudioAppCore
import AudioAppProcessing
@preconcurrency import AVFoundation

/// Renders without a device, as fast as the machine allows: for bouncing to a file, for
/// analysis, and for tests. Every block's context has `isOffline` set.
public enum OfflineRenderer {
    /// What a render function is handed for each block: the input if there is any, the block
    /// to fill, and where on the timeline it falls.
    public typealias Render = (_ input: AudioBlock?, _ output: AudioBlock, _ context: RenderContext) -> Void

    /// Calls `body` once per block across a stretch of timeline.
    static func forEachBlock(frames: Int, sampleRate: SampleRate, blockSize: Int, start: FramePosition,
                             _ body: (_ offset: Int, _ count: Int, _ context: RenderContext) throws -> Void) rethrows {
        let size = max(1, blockSize)
        var done = 0
        while done < frames {
            let count = min(size, frames - done)
            let position = start + done
            let context = RenderContext(sampleRate: sampleRate, position: position,
                                        transport: Transport(isPlaying: true, position: position), isOffline: true)
            try body(done, count, context)
            done += count
        }
    }

    /// Renders with a function of your own, such as one that fills a render-ahead lane and
    /// then renders a graph.
    /// - Parameter input: audio fed in block by block, or nil.
    public static func render(frames: Int, format: Format, blockSize: Int = 512, input: SampleBuffer? = nil,
                              start: FramePosition = 0, _ render: Render) -> SampleBuffer {
        let output = SampleBuffer(channelCount: format.channelCount, frameCapacity: max(0, frames))
        forEachBlock(frames: frames, sampleRate: format.sampleRate, blockSize: blockSize, start: start) { offset, count, context in
            render(input?.block(from: offset, frames: count), output.block(from: offset, frames: count), context)
        }
        return output
    }

    /// Renders a graph.
    public static func render<Node: Processor & ~Copyable>(_ renderer: GraphRenderer<Node>, frames: Int, format: Format,
                                                           blockSize: Int = 512, input: SampleBuffer? = nil,
                                                           start: FramePosition = 0) -> SampleBuffer {
        render(frames: frames, format: format, blockSize: blockSize, input: input, start: start) { input, output, context in
            renderer.render(input: input, output: output, context: context)
        }
    }

    /// Runs audio through a processor, preparing it first. With no input the processor is
    /// handed silence, which suits a source.
    public static func render<P: Processor & ~Copyable>(_ processor: inout P, frames: Int, format: Format,
                                                        blockSize: Int = 512, input: SampleBuffer? = nil,
                                                        start: FramePosition = 0) -> SampleBuffer {
        processor.prepare(format, maxFrames: max(1, blockSize))
        let output = SampleBuffer(channelCount: format.channelCount, frameCapacity: max(0, frames))
        forEachBlock(frames: frames, sampleRate: format.sampleRate, blockSize: blockSize, start: start) { offset, count, context in
            var block = output.block(from: offset, frames: count)
            if let input { block.copy(from: input.block(from: offset, frames: count)) }
            processor.process(&block, context)
        }
        return output
    }

    /// Renders straight to a file, a block at a time, so the length is not limited by memory.
    public static func render(to writer: AudioFileWriter, frames: Int, blockSize: Int = 4_096, input: SampleBuffer? = nil,
                              start: FramePosition = 0, _ render: Render) throws {
        let scratch = SampleBuffer(channelCount: writer.format.channelCount, frameCapacity: max(1, blockSize))
        try forEachBlock(frames: frames, sampleRate: writer.format.sampleRate, blockSize: blockSize, start: start) { offset, count, context in
            let block = scratch.block(frames: count)
            render(input?.block(from: offset, frames: count), block, context)
            try writer.write(block)
        }
    }
}

/// Changes the sample rate of audio that is already in memory or on disk. Not for the audio
/// thread, and not for following a drifting clock.
public enum SampleRateConverter {
    public enum Quality: Sendable {
        case low, medium, high, best

        var value: Int {
            switch self {
            case .low: return AVAudioQuality.low.rawValue
            case .medium: return AVAudioQuality.medium.rawValue
            case .high: return AVAudioQuality.high.rawValue
            case .best: return AVAudioQuality.max.rawValue
            }
        }
    }

    /// Returns the buffer's audio at another rate. The result is the input's length scaled
    /// by the ratio of the rates, to the nearest frame.
    public static func convert(_ buffer: SampleBuffer, from source: SampleRate, to target: SampleRate,
                               quality: Quality = .best) throws -> SampleBuffer {
        let frames = buffer.frameCapacity
        let wanted = Int((Double(frames) * target.hertz / source.hertz).rounded())
        let result = SampleBuffer(channelCount: buffer.channelCount, frameCapacity: wanted)
        guard source != target else {
            result.block.copy(from: buffer.block)
            return result
        }
        guard frames > 0, wanted > 0 else { return result }
        guard let inputFormat = standardFormat(sampleRate: source.hertz, channels: buffer.channelCount),
              let outputFormat = standardFormat(sampleRate: target.hertz, channels: buffer.channelCount),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(wanted + 4_096)),
              let inputChannels = input.floatChannelData, let outputChannels = output.floatChannelData else {
            throw AudioFileError.unsupportedFormat("\(buffer.channelCount) channels from \(source.hertz) to \(target.hertz) Hz")
        }
        converter.sampleRateConverterQuality = quality.value
        // Start the filter primed, so the output lines up with the input from its first frame.
        converter.primeMethod = .none
        for channel in 0..<buffer.channelCount {
            let samples = buffer.block[channel]
            for frame in 0..<frames { inputChannels[channel][frame] = samples[frame] }
        }
        input.frameLength = AVAudioFrameCount(frames)

        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let source = input
        var failure: NSError?
        var written = 0
        // The converter is pulled until it has given back everything, including its tail.
        while written < wanted {
            output.frameLength = 0
            let status = converter.convert(to: output, error: &failure) { _, state in
                if supplied {
                    state.pointee = .endOfStream
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return source
            }
            if status == .error { throw AudioFileError.readFailed(failure?.localizedDescription ?? "conversion failed") }
            let got = min(Int(output.frameLength), wanted - written)
            for channel in 0..<buffer.channelCount {
                let target = result.block[channel]
                for frame in 0..<got { target[written + frame] = outputChannels[channel][frame] }
            }
            written += got
            if status == .endOfStream || (got == 0 && status != .haveData) { break }
        }
        return result
    }

    /// Writes a copy of a file at another sample rate.
    public static func convertFile(from source: URL, to target: URL, sampleRate: SampleRate, quality: Quality = .best,
                                   sampleFormat: AudioFileWriter.SampleFormat = .float32) throws {
        let reader = try AudioFileReader(url: source)
        let converted = try convert(reader.readAll(), from: reader.format.sampleRate, to: sampleRate, quality: quality)
        try converted.write(to: target, sampleRate: sampleRate, sampleFormat: sampleFormat)
    }
}
