import AudioAppKit
import AudioAppTesting
import Testing

@Suite struct CoreTests {
    @Test func decibelsConvertBothWays() {
        #expect(close(Decibels(6.0206).gain, 2, within: 1e-4))
        #expect(close(Decibels(gain: 0.5).value, -6.0206, within: 1e-3))
        #expect(close(Decibels(power: 0.5).value, -3.0103, within: 1e-3))
        #expect(close(Decibels(-20).power, 0.01, within: 1e-6))
        #expect(Decibels(gain: 0).value == -200)
    }

    @Test func sampleRateCountsFrames() {
        let rate: SampleRate = 44_100
        #expect(rate.frames(in: 0.5) == 22_050)
        #expect(rate.seconds(in: 44_100) == 1)
        #expect(FramePosition(96_000).seconds(at: 48_000) == 2)
    }

    @Test(arguments: [Taper.linear, .logarithmic, .skewed(2), .skewed(0.5)])
    func taperRoundTrips(taper: Taper) {
        let range: ClosedRange<Float> = 20...20_000
        #expect(close(taper.value(at: 0, in: range), 20, within: 1e-2))
        #expect(close(taper.value(at: 1, in: range), 20_000, within: 1))
        for position in stride(from: Float(0.05), through: 0.95, by: 0.15) {
            let value = taper.value(at: position, in: range)
            #expect(close(taper.position(of: value, in: range), position, within: 1e-3))
        }
    }

    @Test func logarithmicTaperPutsTheGeometricMiddleHalfway() {
        #expect(close(Taper.logarithmic.value(at: 0.5, in: 20...20_000), 632.46, within: 0.1))
    }

    @Test func blockSlicesAndSums() {
        let a = AudioBuffer([[1, 2, 3, 4], [10, 20, 30, 40]])
        let b = AudioBuffer([[1, 1, 1, 1], [2, 2, 2, 2]])
        a.block.add(b.block, gain: 0.5)
        #expect(a.samples(channel: 0) == [1.5, 2.5, 3.5, 4.5])
        #expect(a.samples(channel: 1) == [11, 21, 31, 41])

        let middle = a.block.slice(from: 1, count: 2)
        middle.scale(by: 2)
        #expect(a.samples(channel: 0) == [1.5, 5, 7, 4.5])
        #expect(a.block.slice(from: 3, count: 10).frameCount == 1)
    }

    @Test func monoSourceReachesEveryChannelAndMissingChannelsClear() {
        let mono = AudioBuffer([[1, 2]])
        let wide = AudioBuffer([[0, 0], [5, 5]])
        wide.block.add(mono.block)
        #expect(wide.samples(channel: 0) == [1, 2])
        #expect(wide.samples(channel: 1) == [6, 7])
        wide.block.copy(from: mono.block)
        #expect(wide.samples(channel: 0) == [1, 2])
        #expect(wide.samples(channel: 1) == [0, 0])
    }
}
