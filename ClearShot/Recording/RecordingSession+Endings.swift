import AppKit
import CoreMedia
import CSCapture
import CSCore
import CSRecording
import Synchronization

/// What ends a recording, and what warns during one: sleep and display changes, the stream's and the writer's own
/// failures, a disk that fills (polled every 5 s off the main actor), the microphone, muted at the start, silent for 5
/// s, disconnected or unusable with the lid closed, and system audio that stops coming (logged only). Every warning is
/// an in-panel notice (`RecordingChrome.ask`), never an alert: nothing modal runs while recording.
extension RecordingSession {
    /// How often the disk's free space is read while recording.
    static let diskPollInterval = Duration.seconds(5)
    /// How often the bar's meter reads the microphone; every third reading also goes to the silence watch, at 4 Hz.
    static let meterInterval = Duration.milliseconds(250) / 3
    private static let silenceEvery = 3
    private static let silenceSeconds = 0.25

    // MARK: Endings

    func end(_ how: Ending) {
        guard ending == nil else { return }
        ending = how
        // Off as soon as the ending is decided, so the journal written as the file finishes no longer says Focus is on.
        endFocus()
        if isCountingDown { countdown.finishNow() }
        endingContinuation?.resume(returning: how)
        endingContinuation = nil
    }

    func waitForEnding() async -> Ending {
        if let ending { return ending }
        return await withCheckedContinuation { endingContinuation = $0 }
    }

