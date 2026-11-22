import AudioAppControls
import AudioAppKit
import AudioAppTesting
import SwiftUI
import Testing

@Suite struct ControlLogicTests {
    @Test func mappingSnapsAndStaysInRange() {
        let pan = ControlMapping(range: -1...1, step: 0.01)
        #expect(pan.value(at: 0.5) == 0)
        #expect(close(pan.value(at: 0.7531), 0.51, within: 1e-6))
        #expect(pan.value(at: 2) == 1)
        #expect(pan.snapped(-7) == -1)
        let frequency = ControlMapping(range: 20...20_000, taper: .logarithmic)
        #expect(close(frequency.value(at: 0.5), 632.46, within: 0.1))
        #expect(close(frequency.position(of: 632.46), 0.5, within: 1e-4))
    }

    @Test func nudgesMoveAStepOrAHundredthOfTheTravel() {
        let stepped = ControlMapping(range: -60...12, step: 0.5)
        #expect(stepped.nudged(0, by: 1) == 0.5)
        #expect(close(stepped.nudged(0, by: -1, fine: true), -0.05))
        #expect(stepped.nudged(12, by: 3) == 12)
        let smooth = ControlMapping(range: 0...200)
        #expect(close(smooth.nudged(100, by: 1), 102, within: 1e-3))
        #expect(close(smooth.nudged(100, by: -2, fine: true), 99.6, within: 1e-3))
        #expect(smooth.nudged(0, by: -5) == 0)
    }

    @Test func aDragMovesFromWhereItWasGrabbed() {
        var tracker = DragTracker()
        tracker.begin(at: 0.25)
        #expect(tracker.update(offset: 0, travel: 200, fine: false) == 0.25)
        #expect(close(tracker.update(offset: 100, travel: 200, fine: false), 0.75))
        #expect(tracker.update(offset: 500, travel: 200, fine: false) == 1)
        #expect(tracker.update(offset: -500, travel: 200, fine: false) == 0)
    }

    @Test func fineModeIsTenTimesSlowerAndSwitchingItNeverJumps() {
        var tracker = DragTracker()
        tracker.begin(at: 0.5)
        #expect(close(tracker.update(offset: 40, travel: 200, fine: false), 0.7))
        // Fine comes on mid-drag: the control stays put, then creeps.
        #expect(close(tracker.update(offset: 40, travel: 200, fine: true), 0.7))
        #expect(close(tracker.update(offset: 60, travel: 200, fine: true), 0.71))
        // Fine goes off: carries on at full speed from where it is.
        #expect(close(tracker.update(offset: 60, travel: 200, fine: false), 0.71))
        #expect(close(tracker.update(offset: 80, travel: 200, fine: false), 0.81))
    }

    @Test func zonesOwnTheirStretchAndTheBoundaryBelongsBelow() {
        let zones = [FaderZone("Cut", -60...0, tint: .cool), FaderZone("Push", 0...12)]
        #expect(FaderZone.zone(at: -10, in: zones)?.name == "Cut")
        #expect(FaderZone.zone(at: 0, in: zones)?.name == "Cut")
        #expect(FaderZone.zone(at: 0.1, in: zones)?.name == "Push")
        #expect(FaderZone.zone(at: -60, in: zones)?.name == "Cut")
        #expect(FaderZone.zone(at: 20, in: zones) == nil)
        #expect(FaderZone.zone(at: 0, in: []) == nil)
    }

    @Test func meterScalePlacesLevels() {
        let scale = MeterScale(range: -60...0, marks: [0, -6, -12, -90])
        #expect(scale.marks == [0, -6, -12])
        #expect(scale.position(of: -30) == 0.5)
        #expect(scale.position(of: 6) == 1 && scale.position(of: -200) == 0)
        #expect(scale.label(for: 0) == "0" && scale.label(for: -12) == "12")
    }

