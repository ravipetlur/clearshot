import AppKit
import CSAnnotation
import SwiftUI

/// The Background panel's preset menu, for the document's kind: window screenshots have their own presets. Each preset
/// (the one matching the background checked) applies it; then Apply Previous Settings, Save as Preset…, Update for the
/// preset applied or saved last in this editor, Rename and Delete, and whether that preset applies to new captures.
struct BackgroundPresetMenu: View {
    @Bindable var editor: AnnotationEditor
    let commands: BackgroundCommands

    var body: some View {
        let presets = editor.presets
        let matching = editor.matchingPreset
        let lastApplied = editor.lastAppliedPreset
        let hasBackground = editor.document.background != nil
        Menu {
            ForEach(presets) { preset in
                // A toggle shows the check; choosing the checked preset applies it again, making it the last applied.
                Toggle(preset.name, isOn: Binding(get: { matching?.id == preset.id }, set: { _ in apply(preset) }))
            }
            if !presets.isEmpty {
                Divider()
            }
            Button("Apply Previous Settings") {
                commands.applyStyle { await $0.applyPreviousSettings(pictures: $1) }
            }
            .disabled(!editor.canApplyPreviousSettings)
            Button("Save as Preset…", action: save)
                .disabled(!hasBackground)
            Button(lastApplied.map { "Update “\($0.name)”" } ?? "Update Preset") {
                commands.endTextEditing()
                editor.updateLastAppliedPreset()
            }
            .disabled(lastApplied == nil || !hasBackground)
            Menu("Rename") {
                ForEach(presets) { preset in
                    Button(preset.name) { rename(preset) }
                }
            }
            .disabled(presets.isEmpty)
            Menu("Delete") {
                ForEach(presets) { preset in
                    Button(preset.name) { delete(preset) }
                }
            }
            .disabled(presets.isEmpty)
            Divider()
            Toggle("Apply to New Screenshots Automatically", isOn: Binding(get: { editor.autoAppliesLastPreset }, set: { on in
                editor.setAutoApplyLastPreset(on)
            }))
            .disabled(lastApplied == nil)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Presets")
        .accessibilityLabel("Presets")
    }

    private func apply(_ preset: BackgroundPreset) {
        commands.applyStyle { await $0.applyPreset(preset, pictures: $1) }
    }

    /// Save as Preset…: the background's style under a name asked for, as the last applied preset.
    private func save() {
        commands.endTextEditing()
        guard let name = PresetNameAlert.ask(title: "Save background preset", button: "Save",
                                             name: "Preset \(editor.presets.count + 1)")
        else { return }
        editor.saveBackgroundAsPreset(named: name)
    }

    private func rename(_ preset: BackgroundPreset) {
        commands.endTextEditing()
        guard let name = PresetNameAlert.ask(title: "Rename preset", button: "Rename", name: preset.name) else { return }
        editor.renamePreset(preset.id, to: name)
    }

    private func delete(_ preset: BackgroundPreset) {
        commands.endTextEditing()
        let alert = NSAlert()
        alert.messageText = "Delete the preset “\(preset.name)”?"
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        editor.deletePreset(preset.id)
    }
}

/// Asks for a preset's name: an alert with a field, `name` filled in and selected.
private enum PresetNameAlert {
    /// The name typed, or nil when cancelled. A name left empty is the editor's to deal with (`BackgroundPresetList`).
    static func ask(title: String, button: String, name: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: name)
        field.placeholderString = "Preset name"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: field.fittingSize.height)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
