import AppKit
import CoreMedia
import CSCapture
import CSCore
import CSRecording

/// One recording, from the countdown to the stop: the stream (with system audio) and the microphone feeding the writer,
/// the countdown, pause and resume, Restart and Delete, keeping the display awake, Do Not Disturb, Highlight Clicks,
/// and every way it ends; what ends it or warns during it (the system, the disk, the microphone) is in
/// `RecordingSession+Endings.swift`, and the microphone Ready handed over and the click rings' lifecycle in
/// `RecordingSession+Inputs.swift`. What it shows on screen (the frame, the bar, notices, the status item) is its
/// `RecordingChrome`; the rings, its `ClickHighlighter`'s. Runs once.
///
/// It owns its Recordings folder until `run` returns: an ending with nothing to keep (Delete, a cancelled countdown, a
/// start error) removes it; a kept recording leaves it, with the file, for the router (which removes it once the history
/// item exists) or for the next launch's recovery. It owns the microphone's session from Ready too, and stops it on every
/// ending.
final class RecordingSession {
    struct Configuration {
        let pick: RecordingPick
        let layout: DisplayLayout
        let plan: EncoderPlan
        /// The Recordings folder, and the recording's folder in it.
        let folders: RecordingFolders
        let folder: RecordingFolder
        var journal: RecordingJournal
        /// ClearShot's windows the recording keeps: the pins on screen as it starts (the session adds its click overlay).
        let keptWindowIDs: Set<UInt32>
        let exclusion: ExclusionRules
        /// "Show countdown": 3 s before the recording starts.
        let countdown: Bool
        /// "Record system audio" and "Record audio in mono", as the recording starts.
        let systemAudio: Bool
        let mono: Bool
        /// The microphone recorded: Ready's warm session and its device; nil records none.
        let microphone: (capture: MicrophoneCapture, device: MicrophoneDeviceInfo)?
        /// Why the chosen microphone doesn't record (`MicrophoneChoice.startIssue`), said once the frame is up.
        let microphoneIssue: MicrophoneStartIssue?
        /// Switches Do Not Disturb with the user's Shortcuts ("Do Not Disturb while recording"); nil leaves Focus
        /// alone.
        let focus: FocusController?
    }

    /// What the person is told about an ending ScreenCaptureKit or the disk caused, by whoever ran the session, once its
    /// windows have closed.
    enum Aftermath: Equatable {
        /// The stream stopped by itself and what was written is kept: the HUD "Recording stopped".
        case stoppedWithFrames
        /// It stopped by itself with nothing written, or the file couldn't be read back: `RecordingWarning.streamStopped`.
        case stoppedEmpty
        /// The disk was almost full: the recording stopped, keeping what was written (`RecordingWarning.diskFull`).
        case diskFull
    }

    enum Ending {
        /// Stop (the bar, a hotkey, the status item, a notice, sleep, quit, a display change), at the stream's clock read
        /// then.
        case stop(at: CMTime?)
        /// The disk poll found the disk almost full: a stop, at the stream's clock read then.
        case diskFull(at: CMTime?)
        /// Delete, or a display change before anything was written: nothing is kept.
        case delete
        /// ScreenCaptureKit ended the stream by itself.
        case streamStopped(RecordingStreamStop, lastSampleTime: CMTime?)
        /// The writer failed: what reached the file is finalized and kept.
        case writerFailed
        /// A restart couldn't make a new writer: the take is gone.
        case restartFailed(any Error)
    }

    static let countdownSeconds = 3

    let configuration: Configuration
    let preferences: Preferences
    private let sounds: SoundPlayer
    let countdown: CountdownController
    /// The stream's and the writer's settings; both lose system audio when it fails to start.
    private var settings: RecordingStreamSettings
    private var writerConfiguration: RecordingWriterConfiguration