    @Test func meterJumpsUpFallsSteadilyHoldsItsPeakAndLatchesClip() {
        var meter = MeterBallistics(fallRate: 20, holdSeconds: 1, clipLevel: 0)
        meter.update(-6, elapsed: 0.02)
        #expect(meter.level == -6 && meter.held == -6 && !meter.isClipped)
        // Silence for half a second: the bar falls 10 dB, the hold line stays.
        for _ in 0..<25 { meter.update(-200, elapsed: 0.02) }
        #expect(close(meter.level, -16, within: 0.01))
        #expect(meter.held == -6)
        // A louder hit takes the bar and the hold line at once.
        meter.update(0.5, elapsed: 0.02)
        #expect(meter.level == 0.5 && meter.held == 0.5 && meter.isClipped)
        // After the hold time the line follows the bar down, and the clip light stays on.
        for _ in 0..<100 { meter.update(-200, elapsed: 0.02) }
        #expect(meter.held < -10)
        #expect(meter.held >= meter.level)
        #expect(meter.isClipped)
        meter.clearClip()
        #expect(!meter.isClipped)
        meter.reset()
        #expect(meter.level == -200 && meter.held == -200)
        #expect(MeterReading(meter, rms: -20) == MeterReading(peak: -200, rms: -20, held: -200))
    }

    @Test func knobPointerSweepsFromLowerLeftToLowerRight() {
        let knob = KnobGeometry()
        #expect(knob.angle(at: 0) == -135 && knob.angle(at: 0.5) == 0 && knob.angle(at: 1) == 135)
        let top = knob.point(angle: 0, radius: 10, centre: CGPoint(x: 20, y: 20))
        #expect(abs(top.x - 20) < 1e-9 && abs(top.y - 10) < 1e-9)
        let right = knob.point(angle: 90, radius: 10, centre: CGPoint(x: 20, y: 20))
        #expect(abs(right.x - 30) < 1e-9 && abs(right.y - 20) < 1e-9)
    }

    @Test func spectrumBarsSitOnALogAxisAndMeetWithoutGaps() {
        let layout = SpectrumLayout(frequencies: 20...20_000, levels: -60...0)
        #expect(abs(layout.x(of: 632.46) - 0.5) < 1e-4)
        #expect(layout.height(of: -30) == 0.5 && layout.height(of: 10) == 1)

        let even = layout.bars(levels: [-60, -30, 0])
        #expect(even.map(\.height) == [0, 0.5, 1])
        #expect(abs(even[1].minX - 1.0 / 3) < 1e-9)

        let bars = layout.bars(levels: [-30, -30, -30, -30], centres: [100, 200, 400, 800])
        for (left, right) in zip(bars, bars.dropFirst()) { #expect(abs(left.maxX - right.minX) < 1e-9) }
        // Octave bands are equally wide on a log axis.
        #expect(abs(bars[1].width - bars[2].width) < 1e-9)
        #expect(layout.bars(levels: []).isEmpty)
    }

    @Test func waveformLayoutConvertsBetweenFramesAndPoints() {
        let layout = WaveformLayout(frames: 1_000..<3_000, width: 400)
        #expect(layout.x(of: 2_000) == 200)
        #expect(layout.frame(at: 100) == 1_500)
        #expect(layout.frame(at: -50) == 1_000 && layout.frame(at: 900) == 3_000)
        #expect(layout.span(of: 500..<1_500) == 0...100)
        #expect(layout.span(of: 0..<900) == nil)
        #expect(layout.span(of: 2_500..<9_000) == 300...400)
    }

    @Test func gainReductionFillsInProportion() {
        #expect(GainReductionMeter.fill(reduction: 5, range: 20) == 0.25)
        #expect(GainReductionMeter.fill(reduction: -5, range: 20) == 0.25)
        #expect(GainReductionMeter.fill(reduction: 40, range: 20) == 1)
    }

    @Test func styleColoursMetersByLevel() {
        var style = ControlStyle()
        style.warningLevel = -10
        style.overLevel = -2
        #expect(style.meterColor(at: -30) == style.signal)
        #expect(style.meterColor(at: -10) == style.warning)
        #expect(style.meterColor(at: -1) == style.over)
        #expect(style.color(.cool) == style.cool)
    }
}

@MainActor @Suite struct ControlViewTests {
    @Test func aBindingDrivesItsParameterAndRecordsOneStepPerDrag() {
        let level = Parameter(id: "level", name: "Level", default: 0, in: -60...12, unit: .decibels)
        let history = ParameterHistory()
        let binding = ParameterBinding(level, history: history)
        #expect(binding.mapping == ControlMapping(range: -60...12))

        binding.editingChanged(true)
        for value in stride(from: Float(-1), through: -9, by: -1) { binding.binding.wrappedValue = value }
        binding.editingChanged(false)
        #expect(level.value == -9 && binding.value == -9)
        #expect(history.edits.count == 1)

        // Undo changes the parameter behind the control's back; refresh brings it forward.
        history.undo()
        #expect(binding.value == -9)
        binding.refresh()
        #expect(binding.value == 0)
    }

