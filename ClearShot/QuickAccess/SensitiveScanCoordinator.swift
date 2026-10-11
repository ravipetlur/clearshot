import CoreGraphics
import CSAnnotation
import CSCapture
import CSCore
import CSHistory
import CSSensitive
import Foundation

/// The secrets check on Quick Access thumbnails: one scan for each screenshot thumbnail, the badge's state for it
/// (`BadgeState`), and what the badge's commands do to the capture.
///
/// **When it scans.** `start` is called as a thumbnail appears, and scans only a screenshot, with the setting on and at least
/// one kind switched on. The scan runs in the background at `.utility` priority, after the thumbnail is up, so it never
/// delays the capture, the thumbnail or a copy. `cancel` is called when the thumbnail closes. A result that arrives after
/// that, or after a cancel, does nothing: no badge, no state, no crash.
///
/// **What it keeps.** Rectangles and counts, in memory, for as long as the thumbnail is open. A finding's text is never
/// read out of the scanner, logged, kept or sent anywhere; the log gets counts by kind and how long the scan took.
///
/// **What is scanned.** A capture never annotated is scanned as its working copy. One with a document (annotated in Annotate,
/// or made with a background) is scanned as the document's picture alone (`Renderer.renderPicture`): the base with its turns,
/// crop and redactions, without the annotations and the background. A mask is a redaction, which lies under every annotation,
/// so a secret inside a label would get a mask that hides nothing, and the badge would say "Masked".
///
/// **Stale rectangles.** A finding's rectangle is good only for the picture it was read from (`PictureIdentity`). A change to
/// the capture that isn't this class's own (Rotate or Resize from the thumbnail's menu, Annotate's Done) that makes the picture
/// another one (a turn, a crop, a redaction) sends a scan or a badge that was showing back to scanning the new picture, and
/// Mask All refuses rectangles that don't belong to the picture it is about to change. A Done that only draws over the
/// picture or around it (a label, a background) rewrites the working copy and leaves the findings where they are.
final class SensitiveScanCoordinator {
    private let preferences: Preferences
    private let history: HistoryStore
    private let actions: HistoryItemActions
    private let hud: HUDController
    /// Tells the thumbnail with this item ID that its badge changed (`badge(for:)`).
    var onBadgeChange: ((UUID) -> Void)?

    /// The capture's working copy as it was last written, by its time and size: what tells that the item in the store has
    /// changed since the coordinator last looked. Whether the picture the findings lie on has changed is `Entry.picture`.
    private struct PictureStamp: Equatable {
        var modifiedAt: Date?
        var pixelSize: CGSize

        init(_ item: HistoryItem) {
            modifiedAt = item.modifiedAt
            pixelSize = item.pixelSize
        }
    }

    /// One open thumbnail's check. A class, so that a scan's result can tell whether the thumbnail it was for is still the
    /// one in `entries`.
    private final class Entry {
        var badge = BadgeState()
        /// The working copy the coordinator last saw.
        var stamp: PictureStamp
        /// The picture `findings` were read from, as the document has it. Nil while the scan runs, and once the picture has
        /// changed under a masked badge. A change to the item that leaves its picture equal to this one doesn't touch the
        /// findings.
        var picture: PictureIdentity?
        /// What the scan found, in the pixels of a picture `scannedSize` across.
        var findings: [ImageFinding] = []
        var scannedSize = CGSize.zero
        var scan: Task<Void, Never>?
        /// The look at the document that says whether a changed item's picture is the one the findings lie on, while it is
        /// being read off the main actor.
        var check: Task<Void, Never>?
        /// The objects Mask All added, for Undo Mask.
        var maskIDs: [UUID] = []
        /// False once the picture has changed under a masked badge: Undo Mask then looks again instead of offering the old
        /// findings.
        var findingsAreCurrent = true
        /// Mask All or Undo Mask is writing the capture, so the change that makes in the picture is this class's own.
        var isWriting = false

