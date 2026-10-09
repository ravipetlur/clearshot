/// What a key pressed while a shortcut is being recorded does.
public enum RecorderKeyOutcome: Equatable, Sendable {
    /// Escape alone: stop recording and change nothing.
    case cancel
    /// Delete or Forward Delete alone: the action has no shortcut.
    case clear
    /// Tab or Shift-Tab alone: stop recording and change nothing, and let the key through, so that keyboard focus moves on.
    case leave
    /// A usable shortcut.
    case record(ShortcutSpec)
    /// Not a shortcut (a plain letter, or Shift and a letter): beep and keep recording.
    case reject
    /// A shortcut that can't be used, for a reason the field shows: beep and keep recording.
    case unsupported(RecorderRejection)
}

/// Why a shortcut that has the modifiers it needs still can't be used.
public enum RecorderRejection: Equatable, Sendable {
    /// ⌥ or ⌥⇧ and no ⌘ or ⌃. Since macOS 15, macOS doesn't deliver a global hot key whose only modifiers are those, so it
    /// would show in Settings and the menu and never fire.
    case optionOnly
    /// A key equivalent of ClearShot's own main menu, such as ⌘W for Close. As a global hot key it would take that
    /// command from every app.
    case usedByMenu(title: String)

    /// What the field says, in a line: what to do or what uses the shortcut.
    public var explanation: String {
        switch self {
        case .optionOnly:
            "Add ⌘ or ⌃: macOS ignores ⌥-only"
        case .usedByMenu(let title):
            // A menu item's title ends in "…" when it opens a dialog; the command is called by the name before it.
            "Used by ClearShot's \(Self.commandName(title)) command"
        }
    }

    private static func commandName(_ title: String) -> String {
        var name = Substring(title)
        while let last = name.last, last == "…" || last == "." || last == " " { name = name.dropLast() }
        return name.isEmpty ? title : String(name)
    }
}

/// The recorder's rules for a key: which presses make a shortcut. Pure, so every key and modifier combination is tested.
public enum ShortcutRecorderRules {
    // Carbon virtual key codes (kVK_* in HIToolbox's Events.h).
    private static let tab = 0x30 // kVK_Tab
    private static let escape = 0x35 // kVK_Escape
    private static let delete = 0x33 // kVK_Delete (the backspace key)
    private static let forwardDelete = 0x75 // kVK_ForwardDelete

    /// kVK_F1 … kVK_F20. The codes are not in order.
    private static let functionKeys: Set<Int> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, // F1 … F10
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A, // F11 … F20
    ]

    /// The modifiers that make an ordinary key a shortcut. Shift alone doesn't: it only types a capital.
    private static let primaryModifiers = ShortcutSpec.command | ShortcutSpec.control | ShortcutSpec.option
    /// The four modifiers a shortcut can have. Any other bit (caps lock, Fn) is not part of the shortcut.
    fileprivate static let shortcutModifiers = primaryModifiers | ShortcutSpec.shift

    /// What a key press means while recording. `carbonModifiers` is the Carbon mask of the modifiers held
    /// (`CarbonModifiers.from(eventFlags:)`); bits other than the four shortcut modifiers are ignored.
    ///
    /// - Escape or Delete with no modifier: cancel or clear. With one, they are keys like any other (⌘⎋ is a shortcut,
    ///   ⇧⎋ is not).
    /// - Tab, with no modifier or only Shift: leave the field.
    /// - F1–F20: recorded, with any modifiers or none.
    /// - A key with ⌘ or ⌃: recorded.
    /// - A key with ⌥ but neither ⌘ nor ⌃, Shift or not: unsupported, since macOS ignores those global hot keys.
    /// - Anything else (no modifier, or only Shift) is rejected.
    ///
    /// Whether ClearShot's own menu uses a shortcut that would record is for the overload with the menu to say.
    public static func outcome(keyCode: Int, carbonModifiers: Int) -> RecorderKeyOutcome {
        let modifiers = carbonModifiers & shortcutModifiers
        if modifiers == 0 {
            if keyCode == escape { return .cancel }
            if keyCode == delete || keyCode == forwardDelete { return .clear }
        }
        if keyCode == tab, modifiers & ~ShortcutSpec.shift == 0 { return .leave }
        let shortcut = ShortcutSpec(carbonKeyCode: keyCode, carbonModifiers: modifiers)
        if functionKeys.contains(keyCode) { return .record(shortcut) }
        if modifiers & (ShortcutSpec.command | ShortcutSpec.control) != 0 { return .record(shortcut) }
        if modifiers & ShortcutSpec.option != 0 { return .unsupported(.optionOnly) }
        return .reject
    }

    /// `outcome(keyCode:carbonModifiers:)`, and a shortcut that would record becomes unsupported when ClearShot's own main
    /// menu uses it. `menuItems` is read only then: the menu's key equivalents (see `menuConflict`).
    public static func outcome(keyCode: Int, carbonModifiers: Int, character: (Int) -> String?,
                               menuItems: () -> [(key: String, carbonModifiers: Int, title: String)]) -> RecorderKeyOutcome {
        let outcome = outcome(keyCode: keyCode, carbonModifiers: carbonModifiers)
        guard case .record(let shortcut) = outcome,
              let title = menuConflict(for: shortcut, character: character, menuItems: menuItems()) else { return outcome }
        return .unsupported(.usedByMenu(title: title))
    }

    /// The title of the first of `menuItems` that `shortcut` is the key equivalent of, or nil. Each item is a key
    /// equivalent, its modifiers as a Carbon mask, and its title. `shortcut` is converted as the status menu converts it
    /// (`MenuKeyEquivalent.make`), so it has a conflict only when a menu could show it: a keypad key, which has no menu
    /// form, is never one. Keys are compared in lower case, modifiers by the four a shortcut can have.
    public static func menuConflict(for shortcut: ShortcutSpec, character: (Int) -> String?,
                                    menuItems: [(key: String, carbonModifiers: Int, title: String)]) -> String? {
        guard let equivalent = MenuKeyEquivalent.make(for: shortcut, character: character) else { return nil }
        let key = equivalent.key.lowercased()
        let modifiers = equivalent.carbonModifiers & shortcutModifiers
        return menuItems.first { $0.key.lowercased() == key && $0.carbonModifiers & shortcutModifiers == modifiers }?.title
    }
}

