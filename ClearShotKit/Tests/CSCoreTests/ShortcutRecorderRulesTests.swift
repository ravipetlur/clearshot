import Testing
@testable import CSCore

/// The Carbon virtual key codes (Events.h) these tests use. The tests carry their own copy of the numbers, so a wrong
/// one in the source can't be hidden by the same mistake here.
private enum Key {
    static let a = 0x00 // kVK_ANSI_A
    static let w = 0x0D // kVK_ANSI_W
    static let q = 0x0C // kVK_ANSI_Q
    static let digit4 = 0x15 // kVK_ANSI_4
    static let returnKey = 0x24 // kVK_Return
    static let tab = 0x30 // kVK_Tab
    static let space = 0x31 // kVK_Space
    static let delete = 0x33 // kVK_Delete
    static let escape = 0x35 // kVK_Escape
    static let f5 = 0x60 // kVK_F5
    static let f13 = 0x69 // kVK_F13
    static let forwardDelete = 0x75 // kVK_ForwardDelete
    static let leftArrow = 0x7B // kVK_LeftArrow
    static let keypad1 = 0x53 // kVK_ANSI_Keypad1
    /// kVK_F1 … kVK_F20: the codes are not in order.
    static let functionKeys = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
                               0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
}

private let command = ShortcutSpec.command
private let shift = ShortcutSpec.shift
private let option = ShortcutSpec.option
private let control = ShortcutSpec.control

/// Every combination of the four modifiers, as Carbon masks.
private let allMasks: [Int] = (0..<16).map { bits in
    (bits & 1 != 0 ? command : 0) | (bits & 2 != 0 ? shift : 0) | (bits & 4 != 0 ? option : 0) | (bits & 8 != 0 ? control : 0)
}

struct ShortcutRecorderRulesTests {
    private func outcome(_ keyCode: Int, _ modifiers: Int = 0) -> RecorderKeyOutcome {
        ShortcutRecorderRules.outcome(keyCode: keyCode, carbonModifiers: modifiers)
    }

    private func spec(_ keyCode: Int, _ modifiers: Int) -> ShortcutSpec {
        ShortcutSpec(carbonKeyCode: keyCode, carbonModifiers: modifiers)
    }

    // MARK: Escape and Delete

    @Test func escapeAloneCancels() {
        #expect(outcome(Key.escape) == .cancel)
    }

    @Test func escapeWithModifiersIsAKeyLikeAnyOther() {
        #expect(outcome(Key.escape, command) == .record(spec(Key.escape, command)))
        #expect(outcome(Key.escape, control) == .record(spec(Key.escape, control)))
        #expect(outcome(Key.escape, option) == .unsupported(.optionOnly))
        #expect(outcome(Key.escape, shift) == .reject)
    }

    @Test func deleteAndForwardDeleteAloneClear() {
        #expect(outcome(Key.delete) == .clear)
        #expect(outcome(Key.forwardDelete) == .clear)
    }

    @Test func deleteWithModifiersIsAKeyLikeAnyOther() {
        for keyCode in [Key.delete, Key.forwardDelete] {
            #expect(outcome(keyCode, command) == .record(spec(keyCode, command)))
            #expect(outcome(keyCode, option | command) == .record(spec(keyCode, option | command)))
            #expect(outcome(keyCode, option | shift) == .unsupported(.optionOnly))
            #expect(outcome(keyCode, shift) == .reject)
        }
    }

    // MARK: Ordinary keys

    @Test func aPlainKeyIsRejected() {
        #expect(outcome(Key.a) == .reject)
        #expect(outcome(Key.digit4) == .reject)
        #expect(outcome(Key.space) == .reject)
        #expect(outcome(Key.returnKey) == .reject)
        #expect(outcome(Key.leftArrow) == .reject)
        #expect(outcome(Key.keypad1) == .reject)
    }

