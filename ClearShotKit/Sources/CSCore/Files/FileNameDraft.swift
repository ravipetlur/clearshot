/// What the file-name editor edits: the template and the three settings beside it, read from the preferences when the
/// editor opens and written back only by Save, so Cancel leaves all four as they were.
@MainActor
public struct FileNameDraft {
    public var templateText: String
    public var useUTC: Bool
    public var removeIllegalCharacters: Bool
    public var nextAutoIncrement: Int

    /// The four as the editor opened. Save writes only what differs from them: a capture taken meanwhile advances the
    /// next number, and an untouched counter mustn't put the older one back.
    private let opened: (templateText: String, useUTC: Bool, removeIllegalCharacters: Bool, nextAutoIncrement: Int)

    /// Reads the four settings; writes nothing.
    public init(preferences: Preferences) {
        templateText = preferences[Prefs.fileNameTemplate].stringValue
        useUTC = preferences[Prefs.fileNameUseUTC]
        removeIllegalCharacters = preferences[Prefs.fileNameRemoveIllegalCharacters]
        nextAutoIncrement = preferences[Prefs.fileNameNextAutoIncrement]
        opened = (templateText, useUTC, removeIllegalCharacters, nextAutoIncrement)
    }

    /// Save: writes each of the four the person changed.
    public func save(to preferences: Preferences) {
        if templateText != opened.templateText {
            preferences[Prefs.fileNameTemplate] = FileNameTemplate(parsing: templateText)
        }
        if useUTC != opened.useUTC { preferences[Prefs.fileNameUseUTC] = useUTC }
        if removeIllegalCharacters != opened.removeIllegalCharacters {
            preferences[Prefs.fileNameRemoveIllegalCharacters] = removeIllegalCharacters
        }
        if nextAutoIncrement != opened.nextAutoIncrement {
            preferences[Prefs.fileNameNextAutoIncrement] = nextAutoIncrement
        }
    }
}
