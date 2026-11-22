import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

@Suite struct IOWaveformTests {
    @Test func aFileOverviewMatchesTheOverviewOfItsSamples() throws {
        let rate: SampleRate = 48_000
        let frames = 150_000
        let buffer = SampleBuffer([TestSignal.sine(frequency: 220, sampleRate: rate, frames: frames, amplitude: 0.5),
                                   TestSignal.noise(frames: frames, amplitude: 0.25)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aak-waveform-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try buffer.write(to: url, sampleRate: rate)

        var reported: [Double] = []
        let fromFile = try WaveformBuilder.overview(ofFileAt: url) { reported.append($0) }
        let direct = WaveformBuilder.overview(of: buffer, sampleRate: rate.hertz)
        #expect(fromFile == direct)
        #expect(fromFile.frameCount == frames)
        #expect(reported.last == 1)
        #expect(reported == reported.sorted())
    }
}
