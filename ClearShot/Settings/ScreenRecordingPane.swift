import AppKit
import CSCore
import CSRecording
import SwiftUI

/// Settings › Screen Recording, in this order: Recording (controls, their position, the menu bar time, dimming, the
/// countdown, Do Not Disturb with whether its two shortcuts exist, keeping the display awake, remembering the
/// selection, the cursor), Highlight clicks (with a live preview), Video, GIF and Audio.
struct ScreenRecordingPane: View {
    @Environment(Preferences.self) private var prefs
    let coordinator: AppCoordinator

    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Show controls while recording", isOn: prefs.binding(Prefs.recordingShowControls))
                Picker("Controls position", selection: prefs.binding(Prefs.recordingControlsPosition)) {
                    ForEach(RecordingControlsPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!prefs[Prefs.recordingShowControls])
                Toggle("Display recording time in menu bar", isOn: prefs.binding(Prefs.recordingShowTimeInMenuBar))
                Toggle("Dim screen while recording", isOn: prefs.binding(Prefs.recordingDimScreen))
                Toggle("Show countdown", isOn: prefs.binding(Prefs.recordingCountdown))
                Toggle("\"Do Not Disturb\" while recording", isOn: prefs.binding(Prefs.recordingDoNotDisturb))
                if prefs[Prefs.recordingDoNotDisturb] {
                    FocusShortcutsStatus(runner: coordinator.focus.shortcuts)
                }
                Toggle("Keep the display awake", isOn: prefs.binding(Prefs.recordingKeepDisplayAwake))
                Toggle("Remember last selection", isOn: prefs.binding(Prefs.recordingRememberSelection))
                Toggle("Show cursor", isOn: prefs.binding(Prefs.recordingShowCursor))
            }
            HighlightClicksSection()
            Section {
                Picker("Frame rate", selection: prefs.binding(Prefs.recordingFrameRate)) {
                    ForEach(Prefs.recordingFrameRateChoices, id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Maximum resolution", selection: prefs.binding(Prefs.recordingMaxResolution)) {
                    ForEach(RecordingMaxResolution.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Scale Retina videos to 1x", isOn: prefs.binding(Prefs.recordingScaleRetinaTo1x))
                Toggle("Hardware encoding", isOn: prefs.binding(Prefs.recordingHardwareEncoding))
            } header: {
                Text("Video")
            } footer: {
                Text("A lower maximum resolution makes smaller files.")
            }
            GIFSection()
            Section {
                MicrophonePicker(permissions: coordinator.permissions)
                Toggle("Record system audio", isOn: prefs.binding(Prefs.recordingSystemAudio))
            } header: {
                Text("Audio")
            } footer: {
                Text("Records the sound other apps play, never ClearShot's own.")
            }
            Section {
                Toggle("Record audio in mono", isOn: prefs.binding(Prefs.recordingMono))
                Picker("Audio tracks", selection: prefs.binding(Prefs.recordingAudioTracks)) {
                    Text("Single track").tag(RecordingAudioTracks.single)
                    Text("Separate tracks").tag(RecordingAudioTracks.separate)
                }
            } footer: {
                Text("Separate tracks keep the microphone and system audio apart, to edit each in a video editor.")
            }
        }
        .formStyle(.grouped)
    }
}

/// "Highlight clicks", which Ready's Highlight Clicks toggles too: the ring's size, colour and style, whether it
/// animates, and a box that draws the ring as chosen at each click in it. The options wait while the toggle is off; the
/// preview always draws.
private struct HighlightClicksSection: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        Section("Highlight clicks") {
            Toggle("Highlight clicks", isOn: prefs.binding(Prefs.recordingHighlightClicks))
            Group {
                Picker("Size", selection: prefs.binding(Prefs.clickHighlightSize)) {
                    Text("Small").tag(ClickHighlightSize.small)
                    Text("Medium").tag(ClickHighlightSize.medium)
                    Text("Large").tag(ClickHighlightSize.large)
                }
                Picker("Color", selection: prefs.binding(Prefs.clickHighlightColor)) {
                    Text("System accent color").tag(ClickHighlightColor.accent)
                    Text("Red").tag(ClickHighlightColor.red)
                    Text("Purple").tag(ClickHighlightColor.purple)
                    Text("Green").tag(ClickHighlightColor.green)
                    Text("Orange").tag(ClickHighlightColor.orange)
                    Text("Yellow").tag(ClickHighlightColor.yellow)
                }
                Picker("Style", selection: prefs.binding(Prefs.clickHighlightStyle)) {
                    Text("Outline").tag(ClickHighlightStyle.outline)
                    Text("Filled").tag(ClickHighlightStyle.filled)
                }
                Toggle("Animate", isOn: prefs.binding(Prefs.clickHighlightAnimates))
            }
            .disabled(!prefs[Prefs.recordingHighlightClicks])
            ClickPreview(style: ClickRippleStyle(preferences: prefs))
                .frame(width: 280, height: 120)
                .frame(maxWidth: .infinity)
        }
    }
}

