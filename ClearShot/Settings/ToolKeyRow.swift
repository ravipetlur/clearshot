import CSAnnotation
import CSCore
import SwiftUI

/// One tool's letter, or the background tool's: a one-character field that takes a new letter when it is free, and says why
/// when it isn't. It rests on the stored letter, in upper case: it goes back to it when the keys change elsewhere or the
/// field loses focus. Its reset button and its context menu's "Reset to default" set the default letter (the button is
/// there because a right-click on the field opens the field's own menu). Settings › Annotate › Tool shortcuts
/// and Settings › Shortcuts › Annotate tools both show these rows, editing the same `annotateToolKeys`.
struct ToolKeyRow: View {
    @Environment(Preferences.self) private var prefs
    let target: AnnotateKeyTarget
    @State private var text = ""
    @State private var problem: AnnotateToolKeys.Problem?
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let problem {
                    Text(message(for: problem))
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                TextField("", text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(.center)
                    .frame(width: 32)
                    .overlay {
                        // A tool with no letter (hand-written or stale settings) says so while its field is empty.
                        if current.isEmpty && text.isEmpty {
                            Text("None")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .allowsHitTesting(false)
                        }
                    }
                    .focused($focused)
                    .onChange(of: text) { old, _ in commit(replacing: old) }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { showStoredLetter() }
                    }
                    .accessibilityLabel("Letter for \(target.title)")
                ResetToDefaultButton(rowTitle: target.title,
                                     isAtDefault: prefs[Prefs.annotateToolKeys].key(for: target) == target.defaultKey,
                                     action: resetToDefault)
            }
        } label: {
            Label(target.title, systemImage: target.symbol)
        }
        .contextMenu {
            Button("Reset to default", action: resetToDefault)
        }
        .onAppear { showStoredLetter() }
        .onChange(of: prefs[Prefs.annotateToolKeys]) { showStoredLetter() }
    }

    /// The target's letter as stored: uppercase, or empty when it has none.
    private var current: String {
        prefs[Prefs.annotateToolKeys].key(for: target).map { String($0).uppercased() } ?? ""
    }

    /// The field's resting state: the stored letter and no message.
    private func showStoredLetter() {
        text = current
        problem = nil
    }

    /// The default letter, unless another target has it, when the row says so as it does for a typed letter.
    private func resetToDefault() {
        var keys = prefs[Prefs.annotateToolKeys]
        if let refusal = keys.set(String(target.defaultKey), for: target) {
            problem = refusal
            return
        }
        prefs[Prefs.annotateToolKeys] = keys
        showStoredLetter()
    }

    /// Typing a letter sets it at once, whether it goes before the letter the field showed or after it. `shown` is what
    /// the field held before this edit.
    private func commit(replacing shown: String) {
        if text.count > 1 {
            text = Self.typedLetter(in: text, replacing: shown) // changes `text` again, which commits that
            return
        }
        // An emptied field has nothing to refuse. It goes back to the stored letter when it loses focus.
        guard !text.isEmpty else {
            problem = nil
            return
        }
        // The stored letter again, in either case: nothing changes but how it is written.
        guard text.uppercased() != current else {
            text = current
            problem = nil
            return
        }
        var keys = prefs[Prefs.annotateToolKeys]
        problem = keys.set(text, for: target)
        if problem == nil {
            prefs[Prefs.annotateToolKeys] = keys
            text = current
        }
    }

    /// The letter just typed into a field that showed `shown`: the field holds it beside the shown letter, before or after,
    /// so it is what is left once `shown` is taken out. If that leaves several characters (a paste), the last one.
    static func typedLetter(in text: String, replacing shown: String) -> String {
        guard text.count > 1 else { return text }
        var rest = text
        if !shown.isEmpty, let range = rest.range(of: shown) {
            rest.removeSubrange(range)
        }
        return String(rest.suffix(1))
    }

    private func message(for problem: AnnotateToolKeys.Problem) -> String {
        switch problem {
        case .notALetter: "Use a single letter"
        case .reserved: "1–6, [ and ] set the size"
        case .taken(let owner): "Used by \(owner.title)"
        }
    }
}
