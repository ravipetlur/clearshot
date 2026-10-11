import CSAnnotation
import CSCore
import CSSensitive
import Foundation
import Observation

/// The sensitive-info button's side of one Annotate editor: it watches the open document and keeps what the button shows
/// (`state`, a `SensitiveButtonState` over the document's `PictureIdentity` and its count of the masks the secrets check made,
/// which decides every question of what to show, what a click does and when to scan).
///
/// **When it scans.** When the editor opens, and again after the picture changes (a crop, a turn, a flip, a resize, the
/// canvas, a redaction added or deleted), as the state machine says: in the background at `.utility` priority, off the main
/// actor, after a quiet half second so a run of changes scans once, with any earlier scan cancelled. What is scanned is
/// exactly what Edit › Mask Sensitive Info scans (`SensitiveInfoScan`, the document's picture alone), so the warning counts
/// what a click would mask. With the master switch off (`Prefs.sensitiveCheckEnabled`) it never scans on its own, and with no
/// kind on (`Prefs.sensitiveKinds`) there is nothing to look for; the state machine knows both, and both are followed live.
///
/// **A click** is the Edit-menu command, one code path (`EditorWindowController.maskSensitiveInfo`). It first reads the document
/// again (`refresh`) and asks the state what a click does: masks every finding, or, in the masked look, takes the marked masks
/// out. Masking asks here for a scan of this very picture and these kinds that is already there (`takeFound`) and scans only
/// when there isn't, then tells the button what it found (`checked`) or masked (`masked`), so the warning clears at once and an
/// undo brings it back without a scan. Taking the masks out calls `refresh` once they are gone.
///
/// **Closing** (`stop`) cancels any scan, and a result that arrives later does nothing.
///
/// **What it logs.** Counts by kind and how long a scan took. A finding's text never leaves the scanner: only rectangles and
/// counts are here.
@Observable
final class AnnotateSensitiveCheck {
    typealias State = SensitiveButtonState<PictureIdentity>

    /// What the button shows.
    private(set) var state: State
    /// Mask Sensitive Info is scanning or adding its masks: a second run is refused, and the button is off meanwhile.
    var isMasking = false

    @ObservationIgnored private let editor: AnnotationEditor
    @ObservationIgnored private let preferences: Preferences
    /// The automatic scan, while one is waiting out its delay or running.
    @ObservationIgnored private var scan: Task<Void, Never>?
    @ObservationIgnored private var isStopped = false
    /// The last scan made, with what it was a scan of, for a click to use instead of scanning the same picture again.
    @ObservationIgnored private var latest: Scanned?

    private struct Scanned {
        var picture: PictureIdentity
        var kinds: SensitiveKinds
        var found: SensitiveInfoScan.Found
    }

    /// What the check reads of the app: the picture the document has now, how many masks the secrets check made it holds, and
    /// the two settings.
    private struct Inputs {
        var picture: PictureIdentity
        var masks: Int
        var automatic: Bool
        var kinds: SensitiveKinds
    }

    init(editor: AnnotationEditor, preferences: Preferences) {
        self.editor = editor
        self.preferences = preferences
        state = State(automatic: preferences[Prefs.sensitiveCheckEnabled], kinds: preferences[Prefs.sensitiveKinds])
    }

    /// Whether a click does anything (not with no kind on, not while a run is under way).
    var isEnabled: Bool { state.isEnabled(maskRunning: isMasking) }

    // MARK: Watching

    /// Starts watching the document and the settings: the first reading scans the picture the editor opened with.
    func start() {
        track()
    }

    /// Ends the check: any scan is cancelled and what arrives later is ignored.
    func stop() {
        isStopped = true
        perform(state.apply(.closed))
        cancelScan()
        latest = nil
    }

    /// What the document and the settings say now.
    private func readInputs() -> Inputs {
        let document = editor.document
        return Inputs(picture: document.pictureIdentity, masks: document.secretsMaskCount,
                      automatic: preferences[Prefs.sensitiveCheckEnabled], kinds: preferences[Prefs.sensitiveKinds])
    }

    /// Reads the document and the settings again, for the state to catch up with a change the watch hasn't reported yet (it
    /// reports on the next turn of the main actor): a click asks before it decides what to do, and the masks it adds or takes out
    /// are in the document before the watch hears of them.
    func refresh() {
        guard !isStopped else { return }
        apply(readInputs())
    }