        /// Whether the badge says "Masked".
        var isMasked: Bool {
            if case .masked = badge.phase { true } else { false }
        }

        init(stamp: PictureStamp) {
            self.stamp = stamp
        }
    }

    private var entries: [UUID: Entry] = [:]

    init(preferences: Preferences, history: HistoryStore, actions: HistoryItemActions, hud: HUDController) {
        self.preferences = preferences
        self.history = history
        self.actions = actions
        self.hud = hud
    }

    /// The badge's state for the thumbnail, or nil when it has no check (a video, the setting off, a closed thumbnail).
    func badge(for itemID: UUID) -> BadgeState? {
        entries[itemID]?.badge
    }

    // MARK: Scanning

    /// Starts the check for a thumbnail that has just appeared. Nothing for a video or GIF, with the master switch off, or
    /// with no kind switched on; nothing if the thumbnail is already being checked.
    func start(_ item: HistoryItem) {
        guard item.kind == .screenshot, preferences[Prefs.sensitiveCheckEnabled], !preferences[Prefs.sensitiveKinds].isEmpty,
              entries[item.id] == nil else { return }
        let entry = Entry(stamp: PictureStamp(item))
        entries[item.id] = entry
        scan(item, entry: entry)
    }

    /// Ends the thumbnail's check: its scan is cancelled and its badge goes. A scan that is past its last check when this
    /// comes still finishes, and its result is dropped.
    func cancel(_ itemID: UUID) {
        guard let entry = entries.removeValue(forKey: itemID) else { return }
        entry.scan?.cancel()
        entry.check?.cancel()
    }

    /// The capture's picture changed (the store's `.updated` for a changed image). Not this class's own change. A scan, or
    /// a badge with findings to mask, starts again on the new picture. A masked badge stays while any mask Mask All added is
    /// in the document, and Undo Mask looks again; once every one of them has been deleted in Annotate it isn't masked any
    /// more: it goes back to its findings if the picture is otherwise the one that was scanned, else the capture is scanned
    /// again.
    func pictureChanged(_ item: HistoryItem) {
        guard let entry = entries[item.id], !entry.isWriting, PictureStamp(item) != entry.stamp else { return }
        entry.check?.cancel()
        entry.check = nil
        let known = entry.picture
        // With no picture known yet (the scan is still running), there is nothing to compare with: it has changed. A masked badge
        // whose findings were given up is the exception: it has no picture to compare, but its masks may all be gone since, and
        // that is read from the document too.
        if known == nil, !entry.isMasked {
            pictureHasChanged(item, entry: entry)
            return
        }
        // The working copy was rewritten, but its picture may be the one the findings lie on: Done in Annotate with a label or a
        // background added, say. Whether it is is read from the document, off the main actor; the badge stays as it is until it
        // is known. They stand if so, and only what the coordinator last saw moves on. A picture that can't be read is taken as
        // changed. The answer is dropped if anything has overtaken it (a newer change, a write of this class's own, a restart).
        let root = history.root
        entry.check = Task { [weak self, weak entry] in
            let current = await Self.pictureIdentity(of: item, root: root)
            guard !Task.isCancelled, let self, let entry, entries[item.id] === entry, !entry.isWriting, entry.picture == known else { return }
            entry.check = nil
            guard let current else {
                pictureHasChanged(item, entry: entry)
                return
            }
            if current == known {
                entry.stamp = PictureStamp(item)
            } else if entry.isMasked {
                masksMayBeGone(item, entry: entry, nowOn: current)
            } else {
                pictureHasChanged(item, entry: entry)
            }
        }
    }

