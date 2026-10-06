import AppKit
import CSCore
import SwiftUI

struct WallpaperPane: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        Form {
            Section {
                Picker("Wallpaper", selection: prefs.binding(Prefs.wallpaperSource)) {
                    ForEach(WallpaperSource.allCases) { Text($0.title).tag($0) }
                }
                if prefs[Prefs.wallpaperSource] == .customImage {
                    LabeledContent("Wallpaper image") {
                        HStack(spacing: 8) {
                            Text(prefs[Prefs.customWallpaperPath].isEmpty ? "None" : (prefs[Prefs.customWallpaperPath] as NSString).lastPathComponent)
                                .foregroundStyle(.secondary)
                            Button("Choose…", action: chooseImage)
                        }
                    }
                }
                if prefs[Prefs.wallpaperSource] == .plainColor {
                    ColorPicker("Color", selection: Binding(
                        get: { Color(cgColor: HexColor.cgColor(from: prefs[Prefs.wallpaperPlainColor]) ?? CGColor(gray: 0.12, alpha: 1)) },
                        set: { prefs[Prefs.wallpaperPlainColor] = HexColor.hex(from: NSColor($0).cgColor) }
                    ), supportsOpacity: false)
                }
                Toggle("Update wallpaper when switching Spaces", isOn: prefs.binding(Prefs.updateWallpaperOnSpaceChange))
            } footer: {
                Text("Used behind window screenshots taken “With wallpaper”, and in place of the desktop while desktop icons are hidden.")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            prefs[Prefs.customWallpaperPath] = url.path(percentEncoded: false)
        }
    }
}
