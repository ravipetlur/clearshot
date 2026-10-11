import CSCore
import CSSensitive
import SwiftUI

/// Where thumbnails appear, how big they are, when they close, what their Save button does, and the secrets check on them.
struct QuickAccessPane: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Position on screen", selection: prefs.binding(Prefs.quickAccessPosition)) {
                    ForEach(QuickAccessPosition.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Overlay size", selection: prefs.binding(Prefs.quickAccessSize)) {
                    ForEach(QuickAccessSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Move to the active screen", isOn: prefs.binding(Prefs.quickAccessMoveToActiveScreen))
            }
            Section {
                Toggle("Close automatically", isOn: prefs.binding(Prefs.quickAccessAutoClose))
                Picker("After", selection: prefs.binding(Prefs.quickAccessAutoCloseSeconds)) {
                    ForEach(Prefs.autoCloseIntervalChoices, id: \.self) { Text(Self.intervalTitle($0)).tag($0) }
                }
                .disabled(!prefs[Prefs.quickAccessAutoClose])
                Picker("Then", selection: prefs.binding(Prefs.quickAccessAutoCloseAction)) {
                    ForEach(AutoCloseAction.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!prefs[Prefs.quickAccessAutoClose])
            } header: {
                Text("Auto-close")
            } footer: {
                Text("The timer pauses while the pointer is over a thumbnail.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Clicking Save", selection: prefs.binding(Prefs.quickAccessSaveAsksForLocation)) {
                    Text("Save to the export location").tag(false)
                    Text("Ask where to save").tag(true)
                }
            } header: {
                Text("Save button")
            } footer: {
                Text("Hold ⌥ Option while clicking to do the opposite.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Close after dragging", isOn: prefs.binding(Prefs.quickAccessCloseAfterDragging))
            } header: {
                Text("Drag and drop")
            } footer: {
                Text("Hold ⌥ Option while dragging to do the opposite.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // The master switch is for the automatic checks alone: new thumbnails, and the picture open in Annotate (its
            // sensitive-info button). The kinds are what they look for and what Annotate's Mask Sensitive Info, a request made on
            // purpose, looks for, so they stay switchable whether or not the check is on.
            Section("Sensitive info") {
                Toggle("Check screenshots for sensitive info", isOn: prefs.binding(Prefs.sensitiveCheckEnabled))
            }
            Section {
                ForEach(SensitiveKind.allCases, id: \.self) { kind in
                    Toggle(isOn: binding(for: kind)) {
                        Text(kind.title)
                        Text(kind.explanation)
                    }
                }
            } header: {
                Text("Look for")
            } footer: {
                Text("Checked on this Mac; nothing leaves it. The first switch turns the automatic check of new screenshots, and of the picture open in Annotate, on or off. The kinds also set what Annotate's sensitive-info button and Edit › Mask Sensitive Info look for. Changes apply to new screenshots.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The switch for one kind of finding: whether the kind is in the set of kinds the check looks for.
    private func binding(for kind: SensitiveKind) -> Binding<Bool> {
        Binding(
            get: { prefs[Prefs.sensitiveKinds].contains(kind.option) },
            set: { on in
                var kinds = prefs[Prefs.sensitiveKinds]
                if on { kinds.insert(kind.option) } else { kinds.remove(kind.option) }
                prefs[Prefs.sensitiveKinds] = kinds
            }
        )
    }

    static func intervalTitle(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "\(seconds) seconds"
        case 60: "1 minute"
        default: "\(seconds / 60) minutes"
        }
    }
}
