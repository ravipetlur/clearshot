import AppKit
import CSCapture
import CSCore
import CSRecording

/// Record Screen: select an area or pick a window, Ready, the countdown, the recording behind its frame, then the file
/// through the after-recording actions. The recording, Select to its stop, runs inside `run`, so a screenshot meanwhile
/// says "A capture is already in progress"; a plain video is routed there too. A recording whose two audio tracks are
/// to be merged, or a GIF recording, goes on in a tail after `run` returns: the merge question and the merge, or the
/// GIF conversion (with its progress and Stop), then routing. The three recording hotkeys reach it directly
/// (`recordingHotkey`), as the scrolling capture's Start/Stop does.
extension CaptureFlow {
    /// The recording's merged file, beside the one it was merged from in its Recordings folder.
    static let mergedFileName = "merged.mp4"

    /// The status menu's Record Screen, and the Record hotkey without a recording. `initial` is a URL's area
    /// (`record-screen` with x, y, width and height): Ready on it, never recording by itself. `picksWindow` opens the
    /// recorder picking a window (Record Window).
    func recordScreen(initial: (rect: CGRect, display: DisplayInfo)? = nil, picksWindow: Bool = false) async {
        await run {
            let front = FrontmostApp.current(windows: WindowList.onScreen())
            try await self.runRecording(initial: initial.map { ($0.rect, $0.display, []) }, front: front,
                                        picksWindow: picksWindow)
        }
    }

    /// The Record Window hotkey: the recorder opens picking a window, whose frame a click makes Ready's selection;
    /// Space switches to areas, as in Record Screen.
    func recordWindow() async {
        await recordScreen(picksWindow: true)
    }

    /// Record Screen / Stop, Pause/Resume and Restart, as the recording's phase reads them (`RecordingControlState`).
    /// Not through `run`, which a recording holds.
    func recordingHotkey(_ hotkey: RecordingControlState.Hotkey) {
        switch recordingControl.command(for: hotkey) {
        case .openRecorder: Task { await recordScreen() }
        case .startRecording: activeRecordingOverlay?.startRecording(nil)
        case .skipCountdown: activeRecording?.skipCountdown()
        case .stop: activeRecording?.stop()
        case .pause, .resume: activeRecording?.togglePause()
        case .restart: activeRecording?.requestRestart()
        case .refuse(let text): hud.show(text, symbol: "hourglass")
        case .none: break
        }
    }

    /// The status item's Stop button.
    func stopRecording() {
        activeRecording?.stop()
    }

    /// The status item's Resume.
    func resumeRecording() {
        guard recordingControl.phase == .paused else { return }
        activeRecording?.togglePause()
    }

    /// The status item's "Creating GIF…" and the progress panel's Stop: Continue, Save as a Video or Delete.
    func requestGIFStop() {
        gifJob?.requestStop()
    }

    /// A recording is past Ready: counting down, recording, or finishing, merging, converting and routing its file.
    /// Quitting waits for it.
    var isRecording: Bool {
        recordingInProgress
    }

    /// A recording's countdown or the recording itself, paused or not, is on screen: a refused question says "Finish the
    /// recording first" (`ModalGate`). Anything else under way, Select and Ready included, is a capture.
    var isRecordingOnScreen: Bool {
        switch recordingControl.phase {
        case .countdown, .recording, .paused: true
        case .none, .selecting, .ready, .finishing, .converting: false
        }
    }

    /// Quitting during a recording: it stops (cancelled during the countdown), finishes and is routed as a video, with
    /// no dialog (the merge question, if it is up, answers Don't Merge); a GIF being converted stops, and its folder
    /// stays for the next launch to recover as a video. This returns once that is done.
    func finishRecordingForQuit() async {
        guard isRecording else { return }
        isFinishingRecordingForQuit = true
        activeRecording?.stop()
        AudioMergeDialog.dismiss()
        gifJob?.cancelForQuit()
        await withCheckedContinuation { recordingEndWaiters.append($0) }
        // "ClearShot Focus Off" too, so quitting doesn't leave Do Not Disturb on (at most the shortcut's time limit).
        await focus.waitForSwitches()
        // The quit may still be cancelled (an editor's question): later recordings speak again.
        isFinishingRecordingForQuit = false
    }

