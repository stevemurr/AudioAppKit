import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

@Suite struct WaveformTests {
    @Test func bucketsHoldTheExtremesAndAverageOfTheirFrames() {
        // 8 frames per bucket: a bucket of +0.5, a bucket ramping, and a short last bucket.
        let samples: [Float] = [Float](repeating: 0.5, count: 8) + [-1, -0.5, 0, 0.25, 0.5, 0.75, 1, 0] + [0.2, -0.2]
        let overview = WaveformBuilder.overview(of: AudioBuffer([samples]), sampleRate: 48_000, framesPerBucket: 8, factor: 2)
        #expect(overview.frameCount == 18)
        let finest = overview.levels[0].channels[0]
        #expect(finest.count == 3)
        #expect(finest[0] == .init(min: 0.5, max: 0.5, rms: 0.5))
        #expect(finest[1].min == -1 && finest[1].max == 1)
        #expect(close(finest[2].rms, 0.2))

        // Each coarser level halves the count until one bucket holds everything.
        #expect(overview.levels.map(\.framesPerBucket) == [8, 16, 32])
        #expect(overview.levels.map { $0.channels[0].count } == [3, 2, 1])
        let whole = overview.levels[2].channels[0][0]
        #expect(whole.min == -1 && whole.max == 1)
        #expect(close(whole.rms, Measure.rms(samples), within: 1e-5))
    }

    @Test func appendingInPiecesMatchesBuildingAtOnce() {
        let noise = TestSignal.noise(frames: 10_000, amplitude: 0.8)
        let buffer = AudioBuffer([noise, noise.reversed()])
        let whole = WaveformBuilder.overview(of: buffer, sampleRate: 44_100)
        var builder = WaveformBuilder(channelCount: 2, sampleRate: 44_100)
        var done = 0
        for size in [1, 255, 256, 257, 4_000, 5_231] {
            builder.append(buffer.block(from: done, frames: size))
            done += size
        }
        #expect(done == 10_000)
        #expect(builder.overview() == whole)
        // The builder carries on after an overview is taken, as during a recording.
        builder.append(buffer.block(from: 0, frames: 100))
        #expect(builder.overview().frameCount == 10_100)
    }

    @Test func aQueryPicksTheCoarsestLevelThatStillResolvesAPixel() {
        let overview = WaveformBuilder.overview(of: AudioBuffer([TestSignal.noise(frames: 100_000)]), sampleRate: 48_000)
        #expect(overview.levels.map(\.framesPerBucket).prefix(4) == [256, 1_024, 4_096, 16_384])
        #expect(overview.levelIndex(framesPerPixel: 10) == 0)
        #expect(overview.levelIndex(framesPerPixel: 256) == 0)
        #expect(overview.levelIndex(framesPerPixel: 1_500) == 1)
        #expect(overview.levelIndex(framesPerPixel: 5_000) == 2)
    }

    @Test func aQueryGivesOneBucketPerPixelAndSilencePastTheEnd() {
        // A burst in the second quarter of the recording.
        var samples = [Float](repeating: 0, count: 40_000)
        for index in 10_000..<20_000 { samples[index] = index % 2 == 0 ? 0.9 : -0.9 }
        let overview = WaveformBuilder.overview(of: AudioBuffer([samples]), sampleRate: 48_000, framesPerBucket: 100, factor: 4)
        let drawn = overview.buckets(channel: 0, frames: 0..<40_000, width: 40)
        #expect(drawn.count == 40)
        #expect(drawn[5] == .silent)
        #expect(drawn[12].max == 0.9 && drawn[12].min == -0.9 && close(drawn[12].rms, 0.9))
        #expect(drawn[25] == .silent)

        // Zoomed in past the finest level, pixels repeat the bucket they fall in.
        let close = overview.buckets(channel: 0, frames: 10_000..<10_050, width: 50)
        #expect(close.allSatisfy { $0.max == 0.9 })
        // A view that runs past the end, a missing channel and a zero width.
        let past = overview.buckets(channel: 0, frames: 30_000..<50_000, width: 20)
        #expect(past.count == 20 && past[15] == .silent)
        #expect(overview.buckets(channel: 3, frames: 0..<100, width: 4) == [WaveformOverview.Bucket](repeating: .silent, count: 4))
        #expect(overview.buckets(channel: 0, frames: 0..<100, width: 0).isEmpty)
    }

    @Test func overviewsCacheAsJSON() throws {
        let overview = WaveformBuilder.overview(of: AudioBuffer([TestSignal.noise(frames: 3_000), TestSignal.silence(frames: 3_000)]), sampleRate: 96_000)
        let decoded = try JSONDecoder().decode(WaveformOverview.self, from: JSONEncoder().encode(overview))
        #expect(decoded == overview)
        #expect(decoded.sampleRate == 96_000 && decoded.channelCount == 2)
    }

    @Test func anEmptyRecordingHasOneEmptyLevel() {
        let overview = WaveformBuilder(channelCount: 2, sampleRate: 48_000).overview()
        #expect(overview.frameCount == 0)
        #expect(overview.levels.count == 1)
        #expect(overview.buckets(channel: 0, frames: 0..<10, width: 5) == [WaveformOverview.Bucket](repeating: .silent, count: 5))
    }
}