    /// Reads the document's picture and the settings, and watches them for the next change. The change is reported before the
    /// new value is set, so it is read again on the next turn of the main actor, when it has landed; one reading both gives
    /// the state its input and registers the next watch, so nothing slips between them.
    private func track() {
        guard !isStopped else { return }
        let inputs = withObservationTracking {
            readInputs()
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        apply(inputs)
    }

    private func apply(_ inputs: Inputs) {
        perform(state.apply(.settingsChanged(automatic: inputs.automatic, kinds: inputs.kinds)))
        perform(state.apply(.masksChanged(inputs.masks)))
        perform(state.apply(.pictureChanged(inputs.picture)))
    }

    private func perform(_ effect: SensitiveButtonEffect) {
        switch effect {
        case .none: break
        case .cancelScan: cancelScan()
        case .scan(let delay): startScan(after: delay)
        }
    }

    private func cancelScan() {
        scan?.cancel()
        scan = nil
    }

    // MARK: Scanning

    /// Starts over: any earlier scan is cancelled, and a new one scans the document as it is once `delay` has passed. The
    /// document is read when the wait is over, so it is the latest, and its picture is read from that same copy: the result
    /// is for exactly what was scanned.
    private func startScan(after delay: Duration) {
        cancelScan()
        let kinds = state.kinds
        scan = Task(priority: .utility) { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard let snapshot = self?.snapshot(), !Task.isCancelled else { return }
            let outcome: Result<SensitiveInfoScan.Found, any Error>
            do {
                outcome = .success(try await SensitiveInfoScan.run(snapshot.document, images: snapshot.images, kinds: kinds))
            } catch {
                outcome = .failure(error)
            }
            // The scan can return normally when the cancel came after its last check, so a result is dropped here too: a
            // cancelled scan is one the state machine no longer wants, and a closed editor has nowhere to show it.
            guard !Task.isCancelled, let self, !isStopped else { return }
            finishScan(outcome, picture: snapshot.picture, kinds: kinds)
        }
    }

    private func snapshot() -> (document: AnnotationDocument, images: ImageStore, picture: PictureIdentity) {
        let document = editor.document
        return (document, editor.images, document.pictureIdentity)
    }

    private func finishScan(_ outcome: Result<SensitiveInfoScan.Found, any Error>, picture: PictureIdentity, kinds: SensitiveKinds) {
        // Past the cancellation check, so this is the scan `scan` holds.
        scan = nil
        switch outcome {
        case .success(let found):
            Log.annotate.info("Sensitive check: \(BadgeText.logSummary(for: found.findings)) in \(BadgeText.seconds(found.duration)) s")
            latest = Scanned(picture: picture, kinds: kinds, found: found)
            perform(state.apply(.scanFinished(picture, kinds: kinds, counts: Self.counts(of: found))))
        case .failure(let error):
            Log.annotate.error("Sensitive check couldn't read the image: \(error)")
            perform(state.apply(.scanFailed(picture, kinds: kinds)))
        }
    }

    /// What the button counts: the findings a click can mask. A scan whose findings have no place on the picture (none got a
    /// mask) has nothing to warn of.
    private static func counts(of found: SensitiveInfoScan.Found) -> FindingCounts {
        found.masks.isEmpty ? FindingCounts([]) : found.findings
    }

    // MARK: The command

    /// The scan of exactly `picture` for `kinds` that is already here, for a click to use instead of scanning it again, or nil.
    /// It is taken: until masks are added (`masked`) it isn't offered twice, so a second click can't add the masks twice.
    ///
    /// With nothing ready the click scans for itself, so the background scan that may be waiting or running is cancelled first:
    /// only one recognition runs. The click's own result then settles the button (`checked`, `masked`, or `failed`), and a change
    /// of picture or settings meanwhile asks for the scan it needs.
    func takeFound(for picture: PictureIdentity, kinds: SensitiveKinds) -> SensitiveInfoScan.Found? {
        guard let latest, latest.picture == picture, latest.kinds == kinds else {
            cancelScan()
            return nil
        }
        self.latest = nil
        return latest.found
    }

    /// A click's scan of `picture` for `kinds` couldn't be made: the button is plain, as after a background scan that failed
    /// (the click's scan had taken the place of the background one, which was cancelled).
    func failed(of picture: PictureIdentity, kinds: SensitiveKinds) {
        perform(state.apply(.scanFailed(picture, kinds: kinds)))
    }

    /// A click's scan of `picture` found `found`, and its masks weren't added (there were none, or a crop or a drag had begun):
    /// the button shows the result.
    func checked(_ found: SensitiveInfoScan.Found, of picture: PictureIdentity, kinds: SensitiveKinds) {
        latest = Scanned(picture: picture, kinds: kinds, found: found)
        perform(state.apply(.checked(picture, kinds: kinds, counts: Self.counts(of: found))))
    }

    /// A click added the masks of `found`, a scan of `picture`: the warning clears and the masked look shows. The scan is kept for
    /// `picture`, so that undoing the masks, which makes that picture again, brings the warning back and a click then needs no
    /// new scan.
    func masked(_ found: SensitiveInfoScan.Found, of picture: PictureIdentity, kinds: SensitiveKinds) {
        latest = Scanned(picture: picture, kinds: kinds, found: found)
        // The scan's result first (for `picture`, which an undo makes current again), then the document with the masks in it,
        // which has nothing unmasked left in it: no scan is needed for it.
        perform(state.apply(.checked(picture, kinds: kinds, counts: Self.counts(of: found))))
        refresh()
        perform(state.apply(.checked(editor.document.pictureIdentity, kinds: kinds, counts: FindingCounts([]))))
    }
}
