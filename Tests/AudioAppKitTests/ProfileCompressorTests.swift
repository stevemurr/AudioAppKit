import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

/// A compressor whose character is data: how its reduction moves, over arrays and a block at a time.
@Suite struct ProfileCompressorTests {
    let rate: SampleRate = 48_000

    func plain(attackMs: Double = 10, releaseMs: Double = 100) -> CompressorCharacter {
        CompressorCharacter(isPeak: true, ratio: 4, attackMs: attackMs, releaseMs: releaseMs)
    }

    /// The reduction for a level held for a while and then dropped to nothing.
    func burst(_ character: CompressorCharacter, over: Float = 12, held: Int, after: Int) -> [Float] {
        let levels = [Float](repeating: -20 + over, count: held) + [Float](repeating: -120, count: after)
        return character.movement(sampleRate: rate).reduction(levels: levels, thresholdDB: -20)
    }

    @Test func theStaticCurveFollowsTheRatioAndEasesInOverTheKnee() {
        let slope = 1 - 1 / 4.0
        #expect(CompressorMovement.staticReduction(over: -10, slope: slope, knee: 6) == 0)
        #expect(CompressorMovement.staticReduction(over: 10, slope: slope, knee: 6) == 7.5)
        #expect(abs(CompressorMovement.staticReduction(over: 3, slope: slope, knee: 6) - slope * 3) < 1e-12)
        #expect(CompressorMovement.staticReduction(over: -3, slope: slope, knee: 6) == 0)
        #expect(abs(CompressorMovement.staticReduction(over: 0, slope: slope, knee: 6) - slope * 9 / 12) < 1e-12)
        #expect(CompressorMovement.staticReduction(over: 0, slope: slope, knee: 0) == 0)
    }

    @Test func aPlainCharacterArrivesAndLeavesOnItsTimes() {
        let gr = burst(plain(), held: 48_000, after: 48_000)
        // 12 dB over at 4:1 settles at 9 dB; after one attack time it is 63% there, after one release 63% gone.
        #expect(abs(gr[479] - 9 * Float(1 - exp(-1.0))) < 0.02)
        #expect(abs(gr[47_999] - 9) < 1e-3)
        #expect(abs(gr[48_000 + 4_799] - 9 * Float(exp(-1.0))) < 0.02)
        #expect(gr[95_999] < 1e-3)
        // No times at all: the reduction is the static curve at once.
        let instant = burst(CompressorCharacter(isPeak: false, rmsMs: 30, ratio: 4, attackMs: 0, releaseMs: 0), held: 10, after: 10)
        #expect(instant[0] == 9 && instant[10] == 0)
    }

    @Test func anOpticalCellQuickensAsItWorksAndLetsGoWithATail() {
        var cell = CompressorCharacter(isPeak: false, rmsMs: 0.5, ratio: 3, attackMs: 90, releaseMs: 60, tailMs: 1_500, tailMix: 0.33)
        let slow = burst(cell, held: 9_600, after: 96_000)
        cell.attackQ = 7.4
        let quick = burst(cell, held: 9_600, after: 96_000)
        // From rest both start at the same rate; once it holds some reduction the quickened one runs away.
        #expect(abs(quick[2] - slow[2]) < 1e-3)
        #expect(quick[2_400] > slow[2_400] + 1)
        // Half a second after the level drops the fast stage is gone and the slow one still holds most of its share.
        let settled = quick[9_599]
        let later = quick[9_600 + 24_000]
        #expect(later > 0.33 * settled * Float(exp(-0.5 / 1.5)) * 0.8 && later < 0.33 * settled)
    }

