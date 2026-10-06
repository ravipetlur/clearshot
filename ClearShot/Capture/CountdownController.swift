import AppKit
import CSCore
import SwiftUI

/// Borderless panels can't become key by default; this one must, so Esc and the Cancel shortcut work while ClearShot isn't active.
private final class CountdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The Self-Timer and recording countdown: seconds left, a Cancel button, and a tick sound when sounds are on.
final class CountdownController {
    /// The countdown on screen, and whether `finishNow` asked it to end.
    private var running: (model: CountdownModel, finishesNow: Bool)?

    /// Counts down `seconds` on `display`; true when it reached zero (or `finishNow` ended it), false when cancelled.
    func run(seconds: Int, on display: DisplayInfo, preferences: Preferences) async -> Bool {
        let model = CountdownModel(remaining: seconds)
        running = (model, false)
        defer { if running?.model === model { running = nil } }
        let host = NSHostingView(rootView: CountdownView(model: model))
        let size = host.fittingSize
        let panel = CountdownPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.setFrameOrigin(NSPoint(x: display.frame.midX - size.width / 2, y: display.frame.midY - size.height / 2))
        // Key once, for Esc and the Cancel shortcut. If the person clicks into another app to set up the shot,
        // the typing goes there; the Cancel button still works with a click.
        panel.makeKeyAndOrderFront(nil)
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { model.cancelled = true; return nil }
            return event
        }
        defer {
            if let escape { NSEvent.removeMonitor(escape) }
            panel.orderOut(nil)
        }
        let tick = NSSound(contentsOf: ShutterSound.tink.fileURL, byReference: true)
        counting: for remaining in stride(from: seconds, to: 0, by: -1) {
            withAnimation { model.remaining = remaining }
            if preferences[Prefs.playSounds] { tick?.play() }
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                if model.cancelled { return false }
                if running?.finishesNow == true { break counting }
            }
        }
        panel.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(40)) // let the panel leave the screen
        return true
    }

    /// The running countdown ends as if it reached zero, within a tenth of a second (the Record hotkey during a
    /// recording's countdown). Does nothing without one.
    func finishNow() {
        running?.finishesNow = true
    }
}