    /// Select and Ready on the overlay (starting in Ready on `initial`, All-In-One's selection, with the keys held as it
    /// was dragged out), then the recording, then its file through the after-recording actions, here or in the tail.
    /// `front` is the app in front as the recording began, for the file name and history. `picksWindow` starts Select
    /// picking a window rather than an area. Runs inside `run`.
    func runRecording(initial: (rect: CGRect, display: DisplayInfo, startModifiers: SelectionModifiers)?,
                      front: FrontmostApp, picksWindow: Bool = false) async throws {
        // All-In-One's R and the status menu reach here inside `run` while the last recording's tail may still be
        // merging or converting.
        guard recordingTail == nil else {
            hud.show(gifJob != nil ? "Still creating a GIF" : "Still saving the recording", symbol: "hourglass")
            return
        }
        recordingControl = RecordingControlState(phase: .selecting)
        defer {
            // A recording whose tail runs ends when the tail does.
            if recordingTail == nil { recordingEnded() }
        }
        let noteLayout = DisplayLayout.current()
        let model = RecordingReadyModel(preferences: preferences, permissions: permissions, initial: initial,
                                        plan: { [unowned self] target, mode in
                                            encoderPlan(for: target, mode: mode, layout: noteLayout)
                                        })
        // The deferred microphone request, however Ready closes without recording; a recording's comes as it ends.
        defer { model.askForMicrophoneIfNeeded(quitting: isFinishingRecordingForQuit) }
        Task { [recordingFolders] in model.availableBytes = await RecordingSession.freeSpace(at: recordingFolders.root) }
        let selection: Selection
        let overlayMode: OverlayMode = picksWindow ? .window : .area
        do {
            selection = try await runOverlay(mode: overlayMode, style: .recordingSelection(model), configure: { session in
                model.onReadyChange = { [weak self] ready in self?.recordingReadyChanged(ready) }
                self.activeRecordingOverlay = session
                model.startMeter()
            })
        } catch {
            model.stopMeter()
            model.readyClosed()
            throw error
        }
        activeRecordingOverlay = nil
        recordingControl.phase = .none
        model.readyClosed()
        if model.opensSettings {
            model.stopMeter()
            openSettings(.recording)
            return
        }
        guard case let .recording(pick) = selection.outcome else {
            model.stopMeter()
            return
        }
        try await record(pick, layout: selection.layout, front: front, model: model)
    }

    /// The overlay reported its selection coming (Ready) or going (Select).
    private func recordingReadyChanged(_ ready: Bool) {
        switch recordingControl.phase {
        case .selecting, .ready: recordingControl.phase = ready ? .ready : .selecting
        default: break
        }
    }

    /// The encoder plan for recording `target` in `mode`: the recorded region's points at the display's scale, with the
    /// Video settings; a GIF's intermediate at the GIF's frame rate (at most 50) and width ("800 × auto" fits 800 px).
    func encoderPlan(for target: RecordingPick.Target, mode: RecordingMode, layout: DisplayLayout) -> EncoderPlan {
        let isGIF = mode == .gif
        let purpose: EncoderPlan.Purpose = isGIF
            ? .gifIntermediate(maxWidth: preferences[Prefs.gifMaxSize] == .width800 ? 800 : nil)
            : .video
        return EncoderPlan.make(regionPoints: target.recordedRect(in: layout).size, scale: target.display.scale,
                                scaleRetinaTo1x: preferences[Prefs.recordingScaleRetinaTo1x],
                                maxResolution: preferences[Prefs.recordingMaxResolution],
                                framesPerSecond: preferences[isGIF ? Prefs.gifFrameRate : Prefs.recordingFrameRate],
                                hardwareEncoding: preferences[Prefs.recordingHardwareEncoding], purpose: purpose)
    }

