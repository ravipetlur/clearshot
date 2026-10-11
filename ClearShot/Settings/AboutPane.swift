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

/// "Check for updates automatically", "Last checked: …", Check Now, and under them the answer to a check (`CheckAnswerLine`):
/// "Checking…", then "up to date", the reason a check failed, or the version that is available. The answer keeps a fixed
/// height, so nothing in the pane shifts as a check starts and ends, and it clears when the pane closes.
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
                Button("Check Now") { updates.checkNow(from: .settings) }
                    .disabled(updates.isChecking)
            }
            CheckAnswerLine(answer: updates.aboutLine)
        }
        // The words that appear under the button are also said to VoiceOver.
        .onChange(of: updates.aboutLine?.title) { _, title in
            if let title { AccessibilityNotification.Announcement(title).post() }
        }
        .onDisappear { updates.aboutPaneClosed() }
    }
}
