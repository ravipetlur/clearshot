import AppKit
import CSAPI
import CSCore

/// The URL scheme API's one question: the first command from another app asks whether third-party apps may control
/// ClearShot at all. The router asks the modal gate and activates ClearShot first, and runs it outside the Apple-event
/// handler (`URLCommandRouter`). It is a permission, not a "Don't ask again" dialog, so Reset All Warning Dialogs
/// doesn't bring it back.
///
/// Opening a URL activates ClearShot, so the alert can take the keys while the person types in another app, and another
/// app can see where it is and draw over it. Neither a stray key or click nor a click through a decoy may grant control
/// (`URLConsent.buttons`, `AllowArming`, `AllowGuard`): Don't Allow is the default, on Return and Esc; Allow can only be
/// clicked, once the alert has been key and uncovered for 1.5 s, and a click on it is refused while another app's window
/// covers it.
enum URLConsentPrompt {
    /// Shows the alert, modal; true only when the person clicked Allow. `command` is the URL's command name as given
    /// (`APIRequest.commandName(of:)`), which the alert shortens; `sender` names the sender as `URLConsent.describe` does.
    static func run(command: String, sender: SenderFacts) -> Bool {
        let text = URLConsent.prompt(command: command, sender: sender)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.title
        alert.informativeText = text.message
        let specs = URLConsent.buttons
        let buttons = specs.map { alert.addButton(withTitle: $0.title) }
        for (spec, button) in zip(specs, buttons) {
            // NSAlert gives the first button Return and a button titled Cancel Esc; each button's keys are set here.
            button.keyEquivalent = spec.isDefault ? "\r" : ""
            button.keyEquivalentModifierMask = []
            // Not even Space can press it through Full Keyboard Access.
            button.refusesFirstResponder = !spec.isDefault
            button.isEnabled = spec.enabledAfter <= 0
        }
        // Laid out now, so the alert appears as `runModal` starts.
        alert.layout()
        let guards = specs.indices.filter { specs[$0].enabledAfter > 0 }.map { index in
            AllowButtonGuard(button: buttons[index], window: alert.window, delay: specs[index].enabledAfter,
                             response: NSApplication.ModalResponse(
                                 rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index))
        }
        guards.forEach { $0.start() }
        // Esc chooses the default button too. A local monitor sees the alert's keys: `runModal` sends them through
        // `NSApplication.sendEvent`.
        let defaultButton = zip(specs, buttons).first { $0.0.isDefault }?.1
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window, event.charactersIgnoringModifiers == "\u{1b}",
                  let defaultButton else { return event }
            defaultButton.performClick(nil)
            return nil
        }
        defer {
            guards.forEach { $0.stop() }
            if let escape { NSEvent.removeMonitor(escape) }
        }
        let response = alert.runModal()
        return URLConsent.allows(choosing: response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
    }
}

/// Keeps the alert's Allow button from being clicked through a window another app draws over the alert. It is enabled
/// only once the alert has been key, visible and uncovered by any other app's window for its delay without a break
/// (`AllowArming`), checked ten times a second and whenever the alert gains or loses key or is hidden or shown. A click
/// on it ends the alert only if the alert passes the same check at that moment, with the delay run; otherwise it beeps
/// and the delay starts again, as it does for any click on the alert while Allow is disabled.
private final class AllowButtonGuard: NSObject {
    private let button: NSButton
    private let window: NSWindow
    private let response: NSApplication.ModalResponse
    private var arming: AllowArming
    private var poll: Timer?
    private var observers: [any NSObjectProtocol] = []
    private var clicks: Any?
    /// Logged once: what covered the alert, so a window that always does can be found.
    private var saidCovered = false

    init(button: NSButton, window: NSWindow, delay: TimeInterval, response: NSApplication.ModalResponse) {
        self.button = button
        self.window = window
        self.response = response
        arming = AllowArming(delay: delay)
        super.init()
    }

    func start() {
        // The alert's own action would end it on any click; this one checks first.
        button.target = self
        button.action = #selector(clicked(_:))
        let poll = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // `runModal` runs the main run loop in the modal-panel mode, where this fires.
        RunLoop.main.add(poll, forMode: .modalPanel)
        self.poll = poll
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            })
        }
        clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, event.window === window, !button.isEnabled {
                arming.restart()
            }
            return event
        }
        check()
    }

    func stop() {
        poll?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let clicks { NSEvent.removeMonitor(clicks) }
        clicks = nil
    }

    /// Ready: ClearShot active, the alert key and visible, and no other app's window over any of it.
    private var isReady: Bool {
        NSApp.isActive && window.isKeyWindow && window.occlusionState.contains(.visible) && !isCovered(window.frame)
    }

    private func check() {
        let enabled = arming.observe(ready: isReady, at: Date())
        if button.isEnabled != enabled { button.isEnabled = enabled }
    }

    /// Judged on the alert as it is now, the full readiness check and the delay, never on the last poll
    /// (`AllowArming.click`): a window that appeared over the alert since then refuses it.
    @objc private func clicked(_ sender: Any?) {
        guard arming.click(ready: isReady, at: Date()) else {
            NSSound.beep()
            button.isEnabled = false
            Log.api.warning("Refused a click on Allow: the consent prompt wasn't in front and uncovered")
            return
        }
        NSApp.stopModal(withCode: response)
    }

    /// Whether a window of another app above the alert overlaps `frame` (AppKit screen coordinates), compared in CG's
    /// global coordinates, as the window list gives bounds. A window list that can't be read counts as covered.
    private func isCovered(_ frame: CGRect) -> Bool {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow],
                                                       CGWindowID(window.windowNumber)) as? [[String: Any]] else {
            return true
        }
        let above = entries.compactMap { entry -> ScreenWindow? in
            guard let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
            return ScreenWindow(ownerPID: pid, frame: rect, alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
        let target = DisplayLayout.current().cgRect(fromAppKit: frame)
        let covered = AllowGuard.isCovered(target, by: above, ownPID: getpid())
        if covered, !saidCovered {
            saidCovered = true
            let owners = Set(entries.compactMap { $0[kCGWindowOwnerName as String] as? String }.compactMap(SenderText.name))
            Log.api.warning("Allow waits: windows of other apps are over the consent prompt (\(owners.sorted().joined(separator: ", ")))")
        }
        return covered
    }
}