/// "GIF": the frame rate (60 plays at 50: players slow down shorter frames), "Optimize GIFs", the quality it optimises
/// to (in steps of 10; without Optimize every change is kept, so it waits), and the largest size.
private struct GIFSection: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        Section("GIF") {
            Picker("Frame rate", selection: prefs.binding(Prefs.gifFrameRate)) {
                ForEach(Prefs.gifFrameRateChoices, id: \.self) { rate in
                    let plays = GIFSchedule.effectiveFramesPerSecond(rate)
                    Text(plays == rate ? "\(rate) fps" : "\(rate) fps (plays at \(plays))").tag(rate)
                }
            }
            Toggle("Optimize GIFs", isOn: prefs.binding(Prefs.gifOptimize))
            LabeledContent("Quality") {
                HStack(spacing: 8) {
                    Slider(value: quality, in: 0...100, step: 10)
                    Text("\(prefs[Prefs.gifQuality])")
                        .monospacedDigit()
                        .frame(minWidth: 32, alignment: .trailing)
                }
            }
            .disabled(!prefs[Prefs.gifOptimize])
            Picker("Maximum size", selection: prefs.binding(Prefs.gifMaxSize)) {
                Text("800 × auto (default)").tag(GIFMaxSize.width800)
                Text("Original").tag(GIFMaxSize.original)
            }
        }
    }

    /// The quality setting (a whole number) as the slider's value, in whole steps of 10.
    private var quality: Binding<Double> {
        Binding(get: { Double(prefs[Prefs.gifQuality]) },
                set: { prefs[Prefs.gifQuality] = Int(($0 / 10).rounded()) * 10 })
    }
}

/// "Microphone": Do Not Record Microphone and the connected inputs (discovery only, no prompt). Choosing one the first
/// time asks for the microphone permission; refused, the choice goes back to Do Not Record Microphone.
private struct MicrophonePicker: View {
    @Environment(Preferences.self) private var prefs
    let permissions: PermissionCenter
    @State private var devices: [MicrophoneDeviceInfo] = []
    @State private var refused = false

    var body: some View {
        let chosen = prefs[Prefs.recordingMicrophoneID]
        Picker("Microphone", selection: Binding(get: { chosen }, set: choose)) {
            Text("Do Not Record Microphone").tag("")
            ForEach(devices) { Text($0.name).tag($0.id) }
            if !chosen.isEmpty, !devices.contains(where: { $0.id == chosen }) {
                Text("Disconnected microphone").tag(chosen)
            }
        }
        .onAppear { devices = MicrophoneDevices.list() }
        if refused {
            Text(RecordingReadyModel.microphoneDeniedWarning)
                .foregroundStyle(.secondary)
        }
    }

    private func choose(_ id: String) {
        refused = false
        prefs[Prefs.recordingMicrophoneID] = id
        guard !id.isEmpty else { return }
        Task {
            let status = permissions.status(of: .microphone) == .notDetermined
                ? await permissions.request(.microphone)
                : permissions.status(of: .microphone)
            if status != .granted, prefs[Prefs.recordingMicrophoneID] == id {
                prefs[Prefs.recordingMicrophoneID] = ""
                refused = true
            }
        }
    }
}

/// Whether "ClearShot Focus On" and "ClearShot Focus Off" exist (`FocusShortcuts.check`, which only lists them), and how
/// to make them when they don't.
private struct FocusShortcutsStatus: View {
    let runner: any ShortcutRunning
    /// Nil while checking.
    @State private var installed: (on: Bool, off: Bool)?
    @State private var isChecking = true

    var body: some View {
        Group {
            if isChecking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking the shortcuts…").foregroundStyle(.secondary)
                }
            } else if installed?.on == true, installed?.off == true {
                Label("Both shortcuts are set up", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create two shortcuts in the Shortcuts app: “ClearShot Focus On” (Set Focus › Do Not Disturb › "
                        + "On) and “ClearShot Focus Off” (Set Focus › Do Not Disturb › Off).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Shortcuts", action: openShortcuts)
                        Button("Check Again") { Task { await check() } }
                    }
                }
            }
        }
        .task { await check() }
    }

    private func check() async {
        isChecking = true
        installed = await FocusShortcuts.check(using: runner)
        isChecking = false
    }

    private func openShortcuts() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
