import AppKit
import CSCore
import CSRecording

/// What a recording takes in besides the screen and system audio: the microphone Ready handed over (taken over before
/// the writer is made, started during the countdown, closed on every ending), and the clicks Highlight Clicks draws (the
/// overlay up before the stream fetches its content, rings from the start of the recording, none new while paused, and
/// gone as soon as it ends).
extension RecordingSession {
    // MARK: The microphone

    /// The session watches the microphone Ready handed over from here. One unplugged since, while nothing watched it,
    /// records nothing: the writer gets no track for it, the journal says so, and the start notice says it was
    /// disconnected, as for one unplugged in Ready (`RecordingMicrophoneState`). The handler is set before the check,
    /// so a disconnection in between is told one way, never both.
    func takeOverMicrophone() {
        guard let microphone else { return }
        microphone.onDisconnect = Self.disconnects(reportedTo: self)
        guard let issue = microphoneState.takeOver(alreadyDisconnected: microphone.isDisconnected) else { return }
        Log.recording.info("The microphone went away after Ready handed it over; recording without it")
        microphoneIssue = issue
        markNoMicrophone()
    }

    /// The warm session keeps running into the recording; started here when Ready hadn't got it running yet. One that
    /// won't start is treated as disconnected.
    func startMicrophone() {
        guard let microphone, !microphoneEnded else { return }
        Task {
            do {
                try await microphone.start()
            } catch {
                Log.recording.error("The microphone didn't start: \(error)")
                microphoneDisconnected()
            }
        }
    }

    /// Stops forwarding and closes the session, once the writer has finished (samples after that are ignored anyway).
    func closeMicrophone() {
        guard let microphone else { return }
        microphone.onDisconnect = nil
        microphone.forward(to: nil, clockOf: nil)
        Task { await microphone.stop() }
    }

    // MARK: Highlight Clicks

    /// The click overlay on screen and among the windows the stream keeps, before the stream fetches its content.
    func showClickOverlay() {
        guard let clickHighlighter else { return }
        clickHighlighter.show()
        if let windowID = clickHighlighter.windowID {
            keptWindowIDs.insert(windowID)
        }
    }

    /// Rings from the moment the recording starts (never in the countdown), and none new while paused, since the writer
    /// drops those frames.
    func highlightClicks(in phase: RecordingControlState.Phase) {
        guard let clickHighlighter else { return }
        switch phase {
        case .recording:
            clickHighlighter.start()
            clickHighlighter.isPaused = false
        case .paused:
            clickHighlighter.isPaused = true
        default:
            break
        }
    }

    /// The monitor off and the rings gone: as soon as the recording ends, and on every way out of `run`.
    func stopHighlightingClicks() {
        clickHighlighter?.stop()
    }
}
