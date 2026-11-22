import AudioAppCore
import AudioAppRenderAhead
import Foundation

/// Reads a file a block at a time for an `AheadLane`. A block that cannot be read is silence.
public struct FileProducer: AheadProducer {
    let reader: AudioFileReader

    public init(_ reader: AudioFileReader) { self.reader = reader }

    public mutating func produce(at position: FramePosition, into output: AudioBlock) {
        if reader.position != Int(position.frames) { reader.seek(to: Int(position.frames)) }
        if (try? reader.read(into: output)) == nil { output.clear() }
    }

    public mutating func seek(to position: FramePosition) {
        reader.seek(to: Int(position.frames))
    }
}

/// Plays a file of any length without the disk ever touching the audio thread. A worker
/// reads ahead of the playhead; the audio thread copies what is ready.
///
/// The file plays at its own sample rate. If that differs from the device's, convert the
/// file first with `SampleRateConverter`.
public final class StreamingFileSource: @unchecked Sendable {
    public let url: URL
    public let format: Format
    /// The file's length in frames.
    public let frameCount: Int
    public let lane: AheadLane<FileProducer>

    /// - Parameters:
    ///   - blockFrames: how much is read from disk at a time.
    ///   - aheadFrames: how far ahead of the playhead to keep read. The default is about a
    ///     third of a second at 48 kHz.
    public init(url: URL, blockFrames: Int = 4_096, aheadFrames: Int = 16_384) throws {
        let reader = try AudioFileReader(url: url)
        self.url = url
        format = reader.format
        frameCount = reader.frameCount
        lane = AheadLane(FileProducer(reader), format: reader.format, blockFrames: blockFrames,
                         aheadFrames: aheadFrames, frameCount: reader.frameCount)
    }

    /// What the audio thread reads from.
    public var reader: AheadReader { lane.reader }

    /// The file as a processor, to add to a graph as a source node.
    public func makeSource() -> AheadSource { AheadSource(lane) }

    /// Starts reading ahead, and waits until the first audio is ready.
    public func start() {
        lane.start()
        lane.waitUntilReady()
    }

    public func stop() { lane.stop() }

    /// Moves the playhead. Reads return silence until the new position has been read from
    /// disk; pass `wait` to hold until it has.
    public func seek(to frame: Int, wait: Bool = false) {
        lane.seek(to: FramePosition(Int64(min(max(frame, 0), frameCount))))
        if wait, lane.isRunning { lane.waitUntilReady() }
    }

    /// The frame the next read starts from.
    public var position: Int { Int(lane.position.frames) }

    public var isAtEnd: Bool { position >= frameCount }

    public var diagnostics: AheadDiagnostics { lane.diagnostics }
}