    @Test func shiftAloneIsNotEnough() {
        #expect(outcome(Key.a, shift) == .reject)
        #expect(outcome(Key.digit4, shift) == .reject)
        #expect(outcome(Key.leftArrow, shift) == .reject)
    }

    @Test func commandOrControlRecords() {
        #expect(outcome(Key.a, control) == .record(spec(Key.a, control)))
        #expect(outcome(Key.a, command) == .record(spec(Key.a, command)))
        #expect(outcome(Key.a, control | option | shift | command) == .record(spec(Key.a, control | option | shift | command)))
    }

    @Test func optionWithCommandOrControlRecords() {
        #expect(outcome(Key.a, option | command) == .record(spec(Key.a, option | command)))
        #expect(outcome(Key.a, control | option) == .record(spec(Key.a, control | option)))
        #expect(outcome(Key.a, option | shift | command) == .record(spec(Key.a, option | shift | command)))
        #expect(outcome(Key.a, control | option | shift) == .record(spec(Key.a, control | option | shift)))
    }

    @Test func optionAloneOrWithShiftAloneIsUnsupportedOnEveryOrdinaryKey() {
        // Since macOS 15 the system doesn't deliver a global hot key whose only modifiers are ⌥ or ⌥⇧.
        for keyCode in [Key.a, Key.digit4, Key.space, Key.returnKey, Key.leftArrow, Key.keypad1, Key.escape, Key.delete] {
            #expect(outcome(keyCode, option) == .unsupported(.optionOnly), "key \(keyCode)")
            #expect(outcome(keyCode, option | shift) == .unsupported(.optionOnly), "key \(keyCode)")
        }
    }

    @Test func optionStillRecordsOnAFunctionKey() {
        #expect(outcome(Key.f5, option) == .record(spec(Key.f5, option)))
        #expect(outcome(Key.f13, option | shift) == .record(spec(Key.f13, option | shift)))
    }

    @Test func theDigitFourWithShiftAndCommandRecordsShiftCommandFour() {
        #expect(outcome(Key.digit4, shift | command) == .record(.commandShift(Key.digit4)))
    }

    @Test func everyModifierCombinationIsDecidedByWhatItHasOfCommandControlAndOption() {
        for mask in allMasks {
            let expected: RecorderKeyOutcome
            if mask & (command | control) != 0 {
                expected = .record(spec(Key.a, mask))
            } else if mask & option != 0 {
                expected = .unsupported(.optionOnly)
            } else {
                expected = .reject
            }
            #expect(outcome(Key.a, mask) == expected, "mask \(mask)")
        }
    }

    // MARK: Tab

    @Test func tabAndShiftTabLeaveTheField() {
        #expect(outcome(Key.tab) == .leave)
        #expect(outcome(Key.tab, shift) == .leave)
    }

    @Test func tabWithAnotherModifierIsAKeyLikeAnyOther() {
        #expect(outcome(Key.tab, command) == .record(spec(Key.tab, command)))
        #expect(outcome(Key.tab, control) == .record(spec(Key.tab, control)))
        #expect(outcome(Key.tab, control | shift) == .record(spec(Key.tab, control | shift)))
        #expect(outcome(Key.tab, option) == .unsupported(.optionOnly))
        #expect(outcome(Key.tab, option | shift) == .unsupported(.optionOnly))
    }

    @Test func aKeypadKeyOrArrowRecordsWithAModifier() {
        #expect(outcome(Key.keypad1, command) == .record(spec(Key.keypad1, command)))
        #expect(outcome(Key.leftArrow, control | shift) == .record(spec(Key.leftArrow, control | shift)))
    }

    // MARK: Function keys

    @Test func functionKeysRecordWithAnyModifiersOrNone() {
        #expect(Key.functionKeys.count == 20)
        for keyCode in Key.functionKeys {
            for mask in allMasks {
                #expect(outcome(keyCode, mask) == .record(spec(keyCode, mask)), "key \(keyCode), mask \(mask)")
            }
        }
    }

