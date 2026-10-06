import AppKit
import CSAnnotation
import CSCore

/// The document windows open, Annotate's and the Video Editor's, which together decide the activation policy: with
/// "Show Dock icon" on, ClearShot is a regular app (Dock icon, ⌘Tab) while any of them is open, and an accessory again
/// once the last one closes, whichever kind it is. So closing the last Annotate window leaves the Dock icon up under an
/// open Video Editor, and the other way round.
final class DocumentWindows {
    private let preferences: Preferences
    private var open: Set<ObjectIdentifier> = []

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    /// A document window is up. Telling the same window twice counts it once.
    func opened(_ window: NSWindow) {
        open.insert(ObjectIdentifier(window))
        updateActivationPolicy()
    }

    /// A document window has closed. A window never told as opened changes nothing.
    func closed(_ window: NSWindow) {
        guard open.remove(ObjectIdentifier(window)) != nil else { return }
        updateActivationPolicy()
    }

    private func updateActivationPolicy() {
        let regular = !open.isEmpty && preferences[Prefs.annotateShowDockIcon]
        NSApp.setActivationPolicy(regular ? .regular : .accessory)
    }
}
