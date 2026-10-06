import Testing
@testable import CSCore

struct ShortcutConflictsTests {
    let area = ShortcutSpec.commandShift(KeyCode.digit4)
    let allInOne = ShortcutSpec.commandShift(KeyCode.digit5)
    /// ⌃⇧⌘4: macOS "copy picture of selected area", which ClearShot doesn't use by default.
    let controlCommandShift4 = ShortcutSpec(carbonKeyCode: KeyCode.digit4, carbonModifiers: ShortcutSpec.control | ShortcutSpec.command | ShortcutSpec.shift)
    /// ⇧⌘6, which no action has by default.
    let commandShift6 = ShortcutSpec.commandShift(KeyCode.digit6)

    @Test func reportsActionsWhoseShortcutMacOSAlsoUses() {
        let assignments: [ClearShotAction: ShortcutSpec] = [.captureArea: area, .allInOne: allInOne]
        let taken = ShortcutConflicts.actionsTakenBySystem(assignments: assignments) { $0 == area }
        #expect(taken == [.captureArea])
    }

    @Test func otherEnabledMacOSShortcutsAreNotConflicts() {
        // The old check warned when only ⌃⇧⌘3/⌃⇧⌘4 were on, though they don't clash with ⇧⌘3/4/5.
        let assignments: [ClearShotAction: ShortcutSpec] = [.captureArea: area, .allInOne: allInOne]
        let taken = ShortcutConflicts.actionsTakenBySystem(assignments: assignments) { $0 == controlCommandShift4 }
        #expect(taken.isEmpty)
    }

    @Test func resultFollowsRegistryOrder() {
        let assignments: [ClearShotAction: ShortcutSpec] = [.allInOne: allInOne, .captureArea: area]
        let taken = ShortcutConflicts.actionsTakenBySystem(assignments: assignments) { _ in true }
        #expect(taken == [.allInOne, .captureArea])
    }

    // MARK: A recorded shortcut

    @Test func aFreeShortcutIsKept() {
        // The recorder has already stored the new key, so the action's own entry holds it.
        let assignments: [ClearShotAction: ShortcutSpec] = [.captureArea: area, .allInOne: allInOne, .captureWindow: commandShift6]
        #expect(ShortcutConflicts.resolve(.captureWindow, recorded: commandShift6, previous: nil, assignments: assignments) == .keep)
        // A cleared shortcut is never a conflict.
        #expect(ShortcutConflicts.resolve(.captureArea, recorded: nil, previous: area, assignments: [.allInOne: allInOne]) == .keep)
    }

    @Test func aConflictRevertsToTheOldShortcut() {
        let assignments: [ClearShotAction: ShortcutSpec] = [.captureArea: area, .allInOne: allInOne, .captureWindow: area]
        let resolution = ShortcutConflicts.resolve(.captureWindow, recorded: area, previous: commandShift6, assignments: assignments)
        #expect(resolution == .revert(to: commandShift6, conflictsWith: .captureArea))
    }

    @Test func aConflictWithNoOldShortcutRevertsToNone() {
        let assignments: [ClearShotAction: ShortcutSpec] = [.captureArea: area, .captureWindow: area]
        let resolution = ShortcutConflicts.resolve(.captureWindow, recorded: area, previous: nil, assignments: assignments)
        #expect(resolution == .revert(to: nil, conflictsWith: .captureArea))
    }
}