    /// After Ready: remembers the mode and the area, takes Ready's microphone (a GIF records no audio), warns about low
    /// disk, makes the recording's folder and journal, runs the session, says what the system or the disk ended once
    /// the windows are gone, then routes the file, or leaves that to the merge or GIF tail.
    private func record(_ pick: RecordingPick, layout: DisplayLayout, front: FrontmostApp,
                        model: RecordingReadyModel) async throws {
        preferences[Prefs.recordingLastMode] = pick.mode
        if case let .area(rect, display) = pick.target {
            preferences[Prefs.recordingLastArea] = SavedArea(rect: rect, displayID: display.id)
        }
        let isGIF = pick.mode == .gif
        let display = pick.target.display
        let recorded = pick.target.recordedRect(in: layout)
        let plan = encoderPlan(for: pick.target, mode: pick.mode, layout: layout)
        let scale = Double(plan.width) / Double(recorded.width)

        // Ready's warm microphone, while the chosen device is still usable: the lid may have closed since Ready opened. A
        // chosen one that doesn't record is never dropped silently: the start notice says why (`startIssue`). A GIF has
        // no audio tracks, so it takes none and says nothing about it.
        let lidClosed = SystemProbes.isLidClosed() ?? false
        let chosenID = preferences[Prefs.recordingMicrophoneID]
        let device = isGIF ? nil : MicrophoneChoice.usable(savedID: chosenID, devices: model.devices, lidClosed: lidClosed)
        let warm = model.takeMicrophone()
        let microphone = device.flatMap { device in warm.map { (capture: $0, device: device) } }
        if microphone == nil, let warm { Task { await warm.stop() } }
        // The real reason, from what Ready did as well as how things are now (i).
        let warmState: MicrophoneSessionState = microphone != nil ? .open : model.openFailed ? .failed : .notOpened
        let microphoneIssue = isGIF ? nil
            : MicrophoneChoice.startIssue(savedID: chosenID, devices: model.devices, lidClosed: lidClosed,
                                          lidClosedInReady: model.lidClosed, permission: permissions.status(of: .microphone),
                                          session: warmState, lostInReady: model.lostMicrophone)
        let systemAudio = !isGIF && preferences[Prefs.recordingSystemAudio]
        let mono = preferences[Prefs.recordingMono]

        // Low disk, after Ready and before the countdown.
        let audio = RecordingSession.audioTracks(systemAudio: systemAudio, mono: mono, microphone: microphone != nil)
        let bits = plan.averageBitRate + (audio.system?.bitRate ?? 0) + (audio.microphone?.bitRate ?? 0)
        if let available = await RecordingSession.freeSpace(at: recordingFolders.root),
           DiskSpaceRule.warnsBeforeRecording(available: available, plannedBitsPerSecond: bits),
           !confirmLowDisk() {
            if let microphone { Task { await microphone.capture.stop() } }
            return
        }

        // A GIF recording's journal keeps the GIF settings it started with, which its conversion uses.
        let journal = RecordingJournal(startedAt: Date(), mode: pick.mode, framesPerSecond: plan.framesPerSecond,
                                       pixelWidth: plan.width, pixelHeight: plan.height, scale: scale,
                                       gifFrameRate: isGIF ? preferences[Prefs.gifFrameRate] : nil,
                                       gifQuality: isGIF ? preferences[Prefs.gifQuality] : nil,
                                       gifOptimize: isGIF ? preferences[Prefs.gifOptimize] : nil,
                                       displayID: display.id, globalRect: recorded, captureKind: pick.target.captureKind,
                                       systemAudio: systemAudio, microphone: microphone != nil, appName: front.name,
                                       appBundleID: front.bundleID, windowTitle: front.windowTitle)
        recordingInProgress = true
        let folder: RecordingFolder
        do {
            folder = try recordingFolders.create(journal)
        } catch {
            Log.recording.error("Couldn't make the recording's folder: \(error)")
            if let microphone { Task { await microphone.capture.stop() } }
            showRecordingAlert("The recording couldn't start", message: error.localizedDescription)
            return
        }
        let session = RecordingSession(
            configuration: .init(pick: pick, layout: layout, plan: plan, folders: recordingFolders, folder: folder,
                                 journal: journal, keptWindowIDs: pinWindowIDs(), exclusion: exclusionRules(),
                                 countdown: preferences[Prefs.recordingCountdown], systemAudio: systemAudio, mono: mono,
                                 microphone: microphone, microphoneIssue: microphoneIssue,
                                 focus: preferences[Prefs.recordingDoNotDisturb] ? focus : nil),
            preferences: preferences, sounds: sounds, statusItem: statusItem, countdown: countdown)
        session.onPhaseChange = { [weak self] phase in self?.recordingControl.phase = phase }
        activeRecording = session
        let written: RecordingWriterResult?
        // No permission prompt from here until the recording's windows have closed: the stream would capture it.
        model.recordingStarts()
        do {
            written = try await session.run()
        } catch {
            model.recordingEnded(quitting: isFinishingRecordingForQuit)
            activeRecording = nil
            Log.recording.error("The recording couldn't start: \(error)")
            if !isFinishingRecordingForQuit { showRecordingStartFailure(error) }
            return
        }
        model.recordingEnded(quitting: isFinishingRecordingForQuit)
        activeRecording = nil
        if !isFinishingRecordingForQuit {
            switch session.aftermath {
            case .stoppedWithFrames?:
                hud.show("Recording stopped", symbol: "stop.circle")
            case .stoppedEmpty?:
                let warning = RecordingWarning.streamStopped
                showRecordingAlert(warning.title, message: warning.message)
            case .diskFull?:
                let warning = RecordingWarning.diskFull
                showRecordingAlert(warning.title, message: warning.message)
            case nil:
                break
            }
        }
        guard let written else {
            if !isFinishingRecordingForQuit { focus.showMissingShortcutsIfNeeded() }
            return
        }
        recordingControl.phase = .finishing
        // The movie: the video recorded, or a GIF recording's intermediate.
        let result = RecordingResult(fileURL: written.fileURL, mode: .video, duration: written.duration,
                                     pixelWidth: plan.width, pixelHeight: plan.height, scale: scale,
                                     hasAudio: written.hasSystemAudio || written.hasMicrophone, displayID: display.id,
                                     globalRect: recorded, captureKind: pick.target.captureKind, appName: front.name,
                                     appBundleID: front.bundleID, windowTitle: front.windowTitle,
                                     createdAt: session.startedAt, sourceVideo: nil)
        if isGIF {
            // Converted after `run`, so captures go on meanwhile. Not while quitting, and not on a disk that just filled
            // up: the intermediate is routed as a video then.
            if !isFinishingRecordingForQuit, session.aftermath != .diskFull {
                startGIFConversion(of: result, in: folder, journal: journal)
                return
            }
            Log.recording.info("Not converting the GIF recording (\(isFinishingRecordingForQuit ? "quitting" : "disk full")); "
                + "saving it as a video")
            await routeRecorded(result, warning: isFinishingRecordingForQuit ? nil : Self.gifFailedWarning)
            return
        }
        // Both tracks with "Single track": the question and the merge run after `run`, so they don't hold up captures.
        // Not on a disk that just filled up: the merge needs room for a second copy.
        if written.hasSystemAudio, written.hasMicrophone, preferences[Prefs.recordingAudioTracks] == .single,
           session.aftermath != .diskFull, !isFinishingRecordingForQuit {
            recordingTail = Task {
                await mergeAndRoute(result)
                recordingTail = nil
                recordingEnded()
            }
            return
        }
        await routeRecorded(result)
    }

