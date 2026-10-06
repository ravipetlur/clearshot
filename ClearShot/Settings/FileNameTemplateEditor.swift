import CSCore
import SwiftUI

/// "Type text and insert elements to create a custom format". It edits a draft of the template and the three settings
/// beside it: Save writes what the person changed (so a capture meanwhile keeps its advance of the next number), Cancel
/// nothing.
struct FileNameTemplateEditor: View {
    @Environment(Preferences.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FileNameDraft

    /// The draft is read from `preferences` as the sheet opens.
    init(preferences: Preferences) {
        _draft = State(initialValue: FileNameDraft(preferences: preferences))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Type text and insert elements to create a custom format:").font(.headline)
            TextField("Format", text: $draft.templateText)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(FileNameTemplate.Token.placeholders, id: \.self) { token in
                    Button(token.displayName) { draft.templateText += token.code ?? "" }
                        .controlSize(.small)
                }
            }
            LabeledContent("Preview") {
                Text(preview).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Toggle("Use UTC time zone", isOn: $draft.useUTC)
            Toggle("Remove illegal characters", isOn: $draft.removeIllegalCharacters)
            Stepper("Auto-increment next number: \(draft.nextAutoIncrement)", value: $draft.nextAutoIncrement,
                    in: 0...999_999)
            HStack {
                Button("Restore defaults") { draft.templateText = FileNameTemplate.standard.stringValue }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    draft.save(to: prefs)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var preview: String {
        let context = FileNameContext(timeZone: draft.useUTC ? .gmt : .current, appName: "Safari", windowTitle: "Inbox",
                                      autoIncrement: draft.nextAutoIncrement,
                                      removeIllegalCharacters: draft.removeIllegalCharacters)
        return FileNamer.baseName(for: FileNameTemplate(parsing: draft.templateText), context: context) + "."
            + prefs[Prefs.imageFormat].fileExtension
    }
}
