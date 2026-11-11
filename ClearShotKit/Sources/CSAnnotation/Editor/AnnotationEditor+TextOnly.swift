import CoreGraphics
import CSOCR
import Foundation
import Observation

/// The word searches of one editor's text-only redactions: the ones running, by redaction, and the ones that failed.
@MainActor
final class TextOnlyWordSearches {
    struct Running {
        var rect: CGRect
        var task: Task<Void, Never>
    }

    var running: [UUID: Running] = [:]
    /// Searches that failed, by redaction and rect: not tried again until the rect changes, so a picture recognition can't
    /// read doesn't search on every change. The redaction covers its whole rect meanwhile.
    var failed: [(id: UUID, rect: CGRect)] = []
    /// The picture the words are read from, made once per picture (`RedactionWordFinder.picture`).
    var picture: (key: PictureKey, task: Task<PictureRender?, Never>)?
    var isWatching = false
    var notice: ((String) -> Void)?

    struct PictureKey: Equatable {
        var base: ImageRef
        var identity: PictureIdentity
    }
}

/// "Text only" on the Redact tool: the style covers only the words inside a redaction's rect.
///
/// **Finding the words.** Whenever a text-only redaction has no words for its rect as it is now (it was just drawn or switched
/// to text only, or it was moved or resized: `RedactObject.needsWords`), the words under it are found in the background,
/// after a quiet `textOnlySearchDelay` and once no drag is open, so a run of changes searches once. They are stored in the
/// redaction (`RedactObject.words`) without an undo step of their own: they follow from the rect, and an undo that brings
/// back a rect brings back its words, or searches again.
///
/// **Fail safe.** Until the words arrive, and when the search fails, the redaction covers its whole rect, so no text is shown
/// while recognition runs. When no text is found it covers the whole rect too, and `textOnlyNotice` says so.
extension AnnotationEditor {
    /// How long a text-only redaction must stay unchanged before its words are searched for.
    static let textOnlySearchDelay = Duration.milliseconds(300)

    /// What the editor says when a text-only redaction found no text.
    public static let noTextFoundNotice = "No text found; covering the whole area"

    /// Called with a short message for the person (`noTextFoundNotice`); the window shows it.
    public var textOnlyNotice: ((String) -> Void)? {
        get { textOnlyWordSearches.notice }
        set { textOnlyWordSearches.notice = newValue }
    }

    // MARK: Watching

    /// Watches the document for text-only redactions that need their words, once; the editor turns it on when it opens.
    func watchTextOnlyRedactions() {
        guard !textOnlyWordSearches.isWatching else { return }
        textOnlyWordSearches.isWatching = true
        updateTextOnlySearches()
    }

    /// Reads which redactions need words, registers for the document's next change, and starts or cancels searches to
    /// match. The change is reported before the new value is set, so it is read again on the next turn of the main actor.
    private func updateTextOnlySearches() {
        let pending = withObservationTracking {
            document.objects.compactMap { object -> (id: UUID, rect: CGRect)? in
                guard case .redact(let redact) = object.kind, redact.needsWords else { return nil }
                return (object.id, redact.rect)
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateTextOnlySearches() }
        }
        let searches = textOnlyWordSearches
        for (id, running) in searches.running where !pending.contains(where: { $0.id == id && $0.rect == running.rect }) {
            running.task.cancel()
            searches.running[id] = nil
        }
        searches.failed.removeAll { failed in !pending.contains { $0.id == failed.id && $0.rect == failed.rect } }
        for item in pending where searches.running[item.id] == nil
            && !searches.failed.contains(where: { $0.id == item.id && $0.rect == item.rect }) {
            searches.running[item.id] = TextOnlyWordSearches.Running(rect: item.rect, task: searchWords(of: item.id, in: item.rect))
        }
    }

    /// Finds the words under redaction `id` at `rect` and stores them, unless the search is cancelled first.
    private func searchWords(of id: UUID, in rect: CGRect) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await Task.sleep(for: Self.textOnlySearchDelay)
                while self?.isInLiveChange == true { try await Task.sleep(for: Self.textOnlySearchDelay) }
            } catch {
                return
            }
            guard let self else { return }
            var options = TextRecognitionOptions(preferences: preferences)
            // Correction can rewrite what it reads, and only the boxes matter here.
            options.usesLanguageCorrection = false
            let picture = await textPicture()
            let words: RedactionWords?
            if let picture {
                words = await RedactionWordFinder.words(in: rect, of: picture, options: options)
            } else {
                words = nil
            }
            guard !Task.isCancelled else { return }
            let searches = textOnlyWordSearches
            searches.running[id] = nil
            // The picture can be large: kept only while searches need it.
            if searches.running.isEmpty { searches.picture = nil }
            guard let words else {
                log.error("Text only: couldn't read the text under a redaction; it covers its whole area")
                searches.failed.append((id, rect))
                return
            }
            guard storeWords(words, of: id) else { return }
            log.info("Text only: \(words.boxes.count) word boxes found under a redaction")
            if words.boxes.isEmpty { searches.notice?(Self.noTextFoundNotice) }
        }
    }

    /// The picture the words are read from (`RedactionWordFinder.picture`), made once for the picture as it is now.
    private func textPicture() async -> PictureRender? {
        let key = TextOnlyWordSearches.PictureKey(base: document.base,
                                                  identity: RedactionWordFinder.textPicture(of: document).pictureIdentity)
        let searches = textOnlyWordSearches
        if let picture = searches.picture, picture.key == key { return await picture.task.value }
        let document = document, images = images
        let task = Task.detached(priority: .userInitiated) {
            RedactionWordFinder.picture(of: document, images: images)
        }
        searches.picture = (key, task)
        return await task.value
    }
}