/// What the recorder's view has to do, in order, after a step of its `RecorderSession`.
public enum RecorderEffect: Equatable, Sendable {
    /// Stop the global hot keys, so that a shortcut ClearShot already uses is recorded instead of run.
    case pauseHotkeys
    /// Let the hot keys register again; the shortcut stored just before it, if any, is among them.
    case resumeHotkeys
    /// Write the shortcut to the store; nil for a cleared one.
    case store(ShortcutSpec?)
    /// Play the system beep.
    case beep
    /// Show why the shortcut just pressed can't be used, until the next key or a modifier pressed (`clearExplanation`).
    case explain(RecorderRejection)
    /// Take the explanation away, so that the modifiers held show again.
    case clearExplanation
}

/// The recorder's state machine: whether a field is recording, and which hot-key pauses and resumes that takes. Every
/// `pauseHotkeys` is matched by exactly one `resumeHotkeys`, whichever way recording ends, so the hot keys can't stay
/// stopped. The view runs the effects each step returns; this holds no references and does nothing itself.
public struct RecorderSession: Sendable, Equatable {
    public private(set) var isRecording = false

    public init() {}

    /// A click or Space/Return on the field. Starting while recording does nothing.
    public mutating func start() -> [RecorderEffect] {
        guard !isRecording else { return [] }
        isRecording = true
        return [.pauseHotkeys]
    }

    /// The outcome of a key pressed while recording. A reject beeps and keeps recording, and so does an unsupported
    /// shortcut, which also says why; every other outcome ends it. The shortcut is stored before the hot keys resume, so
    /// that they register what was just recorded. Does nothing when not recording.
    public mutating func key(_ outcome: RecorderKeyOutcome) -> [RecorderEffect] {
        guard isRecording else { return [] }
        switch outcome {
        case .reject:
            return [.beep]
        case .unsupported(let rejection):
            return [.beep, .explain(rejection)]
        case .cancel, .leave:
            isRecording = false
            return [.resumeHotkeys]
        case .clear:
            isRecording = false
            return [.store(nil), .resumeHotkeys]
        case .record(let shortcut):
            isRecording = false
            return [.store(shortcut), .resumeHotkeys]
        }
    }

    /// A modifier key went down or up while recording; `before` and `after` are the Carbon masks of the modifiers held
    /// before and after. When one is added, the explanation of a refused key goes (`clearExplanation`), so that the
    /// modifiers held show live again. When one is only let go it stays: ⌥ is usually still down for the key that was
    /// refused, and the reason would vanish as it is released. Only the four shortcut modifiers count: caps lock and Fn
    /// are no part of a shortcut. It changes no state, and does nothing when not recording.
    public func modifiersChanged(from before: Int, to after: Int) -> [RecorderEffect] {
        guard isRecording else { return [] }
        let shortcutModifiers = ShortcutRecorderRules.shortcutModifiers
        let added = (after & shortcutModifiers) & ~(before & shortcutModifiers)
        return added == 0 ? [] : [.clearExplanation]
    }

    /// Recording ends without a key: a click outside the field, the window losing key status, the field leaving its
    /// window, or the pane going away. Does nothing when not recording.
    public mutating func end() -> [RecorderEffect] {
        guard isRecording else { return [] }
        isRecording = false
        return [.resumeHotkeys]
    }
}
