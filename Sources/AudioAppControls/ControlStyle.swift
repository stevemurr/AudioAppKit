import SwiftUI

/// Every colour and size the controls draw with. Pass your own through the environment with
/// `.controlStyle(_:)` to make them match an app; the default is a dark console look.
public struct ControlStyle: Sendable {
    /// A colour role, so a zone or a control can say what it means and the style decides how
    /// that looks.
    public enum Tint: Hashable, Sendable {
        case accent, cool, neutral, signal, warning, over
        case custom(red: Double, green: Double, blue: Double)
    }

    public var ink = Color(white: 0.93)
    public var secondaryInk = Color(white: 0.62)
    public var groove = Color.white.opacity(0.10)
    public var mark = Color.white.opacity(0.22)
    public var unityMark = Color.white.opacity(0.42)
    public var well = Color(red: 0.043, green: 0.047, blue: 0.059)
    public var shadow = Color.black.opacity(0.55)

    public var accent = Color(red: 0.988, green: 0.678, blue: 0.388)
    public var cool = Color(red: 0.498, green: 0.616, blue: 0.969)
    public var signal = Color(red: 0.373, green: 0.812, blue: 0.573)
    public var warning = Color(red: 0.925, green: 0.827, blue: 0.361)
    public var over = Color(red: 1, green: 0.365, blue: 0.322)

    public var capTop = Color(red: 0.89, green: 0.902, blue: 0.918)
    public var capBottom = Color(red: 0.749, green: 0.769, blue: 0.796)
    public var grip = Color(red: 0.169, green: 0.184, blue: 0.212)

    /// The width of a fader's or slider's track.
    public var lineWidth: CGFloat = 2
    public var faderCapSize = CGSize(width: 26, height: 14)
    public var thumbDiameter: CGFloat = 10
    public var cornerRadius: CGFloat = 3
    public var scaleFontSize: CGFloat = 8
    /// The level above which a meter turns to the warning colour, in decibels.
    public var warningLevel: Float = -12
    /// The level above which a meter turns to the over colour, in decibels.
    public var overLevel: Float = -3

    public init() {}

    public static let standard = ControlStyle()

    public func color(_ tint: Tint) -> Color {
        switch tint {
        case .accent: accent
        case .cool: cool
        case .neutral: secondaryInk
        case .signal: signal
        case .warning: warning
        case .over: over
        case .custom(let red, let green, let blue): Color(red: red, green: green, blue: blue)
        }
    }

    /// The colour of a meter segment at a level.
    public func meterColor(at decibels: Float) -> Color {
        decibels >= overLevel ? over : decibels >= warningLevel ? warning : signal
    }

    public var scaleFont: Font { .system(size: scaleFontSize).monospacedDigit() }
}

private struct ControlStyleKey: EnvironmentKey {
    static let defaultValue = ControlStyle.standard
}

extension EnvironmentValues {
    public var controlStyle: ControlStyle {
        get { self[ControlStyleKey.self] }
        set { self[ControlStyleKey.self] = newValue }
    }
}

extension View {
    /// Sets the look of every AudioAppKit control inside this view.
    public func controlStyle(_ style: ControlStyle) -> some View {
        environment(\.controlStyle, style)
    }
}
