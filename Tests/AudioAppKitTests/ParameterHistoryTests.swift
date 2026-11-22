import AudioAppKit
import Foundation
import Testing

@MainActor @Suite struct ParameterHistoryTests {
    private func level() -> Parameter { Parameter(id: "level", name: "Level", default: 0, in: -60...12, unit: .decibels) }

    @Test func treeFlattensGroupsInOrderAndFindsByID() {
        let a = level(), b = Parameter(id: "freq", default: 1_000, in: 20...20_000, taper: .logarithmic)
        let c = Parameter(id: "q", default: 1, in: 0.1...10)
        let tree = ParameterTree([.parameter(a), .group(.init(id: "eq", name: "EQ", [b, c]))])
        #expect(tree.parameters.map(\.id) == ["level", "freq", "q"])
        #expect(tree["q"] === c)
        #expect(tree["missing"] == nil)
    }

    @Test func snapshotsRoundTripThroughJSONAndTolerateChangedParameters() throws {
        let a = level(), b = Parameter(id: "freq", default: 1_000, in: 20...20_000)
        let tree = ParameterTree([a, b])
        a.value = -6
        b.value = 440
        let data = try JSONEncoder().encode(tree.snapshot())
        tree.resetToDefaults()
        #expect(a.value == 0 && b.value == 1_000)

        var snapshot = try JSONDecoder().decode(ParameterSnapshot.self, from: data)
        snapshot.values["gone"] = 3          // a parameter this version no longer has
        snapshot.values["freq"] = nil        // one the preset predates
        tree.restore(snapshot)
        #expect(a.value == -6)
        #expect(b.value == 1_000)
        // Restoring clamps like any other set.
        tree.restore(ParameterSnapshot(values: ["level": 99]))
        #expect(a.value == 12)
    }

    @Test func aWholeGestureIsOneUndoStep() {
        let parameter = level()
        let history = ParameterHistory()
        let attachment = ParameterAttachment(parameter, history: history)
        attachment.beginGesture()
        for value in stride(from: Float(0), through: -20, by: -0.5) { attachment.set(value) }
        attachment.endGesture()
        #expect(history.edits == [ParameterEdit(id: "level", name: "Level", before: 0, after: -20)])

        attachment.perform(-3)
        #expect(history.edits.count == 2)
        #expect(history.undo()?.before == -20)
        #expect(parameter.value == -20)
        history.undo()
        #expect(parameter.value == 0)
        #expect(!history.canUndo && history.canRedo)
        history.redo()
        history.redo()
        #expect(parameter.value == -3)
        #expect(history.redo() == nil)
    }

    @Test func aGestureThatEndsWhereItBeganRecordsNothingAndANewEditClearsRedo() {
        let parameter = level()
        let history = ParameterHistory()
        let attachment = ParameterAttachment(parameter, history: history)
        attachment.beginGesture()
        attachment.set(-10)
        attachment.set(0)
        attachment.endGesture()
        #expect(!history.canUndo)

        attachment.perform(-5)
        history.undo()
        #expect(history.canRedo)
        attachment.perform(-7)
        #expect(!history.canRedo)
        attachment.reset()
        #expect(parameter.value == 0)
        #expect(history.edits.last?.before == -7)
    }

    @Test func historyKeepsOnlyItsLimit() {
        let parameter = level()
        let history = ParameterHistory(limit: 3)
        for value in 1...5 { history.set(parameter, to: Float(-value)) }
        #expect(history.edits.map(\.after) == [-3, -4, -5])
    }

    @Test func stepsJoinAnUndoManager() {
        let parameter = level()
        let manager = UndoManager()
        manager.groupsByEvent = false
        let history = ParameterHistory(undoManager: manager)
        let attachment = ParameterAttachment(parameter, history: history)
        manager.beginUndoGrouping()
        attachment.perform(-12)
        manager.endUndoGrouping()
        #expect(history.edits.isEmpty)
        #expect(manager.canUndo)
        #expect(manager.undoActionName == "Level")
        manager.undo()
        #expect(parameter.value == 0)
        #expect(manager.canRedo)
        manager.redo()
        #expect(parameter.value == -12)
        history.undo()
        #expect(parameter.value == 0)
    }

    @Test func attachmentReportsChangesFromBothSides() {
        let parameter = level()
        var heard: [Float] = []
        let attachment = ParameterAttachment(parameter) { heard.append($0) }
        attachment.set(-4)
        attachment.set(-4)                  // no change, no report
        attachment.set(100)                 // clamped
        #expect(heard == [-4, 12])
        #expect(!attachment.poll())

        parameter.value = -30               // undo, a preset or the host
        #expect(attachment.poll())
        #expect(heard == [-4, 12, -30])
        attachment.setPosition(1)
        #expect(attachment.value == 12 && attachment.position == 1)
    }

    @Test func observersHearTheGestureAndAreHeldWeakly() {
        final class Listener: ParameterObserver {
            var log: [String] = []
            func gestureBegan(_ parameter: Parameter) { log.append("began") }
            func changed(_ parameter: Parameter, to value: Float) { log.append("\(value)") }
            func gestureEnded(_ parameter: Parameter) { log.append("ended") }
        }
        let attachment = ParameterAttachment(level())
        var listener: Listener? = Listener()
        weak let weakListener = listener
        attachment.addObserver(listener!)
        attachment.beginGesture()
        attachment.beginGesture()           // already held
        attachment.set(-1)
        attachment.endGesture()
        attachment.endGesture()
        #expect(listener?.log == ["began", "-1.0", "ended"])
        listener = nil
        #expect(weakListener == nil)
        attachment.perform(-2)              // nobody listening; must not crash
    }
}
