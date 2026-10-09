import AppKit
import CSCore
import SwiftUI

/// The shortcut field of Settings › Shortcuts, for one action: it shows the action's shortcut and records a new one.
/// `onChange` runs with each shortcut recorded or cleared, after it is in the `ShortcutStore`; the pane's conflict check
/// is there. `onReset` is the field's own context-menu item, "Reset to default": a right-click on the field opens the
/// field's menu rather than the row's.
struct ShortcutRecorder: NSViewRepresentable {
    let action: ClearShotAction
    let onChange: (ShortcutSpec?) -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let field = ShortcutRecorderField(action: action)
        field.onChange = onChange
        field.onReset = onReset
        return field
    }

    func updateNSView(_ field: ShortcutRecorderField, context: Context) {
        field.onChange = onChange
        field.onReset = onReset
        field.use(action)
    }

    /// The pane going away (another pane picked, the row filtered out by a search) ends a recording: the hot keys must
    /// not stay stopped.
    static func dismantleNSView(_ field: ShortcutRecorderField, coordinator: Void) {
        field.endRecording()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: ShortcutRecorderField, context: Context) -> CGSize? {
        ShortcutRecorderField.preferredSize
    }
}

/// A rounded field with the shortcut as text, and a small button that clears it.
///
/// - **States:** "Record Shortcut" with no shortcut, the shortcut's text with one, and while recording "Type Shortcut"
///   or the modifiers held so far (`⌃⇧`) with the focus ring. A key that can't be a shortcut for a reason of its own
///   (⌥ alone, a key of ClearShot's own menu) shows the reason in place of those, until the next key, or until a
///   modifier is pressed, which brings the modifiers held back; letting one go leaves the reason up.
/// - **Recording** starts on a click, or Space or Return while the field has focus. It goes on until a key ends it
///   (`ShortcutRecorderRules`; Tab ends it and moves focus on), the pointer presses anywhere else (a right-click or a
///   control-click on the field too, for its menu), the window stops being key, the app goes to the background, the
///   field loses focus or leaves its window, or the pane goes away.
/// - **Hot keys:** a recording stops ClearShot's global hot keys, so that a shortcut ClearShot already uses is recorded
///   instead of run. `RecorderSession` pairs each stop with exactly one restart whichever way recording ends, and every
///   way ends through `perform(_:)`.
/// - **Keys:** while recording, a local event monitor takes every key press and modifier change, so none reaches the
///   window or the app. It exists only while recording.
/// - **One at a time:** a field that starts recording ends the one that is.
final class ShortcutRecorderField: NSView {
    static let preferredSize = NSSize(width: 200, height: 24)
    private static let cornerRadius: CGFloat = 6
    /// The space around the clear button, which the text keeps clear of on both sides so that it doesn't move as the
    /// button comes and goes.
    private static let margin: CGFloat = 4
    private static let clearButtonSide: CGFloat = 16
    /// The explanation of a rejected key is a line of its own, so it is set smaller than the shortcut.
    private static let explanationFont = NSFont.systemFont(ofSize: 10)
    private static let shortcutFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    /// The field that is recording; weak, so a field that is gone without having ended can't be held by it.
    private static weak var recordingField: ShortcutRecorderField?

    // Carbon virtual key codes (kVK_* in Events.h) of the keys that start a recording from the keyboard.
    private static let returnKeyCode: UInt16 = 0x24
    private static let spaceKeyCode: UInt16 = 0x31

    private(set) var action: ClearShotAction
    var onChange: ((ShortcutSpec?) -> Void)?
    var onReset: (() -> Void)?

    private var session = RecorderSession()
    /// The action's shortcut in the store, as of the last time it was read.
    private var shortcut: ShortcutSpec?
    /// The modifiers held while recording, as a Carbon mask.
    private var heldModifiers = 0
    /// Why the last key pressed while recording can't be a shortcut; shown until the next key or a modifier pressed.
    private var explanation: String?
    private var eventMonitor: Any?
    /// What ends a recording without a key; only while recording.
    private var recordingObservers: [any NSObjectProtocol] = []
    private var storeObserver: (any NSObjectProtocol)?
    private let label = NSTextField(labelWithString: "")
    private let clearButton = NSButton()

