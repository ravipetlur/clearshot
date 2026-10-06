import AppKit
import CSCapture
import CSCore
import CSHistory
import CSRecording

/// A finished recording, ready for the after-recording actions. Everything in it is Sendable, so the work can leave the
/// main actor.
nonisolated struct RecordingResult: Sendable {
    /// The movie (or GIF) in its Recordings folder.
    var fileURL: URL
    var mode: RecordingMode
    /// Seconds.
    var duration: Double
    var pixelWidth: Int
    var pixelHeight: Int
    /// Pixels per point: the plan's width over the recorded region's.
    var scale: Double
    var hasAudio: Bool
    var displayID: UInt32
    /// The recorded rect in AppKit global points.
    var globalRect: CGRect
    var captureKind: CaptureKind
    var appName: String?
    var appBundleID: String?
    var windowTitle: String?
    var createdAt: Date
    /// A GIF's intermediate video: it goes into the GIF's item as `.source.mp4` (for Trim the GIF…) and gives the
    /// thumbnail, since `VideoThumbnail` never opens a GIF.
    var sourceVideo: URL?
}

/// What `routeRecordingReporting` did with a recording, for a caller that says so itself (launch recovery).
struct RoutedRecording {
    let item: HistoryItem
    /// The saved file in the export folder, or nil (also while the actions wait for the Video Editor).
    let savedURL: URL?
    let saveError: (any Error)?
    /// "Ask for name" holds the save for the thumbnail's name field.
    let savesWhenNamed: Bool
}

extension AfterCaptureRouter {
    /// The after-recording actions, or their defaults when none are chosen, as for screenshots.
    func afterRecordingActions() -> Set<AfterCaptureAction> {
        let actions = preferences[Prefs.afterRecordingActions]
        return actions.isEmpty ? Prefs.afterRecordingActions.defaultValue : actions
    }

    /// Runs the after-recording actions for `result`: the file moves into history as a video or GIF item (a GIF with
    /// its intermediate as `.source.mp4`) with the video's first frame as the thumbnail; Save clones it into the export
    /// folder under the file name template (a GIF as `.gif`), never re-encoding; Copy puts the file on the clipboard (a
    /// GIF with its data as `com.compuserve.gif` too); Open Video Editor opens it in the editor; then what screenshots
    /// share (`present`): holds, the thumbnail, the save-failure alert, the summary. `warning` (the GIF that couldn't
    /// be made) joins the summary HUD, with the warning symbol, and the save-failure alert. Pin never applies.
    ///
    /// Open Video Editor with any other action asks "Do you want to trim the video?" first:
    /// - **Trim:** the editor opens with its trimming handles up, and the other actions wait for it: they run on what
    ///   its Save left, or on the recording as it was when it closes without saving;
    /// - **Don't Trim** (Esc): the other actions run now, and no editor opens;
    /// - **Trim Only:** the editor opens, and the other actions never run.
    ///
    /// Open Video Editor alone opens the editor as Quick Access does (Save asks Replace or Save as New Video), with no
    /// question; only the Trim flow's editor replaces without asking. Either way the editor counts as showing the
    /// recording for the fallback that copies whatever isn't saved or shown, so nothing is copied for it. With
    /// `showsAlerts` false (quitting, recovering) no editor opens, since nothing could wait for one, the question isn't
    /// asked, and a failed save is only logged.
    ///
    /// As soon as the history item exists the recording's folder in Recordings is removed (when the file is in one), so a
    /// crash from then on can't recover it a second time. Returns the item, or nil when it couldn't be made: the folder
    /// then stays for the next launch's recovery, and nothing else runs.
    @discardableResult
    func routeRecording(_ result: RecordingResult, actions: Set<AfterCaptureAction>, showsAlerts: Bool = true,
                        warning: String? = nil) async -> HistoryItem? {
        await routeRecordingReporting(result, actions: actions, showsAlerts: showsAlerts, warning: warning)?.item
    }

