import CSCore
import SwiftUI

/// Two columns of checkboxes, screenshots and recordings. At least one stays on in each column.
struct AfterCaptureGrid: View {
    @Environment(Preferences.self) private var prefs
    @State private var showMinimumAlert = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                Text("")
                Text("Screenshot").font(.headline)
                Text("Recording").font(.headline)
            }
            ForEach(AfterCaptureAction.allCases) { action in
                GridRow {
                    Text(action.rowTitle)
                    checkbox(action, key: Prefs.afterScreenshotActions)
                    if action.appliesToRecordings {
                        checkbox(action, key: Prefs.afterRecordingActions)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .alert("At least one action needs to be enabled", isPresented: $showMinimumAlert) {
            Button("OK", role: .cancel) {}
        }
    }

    private func checkbox(_ action: AfterCaptureAction, key: PrefKey<Set<AfterCaptureAction>>) -> some View {
        Toggle(action.rowTitle, isOn: Binding(
            get: { prefs[key].contains(action) },
            set: { on in
                if let updated = AfterCaptureAction.toggling(action, in: prefs[key], on: on) {
                    prefs[key] = updated
                } else {
                    showMinimumAlert = true
                }
            }
        ))
        .labelsHidden()
        .toggleStyle(.checkbox)
    }
}
