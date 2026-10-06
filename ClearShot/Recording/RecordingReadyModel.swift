import AVFoundation
import CoreGraphics
import CSCapture
import CSCore
import CSRecording

/// Ready's state for one recording: where it starts, what Return records (a video or a GIF, the mode used last), the
/// microphone with its warm session and meter, system audio, Highlight Clicks, the ratio, Toggle fullscreen, and the
/// message the toolbar's slot shows. The overlay draws from it and redraws when it changes (`onChange`); the meter
/// reports on its own (`onMeterLevel`), many times a second.
///
/// The microphone permission is never asked for while Ready, the countdown or a recording is on screen, where the
/// system's prompt could open under the overlay or be recorded: a device chosen without it is asked for once nothing
/// records (`MicrophonePermissionTiming`), and the next recording uses it. Devices plugged in or out while Ready is up
/// update its list; the chosen one going away is remembered, so the recording says why it has no microphone
/// (`MicrophoneChoice.startIssue`).
final class RecordingReadyModel {
    static let microphoneDeniedWarning = MicrophoneStartIssue.noAccess.reason
    /// How often the meter reads the microphone's level.
    static let meterInterval = Duration.milliseconds(80)

    private let preferences: Preferences
    private let permissions: PermissionCenter
    /// All-In-One's selection as R was pressed, with the keys held as it was dragged out; nil to start from the
    /// remembered area, or in Select.
    private let initial: (rect: CGRect, display: DisplayInfo, startModifiers: SelectionModifiers)?
    /// The encoder plan for recording a target in a mode: its frame-rate note (`EncoderPlan.readyNote`) and, with the
    /// audio, the rate the low-disk warning estimates.
    private let plan: (RecordingPick.Target, RecordingMode) -> EncoderPlan

    /// The audio inputs (discovery only: no permission, no prompt), listed again as devices come and go.
    private(set) var devices: [MicrophoneDeviceInfo]
    /// The MacBook's lid was closed as Ready opened: the built-in microphone can't record.
    let lidClosed: Bool

    /// The warm session of the selected microphone, which the meter reads and the recording takes over.
    private var microphone: MicrophoneCapture?
    private var meter: Task<Void, Never>?
    /// Counts microphone picks, so a start or a disconnection that comes after a newer pick is ignored.
    private var pick = 0
    /// The last pick of a device was refused the microphone permission.
    private var permissionDenied = false
    /// The chosen device's session couldn't be opened or started.
    private(set) var openFailed = false
    /// Devices plugged in and out, while Ready is up.
    private var deviceObservers: [any NSObjectProtocol] = []
    /// When the deferred microphone request may be made: once, when nothing records.
    private var permissionTiming = MicrophonePermissionTiming()

    /// The chosen device went away (or its session failed) while Ready was up, and hasn't come back.
    private(set) var lostMicrophone = false

    /// What Return and the Record hotkey record: the mode used last.
    var mode: RecordingMode {
        didSet { if mode != oldValue { onChange?() } }
    }

    /// Told when anything Ready shows changes, so the overlay redraws.
    var onChange: (() -> Void)?

    /// Told with the meter's level, 0…1, while the selected microphone's session runs.
    var onMeterLevel: ((Double) -> Void)?

    /// The meter's latest level, 0…1; nil while no microphone session runs (the toolbar shows no meter then).
    private(set) var meterLevel: Double? {
        didSet { if (meterLevel == nil) != (oldValue == nil) { onChange?() } }
    }

    /// Whether there is a selection to record (Ready) rather than none (Select), as the overlay last drew it.
    var isReady = false {
        didSet { if isReady != oldValue { onReadyChange?(isReady) } }
    }

    /// Told each time `isReady` changes.
    var onReadyChange: ((Bool) -> Void)?

    /// The gear was pressed: once the overlay has closed, Settings opens at Screen Recording.
    var opensSettings = false

    /// Toggle fullscreen, with the selection it replaced (as All-In-One's).
    var fullscreen = FullscreenToggle()

    /// The free bytes where recordings are written, read off the main actor as Ready opens; nil until then, or when
    /// unknown.
    var availableBytes: Int64? {
        didSet { if availableBytes != oldValue { onChange?() } }
    }

    init(preferences: Preferences, permissions: PermissionCenter,
         initial: (rect: CGRect, display: DisplayInfo, startModifiers: SelectionModifiers)?,
         plan: @escaping (RecordingPick.Target, RecordingMode) -> EncoderPlan) {
        self.preferences = preferences
        self.permissions = permissions
        self.initial = initial
        self.plan = plan
        devices = MicrophoneDevices.list()
        lidClosed = SystemProbes.isLidClosed() ?? false
        mode = preferences[Prefs.recordingLastMode]
        watchDevices()
    }

