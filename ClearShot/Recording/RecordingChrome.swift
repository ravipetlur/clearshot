import AppKit
import CSCore
import CSRecording

/// What a recording shows around itself while it runs: the frame over the recorded display (dimming the region too
/// while paused, with the option), the control bar in it with the microphone's meter, notices beside the bar (questions
/// at once, information one after another), the menu bar icon as the Stop button with the time, the first-time "Press
/// to stop recording", and the tick that keeps the bar's and the icon's time current. The session decides what happens;
/// this only shows it.
final class RecordingChrome {
    private let preferences: Preferences
    private weak var statusItem: StatusItemController?
    private let display: DisplayInfo
    private let region: CGRect
    private let frameWindow: RegionFrameWindow
    private lazy var controlBar = RecordingControlBar { [weak self] action in self?.onAction?(action) }
    private var phase = RecordingControlState.Phase.none
    private var ticker: Task<Void, Never>?
    /// Information notices (`tell`): the one on screen, and those waiting for the notice shown to go.
    private var shownInformation: (title: String, message: String?)?
    private var waitingInformation: [(title: String, message: String?)] = []

    /// The bar's buttons.
    var onAction: ((RecordingControlBar.Action) -> Void)?

    /// `region` is what is recorded, AppKit global points on `display`; an area gets the 1 pt frame, a whole display
    /// none.
    init(display: DisplayInfo, region: CGRect, isArea: Bool, preferences: Preferences, statusItem: StatusItemController?) {
        self.preferences = preferences
        self.statusItem = statusItem
        self.display = display
        self.region = region
        frameWindow = RegionFrameWindow(display: display, region: region, dims: preferences[Prefs.recordingDimScreen],
                                        drawsFrame: isArea)
    }

    /// The frame, then the bar ("Show controls while recording"). Before the stream starts: ClearShot needs a window
    /// up to be among the applications it leaves out.
    func show() {
        frameWindow.orderFrontRegardless()
        if preferences[Prefs.recordingShowControls] {
            controlBar.show(attachedTo: frameWindow, region: region, position: preferences[Prefs.recordingControlsPosition],
                            visibleFrame: display.visibleFrame)
        }
    }

    /// Everything goes, and the icon is the menu again.
    func close() {
        stopTicking()
        closeNotice()
        StopRecordingHint.close()
        controlBar.hide()
        frameWindow.orderOut(nil)
        statusItem?.apply(.make(phase: .none, elapsed: 0, showsTime: false, conversionProgress: nil))
    }

    /// The bar's time and buttons, the region's dimming while paused, and the icon, for `phase` and `elapsed` seconds.
    func update(phase: RecordingControlState.Phase, elapsed: Double) {
        self.phase = phase
        let state: RecordingControlBar.State = switch phase {
        case .recording: .recording
        case .paused: .paused
        case .finishing: .finishing
        default: .countdown
        }
        controlBar.update(state: state, elapsed: elapsed)
        // Dimmed as it pauses, undimmed as it records again (a stop while paused stays dimmed until the frame goes).
        switch phase {
        case .paused: frameWindow.dimsRegion = preferences[Prefs.recordingDimScreen]
        case .recording: frameWindow.dimsRegion = false
        default: break
        }
        statusItem?.apply(.make(phase: phase, elapsed: elapsed, showsTime: preferences[Prefs.recordingShowTimeInMenuBar],
                                conversionProgress: nil))
    }

    /// Once a second, just after the time turns over to the next second, in the phase last shown.
    func startTicking(elapsed: @escaping () -> Double) {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let seconds = elapsed()
                update(phase: phase, elapsed: seconds)
                let wait = phase == .paused ? 1 : 1.02 - seconds.truncatingRemainder(dividingBy: 1)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    /// The microphone's meter on the bar, 0…1; nil takes it off.
    func updateMeter(_ level: Double?) {
        controlBar.updateMeter(level)
    }

    /// "Press to stop recording" under the icon, the first recording ever. The icon has just become the Stop button,
    /// maybe just appeared: the menu bar lays it out first.
    func showStopHintTheFirstTime() {
        guard !preferences[Prefs.stopRecordingHintShown] else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, phase == .recording, let button = statusItem?.buttonScreenFrame else { return }
            preferences[Prefs.stopRecordingHintShown] = true
            StopRecordingHint.show(below: button)
        }
    }

    // MARK: Notices

    /// A question is up (a notice with choices; information only doesn't count).
    var isAsking: Bool {
        RecordingNoticePanel.isShown && shownInformation == nil
    }

    /// Asks in the frame, under the bar, or the region without one (`RecordingNoticePanel`). A question replaces the
    /// notice shown; information it replaces comes back once it is answered.
    func ask(_ title: String, message: String? = nil, buttons: [String], suppressible: Bool,
             completion: @escaping (_ button: Int, _ suppress: Bool) -> Void) {
        if let shownInformation {
            waitingInformation.insert(shownInformation, at: 0)
            self.shownInformation = nil
        }
        present(title, message: message, buttons: buttons, suppressible: suppressible) { [weak self] button, suppress in
            completion(button, suppress)
            self?.showWaitingInformation()
        }
    }

    /// Information with an OK, one after another: shown now, or once the notice shown has been answered.
    func tell(_ title: String, message: String?) {
        waitingInformation.append((title, message))
        if !RecordingNoticePanel.isShown { showWaitingInformation() }
    }

    func closeNotice() {
        waitingInformation = []
        shownInformation = nil
        RecordingNoticePanel.close()
    }

    private func showWaitingInformation() {
        guard !RecordingNoticePanel.isShown, !waitingInformation.isEmpty else { return }
        let notice = waitingInformation.removeFirst()
        shownInformation = notice
        present(notice.title, message: notice.message, buttons: ["OK"], suppressible: false) { [weak self] _, _ in
            self?.shownInformation = nil
            self?.showWaitingInformation()
        }
    }

    private func present(_ title: String, message: String?, buttons: [String], suppressible: Bool,
                         completion: @escaping (_ button: Int, _ suppress: Bool) -> Void) {
        let bar = controlBar.frame
        RecordingNoticePanel.show(title, message: message, buttons: buttons, suppressible: suppressible,
                                  near: bar == .zero ? region : bar, attachedTo: frameWindow, completion: completion)
    }
}
