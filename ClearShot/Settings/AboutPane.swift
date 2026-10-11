import AppKit
import CSCore
import CSUpdate
import SwiftUI

struct AboutPane: View {
    /// The updater; nil in a build that names no update repository, which then shows no update rows.
    let updates: UpdateCenter?

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("ClearShot").font(.largeTitle.bold())
            Text("Version \(Bundle.main.versionString)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("A screenshot and screen recording app for macOS.")
                .foregroundStyle(.secondary)
            Button("Show logs in Finder") {
                try? FileManager.default.createDirectory(at: FileLogSink.shared.directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(FileLogSink.shared.directory)
            }
            .padding(.top, 8)
            if let updates {
                UpdateRows(updates: updates)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

/// "Check for updates automatically", "Last checked: …" and Check Now.
private struct UpdateRows: View {
    let updates: UpdateCenter
    @Environment(Preferences.self) private var prefs

    var body: some View {
        VStack(spacing: 8) {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { prefs[Prefs.updateCheckAutomatically] },
                set: { on in
                    prefs[Prefs.updateCheckAutomatically] = on
                    updates.automaticChecksChanged()
                }
            ))
            HStack(spacing: 8) {
                // Re-read every half minute, so "5 minutes ago" keeps up.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(LastChecked.text(lastCheck: updates.lastCheck, now: context.date))
                        .foregroundStyle(.secondary)
                }
                // Its place is kept, so the row doesn't change width when a check starts.
                Group {
                    if updates.isChecking {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Checking for updates")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16, height: 16)
                Button("Check Now") { updates.checkNow() }
                    .disabled(updates.isChecking)
            }
        }
    }
}
