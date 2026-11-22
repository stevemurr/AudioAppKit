import AudioAppKit
import SwiftUI

/// A vertical fader. It moves with the pointer from wherever it is grabbed, a tenth as fast
/// with the fine key held; double-click returns it to its default; the scroll wheel and the
/// arrow keys nudge it.
///
/// Zones tint stretches of its travel that mean something to the app, and marks draw ticks
/// at chosen values.
public struct Fader: View {
    @Binding private var value: Float
    private let mapping: ControlMapping
    private var zones: [FaderZone] = []
    private var marks: [Float] = []
    private var defaultValue: Float?
    private var label = "Fader"
    private var fineModifier: EventModifiers = .shift
    private var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.controlStyle) private var style
    @Environment(\.isEnabled) private var isEnabled
    @State private var tracker = DragTracker()
    @State private var isDragging = false

    public init(value: Binding<Float>, in range: ClosedRange<Float>, taper: Taper = .linear, step: Float = 0,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        mapping = ControlMapping(range: range, taper: taper, step: step)
        self.onEditingChanged = onEditingChanged
    }

    /// A fader for a parameter, using its range, taper, default and name.
    @MainActor public init(_ binding: ParameterBinding) {
        _value = binding.binding
        mapping = binding.mapping
        defaultValue = binding.parameter.defaultValue
        label = binding.parameter.name
        onEditingChanged = { [weak binding] in binding?.editingChanged($0) }
    }

    /// Tints stretches of the travel.
    public func zones(_ zones: [FaderZone]) -> Fader { with { $0.zones = zones } }
    /// Draws ticks at these values.
    public func marks(_ marks: [Float]) -> Fader { with { $0.marks = marks } }
    /// The value a double-click returns to.
    public func defaultValue(_ value: Float?) -> Fader { with { $0.defaultValue = value } }
    public func label(_ label: String) -> Fader { with { $0.label = label } }
    /// The key that slows the fader down while dragging.
    public func fineModifier(_ modifier: EventModifiers) -> Fader { with { $0.fineModifier = modifier } }

    private func with(_ change: (inout Fader) -> Void) -> Fader {
        var copy = self
        change(&copy)
        return copy
    }

    public var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.height - style.faderCapSize.height)
            Canvas { context, size in draw(&context, size: size) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            tracker.begin(at: mapping.position(of: value))
                            onEditingChanged(true)
                        }
                        let position = tracker.update(offset: -drag.translation.height, travel: travel,
                                                      fine: fineModifierIsDown(fineModifier))
                        set(mapping.value(at: position))
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    })
                .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
        }
        .frame(minWidth: style.faderCapSize.width + 4)
        .opacity(isEnabled ? 1 : 0.4)
        .onScrollWheel { nudge(Float($0)) }
        .nudgeKeys { nudge($0) }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.1f", value))
        .accessibilityAdjustableAction { direction in
            nudge(direction == .increment ? 1 : -1)
        }
    }

    private func set(_ next: Float) {
        if next != value { value = next }
    }

    private func nudge(_ notches: Float) {
        guard isEnabled else { return }
        onEditingChanged(true)
        set(mapping.nudged(value, by: notches, fine: fineModifierIsDown(fineModifier)))
        onEditingChanged(false)
    }

    private func reset() {
        guard let defaultValue, isEnabled else { return }
        onEditingChanged(true)
        set(mapping.snapped(defaultValue))
        onEditingChanged(false)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let cap = style.faderCapSize
        let travel = max(1, size.height - cap.height)
        func y(_ value: Float) -> CGFloat { cap.height / 2 + travel * CGFloat(1 - mapping.position(of: value)) }
        let x = size.width / 2
        let line = style.lineWidth

        context.fill(Path(roundedRect: CGRect(x: x - line / 2, y: cap.height / 2, width: line, height: travel), cornerRadius: line / 2),
                     with: .color(style.groove))
        // Each zone shows faintly along its whole stretch and strongly over the part of it
        // the fader has travelled into.
        for zone in zones {
            let top = y(zone.range.upperBound), bottom = y(zone.range.lowerBound)
            let tint = style.color(zone.tint)
            context.fill(Path(CGRect(x: x - line / 2, y: top, width: line, height: bottom - top)), with: .color(tint.opacity(0.3)))
            if let rest = defaultValue, zone.range.contains(value) || (value > zone.range.upperBound && rest <= zone.range.lowerBound)
                || (value < zone.range.lowerBound && rest >= zone.range.upperBound) {
                let from = y(min(max(rest, zone.range.lowerBound), zone.range.upperBound))
                let to = y(min(max(value, zone.range.lowerBound), zone.range.upperBound))
                context.fill(Path(CGRect(x: x - line, y: min(from, to), width: line * 2, height: abs(to - from))), with: .color(tint))
            }
        }
        for mark in marks where mapping.range.contains(mark) {
            let isDefault = mark == defaultValue
            let width: CGFloat = isDefault ? cap.width : cap.width * 0.5
            context.fill(Path(CGRect(x: x - width / 2, y: y(mark) - 0.5, width: width, height: 1)),
                         with: .color(isDefault ? style.unityMark : style.mark))
        }

        let rect = CGRect(x: x - cap.width / 2, y: y(value) - cap.height / 2, width: cap.width, height: cap.height)
        let shape = Path(roundedRect: rect, cornerRadius: style.cornerRadius)
        var shadowed = context
        shadowed.addFilter(.shadow(color: style.shadow, radius: 2, x: 0, y: 2))
        shadowed.fill(shape, with: .color(style.capBottom))
        context.fill(shape, with: .linearGradient(Gradient(colors: [style.capTop, style.capBottom]),
                                                  startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        let zone = FaderZone.zone(at: value, in: zones)
        let heavy = zone != nil && value != defaultValue
        let grip: CGFloat = heavy ? 2 : 1
        context.fill(Path(CGRect(x: rect.minX + 3, y: rect.midY - grip / 2, width: rect.width - 6, height: grip)),
                     with: .color(heavy ? style.color(zone!.tint) : style.grip))
    }
}

/// A rotary control. Drag up and down to turn it; the fine key, double-click, scroll wheel
/// and arrow keys work as they do on a `Fader`.
public struct Knob: View {
    @Binding private var value: Float
    private let mapping: ControlMapping
    private var geometry = KnobGeometry()
    private var defaultValue: Float?
    private var label = "Knob"
    private var tint: ControlStyle.Tint = .accent
    /// How far the pointer travels to turn the knob from one end to the other.
    private var travel: CGFloat = 160
    private var fineModifier: EventModifiers = .shift
    private var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.controlStyle) private var style
    @Environment(\.isEnabled) private var isEnabled
    @State private var tracker = DragTracker()
    @State private var isDragging = false

    public init(value: Binding<Float>, in range: ClosedRange<Float>, taper: Taper = .linear, step: Float = 0,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        mapping = ControlMapping(range: range, taper: taper, step: step)
        self.onEditingChanged = onEditingChanged
    }

    @MainActor public init(_ binding: ParameterBinding) {
        _value = binding.binding
        mapping = binding.mapping
        defaultValue = binding.parameter.defaultValue
        label = binding.parameter.name
        onEditingChanged = { [weak binding] in binding?.editingChanged($0) }
    }

    public func defaultValue(_ value: Float?) -> Knob { with { $0.defaultValue = value } }
    public func label(_ label: String) -> Knob { with { $0.label = label } }
    public func tint(_ tint: ControlStyle.Tint) -> Knob { with { $0.tint = tint } }
    public func geometry(_ geometry: KnobGeometry) -> Knob { with { $0.geometry = geometry } }
    public func dragTravel(_ points: CGFloat) -> Knob { with { $0.travel = max(1, points) } }
    public func fineModifier(_ modifier: EventModifiers) -> Knob { with { $0.fineModifier = modifier } }

    private func with(_ change: (inout Knob) -> Void) -> Knob {
        var copy = self
        change(&copy)
        return copy
    }

    public var body: some View {
        Canvas { context, size in draw(&context, size: size) }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !isDragging {
                        isDragging = true
                        tracker.begin(at: mapping.position(of: value))
                        onEditingChanged(true)
                    }
                    let position = tracker.update(offset: -drag.translation.height, travel: travel,
                                                  fine: fineModifierIsDown(fineModifier))
                    set(mapping.value(at: position))
                }
                .onEnded { _ in
                    isDragging = false
                    onEditingChanged(false)
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
            .opacity(isEnabled ? 1 : 0.4)
            .onScrollWheel { nudge(Float($0)) }
            .nudgeKeys { nudge($0) }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(String(format: "%.1f", value))
            .accessibilityAdjustableAction { direction in
                nudge(direction == .increment ? 1 : -1)
            }
    }

    private func set(_ next: Float) {
        if next != value { value = next }
    }

    private func nudge(_ notches: Float) {
        guard isEnabled else { return }
        onEditingChanged(true)
        set(mapping.nudged(value, by: notches, fine: fineModifierIsDown(fineModifier)))
        onEditingChanged(false)
    }

    private func reset() {
        guard let defaultValue, isEnabled else { return }
        onEditingChanged(true)
        set(mapping.snapped(defaultValue))
        onEditingChanged(false)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - style.lineWidth
        let position = mapping.position(of: value)
        func arc(from: Double, to: Double) -> Path {
            // SwiftUI measures angles clockwise from the positive x axis; the geometry
            // measures them clockwise from straight up.
            Path { $0.addArc(center: centre, radius: radius, startAngle: .degrees(min(from, to) - 90),
                             endAngle: .degrees(max(from, to) - 90), clockwise: false) }
        }
        let stroke = StrokeStyle(lineWidth: style.lineWidth, lineCap: .round)
        context.stroke(arc(from: geometry.startAngle, to: geometry.startAngle + geometry.sweep), with: .color(style.groove), style: stroke)
        let rest = defaultValue.map(mapping.position(of:)) ?? 0
        context.stroke(arc(from: geometry.angle(at: rest), to: geometry.angle(at: position)), with: .color(style.color(tint)), style: stroke)

        let body = radius - style.lineWidth * 2.5
        let disc = Path(ellipseIn: CGRect(x: centre.x - body, y: centre.y - body, width: body * 2, height: body * 2))
        var shadowed = context
        shadowed.addFilter(.shadow(color: style.shadow, radius: 2, x: 0, y: 1))
        shadowed.fill(disc, with: .color(style.capBottom))
        context.fill(disc, with: .linearGradient(Gradient(colors: [style.capTop, style.capBottom]),
                                                 startPoint: CGPoint(x: centre.x, y: centre.y - body), endPoint: CGPoint(x: centre.x, y: centre.y + body)))
        let angle = geometry.angle(at: position)
        var pointer = Path()
        pointer.move(to: geometry.point(angle: angle, radius: body * 0.35, centre: centre))
        pointer.addLine(to: geometry.point(angle: angle, radius: body * 0.85, centre: centre))
        context.stroke(pointer, with: .color(style.grip), style: StrokeStyle(lineWidth: max(1.5, style.lineWidth * 0.75), lineCap: .round))
    }
}

