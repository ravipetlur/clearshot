import CSAPI
import CSCore
import CSOCR
import CSRecording
import SwiftUI

struct AdvancedPane: View {
    /// Vision's languages for the Primary language picker, by name; asked for once.
    private static let recognitionLanguages = RecognitionLanguage.supported()

    let coordinator: AppCoordinator
    @Environment(Preferences.self) private var prefs
    @State private var editingTemplate = false
    @State private var confirmingClear = false
    @State private var warningsReset = false

    var body: some View {
        Form {
            Section("File name") {
                LabeledContent("File name format") {
                    HStack(spacing: 8) {
                        Text(prefs[Prefs.fileNameTemplate].stringValue)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Customize…") { editingTemplate = true }
                    }
                }
                Toggle("Add “@2x” suffix to Retina screenshots", isOn: prefs.binding(Prefs.addRetinaSuffix))
                Toggle("Ask for a name after every capture", isOn: prefs.binding(Prefs.askForNameAfterCapture))
            }
            Section("Clipboard") {
                Picker("Copy to clipboard", selection: prefs.binding(Prefs.clipboardMode)) {
                    ForEach(ClipboardMode.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Picker("Keep captures for", selection: prefs.binding(Prefs.historyRetention)) {
                    ForEach(HistoryRetention.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Capture history") {
                    Button("Clear History…") { confirmingClear = true }
                }
            } header: {
                Text("History")
            } footer: {
                Text("“Never” keeps a capture only while its thumbnail, editor or pin is open. A new setting applies at the next cleanup, within a few hours. Saved files are never deleted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep line breaks", isOn: prefs.binding(Prefs.textRecognitionKeepLineBreaks))
                Toggle("Automatically detect language", isOn: prefs.binding(Prefs.textRecognitionAutoDetectLanguage))
                Picker("Primary language", selection: prefs.binding(Prefs.textRecognitionPrimaryLanguage)) {
                    ForEach(Self.recognitionLanguages) { Text($0.name).tag($0.id) }
                }
                .disabled(prefs[Prefs.textRecognitionAutoDetectLanguage])
                Toggle("Detect links", isOn: prefs.binding(Prefs.textRecognitionDetectLinks))
            } header: {
                Text("Text recognition")
            } footer: {
                Text("Capture Text uses Keep line breaks; the With and Without Line Breaks shortcuts override it. Detect links offers to open a captured link.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Remember last selection", isOn: prefs.binding(Prefs.allInOneRememberSelection))
            } header: {
                Text("All-In-One")
            } footer: {
                Text("All-In-One opens with the area you last captured from it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Shadow", isOn: prefs.binding(Prefs.pinShadow))
                Toggle("Rounded corners", isOn: prefs.binding(Prefs.pinRoundedCorners))
                Toggle("Border", isOn: prefs.binding(Prefs.pinBorder))
            } header: {
                Text("Pins")
            } footer: {
                Text("New pins start with these. Change one pin from its right-click menu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: urlSchemeAPI) {
                    Text("Allow URL scheme API")
                    if URLConsent.setting(preferences: prefs, store: coordinator.consentStore) == .asks {
                        Text(URLConsent.asksCaption)
                    }
                }
            } header: {
                Text("URL scheme API")
            } footer: {
                // Verbatim, so the example is never made a link that would run the command.
                Text(verbatim: "Lets Raycast, Shortcuts and scripts run ClearShot commands such as clearshot://capture-area. Turn it off to ignore them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Warnings") {
                LabeledContent(warningsReset ? "Warnings will be shown again" : "Dialogs you chose not to see again") {
                    Button("Reset All Warning Dialogs") {
                        // CSCore's and the recording's Restart and Delete confirmations.
                        Prefs.allWarningDialogs.forEach { prefs.reset($0) }
                        warningsReset = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $editingTemplate) {
            FileNameTemplateEditor(preferences: prefs).environment(prefs)
        }
        .clearHistoryConfirmation(isPresented: $confirmingClear, coordinator: coordinator)
    }

    /// The URL scheme API's consent, as the next command meets it (`URLConsent.setting`): on while commands run, and
    /// while they ask because nothing is granted yet (said in the switch's second line); off while they are ignored.
    /// Turning it on stores the grant and counts as the answer to the prompt, so none follows; turning it off removes
    /// the grant. Every write also changes a preference, so the switch redraws. Reset All Warning Dialogs never touches
    /// it.
    private var urlSchemeAPI: Binding<Bool> {
        let store = coordinator.consentStore
        return Binding(
            get: { URLConsent.setting(preferences: prefs, store: store).isOn },
            set: { allowed in
                if !URLConsent.setAllowed(allowed, preferences: prefs, store: store) {
                    coordinator.hud.show("Couldn't save the setting in the keychain", symbol: "exclamationmark.triangle.fill")
                }
            }
        )
    }
}