    init(action: ClearShotAction) {
        self.action = action
        shortcut = ShortcutStore.app.shortcut(for: action)
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))
        focusRingType = .exterior

        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.font = Self.shortcutFont
        label.setAccessibilityElement(false)
        addSubview(label)

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear shortcut")
        clearButton.imagePosition = .imageOnly
        clearButton.isBordered = false
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        clearButton.toolTip = "Clear shortcut"
        clearButton.setAccessibilityLabel("Clear shortcut")
        addSubview(clearButton)

        let resetItem = NSMenuItem(title: "Reset to default", action: #selector(resetClicked), keyEquivalent: "")
        resetItem.target = self
        let menu = NSMenu()
        menu.addItem(resetItem)
        self.menu = menu

        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        // The store's changes (a reset, the pane's revert after a conflict, Use System Default Shortcuts…) show at once.
        // The center keeps the observer until the field removes it, so it captures the field weakly.
        storeObserver = NotificationCenter.default.addObserver(forName: ShortcutStore.didChange, object: ShortcutStore.app,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeDidChange() }
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        // Recording is normally over long before this, when the view leaves its window; this is for one that isn't. It
        // only lets the hot keys go and removes the monitors: there is nothing left to show.
        run(session.end())
    }

    /// The field shows `action`'s shortcut from now on. SwiftUI keeps a row's field for the same action; this is for the
    /// day it doesn't.
    func use(_ action: ClearShotAction) {
        guard action != self.action else { return }
        endRecording()
        self.action = action
        shortcut = ShortcutStore.app.shortcut(for: action)
        refresh()
    }

    // MARK: Recording

    /// Starts recording, ending any other field's first. Does nothing while this field is already recording, or when it
    /// is not in a window.
    func startRecording() {
        guard window != nil else { return }
        if let other = Self.recordingField, other !== self { other.endRecording() }
        let effects = session.start()
        guard !effects.isEmpty else { return }
        Self.recordingField = self
        heldModifiers = CarbonModifiers.from(eventFlags: NSEvent.modifierFlags.rawValue)
        perform(effects)
        window?.makeFirstResponder(self)
        installMonitors()
    }

    /// Ends the recording without a shortcut: a click elsewhere, the window or the app going inactive, focus going to
    /// another view, the field leaving its window, the pane going away. Does nothing when not recording.
    func endRecording() {
        perform(session.end())
    }

    /// Runs what the session asks for, in order, and shows the new state. Every way out of recording comes through here
    /// (or `run`, from `deinit`), so the hot keys are restarted exactly once per stop and the monitors are gone.
    private func perform(_ effects: [RecorderEffect]) {
        guard !effects.isEmpty else { return }
        run(effects)
        refresh()
    }

    private func run(_ effects: [RecorderEffect]) {
        for effect in effects {
            switch effect {
            case .pauseHotkeys:
                HotkeyCenter.shared.pause()
            case .resumeHotkeys:
                HotkeyCenter.shared.resume()
            case .store(let newShortcut):
                ShortcutStore.app.set(newShortcut, for: action)
                onChange?(newShortcut)
                // The pane may have put the previous shortcut back, after a conflict.
                shortcut = ShortcutStore.app.shortcut(for: action)
            case .beep:
                NSSound.beep()
            case .explain(let rejection):
                explanation = rejection.explanation
                NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                    .announcement: rejection.explanation,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
            case .clearExplanation:
                explanation = nil
            }
        }
        if !session.isRecording { removeMonitors() }
    }

    private func installMonitors() {
        // The effects or the focus change that came before can have ended the recording; a monitor must not outlive it.
        guard session.isRecording, eventMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            guard let self else { return event }
            return self.recordingEvent(event)
        }
        let center = NotificationCenter.default
        let ends: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didResignKeyNotification, window),
            (NSApplication.didResignActiveNotification, nil),
        ]
        recordingObservers = ends.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endRecording() }
            }
        }
    }

    private func removeMonitors() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        recordingObservers.forEach(NotificationCenter.default.removeObserver)
        recordingObservers = []
        heldModifiers = 0
        explanation = nil
        if Self.recordingField === self { Self.recordingField = nil }
    }

    /// An event while recording. Keys and modifier changes are taken (nil), whatever they are, except the Tab that ends
    /// the recording: that goes on, so that keyboard focus moves as it always does. A press of the mouse goes on to
    /// where it was aimed, after ending the recording if it is aimed anywhere but at this field; a right-click or a
    /// control-click on the field ends it too, for the context menu it opens.
    private func recordingEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            // A key held down repeats; the first press has been decided.
            guard !event.isARepeat else { return nil }
            explanation = nil
            let modifiers = CarbonModifiers.from(eventFlags: event.modifierFlags.rawValue)
            let outcome = ShortcutRecorderRules.outcome(keyCode: Int(event.keyCode), carbonModifiers: modifiers,
                                                        character: { KeyboardLayout.character(for: $0) },
                                                        menuItems: mainMenuKeyEquivalents)
            perform(session.key(outcome))
            return outcome == .leave ? event : nil
        case .flagsChanged:
            // A modifier pressed after a refusal shows the modifiers held again; one let go leaves the reason up.
            let held = CarbonModifiers.from(eventFlags: event.modifierFlags.rawValue)
            let effects = session.modifiersChanged(from: heldModifiers, to: held)
            heldModifiers = held
            run(effects)
            refresh()
        default:
            let opensMenu = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            if opensMenu || !isAimed(at: event) { endRecording() }
            return event
        }
        return nil
    }

    /// The key equivalents of ClearShot's main menu, for the rule against recording a key the menu uses: each item that
    /// has one, in the submenus too, with its modifiers as a Carbon mask. Whether an item is enabled doesn't matter: it
    /// follows the responder chain, so with Settings in front the editor's Save is disabled, and a global hot key on its
    /// key would still take Save from the editor and from every other app.
    private func mainMenuKeyEquivalents() -> [(key: String, carbonModifiers: Int, title: String)] {
        var found: [(key: String, carbonModifiers: Int, title: String)] = []
        func collect(_ menu: NSMenu) {
            for item in menu.items where !item.isSeparatorItem {
                if let submenu = item.submenu { collect(submenu) }
                guard !item.keyEquivalent.isEmpty else { continue }
                found.append((item.keyEquivalent, CarbonModifiers.from(eventFlags: item.keyEquivalentModifierMask.rawValue),
                              item.title))
            }
        }
        if let mainMenu = NSApp.mainMenu { collect(mainMenu) }
        return found
    }

    private func isAimed(at event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    // MARK: View

    override var intrinsicContentSize: NSSize { Self.preferredSize }
    override var acceptsFirstResponder: Bool { true }

    /// A click on the field starts a recording even when it is the click that brings the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== window { endRecording() }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { endRecording() }
        return resigned
    }

    /// The field takes the presses aimed at its label; only the clear button, while it shows, takes its own.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === clearButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click is the context menu's.
        guard !event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        startRecording()
    }

    /// Space or Return, with no modifier, on the focused field starts a recording; every other key is the window's (Tab
    /// goes on to the next view).
    override func keyDown(with event: NSEvent) {
        let modifiers = CarbonModifiers.from(eventFlags: event.modifierFlags.rawValue)
        if modifiers == 0, event.keyCode == Self.returnKeyCode || event.keyCode == Self.spaceKeyCode {
            startRecording()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        startRecording()
        return true
    }

    override func layout() {
        super.layout()
        let button = Self.clearButtonSide
        clearButton.frame = NSRect(x: bounds.width - Self.margin - button, y: (bounds.height - button) / 2,
                                   width: button, height: button)
        // The clear button is gone while recording, and the text may be a line of explanation: it takes the room.
        let textInset = session.isRecording ? Self.margin * 2 : Self.margin + button
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: textInset, y: (bounds.height - height) / 2, width: bounds.width - 2 * textInset, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        NSColor.controlBackgroundColor.setFill()
        outline.fill()
        (session.isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        outline.stroke()
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // MARK: Showing the state

    private func storeDidChange() {
        let stored = ShortcutStore.app.shortcut(for: action)
        guard stored != shortcut else { return }
        shortcut = stored
        refresh()
    }

    /// The text, the clear button and the accessibility value for the state now.
    private func refresh() {
        let text: String
        var isPlaceholder = false
        let explained = session.isRecording ? explanation : nil
        if let explained {
            text = explained
        } else if session.isRecording {
            let held = ShortcutText.modifierGlyphs(heldModifiers)
            isPlaceholder = held.isEmpty
            text = isPlaceholder ? "Type Shortcut" : held
        } else if let shortcut {
            text = ShortcutText.string(for: shortcut)
        } else {
            text = "Record Shortcut"
            isPlaceholder = true
        }
        label.stringValue = text
        label.font = explained == nil ? Self.shortcutFont : Self.explanationFont
        label.textColor = explained != nil ? .systemRed : isPlaceholder ? .placeholderTextColor : .labelColor
        // A long explanation (a menu item with a long name) is cut to the field; the tooltip has all of it.
        toolTip = explained
        clearButton.isHidden = session.isRecording || shortcut == nil
        needsLayout = true
        needsDisplay = true
        noteFocusRingMaskChanged()

        setAccessibilityLabel("Shortcut for \(action.title)")
        let value = session.isRecording ? "Recording" : shortcut.map { ShortcutText.string(for: $0) } ?? "None"
        if accessibilityValue() as? String != value {
            setAccessibilityValue(value)
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    @objc private func clearClicked() {
        ShortcutStore.app.set(nil, for: action)
        onChange?(nil)
        shortcut = ShortcutStore.app.shortcut(for: action)
        refresh()
    }

    @objc private func resetClicked() {
        onReset?()
    }
}