    /// A masked badge, and the picture check has read the document that is there now (`current`, not the picture the badge
    /// holds): what `PictureIdentity.maskedBadgeChange` says of it. With a mask still there the badge stays; with every mask
    /// deleted it is "Masked" no longer, so it goes back to the findings it had (as Undo Mask does, with `current` the picture
    /// they lie on), or, if the picture is another one besides, the capture is scanned again.
    private func masksMayBeGone(_ item: HistoryItem, entry: Entry, nowOn current: PictureIdentity) {
        switch PictureIdentity.maskedBadgeChange(maskIDs: entry.maskIDs, readFrom: entry.picture, nowOn: current,
                                                 stillCurrent: entry.findingsAreCurrent) {
        case .masksRemain:
            pictureHasChanged(item, entry: entry)
        case .findingsBack:
            entry.maskIDs = []
            entry.picture = current
            entry.stamp = PictureStamp(item)
            entry.badge.apply(.undoMask)
            onBadgeChange?(item.id)
        case .rescan:
            restart(item, entry: entry)
        }
    }

    /// The picture the findings lie on is another one: what the badge does about it.
    private func pictureHasChanged(_ item: HistoryItem, entry: Entry) {
        switch entry.badge.phase {
        case .scanning, .found:
            restart(item, entry: entry)
        case .masked:
            entry.findingsAreCurrent = false
            entry.picture = nil
            entry.stamp = PictureStamp(item)
        case .none, .dismissed:
            break
        }
    }

    /// The identity of the picture of the item's saved document, read off the main actor (a file read, small, but not for the
    /// main actor).
    @concurrent
    nonisolated private static func pictureIdentity(of item: HistoryItem, root: URL) async -> PictureIdentity? {
        AnnotationStorage.pictureIdentity(of: item, root: root)
    }

    private func restart(_ item: HistoryItem, entry: Entry) {
        guard preferences[Prefs.sensitiveCheckEnabled], !preferences[Prefs.sensitiveKinds].isEmpty else {
            cancel(item.id)
            onBadgeChange?(item.id)
            return
        }
        entry.check?.cancel()
        entry.check = nil
        entry.badge = BadgeState()
        entry.findings = []
        entry.picture = nil
        entry.maskIDs = []
        entry.findingsAreCurrent = true
        entry.stamp = PictureStamp(item)
        onBadgeChange?(item.id)
        scan(item, entry: entry)
    }

    private func scan(_ item: HistoryItem, entry: Entry) {
        let id = item.id
        let root = history.root
        let kinds = preferences[Prefs.sensitiveKinds]
        entry.scan?.cancel()
        entry.scan = Task(priority: .utility) { [weak self, weak entry] in
            let outcome: Result<Scanned, any Error>
            do {
                outcome = .success(try await Self.scanPicture(of: item, root: root, kinds: kinds))
            } catch {
                outcome = .failure(error)
            }
            // The scanner can return normally when the cancel came after its last check, so a result is dropped here too.
            guard !Task.isCancelled, let self, let entry, entries[id] === entry else { return }
            switch outcome {
            case .success(let scanned):
                let counts = FindingCounts(scanned.findings)
                Log.capture.info("Sensitive scan: \(BadgeText.logSummary(for: counts)) in \(BadgeText.seconds(scanned.duration)) s")
                entry.findings = scanned.findings
                entry.scannedSize = scanned.size
                entry.picture = scanned.picture
                entry.badge.apply(.scanFinished(counts))
            case .failure(let error):
                Log.capture.error("Sensitive scan failed: \(error)")
                entry.badge.apply(.scanFailed)
            }
            onBadgeChange?(id)
        }
    }

    nonisolated private struct Scanned: Sendable {
        var findings: [ImageFinding]
        /// The size of the picture that was scanned, in pixels.
        var size: CGSize
        /// Which picture that was, for Mask All and for telling when it has changed.
        var picture: PictureIdentity
        var duration: Duration
    }

    nonisolated private enum Unreadable: Error {
        case picture
    }

