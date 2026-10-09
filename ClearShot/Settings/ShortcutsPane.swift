import CSAnnotation
import CSCore
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
                               text: "macOS also uses \(SystemShortcutCheck.describe(takenBySystem)) for its own shortcuts and may act on them instead of ClearShot. Turn those off in System Settings › Keyboard › Keyboard Shortcuts, or pick different shortcuts here.",
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
                                    ShortcutRecorder(action: action,
                                                     onChange: { check(action, recorded: $0) },
                                                     onReset: { resetToDefault(action) })
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
                        ShortcutStore.app.resetAll()
                        prefs[Prefs.annotateToolKeys] = AnnotateToolKeys()
                        known = ShortcutStore.app.all()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .searchable(text: $query, placement: .toolbar, prompt: "Search shortcuts")
        .onAppear { known = ShortcutStore.app.all() }
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
    private func check(_ action: ClearShotAction, recorded shortcut: ShortcutSpec?) {
        let resolution = ShortcutConflicts.resolve(action, recorded: shortcut, previous: known[action],
                                                   assignments: ShortcutStore.app.all())
        if case let .revert(previous, other) = resolution, let shortcut {
            ShortcutStore.app.set(previous, for: action)
            conflictMessage = "\(ShortcutText.string(for: shortcut)) is assigned to “\(other.title)”."
        }
        known = ShortcutStore.app.all()
    }

    /// The row's reset button and context menu put back the action's default shortcut (none for most), checked as a
    /// recorded one.
    private func resetToDefault(_ action: ClearShotAction) {
        ShortcutStore.app.reset(action)
        check(action, recorded: ShortcutStore.app.shortcut(for: action))
    }

    /// Sets the system's screenshot keys on the capture actions: ⇧⌘3 Fullscreen, ⇧⌘4 Area, ⇧⌘5 All-In-One, removing
    /// those keys from any other action first.
    private func useSystemDefaults() {
        let targets: [ClearShotAction] = [.captureFullscreen, .captureArea, .allInOne]
        for target in targets {
            guard let shortcut = target.defaultShortcut else { continue }
            for action in ClearShotAction.allCases where action != target && ShortcutStore.app.shortcut(for: action) == shortcut {
                ShortcutStore.app.set(nil, for: action)
            }
            ShortcutStore.app.set(shortcut, for: target)
        }
        known = ShortcutStore.app.all()
        takenBySystem = SystemShortcutCheck.actionsTakenBySystem()
        if !takenBySystem.isEmpty {
            showSystemShortcutInfo = true
        }
    }
}