    @Test func f5AloneAndShiftF13Record() {
        #expect(outcome(Key.f5) == .record(spec(Key.f5, 0)))
        #expect(outcome(Key.f13, shift) == .record(spec(Key.f13, shift)))
    }

    // MARK: Stray bits

    @Test func bitsThatAreNotOneOfTheFourModifiersAreIgnored() {
        // Carbon's own bits for caps lock (alphaLock, 1 << 10) and Fn (1 << 17) are not part of a shortcut: they neither
        // make a plain key record, nor end up in the recorded shortcut.
        let capsLock = 1 << 10
        let fn = 1 << 17
        #expect(outcome(Key.a, capsLock) == .reject)
        #expect(outcome(Key.a, fn | shift) == .reject)
        #expect(outcome(Key.escape, capsLock) == .cancel)
        #expect(outcome(Key.delete, fn) == .clear)
        #expect(outcome(Key.tab, capsLock | fn) == .leave)
        #expect(outcome(Key.a, command | capsLock | fn) == .record(spec(Key.a, command)))
        #expect(outcome(Key.a, option | capsLock | fn) == .unsupported(.optionOnly))
        #expect(outcome(Key.f5, capsLock) == .record(spec(Key.f5, 0)))
    }
}

/// ClearShot's own main menu, as the recorder sees it: a key equivalent, its modifiers, and the item's title.
private let menu: [(key: String, carbonModifiers: Int, title: String)] = [
    (",", command, "Settings…"),
    ("q", command, "Quit ClearShot"),
    ("w", command, "Close"),
    ("s", command | shift, "Save As…"),
    ("\u{F708}", 0, "Preview"), // NSF5FunctionKey
]

/// What the US layout gives for a few keys.
private func usLayout(_ keyCode: Int) -> String? {
    [Key.a: "a", Key.w: "w", Key.q: "q", Key.digit4: "4", Key.keypad1: "1", 0x2B: ",", 0x01: "s"][keyCode]
}

struct RecorderMenuConflictTests {
    private func conflict(_ keyCode: Int, _ modifiers: Int, items: [(key: String, carbonModifiers: Int, title: String)] = menu,
                          layout: (Int) -> String? = usLayout) -> String? {
        ShortcutRecorderRules.menuConflict(for: ShortcutSpec(carbonKeyCode: keyCode, carbonModifiers: modifiers),
                                           character: layout, menuItems: items)
    }

    @Test func commandWAgainstACloseItemIsAConflict() {
        #expect(conflict(Key.w, command) == "Close")
        #expect(conflict(Key.q, command) == "Quit ClearShot")
        #expect(conflict(0x2B, command) == "Settings…")
    }

    @Test func differentModifiersAreNoConflict() {
        #expect(conflict(Key.w, command | shift) == nil)
        #expect(conflict(Key.w, control | command) == nil)
        #expect(conflict(Key.w, control) == nil)
        #expect(conflict(Key.w, command | option) == nil)
        #expect(conflict(0x01, command) == nil) // ⌘S is not ⇧⌘S
        #expect(conflict(0x01, command | shift) == "Save As…")
    }

    @Test func aKeyThatNoItemUsesIsNoConflict() {
        #expect(conflict(Key.a, command) == nil)
        #expect(conflict(Key.digit4, command | shift) == nil)
        #expect(conflict(Key.w, command, items: []) == nil)
    }

    @Test func theComparisonIgnoresTheCaseOfTheItemsKey() {
        let upper: [(key: String, carbonModifiers: Int, title: String)] = [("W", command, "Close")]
        #expect(conflict(Key.w, command, items: upper) == "Close")
        // And of the layout's character.
        #expect(conflict(Key.w, command, layout: { _ in "W" }) == "Close")
    }

