/// What the alert says when a change reached a capture but not the file saved from it: the saved file was edited in another
/// app since ClearShot wrote it (so it is left alone), or it couldn't be rewritten. Done, a thumbnail's image change and the
/// secrets check's Mask All each give their own `change`.
public enum SavedFileNotice {
    /// "`change`, but the saved file was edited in another app, so ClearShot left it alone." or "`change`, but the saved file
    /// wasn't updated", with `note` as one more sentence after it.
    public static func message(change: String, editedElsewhere: Bool, note: String? = nil) -> String {
        let main = editedElsewhere
            ? "\(change), but the saved file was edited in another app, so ClearShot left it alone."
            : "\(change), but the saved file wasn't updated"
        guard let note else { return main }
        return editedElsewhere ? "\(main) \(note)" : "\(main). \(note)"
    }
}
