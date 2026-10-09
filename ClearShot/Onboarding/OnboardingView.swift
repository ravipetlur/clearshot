import AppKit
import CSCore
import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, permissions, shortcuts, startup, workflow, done
    }

    let coordinator: AppCoordinator
    let onFinish: () -> Void
    @State private var step: Step = .welcome

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .permissions: PermissionsStep(permissions: coordinator.permissions, hud: coordinator.hud)
                case .shortcuts: ShortcutsStep(openShortcutsSettings: { coordinator.showSettings(.shortcuts) })
                case .startup: StartupStep()
                case .workflow: WorkflowStep()
                case .done: DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)

            Divider()
            HStack {
                if step != .welcome {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                }
                Spacer()
                Button(step == .done ? "Start using ClearShot" : "Continue") {
                    if let next = Step(rawValue: step.rawValue + 1) {
                        step = next
                    } else {
                        onFinish()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 600, height: 480)
    }
}

private struct StepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tint)
            Text(title).font(.title.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
        .padding(.bottom, 16)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        StepHeader(symbol: "camera.viewfinder", title: "Welcome to ClearShot",
                   subtitle: "Screenshots, recordings, annotations and more, from your menu bar. A few quick steps and you're set.")
    }
}

private struct PermissionsStep: View {
    let permissions: PermissionCenter
    /// Says so when Restart ClearShot can't start.
    let hud: HUDController
    @State private var statuses: [Permission: PermissionStatus] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(symbol: "lock.shield", title: "Permissions",
                       subtitle: "Screen Recording is needed now. The others are asked for the first time you use a feature that needs them.")
            ForEach(Permission.allCases) { permission in
                HStack(spacing: 12) {
                    Image(systemName: statuses[permission] == .granted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(statuses[permission] == .granted ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(permission.title).font(.headline)
                        Text(permission.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if statuses[permission] != .granted {
                        Button(permission.isRequired ? "Grant access" : "Grant now") {
                            Task {
                                let result = await permissions.request(permission)
                                if result != .granted { permissions.openSettings(for: permission) }
                                refresh()
                            }
                        }
                    }
                }
            }
            if statuses[.screenRecording] != .granted {
                HStack {
                    Text("Granted access but it still shows as off? macOS applies it after a restart.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Restart ClearShot") {
                        if !Relauncher.relaunch() {
                            hud.show("Couldn't restart ClearShot; quit and open it again",
                                     symbol: "exclamationmark.triangle.fill")
                        }
                    }
                        .controlSize(.small)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() {
        statuses = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, permissions.status(of: $0)) })
    }
}

private struct ShortcutsStep: View {
    let openShortcutsSettings: () -> Void
    @State private var systemShortcutsOn = !SystemShortcutCheck.actionsTakenBySystem().isEmpty
    @State private var shortcutsInUseElsewhere = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(symbol: "keyboard", title: "Shortcuts",
                       subtitle: "ClearShot uses ⇧⌘3 for fullscreen, ⇧⌘4 for an area and ⇧⌘5 for All-In-One. You can change them in Settings › Shortcuts.")
            if systemShortcutsOn {
                NoticeView(symbol: "exclamationmark.triangle.fill",
                       text: "The macOS screenshot shortcuts are still on, so ⇧⌘4 may open the built-in tool instead. Turn them off in Keyboard Shortcuts › Screenshots.",
                       buttonTitle: "Open Keyboard settings") {
                    NSWorkspace.shared.open(SystemSettingsLinks.keyboard)
                }
            }
            if shortcutsInUseElsewhere {
                NoticeView(symbol: "exclamationmark.triangle.fill",
                       text: "Another app is using some of ClearShot's shortcuts, so they won't work. Choose others, or quit that app and restart ClearShot.",
                       buttonTitle: "Open Shortcuts Settings", action: openShortcutsSettings)
            }
        }
        .task {
            while !Task.isCancelled {
                systemShortcutsOn = !SystemShortcutCheck.actionsTakenBySystem().isEmpty
                shortcutsInUseElsewhere = !HotkeyCenter.shared.unregisteredActions.isEmpty
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct StartupStep: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(symbol: "power", title: "Startup and desktop",
                       subtitle: "Start ClearShot when you log in, and keep desktop icons out of your captures.")
            LaunchAtLoginToggle()
            Toggle("Hide desktop icons while capturing", isOn: prefs.binding(Prefs.hideDesktopIconsWhileCapturing))
        }
    }
}

private struct WorkflowStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(symbol: "arrow.triangle.branch", title: "After you capture",
                       subtitle: "Choose what happens right after a screenshot or recording. You can change this later in Settings › General.")
            AfterCaptureGrid()
        }
    }
}

private struct DoneStep: View {
    var body: some View {
        StepHeader(symbol: "checkmark.seal.fill", title: "You're set",
                   subtitle: "ClearShot lives in your menu bar under the viewfinder icon. Press ⇧⌘4 to capture an area.")
    }
}