    @Test func aKeypadKeyIsNeverAConflict() {
        // A menu can't tell the keypad's 1 from the main row's, and the shortcut has no menu form.
        let items: [(key: String, carbonModifiers: Int, title: String)] = [("1", command, "Zoom to Fit")]
        #expect(conflict(Key.keypad1, command, items: items) == nil)
        #expect(conflict(0x12, command, items: items, layout: { $0 == 0x12 ? "1" : nil }) == "Zoom to Fit")
    }

    @Test func aFunctionKeyIsComparedByItsMenuCharacter() {
        #expect(conflict(Key.f5, 0) == "Preview")
        #expect(conflict(Key.f5, command) == nil)
        #expect(conflict(Key.f13, 0) == nil)
    }

    @Test func aKeyWithNoCharacterIsNoConflict() {
        #expect(conflict(Key.w, command, layout: { _ in nil }) == nil)
        #expect(conflict(Key.w, command, layout: { _ in "" }) == nil)
    }

    @Test func bitsOfAnItemsMaskThatAreNotShortcutModifiersAreIgnored() {
        let items: [(key: String, carbonModifiers: Int, title: String)] = [("w", command | 0x20000 | (1 << 10), "Close")]
        #expect(conflict(Key.w, command, items: items) == "Close")
    }

    @Test func theFirstMatchingItemNamesTheConflict() {
        let items: [(key: String, carbonModifiers: Int, title: String)] = [("w", command, "Close"), ("w", command, "Close All")]
        #expect(conflict(Key.w, command, items: items) == "Close")
    }
}

struct RecorderOutcomeWithMenuTests {
    private func outcome(_ keyCode: Int, _ modifiers: Int, items: [(key: String, carbonModifiers: Int, title: String)] = menu)
        -> RecorderKeyOutcome {
        ShortcutRecorderRules.outcome(keyCode: keyCode, carbonModifiers: modifiers, character: usLayout) { items }
    }

    @Test func aRecordedShortcutTheMenuUsesIsUnsupported() {
        #expect(outcome(Key.w, command) == .unsupported(.usedByMenu(title: "Close")))
        #expect(outcome(Key.q, command) == .unsupported(.usedByMenu(title: "Quit ClearShot")))
        #expect(outcome(Key.f5, 0) == .unsupported(.usedByMenu(title: "Preview")))
    }

    @Test func aRecordedShortcutTheMenuDoesNotUseStillRecords() {
        #expect(outcome(Key.w, command | shift) == .record(.commandShift(Key.w)))
        #expect(outcome(Key.w, control | option) == .record(ShortcutSpec(carbonKeyCode: Key.w, carbonModifiers: control | option)))
        #expect(outcome(Key.w, command, items: []) == .record(ShortcutSpec(carbonKeyCode: Key.w, carbonModifiers: command)))
    }

    @Test func theOtherOutcomesAreTheRulesOwn() {
        #expect(outcome(Key.escape, 0) == .cancel)
        #expect(outcome(Key.delete, 0) == .clear)
        #expect(outcome(Key.tab, 0) == .leave)
        #expect(outcome(Key.w, 0) == .reject)
        #expect(outcome(Key.w, option) == .unsupported(.optionOnly))
    }

    @Test func theMenuIsReadOnlyForAShortcutThatWouldRecord() {
        var reads = 0
        func read(_ keyCode: Int, _ modifiers: Int) {
            _ = ShortcutRecorderRules.outcome(keyCode: keyCode, carbonModifiers: modifiers, character: usLayout) {
                reads += 1
                return menu
            }
        }
        read(Key.escape, 0)
        read(Key.delete, 0)
        read(Key.tab, 0)
        read(Key.w, 0)
        read(Key.w, shift)
        read(Key.w, option)
        #expect(reads == 0)
        read(Key.w, command)
        #expect(reads == 1)
    }
}

struct RecorderRejectionTests {
    @Test func theOptionOnlyMessageSaysWhatToAddAndWhy() {
        #expect(RecorderRejection.optionOnly.explanation == "Add ⌘ or ⌃: macOS ignores ⌥-only")
    }

