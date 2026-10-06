import AppKit
import CSCore
import CSRecording

/// A recording's control bar: Stop, the elapsed time, Pause or Resume, Restart and Delete, then the microphone's meter
/// while it records, on a selection toolbar that is never key, a child of the frame window, where "Controls position"
/// puts it (`RecordingControlsPlacement`). It never takes the keys, so Return and Esc go on to the app being recorded;
/// its buttons still take clicks.
final class RecordingControlBar {
    enum Action {
        case stop, pauseResume, restart, delete
    }

    /// What the buttons can do: during the countdown only Stop and Delete (both cancel it), nothing while finishing.
    enum State {
        case countdown, recording, paused, finishing
    }

    private enum ID {
        static let stop = "stop"
        static let pauseResume = "pauseResume"
        static let restart = "restart"
        static let delete = "delete"
        static let meter = "microphoneLevel"
    }

    private let onAction: (Action) -> Void
    private lazy var toolbar = SelectionToolbar(takesKey: false) { [weak self] action in self?.toolbarAction(action) }
    private var state = State.countdown
    private var elapsed = 0.0
    /// The microphone's meter, 0…1, while it records; nil shows none.
    private var meterLevel: Double?
    /// Where the last `show` put the bar, to place it again when its width changes (the time growing a digit).
    private var placement: (window: NSWindow, region: CGRect, position: RecordingControlsPosition, visibleFrame: CGRect)?

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        showItems()
    }

    /// Shows the bar on `window` (the frame window) for `region` within `visibleFrame`, where `position` says.
    func show(attachedTo window: NSWindow, region: CGRect, position: RecordingControlsPosition, visibleFrame: CGRect) {
        placement = (window, region, position, visibleFrame)
        place()
    }

    func hide() {
        placement = nil
        toolbar.hide()
    }

    /// Where the bar is on screen; `.zero` while hidden.
    var frame: CGRect {
        toolbar.frame
    }

    /// The recording's phase and length so far, in seconds.
    func update(state: State, elapsed: Double) {
        guard state != self.state || ElapsedText.string(seconds: elapsed) != ElapsedText.string(seconds: self.elapsed) else {
            return
        }
        self.state = state
        self.elapsed = elapsed
        showItems()
        place()
    }

    /// The microphone's level, 0…1, after Delete; nil removes the meter (no microphone, or it was disconnected).
    func updateMeter(_ level: Double?) {
        guard level != meterLevel else { return }
        let reshapes = (level == nil) != (meterLevel == nil)
        meterLevel = level
        showItems()
        if reshapes { place() }
    }

    // MARK: Private

    private func showItems() {
        let paused = state == .paused
        let running = state == .recording || state == .paused
        var items: [SelectionToolbarItem] = [
            .button(SelectionToolbarButton(id: ID.stop, symbol: "stop.fill", hoverLabel: "Stop Recording", isProminent: true,
                                           isEnabled: state != .finishing)),
            .message(ElapsedText.string(seconds: elapsed), isWarning: false),
            .button(SelectionToolbarButton(id: ID.pauseResume, symbol: paused ? "play.fill" : "pause.fill",
                                           hoverLabel: paused ? "Resume Recording" : "Pause Recording", isEnabled: running)),
            .button(SelectionToolbarButton(id: ID.restart, symbol: "arrow.counterclockwise", hoverLabel: "Restart Recording",
                                           isEnabled: running)),
            .button(SelectionToolbarButton(id: ID.delete, symbol: "trash", hoverLabel: "Delete Recording",
                                           isEnabled: state != .finishing)),
        ]
        if let meterLevel {
            items.append(.meter(id: ID.meter, level: meterLevel))
        }
        toolbar.update(items)
    }

    private func place() {
        guard let placement else { return }
        let frame = RecordingControlsPlacement.frame(size: toolbar.fittingSize, region: placement.region,
                                                     position: placement.position, visibleFrame: placement.visibleFrame)
        toolbar.show(attachedTo: placement.window, frame: frame)
    }

    private func toolbarAction(_ action: SelectionToolbarAction) {
        guard placement != nil, case .pressed(let id) = action else { return }
        switch id {
        case ID.stop: onAction(.stop)
        case ID.pauseResume: onAction(.pauseResume)
        case ID.restart: onAction(.restart)
        case ID.delete: onAction(.delete)
        default: break
        }
    }
}