    /// Sleep stops the recording; a display connected, unplugged, moved or rescaled stops it once frames are in,
    /// otherwise deletes it without asking (the frame and the stream no longer match the screen). Notifications that
    /// change no display are ignored.
    func observeTheSystem() -> [(center: NotificationCenter, token: any NSObjectProtocol)] {
        let workspace = NSWorkspace.shared.notificationCenter
        let sleep = workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.recording.info("The Mac is going to sleep; stopping the recording")
                self?.stop()
            }
        }
        let screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        return [(workspace, sleep), (NotificationCenter.default, screens)]
    }

    private func screensChanged() {
        guard ending == nil, DisplayLayout.current() != configuration.layout else { return }
        let written = (writer?.statistics.appendedFrames ?? 0) > 0 && !isCountingDown
        Log.recording.info("The displays changed during a recording; \(written ? "stopping" : "deleting") it")
        if written { stop() } else { end(.delete) }
    }

    /// ScreenCaptureKit ended the stream (system audio failing mid-recording included): what was written is kept, up to
    /// its last sample.
    private func streamEnded(_ reason: RecordingStreamStop, lastSampleTime: CMTime?) {
        end(.streamStopped(reason, lastSampleTime: lastSampleTime))
    }

    private func writerFailed(_ error: any Error) {
        Log.recording.error("The recording's writer failed: \(error.localizedDescription)")
        end(.writerFailed)
    }

    // MARK: Watching while recording

    /// Once the frame is up, at the countdown: why the chosen microphone doesn't record (`MicrophoneStartIssue`). The lid
    /// asks whether to go on (Stop stops, which during the countdown records nothing); the rest is information.
    func tellMicrophoneIssue() {
        guard let issue = microphoneIssue else { return }
        Log.recording.info("Recording without the chosen microphone: \(issue.reason)")
        guard issue == .lidClosed else {
            chrome.tell(issue.title, message: issue.message)
            return
        }
        chrome.ask(issue.title, message: issue.message, buttons: issue.buttons, suppressible: false) { [weak self] button, _ in
            if button == 1 { self?.stop() }
        }
    }

    /// From the start of the recording: the disk poll, the system audio watch, the microphone's meter and silence watch,
    /// and whether the microphone is muted as it starts.
    func startWatching() {
        watchDisk()
        watchSystemAudio()
        guard let device = configuration.microphone?.device, !microphoneEnded else { return }
        watchMicrophone()
        Task {
            if await Self.isMuted(device.id) == true {
                Log.recording.info("The microphone \(device.name) is muted as the recording starts")
                tellMuted()
            }
        }
    }

    func stopWatching() {
        diskWatch?.cancel()
        diskWatch = nil
        microphoneWatch?.cancel()
        microphoneWatch = nil
        systemAudioWatch?.cancel()
        systemAudioWatch = nil
    }

    /// Every 5 s: below `DiskSpaceRule.stopBelow` free, the recording stops and keeps what was written, and the
    /// `.diskFull` alert follows once its windows have gone (`Aftermath.diskFull`).
    private func watchDisk() {
        let root = configuration.folders.root
        diskWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.diskPollInterval)
                guard !Task.isCancelled, let available = await Self.freeSpace(at: root),
                      DiskSpaceRule.stopsRecording(available: available) else { continue }
                guard let self else { return }
                Log.recording.error("Only \(available) bytes free; stopping the recording")
                end(.diskFull(at: stream?.currentTime))
                return
            }
        }
    }

    /// System audio that stops arriving for 3 s while recording (not paused) is only logged, once per stretch: whether
    /// ScreenCaptureKit sends silence while nothing plays has to be checked by hand.
    private func watchSystemAudio() {
        guard capturesSystemAudio else { return }
        systemAudioWatch = Task { [weak self] in
            var lastChunks = -1
            var quietSince = ContinuousClock.now
            var logged = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let writer else { return }
                let chunks = writer.statistics.systemAudioChunks
                if chunks != lastChunks || phase != .recording {
                    if logged, chunks != lastChunks { Log.recording.info("System audio is arriving again") }
                    lastChunks = chunks
                    quietSince = .now
                    logged = false
                } else if !logged, ContinuousClock.now - quietSince >= .seconds(3) {
                    logged = true
                    Log.recording.warning("No system audio for 3 s (\(chunks) chunks so far)")
                }
            }
        }
    }

    /// The bar's meter, and 5 s below −60 dBFS while recording (not paused) says the microphone may be muted.
    private func watchMicrophone() {
        guard let microphone else { return }
        chrome.updateMeter(0)
        microphoneWatch = Task { [weak self] in
            var reading = 0
            while !Task.isCancelled {
                guard let self, !microphoneEnded else { return }
                let decibels = microphone.levelDecibels
                chrome.updateMeter(AudioLevel.meterLevel(decibels: decibels))
                reading += 1
                if reading % Self.silenceEvery == 0, phase == .recording,
                   silence.add(levelDecibels: decibels, seconds: Self.silenceSeconds) {
                    Log.recording.info("The microphone has been silent for 5 s")
                    tellMuted()
                }
                try? await Task.sleep(for: Self.meterInterval)
            }
        }
    }

    /// "Microphone is muted": Continue keeps recording, Stop stops. Once per recording.
    private func tellMuted() {
        guard !toldMuted, ending == nil, !microphoneEnded else { return }
        toldMuted = true
        let warning = RecordingWarning.microphoneMuted
        chrome.ask(warning.title, message: warning.message, buttons: warning.buttons, suppressible: false) { [weak self] button, _ in
            if button == 1 { self?.stop() }
        }
    }

    /// The microphone went away (unplugged, a session error, or it wouldn't start): its track ends there and the screen
    /// keeps recording, unless the person chooses Stop.
    func microphoneDisconnected() {
        guard let microphone, ending == nil, microphoneState.disconnected() else { return }
        microphone.forward(to: nil, clockOf: nil)
        writer?.endMicrophoneTrack()
        chrome.updateMeter(nil)
        let warning = RecordingWarning.microphoneDisconnected
        chrome.ask(warning.title, message: warning.message, buttons: warning.buttons, suppressible: false) { [weak self] button, _ in
            if button == 1 { self?.stop() }
        }
    }

    /// Whether the input is muted (Core Audio), off the main actor.
    @concurrent
    private nonisolated static func isMuted(_ deviceID: String) async -> Bool? {
        SystemProbes.isInputMuted(deviceID: deviceID)
    }

    // MARK: Handlers (made outside the main actor; they run on the writer's, the microphone's and ScreenCaptureKit's queues)

    /// Samples go straight to the writer on its queue, where the stream delivers them.
    nonisolated static func forwarding(to writer: RecordingWriter) -> @Sendable (RecordingStreamOutput) -> Void {
        { output in
            switch output {
            case let .frame(frame, presentationTime): writer.appendVideo(frame, at: presentationTime)
            case let .systemAudio(chunk): writer.appendSystemAudio(chunk)
            }
        }
    }

    /// The microphone delivers on its own queue: each chunk hops onto the writer's, noting its time on the way.
    nonisolated static func microphoneForwarding(to writer: RecordingWriter, newest: NewestTime)
        -> @Sendable (CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) -> Void {
        { chunk in
            newest.note(chunk.presentationTimeStamp)
            writer.queue.async { writer.appendMicrophone(chunk) }
        }
    }

    /// The stream's own stop, on the main actor. It runs under the stream's lock, so it only hops.
    nonisolated static func stops(reportedTo session: RecordingSession) -> @Sendable (RecordingStreamStop, CMTime?) -> Void {
        { [weak session] reason, lastSampleTime in
            guard let session else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { session.streamEnded(reason, lastSampleTime: lastSampleTime) }
            }
        }
    }

    /// The writer's failure, which arrives on its queue, on the main actor.
    nonisolated static func failures(reportedTo session: RecordingSession) -> @Sendable (any Error) -> Void {
        { [weak session] error in
            guard let session else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { session.writerFailed(error) }
            }
        }
    }

    /// The microphone's disconnection, from any thread, on the main actor.
    nonisolated static func disconnects(reportedTo session: RecordingSession) -> @Sendable () -> Void {
        { [weak session] in
            guard let session else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { session.microphoneDisconnected() }
            }
        }
    }
}

/// The newest time noted, from any thread: the latest microphone chunk forwarded to the writer.
nonisolated final class NewestTime: Sendable {
    private let time = Mutex<CMTime?>(nil)

    init() {}

    func note(_ new: CMTime) {
        time.withLock { time in
            if new.isNumeric, time.map({ new > $0 }) ?? true { time = new }
        }
    }

    var value: CMTime? {
        time.withLock { $0 }
    }
}