    @Test func theMenuMessageNamesTheItem() {
        #expect(RecorderRejection.usedByMenu(title: "Close").explanation == "Used by ClearShot's Close command")
    }

    @Test func aTrailingEllipsisOfTheItemsTitleIsLeftOut() {
        #expect(RecorderRejection.usedByMenu(title: "Settings…").explanation == "Used by ClearShot's Settings command")
        #expect(RecorderRejection.usedByMenu(title: "Save As…").explanation == "Used by ClearShot's Save As command")
        #expect(RecorderRejection.usedByMenu(title: "Print...").explanation == "Used by ClearShot's Print command")
        #expect(RecorderRejection.usedByMenu(title: "Quit ClearShot").explanation == "Used by ClearShot's Quit ClearShot command")
    }
}

struct RecorderSessionTests {
    private let target = ShortcutSpec.commandShift(KeyCode.digit4)

    // MARK: Starting and ending

    @Test func aNewSessionIsIdle() {
        #expect(!RecorderSession().isRecording)
    }

    @Test func startingWhileIdlePausesTheHotkeysOnce() {
        var session = RecorderSession()
        #expect(session.start() == [.pauseHotkeys])
        #expect(session.isRecording)
    }

    @Test func startingAgainWhileRecordingDoesNothing() {
        var session = RecorderSession()
        _ = session.start()
        #expect(session.start() == [])
        #expect(session.isRecording)
        // Still one pause owed, so one resume closes it.
        #expect(session.end() == [.resumeHotkeys])
    }

    @Test func endingWhileIdleDoesNothing() {
        var session = RecorderSession()
        #expect(session.end() == [])
        #expect(!session.isRecording)
    }

    @Test func endingWhileRecordingResumesTheHotkeysOnce() {
        var session = RecorderSession()
        _ = session.start()
        #expect(session.end() == [.resumeHotkeys])
        #expect(!session.isRecording)
        #expect(session.end() == [])
    }

    // MARK: Keys

    @Test func cancelResumesAndStops() {
        var session = RecorderSession()
        _ = session.start()
        #expect(session.key(.cancel) == [.resumeHotkeys])
        #expect(!session.isRecording)
    }

    @Test func clearStoresNothingThenResumes() {
        var session = RecorderSession()
        _ = session.start()
        #expect(session.key(.clear) == [.store(nil), .resumeHotkeys])
        #expect(!session.isRecording)
    }

    @Test func recordStoresTheShortcutBeforeItResumes() {
        var session = RecorderSession()
        _ = session.start()
        #expect(session.key(.record(target)) == [.store(target), .resumeHotkeys])
        #expect(!session.isRecording)
    }

    @Test func rejectBeepsAndKeepsRecording() {
        var session = RecorderSession()
        _ = session.start()
        #expect(session.key(.reject) == [.beep])
        #expect(session.isRecording)
        #expect(session.key(.reject) == [.beep])
        #expect(session.isRecording)
    }

