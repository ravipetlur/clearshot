import AppKit
import CSCapture
import CSCore
import CSHistory
import CSRecording

/// What a launch does with the recordings a crash, a kill or a failed writer left in Recordings: each one worth
/// recovering is finalized to a plain MP4 in its folder and routed as a video with the after-recording actions plus
/// Save and the thumbnail, its folder removed once it is in history, and the person told; folders not worth it are
/// deleted, unreadable ones kept a day, and ones tried too often set aside (`RecoveryPlanner`); Focus Off runs when one
/// turned Focus on.
enum RecordingRecovery {
    /// A failed or interrupted take, finalized beside it in its folder.
    static let recoveredFileName = "recovered.mp4"

    /// Recovers what the plan says. Recordings started since this launch are this session's and are left alone. Each
    /// recovery waits until no capture or recording is under way (`isIdle`), routes without alerts and says what
    /// happened in one alert, so nothing modal ever opens under an overlay, a recording or its merge question. `focusOff`
    /// turns Focus off again ("ClearShot Focus Off").
    static func run(folders: RecordingFolders, router: AfterCaptureRouter, preferences: Preferences,
                    focusOff: @escaping () async -> Void = {}, isIdle: @escaping () -> Bool = { true }) async {
        let launched = NSRunningApplication.current.launchDate ?? Date()
        let candidates = await folders.scan().filter { candidate in
            guard let journal = candidate.journal else { return true }
            return journal.startedAt < launched
        }
        guard !candidates.isEmpty else { return }
        let plan = RecoveryPlanner.plan(candidates)
        if plan.runsFocusOff { await focusOff() }
        for action in plan.actions {
            switch action {
            case .recover(let candidate):
                await recover(candidate, folders: folders, router: router, isIdle: isIdle)
            case .delete(let folder):
                Log.recording.info("Removing the recording folder \(folder.lastPathComponent): nothing worth recovering")
                folders.remove(folder)
            case .keep(let folder):
                Log.recording.info("Keeping the unreadable recording folder \(folder.lastPathComponent) for now")
            case .setAside(let folder):
                do {
                    let moved = try folders.setAside(folder)
                    Log.recording.error("Gave up recovering the recording in \(folder.lastPathComponent) after "
                        + "\(RecoveryPlanner.maximumAttempts) launches; its files are in \(moved.path(percentEncoded: false))")
                } catch {
                    Log.recording.error("Couldn't set aside the recording folder \(folder.lastPathComponent): \(error)")
                }
            }
        }
    }

    private static func recover(_ candidate: RecoveryCandidate, folders: RecordingFolders, router: AfterCaptureRouter,
                                isIdle: () -> Bool) async {
        guard var journal = candidate.journal else { return }
        await waitUntil(isIdle)
        let folder = RecordingFolder(url: candidate.folder)
        // Counted before trying, so an attempt that crashes counts too: the planner gives up after a few.
        journal.noteRecoveryAttempt()
        do {
            try folders.write(journal, to: folder)
        } catch {
            Log.recording.error("Couldn't count the recovery attempt in \(folder.url.lastPathComponent): \(error)")
        }
        let destination = folder.url.appending(path: recoveredFileName)
        let duration: Double
        do {
            duration = try await RecoveryExporter.finalize(folder.movieURL, to: destination)
        } catch {
            Log.recording.error("Couldn't recover the recording in \(folder.url.lastPathComponent) (attempt "
                + "\(journal.recoveryAttempts ?? 1)): \(error)")
            return
        }
        let info = try? await VideoThumbnail.info(of: destination)
        // A GIF recording comes back as its video: converting at launch would surprise.
        let result = RecordingResult(fileURL: destination, mode: .video, duration: duration,
                                     pixelWidth: info?.pixelWidth ?? journal.pixelWidth,
                                     pixelHeight: info?.pixelHeight ?? journal.pixelHeight, scale: journal.scale,
                                     hasAudio: !(info?.audioChannelCounts.isEmpty ?? true), displayID: journal.displayID,
                                     globalRect: journal.globalRect, captureKind: journal.captureKind,
                                     appName: journal.appName, appBundleID: journal.appBundleID,
                                     windowTitle: journal.windowTitle, createdAt: journal.startedAt, sourceVideo: nil)
        Log.recording.info("Recovering the recording from \(journal.startedAt.formatted(.iso8601)), \(duration) s")
        // Routing removes the folder once the item is in history; when that fails it stays for the next launch. A failed
        // save is told in the alert below, not in an alert of its own.
        guard let routed = await router.routeRecordingReporting(
            result, actions: router.afterRecordingActions().union([.save, .showQuickAccess]), showsAlerts: false) else { return }
        let saved: RecoveryNotice.Saved = if let error = routed.saveError {
            .failed(reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        } else if routed.savesWhenNamed {
            .waitingForName
        } else if routed.savedURL != nil {
            .toExportLocation
        } else {
            // Save is among the actions, so this shouldn't happen; never claim a save that didn't.
            .failed(reason: "The save didn't run")
        }
        // Routing took a moment, and a capture may have started meanwhile.
        await waitUntil(isIdle)
        let alert = NSAlert()
        if case .failed = saved { alert.alertStyle = .warning }
        alert.messageText = RecoveryNotice.title
        alert.informativeText = RecoveryNotice.message(saved: saved, recordedAsGIF: journal.mode == .gif)
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            router.itemActions.showInFinder(router.history.item(id: routed.item.id) ?? routed.item)
        }
    }

    /// Returns once `isIdle` is true, checking once a second. A recording's tail waits with it too, before its alerts.
    static func waitUntil(_ isIdle: () -> Bool) async {
        while !isIdle() {
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