    /// The stream captures system audio (it was asked for and didn't fail to start).
    var capturesSystemAudio: Bool {
        settings.capturesSystemAudio
    }
    let chrome: RecordingChrome
    // Read and set by RecordingSession+Inputs.swift too, so internal rather than private.
    /// Highlight Clicks, as the recording starts: rings at the clicks, in a window over the recorded display that the
    /// stream keeps; nil with it off.
    let clickHighlighter: ClickHighlighter?
    /// ClearShot's windows the stream keeps: the pins, and the click overlay once it is up.
    var keptWindowIDs: Set<UInt32>
    /// What the folder's journal says; rewritten when Focus turns on, system audio drops out, a restart starts a new take
    /// and the file is complete.
    private var journal: RecordingJournal

    /// When the take being recorded started: the recording's start, or its last restart's.
    var startedAt: Date { journal.startedAt }

    private var hasRun = false
    private(set) var stream: ScreenRecordingStream?
    private(set) var writer: RecordingWriter?
    /// The recording's length in the stream's clock, pauses left out, for the bar and the status item.
    private var timeline = PauseTimeline()
    private(set) var phase = RecordingControlState.Phase.none
    private(set) var isCountingDown = false
    private var isRestarting = false
    /// The latest change of the stream's frame rate, which the next one waits for.
    private var rateChange: Task<Void, Never>?

    // Set by RecordingSession+Endings.swift too (`end`, the watchers and the notices), so internal rather than private.
    var ending: Ending?
    var endingContinuation: CheckedContinuation<Ending, Never>?

    /// The microphone's session, while it records into the writer; ended once it was disconnected or failed, in the
    /// handover included (`RecordingMicrophoneState`).
    var microphone: MicrophoneCapture? { configuration.microphone?.capture }
    var microphoneState = RecordingMicrophoneState()
    var microphoneEnded: Bool { microphoneState.hasEnded }
    /// Why the chosen microphone doesn't record, told once the frame is up: Ready's word for it, or that it was unplugged
    /// after Ready handed it over.
    var microphoneIssue: MicrophoneStartIssue?
    /// The newest microphone time forwarded to the writer: a recording the stream ended by itself ends no earlier.
    let microphoneTimes = NewestTime()
    /// Focus over this recording.
    var focusState = FocusSessionState()
    /// The disk poll, the microphone's meter and silence watch and the system audio watch, from the start of the
    /// recording to its ending.
    var diskWatch: Task<Void, Never>?
    var microphoneWatch: Task<Void, Never>?
    var systemAudioWatch: Task<Void, Never>?
    var silence = SilenceDetector()
    /// "Microphone is muted" shows once per recording, at the start or after a silence.
    var toldMuted = false

    /// Told as the session moves through the countdown, recording, paused and finishing.
    var onPhaseChange: ((RecordingControlState.Phase) -> Void)?

    /// Set when `run` returns after ScreenCaptureKit or the disk ended the recording.
    private(set) var aftermath: Aftermath?

    init(configuration: Configuration, preferences: Preferences, sounds: SoundPlayer, statusItem: StatusItemController?,
         countdown: CountdownController) {
        self.configuration = configuration
        self.preferences = preferences
        self.sounds = sounds
        self.countdown = countdown
        journal = configuration.journal
        microphoneIssue = configuration.microphoneIssue
        keptWindowIDs = configuration.keptWindowIDs
        let target = configuration.pick.target
        settings = Self.streamSettings(configuration, preferences: preferences, systemAudio: configuration.systemAudio)
        let audio = Self.audioTracks(systemAudio: configuration.systemAudio, mono: configuration.mono,
                                     microphone: configuration.microphone != nil)
        writerConfiguration = RecordingWriterConfiguration(fileURL: configuration.folder.movieURL, plan: configuration.plan,
                                                           systemAudio: audio.system, microphone: audio.microphone)
        chrome = RecordingChrome(display: target.display, region: settings.globalRect, isArea: target.area != nil,
                                 preferences: preferences, statusItem: statusItem)
        clickHighlighter = preferences[Prefs.recordingHighlightClicks]
            ? ClickHighlighter(style: ClickRippleStyle(preferences: preferences), display: target.display) : nil
        chrome.onAction = { [weak self] action in self?.barAction(action) }
    }

