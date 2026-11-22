import AudioAppKit
import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Whether the fine-adjust key is down right now.
@MainActor func fineModifierIsDown(_ modifier: EventModifiers) -> Bool {
    #if os(macOS)
    let flags = NSEvent.modifierFlags
    if modifier.contains(.shift), flags.contains(.shift) { return true }
    if modifier.contains(.option), flags.contains(.option) { return true }
    if modifier.contains(.command), flags.contains(.command) { return true }
    if modifier.contains(.control), flags.contains(.control) { return true }
    return false
    #else
    return false
    #endif
}

#if os(macOS)
/// Watches the scroll wheel while the pointer is over one view.
@MainActor final class ScrollWheelMonitor {
    var isHovering = false
    var action: ((CGFloat) -> Void)?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.1 : 1)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isHovering, delta != 0 else { return false }
                self.action?(delta)
                return true
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct ScrollWheelModifier: ViewModifier {
    let action: (CGFloat) -> Void
    @State private var monitor = ScrollWheelMonitor()

    func body(content: Content) -> some View {
        // The closure captures the control's current value, so keep the newest one.
        let _ = (monitor.action = action)
        content
            .onHover { monitor.isHovering = $0 }
            .onAppear { monitor.install() }
            .onDisappear { monitor.remove() }
    }
}
#endif

extension View {
    /// Calls `action` with the wheel's movement, in notches, while the pointer is over this
    /// view. Does nothing on platforms without a scroll wheel.
    @ViewBuilder func onScrollWheel(_ action: @escaping (CGFloat) -> Void) -> some View {
        #if os(macOS)
        modifier(ScrollWheelModifier(action: action))
        #else
        self
        #endif
    }

    /// Arrow keys nudge a value up and down while this view has the keyboard.
    func nudgeKeys(_ nudge: @escaping (_ notches: Float) -> Void) -> some View {
        focusable()
            .onKeyPress(keys: [.upArrow, .rightArrow]) { _ in nudge(1); return .handled }
            .onKeyPress(keys: [.downArrow, .leftArrow]) { _ in nudge(-1); return .handled }
    }
}

/// Connects a control to a parameter. Changes made through it are reported to a
/// `ParameterHistory` as one step per gesture, and changes made elsewhere (undo, a preset)
/// show up in the control after `refresh()`.
///
///     @StateObject var level = ParameterBinding(levelParameter, history: history)
///     Fader(level)
@MainActor public final class ParameterBinding: ObservableObject {
    public let attachment: ParameterAttachment
    @Published public private(set) var value: Float

    public init(_ parameter: Parameter, history: ParameterHistory? = nil) {
        attachment = ParameterAttachment(parameter, history: history)
        value = parameter.value
        attachment.onChange = { [weak self] in self?.value = $0 }
    }

    public var parameter: Parameter { attachment.parameter }
    public var mapping: ControlMapping { ControlMapping(attachment.parameter) }

    /// A SwiftUI binding to the parameter's value.
    public var binding: Binding<Float> {
        Binding(get: { self.value }, set: { self.attachment.set($0) })
    }

    /// Pass to a control's `onEditingChanged`.
    public func editingChanged(_ editing: Bool) {
        if editing { attachment.beginGesture() } else { attachment.endGesture() }
    }

    /// Picks up a change made by something other than this control. Call from a display timer.
    public func refresh() { attachment.poll() }
}
