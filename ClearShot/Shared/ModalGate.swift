import AppKit
import CSCore

/// The app's side of `ModalPolicy`, the one rule for app-modal alerts and panels around captures: every app-modal alert
/// or panel that a Quick Access thumbnail or its menu, a pin, a hotkey, the status menu or ClearShot itself raises asks
/// here first, so none opens under a capture's overlay or a recording's frame, whose control bar it would leave dead.
/// Document windows (Annotate, the Video Editor, History, Settings) ask on their own windows, as sheets. No question
/// stacks on an app-modal alert or panel either: it is refused, and that alert comes forward. The other direction, a
/// capture refused while an app-modal session is up, is `CaptureFlow.run`.
final class ModalGate {
    private let hud: HUDController
    /// Where the capture flow is; set once the flow exists (`AppCoordinator`).
    var flowState: () -> ModalPolicy.FlowState = { .idle }
    /// Whether a recording or its countdown is on screen, so a refusal says "recording" rather than "capture"; set once
    /// the flow exists (`AppCoordinator`).
    var recordingOnScreen: () -> Bool = { false }
    /// Told when the relaunch starts waiting and when it stops (`waitUntilIdle`); the update center sets it, to say so in
    /// its window.
    var relaunchWaitChanged: (Bool) -> Void = { _ in }
    /// The last report waiting for the flow to be idle, and how many are waiting: they show one after another, in order,
    /// not stacked on each other.
    private var waiting: Task<Void, Never>?
    private var waitingCount = 0

    init(hud: HUDController) {
        self.hud = hud
    }

    /// What to do with a question the person (or a URL) triggered (`ModalPolicy.decide`). A refusal has been said in
    /// the HUD by the time this returns ("Finish the capture first", "Finish the recording first", or "Close the open
    /// dialog first" with that dialog brought forward, as `CaptureFlow.run` brings it), and logged against the URL
    /// command that asked, if one did. With `saysRefusal` false a refusal is only logged: an app without consent sees
    /// one HUD per sender per 10 s (`RefusalNotices`).
    func decide(_ kind: ModalPolicy.Kind, saysRefusal: Bool = true) -> ModalPolicy.Decision {
        let modalWindow = NSApp.modalWindow
        let decision = ModalPolicy.decide(kind, flow: flowState(), appModalIsUp: modalWindow != nil)
        if decision == .refuse {
            let refusal = ModalPolicy.refusal(appModalIsUp: modalWindow != nil, recordingOnScreen: recordingOnScreen())
            if saysRefusal {
                hud.show(refusal.text, symbol: refusal.symbol)
                if refusal == .appModal { modalWindow?.orderFrontRegardless() }
            }
            URLCommandContext.logRefusal(refusal.text)
        }
        return decision
    }

    /// A question whose "yes" can't be undone, or a panel it opens: true when it may be shown now; otherwise it was
    /// refused, which the HUD has said unless `saysRefusal` is false (`decide`).
    func allowsQuestion(saysRefusal: Bool = true) -> Bool {
        decide(.question(undoable: false), saysRefusal: saysRefusal) == .ask
    }

    /// Returns once nothing is in the relaunch's way (`ModalPolicy.relaunchMustWait`): no capture, recording or recording's
    /// tail is under way, by the same rule and the same once-a-second check as `report`; no report is queued behind them;
    /// and no app-modal alert or panel is up. For work that must not cut one of those off (the update's relaunch). True
    /// when it had to wait; `relaunchWaitChanged` hears when the wait begins and ends. A cancelled wait returns at once, so
    /// what is stopping the work (the app is quitting) isn't held up by it.
    func waitUntilIdle() async -> Bool {
        var waited = false
        defer { if waited { relaunchWaitChanged(false) } }
        while ModalPolicy.relaunchMustWait(flow: flowState(), reportsQueued: waitingCount > 0,
                                           appModalIsUp: NSApp.modalWindow != nil) {
            if !waited {
                waited = true
                relaunchWaitChanged(true)
            }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return waited
            }
        }
        return waited
    }

    /// Shows `alert`, which ClearShot raises by itself or which reports earlier work (a failed save, Mute's outcome, the
    /// trim flow's late actions): now when no capture, recording or recording's tail is under way, else once the flow is
    /// idle, checked once a second as recovery waits (`RecordingRecovery.waitUntil`), after the reports already waiting.
    func report(_ alert: @escaping () -> Void) {
        guard waitingCount > 0 || ModalPolicy.decide(.report, flow: flowState()) == .wait else {
            alert()
            return
        }
        waitingCount += 1
        let previous = waiting
        // The gate lives as long as the app, so the wait holds it.
        waiting = Task {
            await previous?.value
            await RecordingRecovery.waitUntil { ModalPolicy.decide(.report, flow: self.flowState()) != .wait }
            alert()
            waitingCount -= 1
        }
    }
}