    /// The writer's audio tracks: system audio as stereo AAC at 192 kbit/s, or mono at 128 kbit/s with "Record audio in
    /// mono"; the microphone always as mono AAC at 128 kbit/s.
    static func audioTracks(systemAudio: Bool, mono: Bool, microphone: Bool)
        -> (system: AudioTrackSettings?, microphone: AudioTrackSettings?) {
        (systemAudio ? AudioTrackSettings(channels: mono ? 1 : 2, bitRate: mono ? 128_000 : 192_000) : nil,
         microphone ? AudioTrackSettings(channels: 1, bitRate: 128_000) : nil)
    }

    /// The bytes free on the volume where `url` is, or would be (its nearest existing folder), off the main actor: a
    /// query takes 12–41 ms. Nil when it can't be read.
    @concurrent
    nonisolated static func freeSpace(at url: URL) async -> Int64? {
        var url = url
        while !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return SystemProbes.availableCapacity(at: url)
    }

    private static func streamSettings(_ configuration: Configuration, preferences: Preferences,
                                       systemAudio: Bool) -> RecordingStreamSettings {
        let plan = configuration.plan
        let target = configuration.pick.target
        return RecordingStreamSettings.make(region: target.area, display: target.display, layout: configuration.layout,
                                            width: plan.width, height: plan.height, framesPerSecond: plan.framesPerSecond,
                                            showsCursor: preferences[Prefs.recordingShowCursor], systemAudio: systemAudio,
                                            mono: configuration.mono)
    }

    // MARK: Running