    /// `routeRecording`, also saying what became of the save.
    func routeRecordingReporting(_ result: RecordingResult, actions: Set<AfterCaptureAction>, showsAlerts: Bool = true,
                                 warning: String? = nil) async -> RoutedRecording? {
        let opensEditor = showsAlerts && actions.contains(.openEditor)
        let others = actions.subtracting([.openEditor, .pin])
        let askForName = preferences[Prefs.askForNameAfterCapture]
        let settings = outputSettings()
        let made = await Self.makeRecordingItem(result, settings: settings, historyRoot: history.root,
                                                folders: recordingFolders)
        let item: HistoryItem
        switch made {
        case .success(let made):
            item = made
        case .failure(let error):
            Log.history.error("Couldn't add the recording to history: \(error)")
            return nil
        }
        Log.recording.info("Recorded \(item.kind.rawValue) \(result.pixelWidth)×\(result.pixelHeight), \(result.duration) s")
        advanceAutoIncrement(past: settings)

        guard opensEditor, !others.isEmpty else {
            let plan = AfterCapturePlan(actions: opensEditor ? [.openEditor] : others, askForName: askForName)
            return await runActions(plan, on: item, settings: settings, showsAlerts: showsAlerts, warning: warning)
        }
        // The item is held while the question is up, until the editor holds it or the actions have run.
        history.holds.hold(item.id)
        defer { history.holds.release(item.id) }
        history.add(item)
        let plan = AfterCapturePlan(actions: others, askForName: askForName)
        switch askToTrim(warning: warning) {
        case .dontTrim:
            // The warning was in the question.
            return await runActions(plan, on: item, settings: outputSettings(), showsAlerts: true, warning: nil)
        case .trim:
            videoEditor.open(item, mode: .afterRecording, startsTrimming: true) { [weak self] saved in
                // The editor still holds the item: retention "Never" can't take it before these have run. They run as it
                // closes, whenever that is, so a failed save's alert waits for any capture or recording then under way.
                guard let self, let current = saved ?? history.item(id: item.id) else { return }
                _ = await runActions(plan, on: current, settings: outputSettings(), showsAlerts: !videoEditor.isQuitting,
                                     runsLate: true, warning: nil)
            }
        case .trimOnly:
            videoEditor.open(item, mode: .afterRecording, startsTrimming: true)
        }
        return RoutedRecording(item: item, savedURL: nil, saveError: nil, savesWhenNamed: false)
    }

    private enum TrimAnswer {
        case trim, dontTrim, trimOnly
    }

    /// "Do you want to trim the video?" with Trim, Don't Trim (also Esc) and Trim Only; `warning` (the GIF that couldn't
    /// be made) as its text, since the question is the first thing the person sees of the recording.
    private func askToTrim(warning: String?) -> TrimAnswer {
        let alert = NSAlert()
        alert.messageText = "Do you want to trim the video?"
        if let warning { alert.informativeText = "\(warning)." }
        alert.addButton(withTitle: "Trim")
        alert.addButton(withTitle: "Don't Trim").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Trim Only")
        NSApp.activate()
        return switch alert.runModal() {
        case .alertFirstButtonReturn: .trim
        case .alertSecondButtonReturn: .dontTrim
        default: .trimOnly
        }
    }

    /// The actions in `plan` on a recording's item: save and the clipboard's file off the main actor, then `present`
    /// (which adds the item to history, or updates it when it is already listed). `runsLate`: outside routing (the trim
    /// flow's, as its editor closes), so a failed save's alert waits until no capture or recording is under way.
    private func runActions(_ plan: AfterCapturePlan, on item: HistoryItem, settings: OutputSettings, showsAlerts: Bool,
                            runsLate: Bool = false, warning: String?) async -> RoutedRecording {
        let output = await Self.runFileActions(plan, on: item, settings: settings, historyRoot: history.root)
        if let savedURL = output.savedURL {
            Log.capture.info("Saved \(savedURL.lastPathComponent)")
        }
        present(Written(item: output.item, savedURL: output.savedURL, saveError: output.saveError, copy: output.copy),
                plan: plan, noun: "recording", showsAlerts: showsAlerts, runsLate: runsLate, warning: warning,
                writeClipboard: {
                    guard let file = output.clipboardFileURL else { return false }
                    return ClipboardWriter.write(mediaFileURL: file, gifData: output.gifData)
                },
                // Open Video Editor alone: the normal editor, whose Save asks Replace or Save as New Video. Only the
                // trim prompt's editor replaces without asking.
                openEditor: { [videoEditor] in videoEditor.open($0) })
        return RoutedRecording(item: output.item, savedURL: output.savedURL, saveError: output.saveError,
                               savesWhenNamed: plan.defersSave)
    }