    @Test func aSettlingStageGivesABriefPeakOnlyTheFastShare() {
        let fet = CompressorCharacter(isPeak: true, ratio: 4, attackMs: 1.2, releaseMs: 50, tailMs: 1_100, tailMix: 0.25, settleMs: 600)
        // 20 ms: the fast stage is all the way up, the slow one has hardly charged.
        let brief = burst(fet, held: 960, after: 10)
        #expect(abs(brief[959] - 0.75 * 9) < 0.35)
        // Held for three seconds it settles to all of it.
        let held = burst(fet, held: 144_000, after: 48_000)
        #expect(abs(held[143_999] - 9) < 0.1)
        // A quarter is left to drain slowly: 0.2 s on, the fast release is long over.
        let left = held[144_000 + 9_600]
        #expect(left > 0.25 * 9 * Float(exp(-0.2 / 1.1)) * 0.9 && left < 0.25 * 9)
    }

    @Test func withAFloorTheNextNoteHasToClimbBackBeforeAnyReductionStarts() {
        let channel = CompressorCharacter(isPeak: true, ratio: 4, kneeDB: 0, attackMs: 35, releaseMs: 18, floorDB: 5.5)
        let movement = channel.movement(sampleRate: rate)
        let gap = [Float](repeating: -120, count: 48_000)
        let note = [Float](repeating: -8, count: 9_600)
        let gr = movement.reduction(levels: note + gap + note, thresholdDB: -20)
        // After the gap the reduction is nothing, and stays nothing for some milliseconds of the next note.
        #expect(gr[9_600 + 47_999] == 0)
        let start = 9_600 + 48_000
        let dead = (0..<9_600).first { gr[start + $0] > 0 } ?? 0
        #expect(dead > 48 * 5 && dead < 48 * 18)
        // Held, it reaches the static curve's 9 dB.
        #expect(abs(gr[start + 9_599] - 9) < 0.05)
        // A bigger jump gets there sooner.
        let louder = movement.reduction(levels: gap + [Float](repeating: 0, count: 9_600), thresholdDB: -20)
        let sooner = (0..<9_600).first { louder[48_000 + $0] > 0 } ?? 0
        #expect(sooner < dead)
    }

    @Test func theSolverFindsTheThresholdThatGivesTheWantedReductionOnTheLoudParts() {
        // Noise whose level steps between quiet and loud stretches.
        let frames = 96_000
        var signal = TestSignal.noise(frames: frames, amplitude: 0.5, seed: 31)
        for index in 0..<frames where (index / 4_800) % 2 == 0 { signal[index] *= 0.1 }
        let character = CompressorCharacter(isPeak: false, rmsMs: 5, ratio: 4, kneeDB: 6, attackMs: 5, releaseMs: 80)
        let levels = character.detector(sampleRate: rate).levels([signal])
        let movement = character.movement(sampleRate: rate)
        let indices = Array(stride(from: 0, to: frames, by: 32))
        let threshold = try! #require(movement.threshold(reaching: 4, levels: levels, indices: indices))
        let reduction = movement.reduction(levels: levels, thresholdDB: threshold)
        var sampled = indices.map { reduction[$0] }
        #expect(abs(SampleStatistics.percentile(&sampled, 95) - 4) < 0.01)
        // A deeper target needs a lower threshold; a cancelled search gives nothing.
        let deeper = try! #require(movement.threshold(reaching: 8, levels: levels, indices: indices))
        #expect(deeper < threshold)
        #expect(movement.threshold(reaching: 4, levels: levels, indices: indices, isCancelled: { true }) == nil)
    }

    @Test func aPercentileLeansBetweenTheTwoNearestRanks() {
        var values: [Float] = [5, 1, 4, 2, 3]
        #expect(SampleStatistics.percentile(&values, 50) == 3)
        values = [5, 1, 4, 2, 3]
        #expect(SampleStatistics.percentile(&values, 0) == 1)
        values = [5, 1, 4, 2, 3]
        #expect(SampleStatistics.percentile(&values, 100) == 5)
        values = [5, 1, 4, 2, 3]
        #expect(abs(SampleStatistics.percentile(&values, 90) - 4.6) < 1e-9)
        var none: [Float] = []
        #expect(SampleStatistics.percentile(&none, 50) == 0)
        var noise = TestSignal.noise(frames: 1_001, seed: 9)
        let sorted = noise.sorted()
        #expect(SampleStatistics.select(&noise, 250) == sorted[250])
    }

