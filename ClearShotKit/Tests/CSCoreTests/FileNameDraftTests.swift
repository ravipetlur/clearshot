import CSTestSupport
import Testing
@testable import CSCore

/// The file-name editor's draft: Save writes the template, UTC, illegal characters and the next number; Cancel, which
/// drops the draft, writes nothing.
@MainActor
final class FileNameDraftTests {
    let throwaway = ThrowawayDefaults("file-name-draft")
    let prefs: Preferences

    init() {
        prefs = Preferences(defaults: throwaway.defaults)
    }

    /// Taking a draft writes nothing (none of the four keys gets a stored value), and changing it without saving leaves
    /// the preferences as they were.
    @Test func cancellingLeavesThePreferencesAlone() {
        var draft = FileNameDraft(preferences: prefs)
        #expect(!prefs.hasValue(Prefs.fileNameTemplate))
        #expect(!prefs.hasValue(Prefs.fileNameUseUTC))
        #expect(!prefs.hasValue(Prefs.fileNameRemoveIllegalCharacters))
        #expect(!prefs.hasValue(Prefs.fileNameNextAutoIncrement))
        draft.templateText = "Shot %i"
        draft.useUTC = true
        draft.removeIllegalCharacters = false
        draft.nextAutoIncrement = 42
        #expect(!prefs.hasValue(Prefs.fileNameTemplate))
        #expect(!prefs.hasValue(Prefs.fileNameUseUTC))
        #expect(!prefs.hasValue(Prefs.fileNameRemoveIllegalCharacters))
        #expect(!prefs.hasValue(Prefs.fileNameNextAutoIncrement))
        #expect(prefs[Prefs.fileNameTemplate] == .standard)
        #expect(prefs[Prefs.fileNameUseUTC] == false)
        #expect(prefs[Prefs.fileNameRemoveIllegalCharacters] == true)
        #expect(prefs[Prefs.fileNameNextAutoIncrement] == 1)
    }

    /// A capture taken while the editor is open advances the next number; Save writes only what the person changed, so
    /// it doesn't put the older number back (and a number the person did change still wins).
    @Test func saveKeepsANumberACaptureTookMeanwhile() {
        prefs[Prefs.fileNameNextAutoIncrement] = 7
        var draft = FileNameDraft(preferences: prefs)
        draft.useUTC = true
        prefs[Prefs.fileNameNextAutoIncrement] = 8 // a capture used 7
        prefs[Prefs.fileNameTemplate] = FileNameTemplate(parsing: "Elsewhere %i")
        draft.save(to: prefs)
        #expect(prefs[Prefs.fileNameNextAutoIncrement] == 8)
        #expect(prefs[Prefs.fileNameTemplate] == FileNameTemplate(parsing: "Elsewhere %i"))
        #expect(prefs[Prefs.fileNameUseUTC] == true)
        #expect(!prefs.hasValue(Prefs.fileNameRemoveIllegalCharacters))

        var renumbered = FileNameDraft(preferences: prefs)
        renumbered.nextAutoIncrement = 100
        prefs[Prefs.fileNameNextAutoIncrement] = 9
        renumbered.save(to: prefs)
        #expect(prefs[Prefs.fileNameNextAutoIncrement] == 100)
    }

    @Test func saveWritesAllFour() {
        prefs[Prefs.fileNameTemplate] = FileNameTemplate(parsing: "Capture %H.%M")
        prefs[Prefs.fileNameNextAutoIncrement] = 7
        var draft = FileNameDraft(preferences: prefs)
        // The draft starts from what is stored.
        #expect(draft.templateText == "Capture %H.%M")
        #expect(draft.useUTC == false)
        #expect(draft.removeIllegalCharacters == true)
        #expect(draft.nextAutoIncrement == 7)
        draft.templateText = "Shot %i"
        draft.useUTC = true
        draft.removeIllegalCharacters = false
        draft.nextAutoIncrement = 42
        draft.save(to: prefs)
        #expect(prefs[Prefs.fileNameTemplate] == FileNameTemplate(parsing: "Shot %i"))
        #expect(prefs[Prefs.fileNameUseUTC] == true)
        #expect(prefs[Prefs.fileNameRemoveIllegalCharacters] == false)
        #expect(prefs[Prefs.fileNameNextAutoIncrement] == 42)
    }
}