    /// Draws each control offscreen. This catches a crash or an empty drawing, not a wrong one.
    @Test func everyControlDraws() {
        let level = Parameter(id: "level", name: "Level", default: 0, in: -60...12, unit: .decibels)
        let binding = ParameterBinding(level)
        let overview = WaveformBuilder.overview(of: SampleBuffer([TestSignal.sine(frequency: 5, sampleRate: 1_000, frames: 4_000)]), sampleRate: 1_000)
        func drawn(_ view: some View, _ width: CGFloat, _ height: CGFloat) -> Bool {
            let renderer = ImageRenderer(content: view.frame(width: width, height: height).background(Color.black))
            guard let image = renderer.cgImage else { return false }
            return image.width >= Int(width) && image.height >= Int(height)
        }
        #expect(drawn(Fader(binding).zones([FaderZone("Cut", -60...0, tint: .cool), FaderZone("Push", 0...12)]).marks([0, -12, -24]), 40, 200))
        #expect(drawn(Fader(value: .constant(0.3), in: 0...1), 40, 120))
        #expect(drawn(Knob(binding).tint(.cool), 44, 44))
        #expect(drawn(LineSlider(value: .constant(-0.25), in: -1...1, step: 0.01).centred().defaultValue(0), 120, 16))
        #expect(drawn(LevelMeter([MeterReading(peak: -8, rms: -18, held: -4), MeterReading(peak: 1, isClipped: true)]), 40, 160))
        #expect(drawn(LevelMeter([]).showsScale(false), 10, 60))
        #expect(drawn(GainReductionMeter(reduction: 4).range(12), 4, 80))
        #expect(drawn(SpectrumView(levels: [-40, -20, -10, -30], centres: [100, 400, 1_600, 6_400]), 200, 80))
        #expect(drawn(SpectrumView(levels: []), 50, 20))
        #expect(drawn(WaveformView(overview).selection(500..<1_500).playhead(2_000).controlStyle(ControlStyle()), 300, 60))
        #expect(drawn(WaveformView(overview).frames(3_900..<6_000).channel(0), 100, 40))
    }

    /// A waveform view draws the audio it was given: louder stretches reach further from the middle.
    @Test func theWaveformPictureFollowsTheAudio() throws {
        var samples = [Float](repeating: 0, count: 2_000)
        for index in 1_000..<2_000 { samples[index] = index % 2 == 0 ? 1 : -1 }
        let overview = WaveformBuilder.overview(of: SampleBuffer([samples]), sampleRate: 1_000, framesPerBucket: 10, factor: 2)
        let renderer = ImageRenderer(content: WaveformView(overview).frame(width: 200, height: 40).background(Color.black))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let data = try #require(image.dataProvider?.data as Data?)
        func brightness(x: Int, y: Int) -> Int {
            let offset = y * image.bytesPerRow + x * image.bitsPerPixel / 8
            return Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])
        }
        // Near the top edge, the quiet half is background and the loud half is waveform.
        #expect(brightness(x: 50, y: 5) < 40)
        #expect(brightness(x: 150, y: 5) > 150)
    }
}