    /// Reads the picture and scans it, off the main actor. The time is that of the scan itself.
    ///
    /// The picture is the working copy for a capture with no document, and for one whose document can't be used (the scan then
    /// sees the annotations too, and Mask All says why it can't mask). For one with a document it is the document's picture
    /// alone (`Renderer.renderPicture`), with `size` that render's size, which is what Mask All maps back to the base.
    ///
    /// **It never writes.** The document is read with `AnnotationStorage.openReadOnly`, which is `open` without its recovery
    /// (that copies the working copy over a lost base). A background scan that ran on a thumbnail the person hasn't touched
    /// must not change what is in the capture's folder; if the document can't be read, the working copy is scanned instead.
    @concurrent
    nonisolated private static func scanPicture(of item: HistoryItem, root: URL, kinds: SensitiveKinds) async throws -> Scanned {
        let image: CGImage
        let picture: PictureIdentity
        if let read = AnnotationStorage.openReadOnly(item, root: root) {
            guard let rendered = Renderer.renderPicture(of: read.document, images: read.images) else { throw Unreadable.picture }
            image = rendered.image
            picture = read.document.pictureIdentity
        } else {
            guard let working = ImageOps.load(item.mediaURL(in: root)) else { throw Unreadable.picture }
            image = working
            picture = .plain(size: CGSize(width: working.width, height: working.height))
        }
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let start = clock.now
        let findings = try await SensitiveScanner.scan(image, kinds: kinds)
        return Scanned(findings: findings, size: CGSize(width: image.width, height: image.height), picture: picture,
                       duration: clock.now - start)
    }

    // MARK: The badge's commands

    /// Dismiss: the badge goes for this capture. A mask already added stays.
    func dismiss(_ itemID: UUID) {
        guard let entry = entries[itemID] else { return }
        entry.badge.apply(.dismiss)
        onBadgeChange?(itemID)
    }

    /// How many masks Mask All added for the thumbnail, once it has: fewer than the findings when some lie where a mask
    /// can't (text in a background's frame).
    func masksAdded(for itemID: UUID) -> Int? {
        guard let entry = entries[itemID], case .masked = entry.badge.phase else { return nil }
        return entry.maskIDs.count
    }

    /// Mask All: one Pixelate redaction over each finding, added to the capture's document, which is saved and rendered as
    /// Done does it, so the thumbnail, copies, drags and saves show the masks. The badge becomes "Masked". Returns the
    /// capture as it is now, or nil when nothing changed: it had nothing to mask, or its picture had changed since the scan
    /// (it is checked again), or the write failed, which has told the person why.
    func maskAll(_ item: HistoryItem) async -> HistoryItem? {
        guard let entry = entries[item.id], !entry.isWriting, case .found(let counts) = entry.badge.phase else { return nil }
        guard PictureStamp(item) == entry.stamp else {
            hud.show("The screenshot changed, so it's being checked again", symbol: "magnifyingglass")
            restart(item, entry: entry)
            return nil
        }
        // Which picture the findings lie on is known once the scan has finished, which a found badge has.
        guard let scannedPicture = entry.picture else {
            hud.show("The screenshot changed, so it's being checked again", symbol: "magnifyingglass")
            restart(item, entry: entry)
            return nil
        }
        // A look at the document that is still on its way would end after the write, about a picture that has changed again.
        entry.check?.cancel()
        entry.check = nil
        entry.isWriting = true
        defer { entry.isWriting = false }
        // Held while it is written, so a thumbnail closing meanwhile can't purge the capture under retention "Never".
        history.holds.hold(item.id)
        defer { history.holds.release(item.id) }
        let findings = entry.findings
        let size = entry.scannedSize
        let root = history.root
        let quality = preferences[Prefs.imageQuality]
        let outcome = await Task.detached(priority: .userInitiated) {
            Result {
                try SensitiveMasking.apply(findings, scannedSize: size, scannedPicture: scannedPicture, to: item, root: root,
                                           quality: quality)
            }
        }.value
        switch outcome {
        case .success(let applied):
            Log.annotate.info("Mask All: \(applied.maskIDs.count) masks added for \(counts.total) findings")
            record(applied.written, as: .masksAdded)
            // The after-capture copy, if it is still on the clipboard, is the picture with its secrets: the masked one
            // replaces it, and the message below says so. A copy that failed has said so already, and that is the message
            // that stays: the clipboard still holds the secrets.
            let replacement = actions.replaceCopyIfStillOnClipboard(applied.written.item)
            if replacement != .failed {
                hud.show(MaskCommandText.maskAllConfirmation(masksAdded: applied.maskIDs.count, clipboardUpdated: replacement == .replaced),
                         symbol: "eye.slash")
            }
            if entries[item.id] === entry {
                entry.maskIDs = applied.maskIDs
                entry.picture = applied.picture
                entry.stamp = PictureStamp(applied.written.item)
                entry.badge.apply(.maskAll)
                onBadgeChange?(item.id)
            }
            return applied.written.item
        case .failure(let error):
            Log.annotate.error("Mask All failed: \(error)")
            // A save that failed partway has already put `hasDocument` on disk (see `AnnotationStorage.save`): read the item
            // back so memory says so too, as Done does.
            history.reload(item.id)
            // The alert says it is checked again.
            if (error as? SensitiveMasking.Failure) == .pictureChanged, entries[item.id] === entry { restart(item, entry: entry) }
            actions.showAlert(message: "Couldn't mask this screenshot", error: error)
            return nil
        }
    }