    @Test func aBlockAtATimeIsTheSameArithmeticAsTheWholeSignal() {
        let frames = 30_000
        let left = TestSignal.noise(frames: frames, amplitude: 0.5, seed: 41), right = TestSignal.noise(frames: frames, amplitude: 0.4, seed: 42)
        let character = CompressorCharacter(isPeak: false, rmsMs: 0.5, ratio: 3, kneeDB: 10, attackMs: 90, releaseMs: 60, tailMs: 1_500, tailMix: 0.33, attackQ: 7.4,
                                            toneD2: 4e-3, toneR3: 0.022)
        let settings = ProfileCompressor.Settings(character, thresholdDB: -24, makeupDB: 3, sampleRate: rate)
        let whole = ProfileCompressor.render([left, right], settings)
        var unit = ProfileCompressor()
        unit.configure(sampleRate: rate, glideSeconds: 0.03)
        unit.snap(to: settings)
        var l = left, r = right
        var done = 0, turn = 0, deepest: Float = 0
        let blocks = [64, 511, 1, 2_048]
        while done < frames {
            let count = min(blocks[turn % blocks.count], frames - done)
            let reading = l.withUnsafeMutableBufferPointer { l in
                r.withUnsafeMutableBufferPointer { r in unit.process(l.baseAddress! + done, r.baseAddress! + done, stereo: true, frames: count, settings) }
            }
            deepest = max(deepest, reading?.reductionDB ?? 0)
            done += count
            turn += 1
        }
        #expect(l == whole[0] && r == whole[1])
        #expect(deepest > 1)
        #expect(Measure.isFinite(l))

        // Without colour the output is the input under the gain the levels give: the two halves agree to the bit.
        let clean = ProfileCompressor.Settings(plain(), thresholdDB: -24, makeupDB: 2, sampleRate: rate)
        let out = ProfileCompressor.render([left], clean)[0]
        let levels = plain().detector(sampleRate: rate).levels([left])
        let gr = plain().movement(sampleRate: rate).reduction(levels: levels, thresholdDB: -24)
        #expect(out == (0..<frames).map { left[$0] * exp((2 - gr[$0]) * 0.115_129_255) })
    }

    @Test func oneLoudChannelTurnsBothDownTogether() {
        let loud = TestSignal.sine(frequency: 500, sampleRate: rate, frames: 24_000, amplitude: 0.9)
        let soft = TestSignal.sine(frequency: 700, sampleRate: rate, frames: 24_000, amplitude: 0.01)
        let settings = ProfileCompressor.Settings(plain(attackMs: 1, releaseMs: 500), thresholdDB: -30, sampleRate: rate)
        let out = ProfileCompressor.render([loud, soft], settings)
        let a = Measure.amplitude(of: 500, in: Array(out[0][12_000...]), sampleRate: rate) / 0.9
        let b = Measure.amplitude(of: 700, in: Array(out[1][12_000...]), sampleRate: rate) / 0.01
        #expect(a < 0.2 && abs(a - b) < 0.01 * a)
    }

