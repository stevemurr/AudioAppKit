import AudioAppCore
import Foundation

extension WaveformBuilder {
    /// Builds the overview of an audio file, reading it a piece at a time so a long file
    /// never has to fit in memory. Call away from the main thread for anything long.
    /// - Parameter progress: called with the fraction read so far, from 0 to 1.
    public static func overview(ofFileAt url: URL, framesPerBucket: Int = 256, factor: Int = 4,
                                progress: ((Double) -> Void)? = nil) throws -> WaveformOverview {
        let reader = try AudioFileReader(url: url)
        var builder = WaveformBuilder(channelCount: reader.format.channelCount, sampleRate: reader.format.sampleRate.hertz,
                                      framesPerBucket: framesPerBucket, factor: factor)
        let piece = SampleBuffer(channelCount: reader.format.channelCount, frameCapacity: 65_536)
        var done = 0
        while done < reader.frameCount {
            let frames = try reader.read(into: piece.block)
            guard frames > 0 else { break }
            builder.append(piece.block(frames: frames))
            done += frames
            progress?(Double(done) / Double(max(1, reader.frameCount)))
        }
        return builder.overview()
    }
}