    /// Shows the windows, starts the stream with the countdown, records until an ending, and returns the finished file;
    /// nil when it was deleted, cancelled during the countdown, or ended before anything was written. Throws when the
    /// stream or the writer couldn't start (a `RecordingStartError`, `VideoFileError.cannotConfigureWriter`) or a restart
    /// failed; nothing is kept then. Runs once.
    func run() async throws -> RecordingWriterResult? {
        guard !hasRun else { return nil }
        hasRun = true
        // On screen before the stream starts: ClearShot needs a window up to be among the applications it leaves out, and
        // the click overlay to be among the windows it keeps.
        chrome.show()
        showClickOverlay()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: preferences[Prefs.recordingKeepDisplayAwake] ? [.userInitiated, .idleDisplaySleepDisabled] : .userInitiated,
            reason: "Recording the screen")
        let observers = observeTheSystem()
        defer {
            observers.forEach { $0.center.removeObserver($0.token) }
            stopWatching()
            endFocus()
            closeMicrophone()
            stopHighlightingClicks()
            chrome.close()
            ProcessInfo.processInfo.endActivity(activity)
        }
        do {
            return try await record()
        } catch {
            removeFolder()
            throw error
        }
    }

    /// Stop: the bar, the Record hotkey, the status item, a notice, sleep, quit. During the countdown nothing has been
    /// recorded, so it ends there with nothing.
    func stop() {
        end(.stop(at: stream?.currentTime))
    }

    /// Pause or resume (the bar, the hotkey, the status item's Resume).
    func togglePause() {
        guard let stream, let writer, ending == nil, !isRestarting else { return }
        switch phase {
        case .recording:
            // Read just before the writer pauses, so no chunk starting after the pause slips in whole.
            guard let now = stream.currentTime else { return }
            writer.pause(at: now)
            timeline.pause(at: now)
            setStreamPaused(true)
            sounds.playRecordPause()
            setPhase(.paused)
        case .paused:
            guard let now = stream.currentTime else { return }
            writer.resume(at: now)
            timeline.resume(at: now)
            setStreamPaused(false)
            setPhase(.recording)
        default:
            return
        }
        showProgress()
    }

    /// Restart: asks first unless "Don't ask again" was ticked, then throws the take away and starts again at once.
    func requestRestart() {
        guard phase == .recording || phase == .paused, ending == nil, !isRestarting, !chrome.isAsking else { return }
        guard preferences[Prefs.confirmRestartRecording] else {
            restart()
            return
        }
        chrome.ask("Discard this recording and start a new one?", buttons: ["Restart", "Cancel"],
                   suppressible: true) { [weak self] button, suppress in
            guard let self, button == 0 else { return }
            if suppress { preferences[Prefs.confirmRestartRecording] = false }
            restart()
        }
    }

    /// Delete: asks first unless "Don't ask again" was ticked, then ends with nothing. During the countdown it just
    /// cancels it.
    func requestDelete() {
        guard ending == nil else { return }
        if isCountingDown {
            end(.delete)
            return
        }
        guard phase == .recording || phase == .paused, !chrome.isAsking else { return }
        guard preferences[Prefs.confirmDeleteRecording] else {
            end(.delete)
            return
        }
        chrome.ask("Are you sure you want to delete this recording?", buttons: ["Delete", "Cancel"],
                   suppressible: true) { [weak self] button, suppress in
            guard let self, button == 0 else { return }
            if suppress { preferences[Prefs.confirmDeleteRecording] = false }
            end(.delete)
        }
    }

    /// The Record hotkey during the countdown: the recording starts now.
    func skipCountdown() {
        if isCountingDown { countdown.finishNow() }
    }

    // MARK: Recording

    private func record() async throws -> RecordingWriterResult? {
        takeOverMicrophone()
        try makeWriterAndStream()
        setPhase(.countdown)
        showProgress()
        tellMicrophoneIssue()
        turnFocusOn()
        startMicrophone()

        // The stream starts during the countdown, so its start-up doesn't eat the first moment; a failed start ends the
        // countdown early.
        let starting = Task { await startStream() }
        var counted = true
        if configuration.countdown, ending == nil {
            isCountingDown = true
            counted = await countdown.run(seconds: Self.countdownSeconds, on: settings.display, preferences: preferences)
            isCountingDown = false
        }
        if let startError = await starting.value {
            await stream?.stop()
            await writer?.cancel()
            throw startError
        }
        // Cancelled (Esc, the countdown's Cancel, the bar's Stop or Delete) or ended during it (sleep, quit, a display
        // change, the stream): nothing was recorded.
        guard counted, ending == nil, let stream, let writer, let start = stream.currentTime else {
            if case .streamStopped = ending { aftermath = .stoppedEmpty }
            await stream?.stop()
            await writer?.cancel()
            removeFolder()
            return nil
        }

        writer.start(at: start)
        timeline.begin(at: start)
        setPhase(.recording)
        sounds.playRecordStart()
        showProgress()
        chrome.showStopHintTheFirstTime()
        chrome.startTicking { [weak self] in self?.elapsedSeconds ?? 0 }
        startWatching()
        let how = await waitForEnding()
        stopWatching()
        stopHighlightingClicks()
        chrome.stopTicking()
        chrome.closeNotice()

        switch how {
        case .stop(let requested):
            return await finish(at: RecordingStopTime.make(streamEnded: false, clock: requested ?? stream.currentTime,
                                                           lastStreamSample: nil, lastMicrophoneSample: nil))
        case .diskFull(let requested):
            aftermath = .diskFull
            return await finish(at: RecordingStopTime.make(streamEnded: false, clock: requested ?? stream.currentTime,
                                                           lastStreamSample: nil, lastMicrophoneSample: nil))
        case let .streamStopped(reason, lastSampleTime):
            Log.recording.info("The stream stopped by itself (\(reason)); keeping what was written")
            let result = await finish(at: RecordingStopTime.make(streamEnded: true, clock: stream.currentTime,
                                                                 lastStreamSample: lastSampleTime,
                                                                 lastMicrophoneSample: microphoneTimes.value))
            aftermath = reason == .insufficientStorage ? .diskFull : result == nil ? .stoppedEmpty : .stoppedWithFrames
            return result
        case .writerFailed:
            let result = await finish(at: stream.currentTime)
            aftermath = result == nil ? .stoppedEmpty : .stoppedWithFrames
            return result
        case .delete:
            await stream.stop()
            await writer.cancel()
            removeFolder()
            return nil
        case .restartFailed(let error):
            await stream.stop()
            await writer.cancel()
            throw error
        }
    }

    /// A writer for `writerConfiguration` and a stream for `settings` that delivers on its queue, with the microphone
    /// forwarding into it. Throws `VideoFileError.cannotConfigureWriter`.
    private func makeWriterAndStream() throws {
        // A microphone disconnected during the countdown has no track in a writer made after it.
        if microphoneEnded { writerConfiguration.microphone = nil }
        let writer = try RecordingWriter(configuration: writerConfiguration)
        writer.onFailure = Self.failures(reportedTo: self)
        let rules = RecordingContentRules(ownBundleID: CSCore.bundleIdentifier, keptOwnWindowIDs: keptWindowIDs,
                                          exclusion: configuration.exclusion)
        let stream = ScreenRecordingStream(settings: settings, rules: rules, sampleQueue: writer.queue,
                                           onOutput: Self.forwarding(to: writer), onStop: Self.stops(reportedTo: self))
        self.writer = writer
        self.stream = stream
        if let microphone, !microphoneEnded {
            // Dropped until the stream has started, and by the writer until the recording has.
            microphone.forward(to: Self.microphoneForwarding(to: writer, newest: microphoneTimes), clockOf: stream)
        }
    }

    /// Starts the stream during the countdown; nil once it runs, else the error that stopped it, having ended the
    /// countdown. When system audio fails to start (−3818), which fails the whole stream, the recording goes on without
    /// it: a new writer without its track, a new stream without audio, and the information notice.
    private func startStream() async -> (any Error)? {
        guard let stream else { return nil }
        do {
            try await stream.start()
            return nil
        } catch RecordingStartError.audioFailed where settings.capturesSystemAudio {
            Log.recording.error("System audio didn't start; recording without it")
        } catch {
            countdown.finishNow()
            return error
        }
        do {
            // Stopped first, so a late stop ScreenCaptureKit may still report for the failed start is dropped, never taken
            // for the new stream's.
            await stream.stop()
            await writer?.cancel()
            settings = Self.streamSettings(configuration, preferences: preferences, systemAudio: false)
            writerConfiguration.systemAudio = nil
            journal.systemAudio = false
            writeJournal()
            try makeWriterAndStream()
            try await self.stream?.start()
        } catch {
            countdown.finishNow()
            return error
        }
        let warning = RecordingWarning.systemAudioFailed
        chrome.tell(warning.title, message: warning.message)
        return nil
    }

    /// Stops the stream, then finishes the file at `stopTime`, read before the stream stopped (its clock goes with it).
    /// A failed writer's file is finalized as recovery would (never cancelled, which would delete it).
    private func finish(at stopTime: CMTime?) async -> RecordingWriterResult? {
        guard let stream, let writer else { return nil }
        sounds.playRecordStop()
        setPhase(.finishing)
        showProgress()
        // First: in real-time mode the stop's frame may wait on the writer's queue, which the stream delivers on.
        await stream.stop()
        do {
            let result = try await writer.finish(at: stopTime ?? timeline.start ?? .zero)
            markFinishing()
            return result
        } catch let error as VideoFileError where error == .noVideoTrack {
            Log.recording.info("Nothing was written; removing the recording")
            removeFolder()
            return nil
        } catch {
            Log.recording.error("The recording's writer failed: \(error.localizedDescription); finalizing what was written")
            return await finalizeFailedTake(statistics: writer.statistics)
        }
    }

    /// The failed take's file up to its last whole fragment, as a launch would recover it, beside it in the folder. When
    /// even that can't be read, the folder stays for the next launch (which keeps it a day) and nothing is returned.
    private func finalizeFailedTake(statistics: RecordingStatistics) async -> RecordingWriterResult? {
        let folder = configuration.folder
        let destination = folder.url.appending(path: RecordingRecovery.recoveredFileName)
        do {
            let duration = try await RecoveryExporter.finalize(folder.movieURL, to: destination)
            let audioTracks = (try? await VideoThumbnail.info(of: destination))?.audioChannelCounts.count ?? 0
            // The writer's tracks are system audio first, then the microphone.
            let hasSystemAudio = writerConfiguration.systemAudio != nil && audioTracks > 0
            let hasMicrophone = writerConfiguration.microphone != nil && audioTracks > (hasSystemAudio ? 1 : 0)
            markFinishing()
            return RecordingWriterResult(fileURL: destination, duration: duration, hasSystemAudio: hasSystemAudio,
                                         hasMicrophone: hasMicrophone, statistics: statistics)
        } catch {
            Log.recording.error("Couldn't finalize the failed recording: \(error.localizedDescription)")
            return nil
        }
    }

    /// Throws the take away and starts again at once, unpaused, the time back at zero (no countdown). The microphone
    /// keeps forwarding into the same writer. The new take is a recording of its own: "Microphone is muted" can be said
    /// again, and it starts now, which the journal records (`startedAt` names the file and dates the history item).
    private func restart() {
        guard let stream, let writer, phase == .recording || phase == .paused, ending == nil, !isRestarting,
              let now = stream.currentTime else { return }
        isRestarting = true
        if phase == .paused { setStreamPaused(false) }
        timeline.begin(at: now)
        toldMuted = false
        silence = SilenceDetector()
        journal.startedAt = Date()
        writeJournal()
        setPhase(.recording)
        showProgress()
        Task {
            do {
                try await writer.restart(at: now)
            } catch {
                Log.recording.error("Couldn't restart the recording: \(error.localizedDescription)")
                end(.restartFailed(error))
            }
            isRestarting = false
        }
    }

    /// A frame a second while paused, the plan's rate otherwise. Each change waits for the one before, so a quick pause
    /// and resume end at the resume's rate.
    private func setStreamPaused(_ paused: Bool) {
        guard let stream else { return }
        let previous = rateChange
        rateChange = Task {
            await previous?.value
            await stream.setPaused(paused)
        }
    }

    /// The journal says the file is complete, so a crash before routing recovers it.
    private func markFinishing() {
        journal.state = .finishing
        writeJournal()
    }

    /// The journal says there is no microphone track: the microphone went before the writer was made.
    func markNoMicrophone() {
        journal.microphone = false
        writeJournal()
    }

    /// Writes the journal, saying whether Focus is on because of this recording.
    func writeJournal() {
        journal.focusTurnedOn = focusState.journalSaysOn
        do {
            try configuration.folders.write(journal, to: configuration.folder)
        } catch {
            Log.recording.error("Couldn't update the recording's journal: \(error.localizedDescription)")
        }
    }

    private func removeFolder() {
        configuration.folders.remove(configuration.folder.url)
    }

    // MARK: Do Not Disturb

    /// "ClearShot Focus On" during the countdown, off the main actor, never waited for: the recording doesn't depend on it.
    private func turnFocusOn() {
        guard let focus = configuration.focus, focusState.beginTurningOn() else { return }
        Task {
            let ran = await focus.turnOn()
            switch focusState.turnOnFinished(succeeded: ran) {
            case .recordInJournal: writeJournal()
            case .turnOff: focus.turnOffInBackground()
            case .none: break
            }
        }
    }

    /// "ClearShot Focus Off" on every ending, once, when On ran (`FocusSessionState`); nothing waits for it but a quit.
    func endFocus() {
        guard let focus = configuration.focus, focusState.sessionEnded() else { return }
        focus.turnOffInBackground()
    }

    // MARK: The bar, the phase and the time

    private func barAction(_ action: RecordingControlBar.Action) {
        switch action {
        case .stop: stop()
        case .pauseResume: togglePause()
        case .restart: requestRestart()
        case .delete: requestDelete()
        }
    }

    private func setPhase(_ phase: RecordingControlState.Phase) {
        guard phase != self.phase else { return }
        self.phase = phase
        highlightClicks(in: phase)
        onPhaseChange?(phase)
    }

    /// The recording's length now, pauses left out; zero before it starts.
    private var elapsedSeconds: Double {
        guard let now = stream?.currentTime else { return 0 }
        return timeline.elapsed(at: now).seconds
    }

    /// The phase and the time, on the bar, the frame and the status item.
    private func showProgress() {
        chrome.update(phase: phase, elapsed: elapsedSeconds)
    }
}
