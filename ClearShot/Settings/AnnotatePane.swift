import CSAnnotation
import CSCore
import SwiftUI

/// The Annotate editor's settings, with the letters of the tools and the background tool.
struct AnnotatePane: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        Form {
            Section("Drawing") {
                Toggle("Invert arrow direction", isOn: prefs.binding(Prefs.annotateInvertArrows))
                Toggle("Smooth drawing", isOn: prefs.binding(Prefs.annotateSmoothDrawing))
                Toggle("Draw shadow on objects", isOn: prefs.binding(Prefs.annotateObjectShadows))
                Toggle("Automatically expand canvas", isOn: prefs.binding(Prefs.annotateAutoExpandCanvas))
                Toggle("Show color names", isOn: prefs.binding(Prefs.annotateShowColorNames))
            }
            Section {
                Toggle("Always on top", isOn: prefs.binding(Prefs.annotateAlwaysOnTop))
                Toggle("Show Dock icon", isOn: prefs.binding(Prefs.annotateShowDockIcon))
                Toggle("Remember if the background tool was open", isOn: prefs.binding(Prefs.annotateRememberBackgroundTool))
            } header: {
                Text("Window")
            } footer: {
                Text("With the Dock icon on, an open Annotate window appears in ⌘Tab. Changes apply to windows opened afterwards.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(AnnotateKeyTarget.allCases) { target in
                    ToolKeyRow(target: target)
                }
            } header: {
                Text("Tool shortcuts")
            } footer: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Press a letter in the editor to pick a tool or open the background tool. 1–6, [ and ] set the size.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { prefs[Prefs.annotateToolKeys] = AnnotateToolKeys() }
                        .disabled(prefs[Prefs.annotateToolKeys] == AnnotateToolKeys())
                }
            }
        }
        .formStyle(.grouped)
    }
}
