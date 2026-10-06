import AppKit
import CSCore
import CSOCR

/// Reads the text in a picture and puts it on the clipboard, for Capture Text, All-In-One's O, Extract Text and
/// `capture-text` URLs: "Text has been copied" with the OCR sound, or "No text detected"; then, when the text is a
/// single link, Detect links is on, no capture is under way and the modal gate allows a question, an offer to open it.
/// Nothing goes to history and no after-capture action runs.
final class TextResultPresenter {
    private let preferences: Preferences
    private let hud: HUDController
    private let sounds: SoundPlayer
    /// Asked before the link offer: a URL's `capture-text?filepath=` runs outside any capture, so only the gate keeps
    /// its offer off an open app-modal dialog.
    private let gate: ModalGate
    /// Whether a capture is under way (`CaptureFlow.isCapturing`), read just before the link prompt: Extract Text runs beside
    /// captures, and an alert shown while a capture's overlay is up would open beneath it.
    var isCapturing: () -> Bool = { false }

    init(preferences: Preferences, hud: HUDController, sounds: SoundPlayer, gate: ModalGate) {
        self.preferences = preferences
        self.hud = hud
        self.sounds = sounds
        self.gate = gate
    }

    /// Recognizes `image` with the language settings and presents the result. `keepLineBreaks` nil follows the Keep line
    /// breaks setting; the With and Without Line Breaks shortcuts pass true or false. A picture read as several tiles can
    /// take seconds, so it first shows "Recognizing text…", which the result's HUD replaces. A one-line strip, read as one
    /// tile, doesn't: the HUD would only flicker.
    func recognizeAndPresent(_ image: CGImage, keepLineBreaks: Bool?) async {
        let keepsLineBreaks = keepLineBreaks ?? preferences[Prefs.textRecognitionKeepLineBreaks]
        if OCRTiling.tileCount(width: image.width, height: image.height) > 1 {
            // Long enough that it can't fade while the tiles are read; the result's HUD cancels the hide.
            hud.show("Recognizing text…", symbol: "text.viewfinder", duration: .seconds(30))
        }
        let result: OCRResult
        do {
            result = try await TextRecognizer.recognize(image, options: TextRecognitionOptions(preferences: preferences))
        } catch {
            Log.capture.error("Text recognition failed on a \(image.width)×\(image.height) picture: \(error)")
            hud.show("Couldn't recognize text", symbol: "exclamationmark.triangle.fill")
            return
        }
        let text = TextOutput.text(for: result, keepLineBreaks: keepsLineBreaks)
        guard !text.isEmpty else {
            hud.show("No text detected", symbol: "text.magnifyingglass")
            return
        }
        // Plain text only: it isn't a capture, so it isn't recorded as ClearShot's copy (`ClipboardOwnership`), and a later
        // Trash leaves it alone.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            Log.capture.error("Couldn't put \(text.count) characters of recognized text on the clipboard")
            hud.show("Couldn't copy to the clipboard", symbol: "exclamationmark.triangle.fill")
            return
        }
        hud.show("Text has been copied", symbol: "doc.on.clipboard")
        sounds.playOCR()
        // Read now, not when recognition began: a capture may have started while a big picture was read. During one the
        // offer is held back quietly; over an open app-modal dialog the gate refuses it (the text is copied either
        // way).
        if let link = TextOutput.linkToOffer(in: text, detectsLinks: preferences[Prefs.textRecognitionDetectLinks],
                                             isCapturing: isCapturing()),
           gate.allowsQuestion() {
            offerToOpen(link)
        }
    }

    /// "Do you want to open this link?". The link is already on the clipboard, so "Copy to Clipboard" just closes the
    /// alert; "Never open links" turns Detect links off. The only time Capture Text activates ClearShot.
    private func offerToOpen(_ link: URL) {
        let alert = NSAlert()
        alert.messageText = "Do you want to open this link?"
        alert.informativeText = link.absoluteString
        alert.addButton(withTitle: "Open Link in Browser")
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "Never open links")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if !NSWorkspace.shared.open(link) {
                Log.capture.error("Couldn't open \(link.absoluteString)")
                hud.show("Couldn't open the link", symbol: "exclamationmark.triangle.fill")
            }
        case .alertThirdButtonReturn:
            preferences[Prefs.textRecognitionDetectLinks] = false
        default:
            break
        }
    }
}
