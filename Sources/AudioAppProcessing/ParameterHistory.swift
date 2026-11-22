import AudioAppCore
import Foundation

/// One change to one parameter: where it was and where it ended up.
public struct ParameterEdit: Equatable, Sendable {
    public let id: String
    public let name: String
    public let before: Float
    public let after: Float

    public init(id: String, name: String, before: Float, after: Float) {
        self.id = id
        self.name = name
        self.before = before
        self.after = after
    }
}

/// Told when a control takes hold of a parameter, moves it, and lets go.
@MainActor public protocol ParameterObserver: AnyObject {
    func gestureBegan(_ parameter: Parameter)
    func changed(_ parameter: Parameter, to value: Float)
    func gestureEnded(_ parameter: Parameter)
}

extension ParameterObserver {
    public func gestureBegan(_ parameter: Parameter) {}
    public func changed(_ parameter: Parameter, to value: Float) {}
    public func gestureEnded(_ parameter: Parameter) {}
}

/// Undo and redo for parameter changes. A whole gesture, from taking hold of a control to
/// letting go, is one step however many values it passed through. A gesture that ends where
/// it began records nothing.
///
/// Give it an `UndoManager` and its steps join the app's own Edit menu; without one it keeps
/// its own stacks.
@MainActor public final class ParameterHistory: ParameterObserver {
    private struct Step {
        let parameter: Parameter
        let edit: ParameterEdit
    }

    private var undone: [Step] = []
    private var done: [Step] = []
    private var open: [String: Float] = [:]
    /// The most steps kept. Older ones are dropped.
    public var limit: Int
    /// When set, steps are registered here instead of being kept by the history itself.
    public weak var undoManager: UndoManager?
    /// Called after any step is recorded, undone or redone.
    public var onChange: ((ParameterEdit) -> Void)?

    public init(limit: Int = 200, undoManager: UndoManager? = nil) {
        self.limit = max(1, limit)
        self.undoManager = undoManager
    }

    public var canUndo: Bool { undoManager?.canUndo ?? !done.isEmpty }
    public var canRedo: Bool { undoManager?.canRedo ?? !undone.isEmpty }
    /// The steps that `undo` would take back, oldest first. Empty when an `UndoManager` holds them.
    public var edits: [ParameterEdit] { done.map(\.edit) }

    public func gestureBegan(_ parameter: Parameter) {
        if open[parameter.id] == nil { open[parameter.id] = parameter.value }
    }

    public func gestureEnded(_ parameter: Parameter) {
        guard let before = open.removeValue(forKey: parameter.id) else { return }
        record(parameter, before: before)
    }

    /// Records a change that has already been made, as one step.
    public func record(_ parameter: Parameter, before: Float) {
        let after = parameter.value
        guard after != before else { return }
        let step = Step(parameter: parameter, edit: ParameterEdit(id: parameter.id, name: parameter.name, before: before, after: after))
        if let undoManager {
            register(step, with: undoManager, undoing: true)
        } else {
            done.append(step)
            if done.count > limit { done.removeFirst(done.count - limit) }
            undone.removeAll()
        }
        onChange?(step.edit)
    }

    /// Sets a parameter and records the change as one step.
    public func set(_ parameter: Parameter, to value: Float) {
        let before = parameter.value
        parameter.value = value
        record(parameter, before: before)
    }

    /// Takes back the latest step. Returns it, or nil when there is nothing to undo.
    @discardableResult public func undo() -> ParameterEdit? {
        if let undoManager {
            guard undoManager.canUndo else { return nil }
            undoManager.undo()
            return nil
        }
        guard let step = done.popLast() else { return nil }
        step.parameter.value = step.edit.before
        undone.append(step)
        onChange?(step.edit)
        return step.edit
    }

    /// Makes the latest undone step again.
    @discardableResult public func redo() -> ParameterEdit? {
        if let undoManager {
            guard undoManager.canRedo else { return nil }
            undoManager.redo()
            return nil
        }
        guard let step = undone.popLast() else { return nil }
        step.parameter.value = step.edit.after
        done.append(step)
        onChange?(step.edit)
        return step.edit
    }

    public func clear() {
        done.removeAll()
        undone.removeAll()
        open.removeAll()
    }

    /// Hands a step to the app's undo manager. Undoing it registers the opposite, which is
    /// how `UndoManager` builds its redo stack.
    private func register(_ step: Step, with manager: UndoManager, undoing: Bool) {
        manager.registerUndo(withTarget: self) { history in
            MainActor.assumeIsolated {
                step.parameter.value = undoing ? step.edit.before : step.edit.after
                history.register(step, with: manager, undoing: !undoing)
                history.onChange?(step.edit)
            }
        }
        manager.setActionName(step.edit.name)
    }
}

/// The link between one parameter and whatever shows or moves it: a fader, a text field, a
/// control surface. The control calls in when the user moves it; the attachment calls out
/// when the value changes for any other reason, such as undo or a preset.
///
/// Everything here runs on the main thread. The audio thread is never waited on: it reads
/// the parameter's value whenever it next renders.
@MainActor public final class ParameterAttachment {
    public let parameter: Parameter
    /// Called with the new value whenever it changes, whoever changed it.
    public var onChange: ((Float) -> Void)?
    public private(set) var isGesturing = false
    private var observers: [WeakObserver] = []
    private var lastSeen: Float

    private struct WeakObserver {
        weak var observer: (any ParameterObserver)?
    }

    public init(_ parameter: Parameter, history: ParameterHistory? = nil, onChange: ((Float) -> Void)? = nil) {
        self.parameter = parameter
        self.onChange = onChange
        lastSeen = parameter.value
        if let history { addObserver(history) }
    }

    /// Observers are held weakly.
    public func addObserver(_ observer: any ParameterObserver) {
        observers.removeAll { $0.observer == nil }
        observers.append(WeakObserver(observer: observer))
    }

    public var value: Float { parameter.value }
    public var position: Float { parameter.position }

    /// The user has taken hold of the control.
    public func beginGesture() {
        guard !isGesturing else { return }
        isGesturing = true
        for entry in observers { entry.observer?.gestureBegan(parameter) }
    }

    /// The user has moved the control to a value.
    public func set(_ value: Float) {
        parameter.value = value
        let stored = parameter.value
        guard stored != lastSeen else { return }
        lastSeen = stored
        for entry in observers { entry.observer?.changed(parameter, to: stored) }
        onChange?(stored)
    }

    /// The user has moved the control to a position from 0 to 1.
    public func setPosition(_ position: Float) {
        set(parameter.taper.value(at: position, in: parameter.range))
    }

    /// The user has let go.
    public func endGesture() {
        guard isGesturing else { return }
        isGesturing = false
        for entry in observers { entry.observer?.gestureEnded(parameter) }
    }

    /// A change made in one go, such as typing a value or double-clicking to reset.
    public func perform(_ value: Float) {
        beginGesture()
        set(value)
        endGesture()
    }

    public func reset() { perform(parameter.defaultValue) }

    /// Checks whether something else changed the parameter (undo, a preset, automation) and
    /// calls `onChange` if so. Call it from a display timer. Returns true when it had changed.
    @discardableResult public func poll() -> Bool {
        let current = parameter.value
        guard current != lastSeen else { return false }
        lastSeen = current
        onChange?(current)
        return true
    }
}
