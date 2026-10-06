import AppKit
import CSCore
import SwiftUI

struct GeneralPane: View {
    let coordinator: AppCoordinator
    @Environment(Preferences.self) private var prefs
    @State private var showHiddenIconInfo = false

    var body: some View {
        Form {
            Section("App") {
                LaunchAtLoginToggle()
                Toggle("Show menu bar icon", isOn: Binding(
                    get: { prefs[Prefs.showMenuBarIcon] },
                    set: { visible in
                        coordinator.setMenuBarIconVisible(visible)
                        if !visible, !prefs[Prefs.didInformAboutHiddenMenuBarIcon] {
                            prefs[Prefs.didInformAboutHiddenMenuBarIcon] = true
                            showHiddenIconInfo = true
                        }
                    }
                ))
            }
            Section("Capture") {
                Toggle("Hide desktop icons while capturing", isOn: prefs.binding(Prefs.hideDesktopIconsWhileCapturing))
            }
            Section("Sounds") {
                Toggle("Play sounds", isOn: prefs.binding(Prefs.playSounds))
                Picker("Shutter sound", selection: Binding(
                    get: { prefs[Prefs.shutterSound] },
                    set: { sound in
                        prefs[Prefs.shutterSound] = sound
                        coordinator.sounds.preview(sound)
                    }
                )) {
                    ForEach(ShutterSound.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!prefs[Prefs.playSounds])
            }
            Section("Export") {
                LabeledContent("Export location") {
                    HStack(spacing: 8) {
                        Text((prefs[Prefs.exportLocation].path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseExportLocation)
                    }
                }
            }
            Section("After capture") {
                AfterCaptureGrid()
            }
        }
        .formStyle(.grouped)
        .alert("Menu bar icon hidden", isPresented: $showHiddenIconInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("To open Settings again, launch ClearShot from Finder or Spotlight while it's running.")
        }
    }

    private func chooseExportLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = prefs[Prefs.exportLocation]
        if panel.runModal() == .OK, let url = panel.url {
            prefs[Prefs.exportLocation] = url
        }
    }
}