    /// The ratio the selection keeps, remembered for the next recording.
    var ratio: SelectionRatio {
        get { preferences[Prefs.recordingRatio] }
        set {
            guard newValue != ratio else { return }
            preferences[Prefs.recordingRatio] = newValue
            onChange?()
        }
    }

    /// Record System Audio.
    var systemAudio: Bool {
        get { preferences[Prefs.recordingSystemAudio] }
        set {
            guard newValue != systemAudio else { return }
            preferences[Prefs.recordingSystemAudio] = newValue
            onChange?()
        }
    }

    /// Highlight Clicks: the setting Settings › Screen Recording shows too.
    var highlightClicks: Bool {
        get { preferences[Prefs.recordingHighlightClicks] }
        set {
            guard newValue != highlightClicks else { return }
            preferences[Prefs.recordingHighlightClicks] = newValue
            onChange?()
        }
    }

    /// The microphone chosen: a device's unique ID, or "" for Do Not Record Microphone.
    var microphoneID: String {
        preferences[Prefs.recordingMicrophoneID]
    }

    /// The device a recording would use now: the chosen one, when it is connected and usable (`MicrophoneChoice.usable`).
    var microphoneDevice: MicrophoneDeviceInfo? {
        MicrophoneChoice.usable(savedID: microphoneID, devices: devices, lidClosed: lidClosed)
    }

    /// Where Ready starts: All-In-One's selection while its display is connected; else, with "Remember last selection",
    /// the last area recorded, still on its display (`SavedArea.resolved`); else nowhere (Select).
    func startingSelection(in layout: DisplayLayout)
        -> (rect: CGRect, display: DisplayInfo, startModifiers: SelectionModifiers)? {
        if let initial, layout.display(id: initial.display.id) != nil { return initial }
        guard preferences[Prefs.recordingRememberSelection],
              case let (rect, display)? = preferences[Prefs.recordingLastArea].resolved(in: layout) else { return nil }
        return (rect, display, [])
    }

    /// The message slot for recording `target` in the mode Return records: a warning first (for a video, why the chosen
    /// microphone won't record: the lid, the permission, a device that went away or wouldn't open; then low disk), else
    /// the encoder's note when it can't keep up with the frame rate; nil for none. A GIF records no audio.
    func message(for target: RecordingPick.Target) -> (text: String, isWarning: Bool)? {
        let recordsAudio = mode == .video
        if recordsAudio, permissionDenied {
            return (Self.microphoneDeniedWarning, true)
        }
        // While a session is still opening it counts as open; only a failed one says so.
        if recordsAudio,
           let issue = MicrophoneChoice.startIssue(savedID: microphoneID, devices: devices, lidClosed: lidClosed,
                                                   permission: permissions.status(of: .microphone),
                                                   session: openFailed ? .failed : .open, lostInReady: lostMicrophone) {
            return (issue.reason, true)
        }
        let plan = plan(target, mode)
        if let availableBytes {
            let audio = RecordingSession.audioTracks(systemAudio: recordsAudio && systemAudio,
                                                     mono: preferences[Prefs.recordingMono],
                                                     microphone: recordsAudio && microphoneDevice != nil)
            let bits = plan.averageBitRate + (audio.system?.bitRate ?? 0) + (audio.microphone?.bitRate ?? 0)
            if DiskSpaceRule.warnsBeforeRecording(available: availableBytes, plannedBitsPerSecond: bits) {
                return (RecordingWarning.lowDiskBefore.title, true)
            }
        }
        return plan.readyNote.map { ($0, false) }
    }

    // MARK: The microphone

    /// A pick from the microphone list: a device's unique ID, or "" for Do Not Record Microphone. The meter follows it.
    func chooseMicrophone(_ id: String) {
        // The one already metering stays as it is.
        if id == microphoneID, microphone != nil { return }
        permissionDenied = false
        lostMicrophone = false
        preferences[Prefs.recordingMicrophoneID] = id
        onChange?()
        startMeter()
    }

    /// Opens the chosen microphone and runs the meter on it, while it is usable and the permission is granted. A refused
    /// permission puts the choice back to Do Not Record Microphone with a warning; an unanswered one is asked for once
    /// nothing records (`askForMicrophoneIfNeeded`).
    func startMeter() {
        stopMeter()
        openFailed = false
        let pick = self.pick
        guard let device = microphoneDevice else { return }
        switch permissions.status(of: .microphone) {
        case .granted: open(device, pick: pick)
        case .notDetermined: onChange?()
        case .denied: refuse()
        }
    }