    @Test func theColourAddsHarmonicsThatGrowWithTheReduction() {
        let frames = 48_000
        let tone = TestSignal.sine(frequency: 1_000, sampleRate: rate, frames: frames, amplitude: 0.5)
        // A third harmonic that comes with the reduction, and a second that is always there.
        var character = CompressorCharacter(isPeak: true, ratio: 4, attackMs: 1, releaseMs: 500, toneD2: 4e-3, toneR3: 0.02)
        let working = ProfileCompressor.render([tone], ProfileCompressor.Settings(character, thresholdDB: -18, sampleRate: rate))[0]
        let resting = ProfileCompressor.render([tone], ProfileCompressor.Settings(character, thresholdDB: 0, sampleRate: rate))[0]
        func harmonic(_ number: Double, _ samples: [Float]) -> Double {
            Measure.amplitude(of: 1_000 * number, in: Array(samples[24_000...]), sampleRate: rate) / Measure.amplitude(of: 1_000, in: Array(samples[24_000...]), sampleRate: rate)
        }
        #expect(harmonic(3, working) > 5 * harmonic(3, resting))
        #expect(harmonic(3, working) > 1e-3)
        #expect(harmonic(2, working) > 1e-4 && harmonic(2, resting) > 1e-5)
        // The second harmonic's steady part is taken out.
        let mean = working[24_000...].reduce(0.0) { $0 + Double($1) } / 24_000
        #expect(abs(mean) < 1e-5)
        // With the tone at nothing, or no coefficients, it is the clean compressor to the bit.
        var silent = ProfileCompressor.Settings(character, thresholdDB: -18, sampleRate: rate)
        silent.tone = 0
        character.toneD2 = 0
        character.toneR3 = 0
        let clean = ProfileCompressor.render([tone], ProfileCompressor.Settings(character, thresholdDB: -18, sampleRate: rate))[0]
        #expect(ProfileCompressor.render([tone], silent)[0] == clean)
        #expect(harmonic(3, clean) < harmonic(3, working) / 5)
    }

    @Test func switchedOutItFadesAwayAndThenLeavesTheBlockAlone() {
        var unit = ProfileCompressor()
        unit.configure(sampleRate: rate, glideSeconds: 0.01)
        var settings = ProfileCompressor.Settings(plain(attackMs: 0.1), thresholdDB: -30, sampleRate: rate)
        let frames = 960
        let noise = TestSignal.noise(frames: frames, amplitude: 0.5, seed: 51)
        var block = noise
        // Switched in while playing, it glides in from nothing.
        var reading = block.withUnsafeMutableBufferPointer { unit.process($0.baseAddress!, $0.baseAddress!, stereo: false, frames: frames, settings) }
        #expect(reading != nil && block[0] == noise[0] * exp(Float(0)) && abs(block[900]) < abs(noise[900]) * 0.9)
        settings.mix = 0
        block = noise
        reading = block.withUnsafeMutableBufferPointer { unit.process($0.baseAddress!, $0.baseAddress!, stereo: false, frames: frames, settings) }
        #expect(reading != nil && block != noise)
        #expect(Array(block[480...]) == Array(noise[480...]))
        block = noise
        reading = block.withUnsafeMutableBufferPointer { unit.process($0.baseAddress!, $0.baseAddress!, stereo: false, frames: frames, settings) }
        #expect(reading == nil && block == noise)
        unit.reset()
        #expect(unit.fast == 0 && unit.slow == 0 && unit.power == 0)
    }

    @Test func processingTouchesNoHeap() {
        var unit = ProfileCompressor()
        unit.configure(sampleRate: rate, glideSeconds: 0.03)
        let character = CompressorCharacter(isPeak: false, rmsMs: 0.5, ratio: 3, kneeDB: 10, attackMs: 90, releaseMs: 60, tailMs: 1_500, tailMix: 0.33, attackQ: 7.4,
                                            toneD2: 4e-3, toneR3: 0.022)
        let settings = ProfileCompressor.Settings(character, thresholdDB: -24, makeupDB: 3, sampleRate: rate)
        var left = TestSignal.noise(frames: 4_096, seed: 1), right = TestSignal.noise(frames: 4_096, seed: 2)
        let report = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                RealtimeProbe.measure { _ = unit.process(l.baseAddress!, r.baseAddress!, stereo: true, frames: 4_096, settings) }
            }
        }
        #expect(report.isClean, "\(report)")
    }
}

extension ProfileCompressor.Reading: Equatable {
    public static func == (a: Self, b: Self) -> Bool { a.levelDB == b.levelDB && a.reductionDB == b.reductionDB }
}