/// A thin horizontal slider. The thumb goes to the pointer and follows it. Filled from the
/// left, or from the centre for a control that rests in the middle, such as pan.
public struct LineSlider: View {
    @Binding private var value: Float
    private let mapping: ControlMapping
    private var centred = false
    private var defaultValue: Float?
    private var label = "Slider"
    private var tint: ControlStyle.Tint = .neutral
    private var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.controlStyle) private var style
    @Environment(\.isEnabled) private var isEnabled
    @State private var isDragging = false

    public init(value: Binding<Float>, in range: ClosedRange<Float>, taper: Taper = .linear, step: Float = 0,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        mapping = ControlMapping(range: range, taper: taper, step: step)
        self.onEditingChanged = onEditingChanged
    }

    @MainActor public init(_ binding: ParameterBinding) {
        _value = binding.binding
        mapping = binding.mapping
        defaultValue = binding.parameter.defaultValue
        label = binding.parameter.name
        onEditingChanged = { [weak binding] in binding?.editingChanged($0) }
    }

    /// Fills from the middle of the track instead of the left end.
    public func centred(_ centred: Bool = true) -> LineSlider { with { $0.centred = centred } }
    public func defaultValue(_ value: Float?) -> LineSlider { with { $0.defaultValue = value } }
    public func label(_ label: String) -> LineSlider { with { $0.label = label } }
    public func tint(_ tint: ControlStyle.Tint) -> LineSlider { with { $0.tint = tint } }

    private func with(_ change: (inout LineSlider) -> Void) -> LineSlider {
        var copy = self
        change(&copy)
        return copy
    }

    public var body: some View {
        GeometryReader { geometry in
            let pad = style.thumbDiameter / 2
            let travel = max(1, geometry.size.width - 2 * pad)
            Canvas { context, size in draw(&context, size: size) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        set(mapping.value(at: Float((drag.location.x - pad) / travel)))
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    })
                .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
        }
        .frame(minHeight: style.thumbDiameter + 4)
        .opacity(isEnabled ? 1 : 0.4)
        .nudgeKeys { nudge($0) }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityAdjustableAction { direction in
            nudge(direction == .increment ? 1 : -1)
        }
    }

    private func set(_ next: Float) {
        if next != value { value = next }
    }

    private func nudge(_ notches: Float) {
        guard isEnabled else { return }
        onEditingChanged(true)
        set(mapping.nudged(value, by: notches))
        onEditingChanged(false)
    }

    private func reset() {
        guard let defaultValue, isEnabled else { return }
        onEditingChanged(true)
        set(mapping.snapped(defaultValue))
        onEditingChanged(false)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let pad = style.thumbDiameter / 2
        let line = style.lineWidth
        let track = CGRect(x: 0, y: size.height / 2 - line / 2, width: size.width, height: line)
        let thumbX = pad + CGFloat(mapping.position(of: value)) * max(0, size.width - 2 * pad)
        context.fill(Path(roundedRect: track, cornerRadius: line / 2), with: .color(style.groove))
        let from = centred ? track.midX : track.minX
        context.fill(Path(roundedRect: CGRect(x: min(from, thumbX), y: track.minY, width: abs(thumbX - from), height: line), cornerRadius: line / 2),
                     with: .color(style.color(tint)))
        if centred {
            context.fill(Path(CGRect(x: track.midX - 0.5, y: size.height / 2 - 3, width: 1, height: 6)), with: .color(style.mark))
        }
        let thumb = Path(ellipseIn: CGRect(x: thumbX - pad, y: size.height / 2 - pad, width: pad * 2, height: pad * 2))
        var shadowed = context
        shadowed.addFilter(.shadow(color: style.shadow, radius: 1, x: 0, y: 1))
        shadowed.fill(thumb, with: .color(style.capTop))
    }
}