    /// Stops the meter and closes the microphone: Ready closed without recording, or with a recording that takes none.
    func stopMeter() {
        // A start or a disconnection still on its way no longer meters or reports anything.
        pick += 1
        meter?.cancel()
        meter = nil
        meterLevel = nil
        if let microphone {
            self.microphone = nil
            microphone.onDisconnect = nil
            Task { await microphone.stop() }
        }
    }

    /// The warm session of the chosen microphone, for the recording to take over without a gap; nil when there is none
    /// (Do Not Record, an unusable, unanswered or refused device, one that wouldn't open). The meter stops; the session
    /// keeps running.
    func takeMicrophone() -> MicrophoneCapture? {
        guard microphoneDevice != nil, !openFailed, let microphone else {
            stopMeter()
            return nil
        }
        pick += 1
        meter?.cancel()
        meter = nil
        meterLevel = nil
        self.microphone = nil
        microphone.onDisconnect = nil
        return microphone
    }

    /// Ready has closed, however: devices are no longer watched.
    func readyClosed() {
        deviceObservers.forEach(NotificationCenter.default.removeObserver)
        deviceObservers = []
        permissionTiming.readyClosed()
    }

    /// The countdown is about to start: the deferred request waits for the recording to end.
    func recordingStarts() {
        permissionTiming.recordingStarts()
    }

    /// The recording's windows have closed and its stream has stopped: the deferred request may be made now.
    func recordingEnded(quitting: Bool) {
        permissionTiming.recordingEnded()
        askForMicrophoneIfNeeded(quitting: quitting)
    }

    /// A device chosen without the microphone permission gets the system's prompt, once, when nothing records: as Ready
    /// closes without a recording, or once the recording has ended; never during the countdown or the recording, whose
    /// stream would capture it (`MicrophonePermissionTiming`). Not while quitting. The next recording uses the answer.
    func askForMicrophoneIfNeeded(quitting: Bool) {
        let needed = microphoneDevice != nil && permissions.status(of: .microphone) == .notDetermined
        guard permissionTiming.shouldAsk(needed: needed, quitting: quitting) else { return }
        Log.recording.info("Asking for the microphone permission now that nothing records")
        Task { [permissions] in await permissions.request(.microphone) }
    }

    private func open(_ device: MicrophoneDeviceInfo, pick: Int) {
        let microphone: MicrophoneCapture
        do {
            microphone = try MicrophoneCapture(deviceID: device.id)
        } catch {
            Log.recording.error("Couldn't open the microphone \(device.name): \(error)")
            openFailed = true
            onChange?()
            return
        }
        self.microphone = microphone
        microphone.onDisconnect = Self.disconnects(reportedTo: self, pick: pick)
        Task {
            do {
                try await microphone.start()
            } catch {
                Log.recording.error("The microphone \(device.name) didn't start: \(error)")
                guard pick == self.pick else { return }
                openFailed = true
                onChange?()
                return
            }
            guard pick == self.pick, self.microphone === microphone else { return }
            lostMicrophone = false
            runMeter(on: microphone)
        }
    }

    private func runMeter(on microphone: MicrophoneCapture) {
        meterLevel = 0
        meter = Task { [weak self] in
            while !Task.isCancelled {
                let level = AudioLevel.meterLevel(decibels: microphone.levelDecibels)
                guard let self else { return }
                meterLevel = level
                onMeterLevel?(level)
                try? await Task.sleep(for: Self.meterInterval)
            }
        }
    }

    private func refuse() {
        Log.recording.info("No microphone permission; recording without the microphone")
        preferences[Prefs.recordingMicrophoneID] = ""
        permissionDenied = true
        onChange?()
    }

    // MARK: Devices coming and going

    /// The list follows devices plugged in and out; the chosen one plugged back in opens again.
    private func watchDevices() {
        let center = NotificationCenter.default
        deviceObservers = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.devicesChanged() }
            }
        }
    }

    private func devicesChanged() {
        devices = MicrophoneDevices.list()
        if microphone == nil, !openFailed || lostMicrophone, microphoneDevice != nil {
            startMeter()
        }
        onChange?()
    }

    /// The chosen device's session reported a disconnection (or a failure) while Ready is up.
    private func microphoneLost(pick: Int) {
        guard pick == self.pick, microphone != nil else { return }
        Log.recording.info("The chosen microphone went away while Ready was up")
        stopMeter()
        lostMicrophone = true
        devices = MicrophoneDevices.list()
        onChange?()
    }

    /// The warm session's disconnection, from any thread, on the main actor.
    private nonisolated static func disconnects(reportedTo model: RecordingReadyModel, pick: Int) -> @Sendable () -> Void {
        { [weak model] in
            guard let model else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model.microphoneLost(pick: pick) }
            }
        }
    }
}