    /// The recording is over, routed or not: the hotkeys and the icon are themselves again, and quitting waits no more.
    /// On every way out (Stop, Delete, a cancelled countdown, a start error, a stream error, sleep, a display change,
    /// quit), at the end of the tail when there is one.
    private func recordingEnded() {
        recordingControl = RecordingControlState()
        activeRecordingOverlay = nil
        activeRecording = nil
        // The icon is the menu again, hidden again if the setting hides it.
        statusItem?.apply(.make(phase: .none, elapsed: 0, showsTime: false, conversionProgress: nil))
        recordingInProgress = false
        // A quit that is then cancelled mustn't keep later recordings quiet.
        isFinishingRecordingForQuit = false
        let waiters = recordingEndWaiters
        recordingEndWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// The after-recording actions on `result`, with `warning` joining their HUD or alert; then, after a recording, the
    /// one-time word that the Do Not Disturb shortcuts are missing.
    private func routeRecorded(_ result: RecordingResult, warning: String? = nil) async {
        let item = await router.routeRecording(result, actions: router.afterRecordingActions(),
                                               showsAlerts: !isFinishingRecordingForQuit, warning: warning)
        guard !isFinishingRecordingForQuit else { return }
        if item == nil {
            // The folder stays in Recordings with the file, so the next launch recovers it.
            showRecordingAlert("The recording couldn't be added to Capture History.",
                               message: "It will be recovered the next time ClearShot opens.")
        }
        focus.showMissingShortcutsIfNeeded()
    }

    // MARK: The GIF

    /// What the HUD says when a GIF recording ends up a video.
    static let gifFailedWarning = "Couldn't create the GIF; saved as a video"

    /// The GIF recording's tail: its conversion with the GIF settings it started with, then routing. Record is refused
    /// ("Still creating a GIF") until it ends.
    private func startGIFConversion(of result: RecordingResult, in folder: RecordingFolder, journal: RecordingJournal) {
        let settings = GIFConversionSettings(framesPerSecond: journal.gifFrameRate ?? preferences[Prefs.gifFrameRate],
                                             quality: journal.gifQuality ?? preferences[Prefs.gifQuality],
                                             optimize: journal.gifOptimize ?? preferences[Prefs.gifOptimize])
        let job = GIFConversionJob(folder: folder, result: result, settings: settings, encoder: StreamingGIFEncoder())
        // Stop's question waits for a capture under way and holds new ones back, like the merge question; quitting
        // asks nothing.
        job.presentsModally = { [weak self] ask in
            guard let self else { return }
            await tailModal { if !isFinishingRecordingForQuit { ask() } }
        }
        gifJob = job
        recordingControl.phase = .converting
        recordingTail = Task {
            await convertAndRoute(job, result: result)
            gifJob = nil
            recordingTail = nil
            recordingEnded()
        }
    }

    /// Converts with "Creating GIF…" and its percentage in the status item and the progress panel, then routes the GIF
    /// (its thumbnail the intermediate's first frame), or the intermediate as a video (Save as a Video; a failed
    /// conversion, with the HUD saying so), or nothing (Delete). Quitting leaves a stopped conversion's folder for the
    /// next launch's recovery; a quit that is then cancelled saves it as a video (`quitWasCancelled`).
    private func convertAndRoute(_ job: GIFConversionJob, result: RecordingResult) async {
        let panel = GIFProgressPanel(preferences: preferences,
                                     imagePixels: CGSize(width: result.pixelWidth, height: result.pixelHeight),
                                     thumbnailFrames: { [weak router] in router?.quickAccess.shownThumbnailFrames ?? [] },
                                     onStop: { [weak self] in self?.requestGIFStop() })
        statusItem?.apply(.make(phase: .converting, elapsed: 0, showsTime: false, conversionProgress: 0))
        panel.show()
        Task {
            if let image = try? await VideoThumbnail.image(of: result.fileURL, maximumPixel: 480) { panel.setImage(image) }
        }
        job.onProgress = { [weak self, weak job] progress in
            self?.statusItem?.apply(.make(phase: .converting, elapsed: 0, showsTime: false, conversionProgress: progress))
            panel.update(progress: progress, bytesWritten: job?.bytesWritten ?? 0)
        }
        let outcome = await job.run()
        job.onProgress = nil
        panel.close()
        switch outcome {
        case .gif(let routed), .video(let routed):
            await tailModal { await routeRecorded(routed) }
        case .deleted:
            break
        case .failed(let error):
            guard !isFinishingRecordingForQuit else {
                // Kept for a quit that is then cancelled (`quitWasCancelled`).
                stoppedForQuit = result
                Log.recording.info("Stopped the GIF conversion to quit; the next launch recovers the recording")
                return
            }
            Log.recording.error("Couldn't create the GIF: \(error); saving the recording as a video")
            await tailModal { await routeRecorded(result, warning: Self.gifFailedWarning) }
        }
    }

    /// The quit was cancelled after it stopped a GIF's conversion (an editor's question): the recording goes into
    /// history as a video now, saying the GIF wasn't made, rather than waiting for the next launch. It is a recording in
    /// progress until then, so another quit waits for it (and routing removes the folder, journal and all, as soon as
    /// the item exists, so it is never recovered as well).
    func quitWasCancelled() {
        guard let result = stoppedForQuit, recordingTail == nil, !recordingInProgress else { return }
        stoppedForQuit = nil
        Log.recording.info("The quit was cancelled; saving the stopped GIF recording as a video")
        recordingInProgress = true
        recordingControl.phase = .finishing
        recordingTail = Task {
            await tailModal { await routeRecorded(result, warning: Self.gifFailedWarning) }
            recordingTail = nil
            recordingEnded()
        }
    }

    // MARK: The merge

    /// The merge question; Merge exports one track, each at its volume, beside the recording and routes that; Don't
    /// Merge (or a quit meanwhile, or a failed merge) routes the recording with both tracks. The question, the alerts
    /// and routing (which may show one) are modal moments: each waits for any capture under way to finish, and no capture
    /// starts while it lasts (`tailModal`). Captures are free during the export.
    private func mergeAndRoute(_ result: RecordingResult) async {
        var routed = result
        // Quitting (even while the question waited for a capture to end) asks nothing and keeps both tracks.
        let volumes = await tailModal { isFinishingRecordingForQuit ? nil : AudioMergeDialog.ask(preferences: preferences) }
        if let volumes, !isFinishingRecordingForQuit, let merged = await merge(result.fileURL, volumes: volumes) {
            routed.fileURL = merged
        }
        await tailModal { await routeRecorded(routed) }
    }

    /// Runs `body`, a modal moment of the recording's tail, once no capture is under way (as recovery waits), keeping
    /// captures out until it returns.
    private func tailModal<Value>(_ body: () async -> Value) async -> Value {
        await RecordingRecovery.waitUntil { !isRunning }
        recordingTailIsModal = true
        defer { recordingTailIsModal = false }
        return await body()
    }

    /// `source`'s two audio tracks merged into one (`RecordingExporter`'s remix: the video copied), with the HUD
    /// "Merging audio..." until it is done; nil when there is no room for the copy (said in an alert) or it fails.
    private func merge(_ source: URL, volumes: (mic: Double, system: Double)) async -> URL? {
        let bytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard DiskSpaceRule.allowsMerge(available: await RecordingSession.freeSpace(at: source), fileBytes: bytes) else {
            Log.recording.error("Not enough free space to merge the audio tracks; keeping them separate")
            await tailModal {
                guard !isFinishingRecordingForQuit else { return }
                showRecordingAlert("Can't merge audio tracks",
                                   message: "There isn't enough free disk space to merge them. The recording is "
                                       + "saved and unaffected: the microphone and system audio stay on separate "
                                       + "tracks.")
            }
            return nil
        }
        // Up until the merge is done (an hour is a bound, never reached): then it goes, unless another message replaced it.
        let message = hud.show("Merging audio...", symbol: "waveform", duration: .seconds(3600))
        defer { hud.hide(message) }
        let destination = source.deletingLastPathComponent().appending(path: Self.mergedFileName)
        do {
            var edit = VideoEdit()
            // System audio first, then the microphone: the writer's track order.
            edit.trackVolumes = [volumes.system, volumes.mic]
            edit.mono = preferences[Prefs.recordingMono]
            let plan = VideoEditPlan.make(edit: edit, source: try await VideoThumbnail.info(of: source))
            try await RecordingExporter.export(source, to: destination, plan: plan)
            Log.recording.info("Merged the audio tracks (microphone \(volumes.mic), system audio \(volumes.system))")
            return destination
        } catch {
            Log.recording.error("Couldn't merge the audio tracks: \(error); keeping them separate")
            return nil
        }
    }

    // MARK: Alerts (only once the recording's windows have closed)

    /// "Your free disk space is low.": Record Anyway goes on, Cancel doesn't. The app being recorded is active again
    /// afterwards, so it records as it looked.
    private func confirmLowDisk() -> Bool {
        let warning = RecordingWarning.lowDiskBefore
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.title
        alert.informativeText = warning.message
        warning.buttons.forEach { alert.addButton(withTitle: $0) }
        let wasActive = NSApp.isActive
        NSApp.activate()
        let recordsAnyway = alert.runModal() == .alertFirstButtonReturn
        if !wasActive { NSApp.deactivate() }
        return recordsAnyway
    }

    /// The start failed: the permission alert without Screen Recording, else the "couldn't start" alert.
    private func showRecordingStartFailure(_ error: any Error) {
        switch error as? RecordingStartError {
        case .permissionDenied?:
            show(CaptureError.permissionDenied)
        case .displayNotFound?:
            show(CaptureError.displayNotFound)
        case .audioFailed?, .failed?:
            let warning = RecordingWarning.startFailed
            showRecordingAlert(warning.title, message: warning.message)
        case nil:
            showRecordingAlert("The recording couldn't start",
                               message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// An alert after the recording's windows have closed (never while recording or counting down).
    private func showRecordingAlert(_ title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
