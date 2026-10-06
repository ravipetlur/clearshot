import CSCore
import SwiftUI

/// Where thumbnails appear, how big they are, when they close, and what their Save button does.
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
        }
        .formStyle(.grouped)
    }

    static func intervalTitle(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "\(seconds) seconds"
        case 60: "1 minute"
        default: "\(seconds / 60) minutes"
        }
    }
}
