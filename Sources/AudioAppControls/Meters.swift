import AudioAppKit
import SwiftUI

/// A level meter: one bar per channel, with optional average level, peak-hold line, clip
/// light and decibel scale. It draws what it is given; feed it from a display timer, with
/// `MeterBallistics` if the bars should fall smoothly.
public struct LevelMeter: View {
    private let readings: [MeterReading]
    private var scale = MeterScale()
    private var showsScale = true
    private var barWidth: CGFloat = 6

    @Environment(\.controlStyle) private var style

    /// - Parameter readings: one per channel, left to right.
    public init(_ readings: [MeterReading]) { self.readings = readings }

    public func scale(_ scale: MeterScale) -> LevelMeter { with { $0.scale = scale } }
    public func showsScale(_ shows: Bool) -> LevelMeter { with { $0.showsScale = shows } }
    public func barWidth(_ width: CGFloat) -> LevelMeter { with { $0.barWidth = max(1, width) } }

    private func with(_ change: (inout LevelMeter) -> Void) -> LevelMeter {
        var copy = self
        change(&copy)
        return copy
    }

    public var body: some View {
        Canvas { context, size in draw(&context, size: size) }
            .frame(minWidth: CGFloat(max(1, readings.count)) * (barWidth + 2) + (showsScale ? 18 : 0))
            .accessibilityElement()
            .accessibilityLabel("Level")
            .accessibilityValue(readings.map { String(format: "%.0f dB", $0.peak) }.joined(separator: ", "))
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let light: CGFloat = 4
        let top = light + 2
        let height = max(1, size.height - top)
        func y(_ decibels: Float) -> CGFloat { top + height * CGFloat(1 - scale.position(of: decibels)) }

        for (index, reading) in readings.enumerated() {
            let x = CGFloat(index) * (barWidth + 2)
            context.fill(Path(roundedRect: CGRect(x: x, y: top, width: barWidth, height: height), cornerRadius: 1), with: .color(style.groove))
            // The bar is three stacked stretches, so the colour says how close to full it is.
            let stops: [(from: Float, to: Float)] = [(scale.range.lowerBound, style.warningLevel), (style.warningLevel, style.overLevel),
                                                    (style.overLevel, scale.range.upperBound)]
            for stop in stops where reading.peak > stop.from {
                let upper = y(min(reading.peak, stop.to)), lower = y(stop.from)
                context.fill(Path(CGRect(x: x, y: upper, width: barWidth, height: max(0, lower - upper))),
                             with: .color(style.meterColor(at: stop.from).opacity(reading.rms == nil ? 1 : 0.55)))
            }
            if let rms = reading.rms, rms > scale.range.lowerBound {
                let upper = y(rms)
                context.fill(Path(CGRect(x: x, y: upper, width: barWidth, height: max(0, y(scale.range.lowerBound) - upper))),
                             with: .color(style.meterColor(at: rms)))
            }
            if let held = reading.held, held > scale.range.lowerBound {
                context.fill(Path(CGRect(x: x, y: y(held) - 0.5, width: barWidth, height: 1)), with: .color(style.ink))
            }
            context.fill(Path(roundedRect: CGRect(x: x, y: 0, width: barWidth, height: light), cornerRadius: 1),
                         with: .color(reading.isClipped ? style.over : style.groove))
        }

        guard showsScale else { return }
        let x = CGFloat(readings.count) * (barWidth + 2) + 1
        for mark in scale.marks {
            context.fill(Path(CGRect(x: x, y: y(mark) - 0.5, width: 3, height: 1)), with: .color(mark == 0 ? style.unityMark : style.mark))
            context.draw(Text(scale.label(for: mark)).font(style.scaleFont).foregroundColor(style.secondaryInk),
                         at: CGPoint(x: x + 5, y: y(mark)), anchor: .leading)
        }
    }
}

/// Shows how much a compressor or limiter is turning the signal down: a bar that grows
/// downwards from the top.
public struct GainReductionMeter: View {
    private let reduction: Float
    private var range: Float = 20
    private var tint: ControlStyle.Tint = .accent

    @Environment(\.controlStyle) private var style

    /// - Parameter reduction: decibels of reduction, as a positive number.
    public init(reduction: Float) { self.reduction = reduction }

    /// The reduction that fills the meter.
    public func range(_ decibels: Float) -> GainReductionMeter { with { $0.range = max(0.1, decibels) } }
    public func tint(_ tint: ControlStyle.Tint) -> GainReductionMeter { with { $0.tint = tint } }

    private func with(_ change: (inout GainReductionMeter) -> Void) -> GainReductionMeter {
        var copy = self
        change(&copy)
        return copy
    }

    /// How much of the meter is filled, from 0 to 1.
    public static func fill(reduction: Float, range: Float) -> Float {
        min(max(abs(reduction) / max(range, 0.1), 0), 1)
    }

    public var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 1), with: .color(style.groove))
            let height = size.height * CGFloat(Self.fill(reduction: reduction, range: range))
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: height)), with: .color(style.color(tint)))
        }
        .frame(minWidth: 3)
        .accessibilityElement()
        .accessibilityLabel("Gain reduction")
        .accessibilityValue(String(format: "%.1f dB", abs(reduction)))
    }
}