    /// What the file actions off the main actor hand back.
    private nonisolated struct RecordingOutput: Sendable {
        var item: HistoryItem
        var savedURL: URL?
        var saveError: (any Error)?
        var copy = CopyDecision.none
        var clipboardFileURL: URL?
        var gifData: Data?
    }

    /// Makes the history item (moving the file in, with its first frame as the thumbnail) under the template's name, and
    /// removes the Recordings folder. Touches no preferences.
    @concurrent
    private nonisolated static func makeRecordingItem(_ result: RecordingResult, settings: OutputSettings, historyRoot: URL,
                                                      folders: RecordingFolders) async -> Result<HistoryItem, any Error> {
        // Fix the name once: a template with random characters would give the item and the saved file different names.
        let name = FileNamer.baseName(for: settings.template, context: settings.nameContext(date: result.createdAt,
                                                                                           appName: result.appName,
                                                                                           windowTitle: result.windowTitle))
        let kind: MediaKind = result.mode == .gif ? .gif : .video
        let item: HistoryItem
        do {
            // A GIF's thumbnail is its intermediate's first frame: `VideoThumbnail` never opens a GIF.
            let thumbnail = try await VideoThumbnail.image(of: result.sourceVideo ?? result.fileURL)
            let details = HistoryWriter.Details(kind: kind, origin: .capture, captureKind: result.captureKind,
                                                displayName: name, savedURL: nil, scale: result.scale,
                                                appName: result.appName, isTransparent: false, globalRect: result.globalRect,
                                                createdAt: result.createdAt, appBundleID: result.appBundleID,
                                                windowTitle: result.windowTitle)
            item = try HistoryWriter.createMedia(result.fileURL, transfer: .move, pixelWidth: result.pixelWidth,
                                                 pixelHeight: result.pixelHeight, duration: result.duration,
                                                 hasAudio: result.hasAudio, thumbnail: thumbnail, details: details,
                                                 sourceVideo: result.sourceVideo, root: historyRoot)
        } catch {
            return .failure(error)
        }
        // The item is complete: the recording's folder (its journal above all) goes now, so a crash later can't recover
        // the same recording again. A file outside Recordings has no folder there, and nothing is removed.
        folders.remove(result.fileURL.deletingLastPathComponent())
        return .success(item)
    }

    /// Saves a clone of the item's working copy under its name, and prepares the clipboard's file. Touches no
    /// preferences.
    @concurrent
    private nonisolated static func runFileActions(_ plan: AfterCapturePlan, on item: HistoryItem, settings: OutputSettings,
                                                   historyRoot: URL) async -> RecordingOutput {
        var item = item
        var output = RecordingOutput(item: item)
        if plan.saves {
            do {
                let url = try Exporter.saveCopy(of: item.mediaURL(in: historyRoot), in: settings.exportDirectory,
                                                baseName: item.displayName)
                output.savedURL = url
                item.savedPath = url.path(percentEncoded: false)
                item.savedFileDate = HistoryWriter.modificationDate(of: url)
                do {
                    try HistoryWriter.writeMetadata(item, root: historyRoot)
                } catch {
                    Log.history.error("Couldn't record the save of \(item.displayName) in history: \(error)")
                }
            } catch {
                output.saveError = error
            }
        }
        output.item = item
        // Whatever isn't saved or shown is copied, so the recording is never lost.
        output.copy = plan.copy(saved: output.savedURL != nil, shown: plan.showsCapture)
        guard output.copy != .none else { return output }
        // The saved file, else a temporary copy of the history copy, which outlives the history folder (retention
        // "Never" removes that when the thumbnail closes).
        output.clipboardFileURL = output.savedURL
            ?? (try? HistoryWriter.temporaryCopy(of: item, root: historyRoot, in: temporaryDirectory))
        if item.kind == .gif, let file = output.clipboardFileURL {
            output.gifData = try? Data(contentsOf: file)
        }
        return output
    }
}