    /// Undo Mask: takes out exactly the objects Mask All added, saves and renders again, and the badge goes back to its
    /// findings. If the picture changed under the masked badge, it looks again instead, since the findings are out of date.
    /// Returns the capture as it is now, or nil when the write failed, which has told the person why.
    func undoMask(_ item: HistoryItem) async -> HistoryItem? {
        guard let entry = entries[item.id], !entry.isWriting, case .masked = entry.badge.phase else { return nil }
        entry.check?.cancel()
        entry.check = nil
        entry.isWriting = true
        defer { entry.isWriting = false }
        history.holds.hold(item.id)
        defer { history.holds.release(item.id) }
        let ids = Set(entry.maskIDs)
        let root = history.root
        let quality = preferences[Prefs.imageQuality]
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { try SensitiveMasking.remove(ids, from: item, root: root, quality: quality) }
        }.value
        switch outcome {
        case .success(let removal):
            let written = removal.written
            Log.annotate.info("Undo Mask: \(removal.removed) masks taken out")
            if written.item != item { record(written, as: .masksRemoved) }
            if entries[item.id] === entry {
                entry.maskIDs = []
                // The findings come back only if the document, just before the masks came out, was the one they were read from
                // (and nothing has marked them out of date): a change made in Annotate that a picture check still on its way
                // hadn't reported (a flip, a half turn, a crop, a redaction) would otherwise bring them back over other pixels.
                if PictureIdentity.findingsStand(readFrom: entry.picture, nowOn: removal.before, stillCurrent: entry.findingsAreCurrent) {
                    entry.picture = removal.picture
                    entry.stamp = PictureStamp(written.item)
                    entry.badge.apply(.undoMask)
                    onBadgeChange?(item.id)
                } else {
                    restart(written.item, entry: entry)
                }
            }
            return written.item
        case .failure(let error):
            Log.annotate.error("Undo Mask failed: \(error)")
            history.reload(item.id)
            actions.showAlert(message: "Couldn't remove the masks", error: error)
            return nil
        }
    }

    /// Records what a write did in the store, as Done does (`recordDocumentWrite`): the store's `.updated` shows it on the
    /// thumbnail, and a saved file that couldn't be rewritten is reported once the thumbnail shows the change, since it is
    /// then the one place the old picture, secrets and all, still is.
    private func record(_ written: SensitiveMasking.Written, as report: HistoryItemActions.DocumentWriteReport) {
        actions.recordDocumentWrite(written.item, savedFileError: written.savedFileError, as: report)
    }
}