/// A spectrum as bars, one per band or bin, on a logarithmic frequency axis when the bands'
/// centre frequencies are given.
public struct SpectrumView: View {
    private let levels: [Float]
    private let centres: [Double]?
    private var layout = SpectrumLayout()
    private var tint: ControlStyle.Tint = .cool
    private var gridFrequencies: [Double] = [100, 1_000, 10_000]

    @Environment(\.controlStyle) private var style

    /// - Parameters:
    ///   - levels: decibels, one per band, low to high.
    ///   - centres: each band's centre frequency in hertz, or nil to spread the bars evenly.
    public init(levels: [Float], centres: [Double]? = nil) {
        self.levels = levels
        self.centres = centres
    }

    public func layout(_ layout: SpectrumLayout) -> SpectrumView { with { $0.layout = layout } }
    public func tint(_ tint: ControlStyle.Tint) -> SpectrumView { with { $0.tint = tint } }
    /// Frequencies that get a faint vertical line. Only drawn when centres are given.
    public func gridFrequencies(_ frequencies: [Double]) -> SpectrumView { with { $0.gridFrequencies = frequencies } }

    private func with(_ change: (inout SpectrumView) -> Void) -> SpectrumView {
        var copy = self
        change(&copy)
        return copy
    }

    public var body: some View {
        Canvas { context, size in
            if centres != nil {
                for frequency in gridFrequencies where layout.frequencies.contains(frequency) {
                    let x = size.width * CGFloat(layout.x(of: frequency))
                    context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(style.groove))
                }
            }
            for bar in layout.bars(levels: levels, centres: centres) {
                let gap: CGFloat = bar.width * size.width > 3 ? 1 : 0
                let rect = CGRect(x: bar.minX * size.width, y: size.height * (1 - bar.height),
                                  width: max(0.5, bar.width * size.width - gap), height: size.height * bar.height)
                context.fill(Path(rect), with: .color(style.color(tint)))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Spectrum")
    }
}

/// Draws a `WaveformOverview`: any range of frames at any width, with an optional selection
/// and playhead. Click or drag to report a frame.
public struct WaveformView: View {
    private let overview: WaveformOverview
    private var frames: Range<Int>?
    private var channel: Int?
    private var selection: Range<Int>?
    private var playhead: Int?
    private var tint: ControlStyle.Tint = .cool
    private var onSeek: ((Int) -> Void)?

    @Environment(\.controlStyle) private var style

    public init(_ overview: WaveformOverview) { self.overview = overview }

    /// The frames to show. The whole recording when nil.
    public func frames(_ frames: Range<Int>?) -> WaveformView { with { $0.frames = frames } }
    /// The one channel to draw, or nil to stack them all.
    public func channel(_ channel: Int?) -> WaveformView { with { $0.channel = channel } }
    public func selection(_ selection: Range<Int>?) -> WaveformView { with { $0.selection = selection } }
    public func playhead(_ frame: Int?) -> WaveformView { with { $0.playhead = frame } }
    public func tint(_ tint: ControlStyle.Tint) -> WaveformView { with { $0.tint = tint } }
    /// Called with the frame under the pointer on a click or drag.
    public func onSeek(_ action: ((Int) -> Void)?) -> WaveformView { with { $0.onSeek = action } }

    private func with(_ change: (inout WaveformView) -> Void) -> WaveformView {
        var copy = self
        change(&copy)
        return copy
    }

    private var shown: Range<Int> { frames ?? 0..<max(1, overview.frameCount) }

    public var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in draw(&context, size: size) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    onSeek?(WaveformLayout(frames: shown, width: geometry.size.width).frame(at: drag.location.x))
                })
        }
        .accessibilityElement()
        .accessibilityLabel("Waveform")
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let layout = WaveformLayout(frames: shown, width: size.width)
        if let selection, let span = layout.span(of: selection) {
            context.fill(Path(CGRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: size.height)),
                         with: .color(style.accent.opacity(0.18)))
        }
        let channels = channel.map { [$0] } ?? Array(0..<overview.channelCount)
        let lane = size.height / CGFloat(max(1, channels.count))
        let width = max(1, Int(size.width))
        for (row, channel) in channels.enumerated() {
            let middle = lane * (CGFloat(row) + 0.5), reach = lane / 2 - 1
            let buckets = overview.buckets(channel: channel, frames: shown, width: width)
            var peaks = Path(), body = Path()
            for (x, bucket) in buckets.enumerated() {
                let top = middle - CGFloat(min(max(bucket.max, -1), 1)) * reach
                let bottom = middle - CGFloat(min(max(bucket.min, -1), 1)) * reach
                peaks.addRect(CGRect(x: CGFloat(x), y: top, width: 1, height: max(1, bottom - top)))
                let rms = CGFloat(min(bucket.rms, 1)) * reach
                body.addRect(CGRect(x: CGFloat(x), y: middle - rms, width: 1, height: max(0, 2 * rms)))
            }
            context.fill(peaks, with: .color(style.color(tint).opacity(0.55)))
            context.fill(body, with: .color(style.color(tint)))
            context.fill(Path(CGRect(x: 0, y: middle - 0.5, width: size.width, height: 0.5)), with: .color(style.groove))
        }
        if let playhead, shown.contains(playhead) {
            context.fill(Path(CGRect(x: layout.x(of: playhead), y: 0, width: 1, height: size.height)), with: .color(style.ink))
        }
    }
}