    @Test func anUnsupportedShortcutBeepsExplainsAndKeepsRecording() {
        var session = RecorderSession()
        _ = session.start()
        #expect(session.key(.unsupported(.optionOnly)) == [.beep, .explain(.optionOnly)])
        #expect(session.isRecording)
        #expect(session.key(.unsupported(.usedByMenu(title: "Close")))
            == [.beep, .explain(.usedByMenu(title: "Close"))])
        #expect(session.isRecording)
        // Still one pause owed.
        #expect(session.key(.record(target)) == [.store(target), .resumeHotkeys])
    }

    @Test func leavingResumesAndStopsWithoutAStore() {
        var session = RecorderSession()
        _ = session.start()
        #expect(session.key(.leave) == [.resumeHotkeys])
        #expect(!session.isRecording)
    }

    @Test func aKeyWhileIdleDoesNothing() {
        var session = RecorderSession()
        #expect(session.key(.record(target)) == [])
        #expect(session.key(.clear) == [])
        #expect(session.key(.cancel) == [])
        #expect(session.key(.leave) == [])
        #expect(session.key(.reject) == [])
        #expect(session.key(.unsupported(.optionOnly)) == [])
        #expect(!session.isRecording)
    }

    @Test func aKeyAfterTheSessionEndedDoesNothing() {
        var session = RecorderSession()
        _ = session.start()
        _ = session.key(.record(target))
        #expect(session.key(.record(target)) == [])
        #expect(session.key(.clear) == [])
    }

    // MARK: Modifiers

    @Test func aModifierPressedWhileRecordingClearsTheExplanation() {
        // After a refusal ("Add ⌘ or ⌃…") the field shows the reason; a modifier pressed next shows the modifiers held
        // again, as they are before any key.
        var session = RecorderSession()
        _ = session.start()
        #expect(session.modifiersChanged(from: 0, to: shift) == [.clearExplanation])
        #expect(session.modifiersChanged(from: option, to: option | shift) == [.clearExplanation])
        #expect(session.modifiersChanged(from: option | shift, to: option | shift | command) == [.clearExplanation])
        #expect(session.isRecording)
    }

    @Test func aModifierLetGoLeavesTheExplanation() {
        // ⌥ was held for the key that was refused; letting it go must not take the reason away with it.
        var session = RecorderSession()
        _ = session.start()
        #expect(session.modifiersChanged(from: option, to: 0) == [])
        #expect(session.modifiersChanged(from: option | shift, to: option) == [])
        #expect(session.modifiersChanged(from: option | shift | command | control, to: 0) == [])
        #expect(session.modifiersChanged(from: 0, to: 0) == [])
    }

    @Test func aModifierPassedFromOneKeyToAnotherCountsAsAdded() {
        var session = RecorderSession()
        _ = session.start()
        #expect(session.modifiersChanged(from: option, to: command) == [.clearExplanation])
    }

    @Test func bitsThatAreNotOneOfTheFourModifiersAreNotModifiersChanging() {
        // Caps lock (alphaLock, 1 << 10) and Fn (1 << 17) are not part of a shortcut, so pressing one tells nothing.
        let capsLock = 1 << 10
        let fn = 1 << 17
        var session = RecorderSession()
        _ = session.start()
        #expect(session.modifiersChanged(from: 0, to: capsLock) == [])
        #expect(session.modifiersChanged(from: option, to: option | fn | capsLock) == [])
        #expect(session.modifiersChanged(from: option | capsLock, to: option | shift | capsLock) == [.clearExplanation])
    }

    @Test func everyChangeOfModifiersClearsOnlyWhenAModifierIsAdded() {
        var session = RecorderSession()
        _ = session.start()
        for before in allMasks {
            for after in allMasks {
                let added = after & ~before != 0
                #expect(session.modifiersChanged(from: before, to: after) == (added ? [.clearExplanation] : []),
                        "from \(before) to \(after)")
            }
        }
    }

    @Test func aModifierWhileIdleDoesNothing() {
        let session = RecorderSession()
        #expect(session.modifiersChanged(from: 0, to: command) == [])
        var ended = RecorderSession()
        _ = ended.start()
        _ = ended.end()
        #expect(ended.modifiersChanged(from: 0, to: command) == [])
    }

    @Test func aModifierChangeIsNotAKeyAndOwesNothing() {
        // It changes no state: one resume still closes the pause, however many modifiers came and went.
        var session = RecorderSession()
        var effects = session.start()
        effects += session.key(.unsupported(.optionOnly))
        effects += session.modifiersChanged(from: option, to: option | shift)
        effects += session.modifiersChanged(from: option | shift, to: 0)
        #expect(session.isRecording)
        effects += session.end()
        #expect(effects == [.pauseHotkeys, .beep, .explain(.optionOnly), .clearExplanation, .resumeHotkeys])
    }

    // MARK: Balance

    /// Pauses and resumes in `effects`: every way out has to leave these equal.
    private func balance(_ effects: [RecorderEffect]) -> Int {
        effects.reduce(0) { total, effect in
            switch effect {
            case .pauseHotkeys: total + 1
            case .resumeHotkeys: total - 1
            case .store, .beep, .explain, .clearExplanation: total
            }
        }
    }

    @Test func everyPathOutOfRecordingResumesExactlyOnce() {
        let paths: [(name: String, steps: (inout RecorderSession) -> [RecorderEffect])] = [
            ("start, cancel", { s in s.start() + s.key(.cancel) }),
            ("start, clear", { s in s.start() + s.key(.clear) }),
            ("start, record", { s in s.start() + s.key(.record(ShortcutSpec.commandShift(KeyCode.digit4))) }),
            ("start, end", { s in s.start() + s.end() }),
            ("start, reject, reject, end", { s in s.start() + s.key(.reject) + s.key(.reject) + s.end() }),
            ("start, reject, record", { s in s.start() + s.key(.reject) + s.key(.record(ShortcutSpec.commandShift(KeyCode.digit4))) }),
            ("start, start, end", { s in s.start() + s.start() + s.end() }),
            ("start, end, end", { s in s.start() + s.end() + s.end() }),
            ("start, cancel, end", { s in s.start() + s.key(.cancel) + s.end() }),
            ("start, record, end, clear", { s in s.start() + s.key(.record(ShortcutSpec.commandShift(KeyCode.digit4))) + s.end() + s.key(.clear) }),
            ("start, leave", { s in s.start() + s.key(.leave) }),
            ("start, leave, end", { s in s.start() + s.key(.leave) + s.end() }),
            ("start, unsupported, leave", { s in s.start() + s.key(.unsupported(.optionOnly)) + s.key(.leave) }),
            ("start, unsupported, unsupported, end", { s in
                s.start() + s.key(.unsupported(.optionOnly)) + s.key(.unsupported(.usedByMenu(title: "Close"))) + s.end()
            }),
            ("start, reject, unsupported, record", { s in
                s.start() + s.key(.reject) + s.key(.unsupported(.optionOnly)) + s.key(.record(ShortcutSpec.commandShift(KeyCode.digit4)))
            }),
            ("start, unsupported, cancel, leave", { s in s.start() + s.key(.unsupported(.optionOnly)) + s.key(.cancel) + s.key(.leave) }),
        ]
        for path in paths {
            var session = RecorderSession()
            let effects = path.steps(&session)
            #expect(balance(effects) == 0, "\(path.name): \(effects)")
            #expect(effects.filter { $0 == .pauseHotkeys }.count == 1, "\(path.name): \(effects)")
            #expect(effects.filter { $0 == .resumeHotkeys }.count == 1, "\(path.name): \(effects)")
            #expect(!session.isRecording, "\(path.name)")
        }
    }

    @Test func aSessionCanRecordAgainAfterItEnded() {
        var session = RecorderSession()
        var effects: [RecorderEffect] = []
        for _ in 0..<3 {
            effects += session.start()
            effects += session.key(.reject)
            effects += session.key(.record(target))
        }
        #expect(balance(effects) == 0)
        #expect(effects.filter { $0 == .pauseHotkeys }.count == 3)
        #expect(effects.filter { $0 == .resumeHotkeys }.count == 3)
        #expect(effects.filter { $0 == .beep }.count == 3)
    }

    @Test func theStoreAlwaysComesBeforeTheResume() {
        for outcome in [RecorderKeyOutcome.clear, .record(target)] {
            var session = RecorderSession()
            _ = session.start()
            let effects = session.key(outcome)
            #expect(effects.count == 2)
            #expect(effects.last == .resumeHotkeys)
            if case .store = effects.first {} else { Issue.record("no store first: \(effects)") }
        }
    }
}
