import CSAnnotation
import CSCore
import KeyboardShortcuts
import SwiftUI

struct ShortcutsPane: View {
    @Environment(Preferences.self) private var prefs
    @State private var query = ""
    @State private var conflictMessage: String?
    @State private var showSystemShortcutInfo = false
    @State private var takenBySystem: [ClearShotAction] = []
    /// Each action's shortcut as this pane last saw it, read on appear and after every change. The recorder has already
    /// stored a new shortcut when it reports it, so the one to go back to after a conflict comes from here.
    @State private var known: [ClearShotAction: ShortcutSpec] = [:]

    var body: some View {
        Form {
            if !takenBySystem.isEmpty {
                Section {
                    NoticeView(symbol: "exclamationmark.triangle.fill",
                               text: "macOS also uses \(SystemShortcutCheck.describe(takenBySystem)) and may open its own screenshot tool instead of ClearShot. Turn the macOS shortcut off in Keyboard Shortcuts › Screenshots, or pick a different shortcut here.",
                               buttonTitle: "Open Keyboard settings") {
                        NSWorkspace.shared.open(SystemSettingsLinks.keyboard)
                    }
                }
            }
            ForEach(ActionGroup.allCases) { group in
                let actions = ClearShotAction.matching(query).filter { $0.group == group }
                if !actions.isEmpty {
                    Section(group.title) {
                        ForEach(actions) { action in
                            LabeledContent(action.title) {
                                HStack(spacing: 6) {
                                    KeyboardShortcuts.Recorder(for: .for(action)) { shortcut in
                                        check(action, recorded: shortcut)
                                    }
                                    ResetToDefaultButton(rowTitle: action.title,
                                                         isAtDefault: known[action] == action.defaultShortcut) {
                                        resetToDefault(action)
                                    }
                                }
                            }
                            .contextMenu {
                                Button("Reset to default") { resetToDefault(action) }
                            }
                        }
                    }
                }
            }
            // The editor's tool letters, the same rows as Settings › Annotate › Tool shortcuts.
            let targets = AnnotateKeyTarget.matching(query)
            if !targets.isEmpty {
                Section {
                    ForEach(targets) { target in
                        ToolKeyRow(target: target)
                    }
                } header: {
                    Text(AnnotateKeyTarget.groupTitle)
                } footer: {
                    Text("Annotate's menu commands, such as Copy, Duplicate and Save, follow System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button("Use System Default Shortcuts…", action: useSystemDefaults)
                    Spacer()
                    Button("Restore Defaults") {
                        KeyboardShortcuts.reset(ClearShotAction.allCases.map { .for($0) })
                        prefs[Prefs.annotateToolKeys] = AnnotateToolKeys()
                        known = Self.storedShortcuts()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .searchable(text: $query, placement: .toolbar, prompt: "Search shortcuts")
        .onAppear { known = Self.storedShortcuts() }
        .task {
            // Re-check every second so the warning clears as soon as the macOS shortcut is turned off.
            while !Task.isCancelled {
                takenBySystem = SystemShortcutCheck.actionsTakenBySystem()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .alert("Shortcut is used for another action", isPresented: Binding(get: { conflictMessage != nil }, set: { if !$0 { conflictMessage = nil } })) {
            Button("Use old shortcut", role: .cancel) {}
        } message: {
            Text(conflictMessage ?? "")
        }
        .alert("Turn off the macOS screenshot shortcuts", isPresented: $showSystemShortcutInfo) {
            Button("Open Keyboard settings") { NSWorkspace.shared.open(SystemSettingsLinks.keyboard) }
            Button("Later", role: .cancel) {}
        } message: {
            Text("ClearShot now uses ⇧⌘3, ⇧⌘4 and ⇧⌘5. In Keyboard Shortcuts › Screenshots, turn off the macOS shortcuts so they don't open the built-in tool instead.")
        }
    }

    /// One shortcut per action: `shortcut`, just stored for `action` by its recorder or a reset, stays unless another
    /// action already has it. Then `action` gets back the shortcut it had before (none if it had none), and the alert
    /// names the other action.
    private func check(_ action: ClearShotAction, recorded shortcut: KeyboardShortcuts.Shortcut?) {
        let resolution = ShortcutConflicts.resolve(action, recorded: shortcut.map(ShortcutSpec.init(shortcut:)),
                                                   previous: known[action], assignments: Self.storedShortcuts())
        if case let .revert(previous, other) = resolution, let shortcut {
            KeyboardShortcuts.setShortcut(previous.map(KeyboardShortcuts.Shortcut.init(spec:)), for: .for(action))
            conflictMessage = "\(shortcut) is assigned to “\(other.title)”."
        }
        known = Self.storedShortcuts()
    }

    /// The row's reset button and context menu put back the action's default shortcut (none for most), checked as a
    /// recorded one.
    private func resetToDefault(_ action: ClearShotAction) {
        KeyboardShortcuts.reset(.for(action))
        check(action, recorded: KeyboardShortcuts.getShortcut(for: .for(action)))
    }

    /// Every action's stored shortcut; an action without one is absent.
    private static func storedShortcuts() -> [ClearShotAction: ShortcutSpec] {
        var result: [ClearShotAction: ShortcutSpec] = [:]
        for action in ClearShotAction.allCases {
            if let shortcut = KeyboardShortcuts.getShortcut(for: .for(action)) { result[action] = ShortcutSpec(shortcut: shortcut) }
        }
        return result
    }

    /// Sets the system's screenshot keys on the capture actions: ⇧⌘3 Fullscreen, ⇧⌘4 Area, ⇧⌘5 All-In-One, removing
    /// those keys from any other action first.
    private func useSystemDefaults() {
        let targets: [ClearShotAction] = [.captureFullscreen, .captureArea, .allInOne]
        for target in targets {
            guard let spec = target.defaultShortcut else { continue }
            let shortcut = KeyboardShortcuts.Shortcut(spec: spec)
            for action in ClearShotAction.allCases where action != target && KeyboardShortcuts.getShortcut(for: .for(action)) == shortcut {
                KeyboardShortcuts.setShortcut(nil, for: .for(action))
            }
            KeyboardShortcuts.setShortcut(shortcut, for: .for(target))
        }
        known = Self.storedShortcuts()
        takenBySystem = SystemShortcutCheck.actionsTakenBySystem()
        if !takenBySystem.isEmpty {
            showSystemShortcutInfo = true
        }
    }
}

private extension ShortcutSpec {
    init(shortcut: KeyboardShortcuts.Shortcut) {
        self.init(carbonKeyCode: shortcut.carbonKeyCode, carbonModifiers: shortcut.carbonModifiers)
    }
}
