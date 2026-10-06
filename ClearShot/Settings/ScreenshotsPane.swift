import CSAnnotation
import CSCore
import SwiftUI

struct ScreenshotsPane: View {
    @Environment(Preferences.self) private var prefs
    @State private var confirmBorder = false

    var body: some View {
        Form {
            Section("Output") {
                Picker("File format", selection: prefs.binding(Prefs.imageFormat)) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0) }
                }
                if prefs[Prefs.imageFormat].supportsQuality {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: prefs.binding(Prefs.imageQuality), in: 0.5...1.0)
                            Text("\(Int((prefs[Prefs.imageQuality] * 100).rounded()))%").monospacedDigit().frame(width: 44)
                        }
                    }
                }
                Toggle("Convert to sRGB profile", isOn: prefs.binding(Prefs.convertToSRGB))
                Toggle("Scale Retina screenshots to 1x", isOn: prefs.binding(Prefs.scaleRetinaTo1x))
                Toggle("Add 1px border to all screenshots", isOn: Binding(
                    get: { prefs[Prefs.addBorderToScreenshots] },
                    set: { on in
                        if on { confirmBorder = true } else { prefs[Prefs.addBorderToScreenshots] = false }
                    }
                ))
            }
            Section {
                presetPicker("Screenshots", kind: .screenshot)
                presetPicker("Window screenshots", kind: .window)
            } header: {
                Text("Background preset")
            } footer: {
                Text("Applied to every new capture. Hold ⇧ as you start a selection, or as you click a window, to skip it. Make presets in Annotate's background tool.")
            }
            Section("Capture") {
                Picker("Self-timer interval", selection: prefs.binding(Prefs.selfTimerSeconds)) {
                    ForEach(Prefs.selfTimerChoices, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Toggle(isOn: prefs.binding(Prefs.showCursorInScreenshots)) {
                    Text("Show cursor on screenshots")
                    Text("Fullscreen and self-timer captures only.")
                }
                Toggle("Freeze screen when taking a screenshot", isOn: prefs.binding(Prefs.freezeScreen))
                Toggle("Dim the screen while selecting", isOn: prefs.binding(Prefs.dimScreenWhileSelecting))
                Toggle("Fullscreen captures every display", isOn: prefs.binding(Prefs.fullscreenCapturesAllDisplays))
            }
            Section("Crosshair") {
                Picker("Crosshair mode", selection: prefs.binding(Prefs.crosshairMode)) {
                    ForEach(CrosshairMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show magnifier", isOn: prefs.binding(Prefs.showMagnifier))
                    .disabled(prefs[Prefs.crosshairMode] == .off)
            }
            Section {
                Picker("Background", selection: prefs.binding(Prefs.windowBackground)) {
                    ForEach(WindowBackgroundMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Padding") {
                    HStack {
                        Slider(value: Binding(get: { Double(prefs[Prefs.windowPadding]) },
                                              set: { prefs[Prefs.windowPadding] = Int($0) }), in: 0...120, step: 4)
                        Text("\(prefs[Prefs.windowPadding]) pt").monospacedDigit().frame(width: 52)
                    }
                }
                .disabled(prefs[Prefs.windowBackground] == .transparent)
                Toggle("Capture window shadow", isOn: prefs.binding(Prefs.captureWindowShadow))
                Button("Reset to defaults") {
                    prefs.reset(Prefs.windowBackground)
                    prefs.reset(Prefs.windowPadding)
                    prefs.reset(Prefs.captureWindowShadow)
                }
            } header: {
                Text("Window screenshots")
            } footer: {
                Text("Hold ⇧ while clicking a window to switch between wallpaper and transparent for that shot (with a window background preset, ⇧ skips the preset instead). Turn off the shadow too if you want no padding at all.")
            }
            Section("Capture area & … shortcuts") {
                Toggle("Ignore “After capture” actions", isOn: prefs.binding(Prefs.captureAreaShortcutsIgnoreAfterCapture))
            }
        }
        .formStyle(.grouped)
        .alert("Add a border to every screenshot?", isPresented: $confirmBorder) {
            Button("Add border") { prefs[Prefs.addBorderToScreenshots] = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A 1-pixel border is drawn over the outermost pixels of each screenshot.")
        }
    }

    /// The preset applied to every new capture of `kind`: None, then that kind's presets by name. A stored id that
    /// names none of them shows None, since nothing is applied for it.
    private func presetPicker(_ title: String, kind: BackgroundPresetKind) -> some View {
        let list = prefs[kind.presetsKey]
        let selection = Binding(
            get: { list.preset(idString: prefs[kind.autoApplyKey])?.id.uuidString ?? "" },
            set: { prefs[kind.autoApplyKey] = $0 })
        return Picker(title, selection: selection) {
            Text("None").tag("")
            ForEach(list.presets) { preset in
                Text(preset.name).tag(preset.id.uuidString)
            }
        }
    }
}
