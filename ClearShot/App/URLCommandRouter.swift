import AppKit
import CSAnnotation
import CSAPI
import CSCore

/// Runs `clearshot://` commands as the receiver hands them over: consent first (run, ask once through the modal gate,
/// or drop while the setting is off), then the URL parsed and its area and file checked against the screen and the
/// disk, then the activation handed back (unless the command opens a ClearShot window), then the command itself
/// (`dispatch`, in `URLCommandRouter+Dispatch.swift`). Every error is one HUD line and a log line naming the command
/// and its sender. Owned by the coordinator.
final class URLCommandRouter {
    /// Internal, not private: the dispatch extension (another file) runs commands on the coordinator's collaborators.
    unowned let coordinator: AppCoordinator
    /// Hands the activation back before a command that doesn't keep it. Internal like `coordinator`, so the dispatch
    /// extension in another file can reach it.
    let activation: ActivationHandBack
    /// The last command's start. Each command starts once the one before it has, so they start in arrival order, but
    /// none waits for the one before to finish: a command runs in a task of its own.
    private var lastStart: Task<Void, Never>?
    /// The command the consent prompt is up for, and those that arrived meanwhile.
    private var consent = ConsentQueue()
    /// The "URL commands are off" HUD has shown this launch; later drops are only logged.
    private var saidCommandsAreOff = false
    /// When the person last chose Don't Allow: commands that arrived before it were answered by it, so their drop shows
    /// no HUD.
    private var refusedAt: Date?
    /// The modal gate's refusals shown to apps without consent: one per sender per 10 s.
    private var refusalNotices = RefusalNotices()

    #if DEBUG
    private static let allowsDebugCommands = true
    #else
    private static let allowsDebugCommands = false
    #endif

    init(coordinator: AppCoordinator, activation: ActivationHandBack) {
        self.coordinator = coordinator
        self.activation = activation
    }

    /// Called from the receiver's Apple-event handler, which may be inside a modal session (the consent prompt's own,
    /// among others): this decides and queues, and shows nothing itself. The prompt, and the HUD of a dropped command,
    /// come in a task once the handler has returned.
    func handle(_ received: ReceivedURL) {
        let label = Self.label(received)
        switch decision(for: received) {
        case .run: enqueue(received, label: label)
        case .ask: Task { self.ask(received, label: label) }
        case .drop: Task { self.drop(received, label: label) }
        }
    }

    /// One HUD line, and the log line with the command and its sender. Internal: the dispatch extension (another file)
    /// reports a file it can't read with it.
    func fail(_ label: String, _ message: String) {
        coordinator.hud.show(message, symbol: "exclamationmark.triangle.fill")
        Log.api.error("\(label): \(message)")
    }

    // MARK: Consent

    /// The setting and the Keychain grant decide (`URLConsent.decide`); the defaults alone never grant anything.
    private func decision(for received: ReceivedURL) -> URLConsent.Decision {
        URLConsent.decide(preferences: coordinator.preferences, store: coordinator.consentStore,
                          sender: received.sender, ownPID: getpid())
    }

    /// Starts the command once the one before it has started.
    private func enqueue(_ received: ReceivedURL, label: String) {
        let previous = lastStart
        lastStart = Task {
            await previous?.value
            await self.start(received, label: label)
        }
    }

    /// The setting is off: the command is logged with its sender and dropped, the HUD says so once a launch, and the
    /// activation the URL gave ClearShot goes back. A command that arrived before the person's own Don't Allow shows no
    /// HUD: their answer covered it.
    private func drop(_ received: ReceivedURL, label: String) {
        Log.api.info("\(label): dropped, URL commands are off")
        let answered = refusedAt.map { received.receivedAt <= $0 } ?? false
        if !saidCommandsAreOff, !answered {
            saidCommandsAreOff = true
            coordinator.hud.show(URLConsent.offNotice, symbol: "hand.raised")
        }
        handBack(received)
    }

    /// The first command from another app asks whether other apps may control ClearShot at all (`ConsentQueue.arrive`).
    /// While the prompt is up (this task may run inside its modal session) the command only waits for the answer.
    /// Otherwise the modal gate is asked first; refused, the command is dropped and the next one asks again.
    private func ask(_ received: ReceivedURL, label: String) {
        // The prompt may have been answered since this command arrived.
        switch decision(for: received) {
        case .run: return enqueue(received, label: label)
        case .drop: return drop(received, label: label)
        case .ask: break
        }
        let gate = coordinator.gate
        // The gate logs its refusal against this command; it shows it (a HUD, a dialog brought forward) at most once
        // per sender per 10 s.
        let now = Date()
        let saysRefusal = refusalNotices.mayShow(for: received.sender, at: now)
        let arrival = consent.arrive(received) {
            URLCommandContext.$label.withValue(label) { gate.allowsQuestion(saysRefusal: saysRefusal) }
        }
        switch arrival {
        case .waits:
            Log.api.info("\(label): waits for the answer to the consent prompt")
        case .dropped:
            Log.api.error("\(label): dropped, \(ConsentQueue.limit) commands already wait for the consent prompt")
        case .refused where saysRefusal:
            Log.api.info("\(label): dropped; the next command asks for consent again")
            refusalNotices.shown(for: received.sender, at: now)
            // Refused over an app-modal dialog, the gate brought it forward to be closed: ClearShot keeps the activation.
            if NSApp.modalWindow == nil { handBack(received) }
        case .refused:
            Log.api.info("\(label): dropped; the next command asks for consent again (not shown: this sender's last "
                + "refusal was under \(Int(RefusalNotices.interval)) s ago)")
            // Nothing came forward: the activation the URL gave ClearShot goes back.
            handBack(received)
        case .asks:
            Log.api.info("\(label): asking whether other apps may control ClearShot")
            NSApp.activate()
            answer(URLConsentPrompt.run(command: APIRequest.commandName(of: received.url), sender: received.sender))
        }
    }

    /// Allow stores the Keychain grant and turns the API on, then runs the prompt's command and those that waited, in
    /// arrival order: the person allowed them, even if the grant couldn't be stored (then the next command asks again).
    /// Don't Allow removes the grant, turns the API off, and drops them all, logged, and hands the activation back.
    /// Either way the person has been asked (`URLConsent.record`).
    private func answer(_ allowed: Bool) {
        let stored = URLConsent.record(allowed: allowed, preferences: coordinator.preferences,
                                       store: coordinator.consentStore)
        let pending = consent.pending
        let running = consent.answer(allowed: allowed)
        if allowed {
            Log.api.info(stored ? "URL commands allowed" : "URL commands allowed this time; the consent couldn't be stored")
        } else {
            refusedAt = Date()
            Log.api.info("URL commands not allowed; Settings › Advanced can allow them")
        }
        for received in running {
            enqueue(received, label: Self.label(received))
        }
        guard !allowed else { return }
        for received in pending {
            Log.api.info("\(Self.label(received)): dropped, URL commands are off")
        }
        if let first = pending.first { handBack(first) }
    }

    /// Nothing of ClearShot's comes on screen for the command, so the activation the URL gave ClearShot goes back.
    private func handBack(_ received: ReceivedURL) {
        Task { await activation.yieldIfNeeded(since: received.receivedAt) }
    }

    // MARK: Running

    /// Parses and checks the command, hands the activation back unless the command keeps it, then starts the command
    /// in a task of its own, so a chooser it opens holds up no later command.
    private func start(_ received: ReceivedURL, label: String) async {
        // The setting may have been turned off since this command was queued.
        guard decision(for: received) != .drop else {
            drop(received, label: label)
            return
        }
        let command: APICommand
        var area: ResolvedAPIArea?
        var file: URL?
        do throws(APIError) {
            let request = try APIRequest.parse(received.url, allowsDebugCommands: Self.allowsDebugCommands)
            for note in request.notes {
                Log.api.info("\(label): \(note)")
            }
            command = request.command
            let checks = command.checks
            if let needed = checks.file {
                // Off the main actor: a file on a stalled network volume can't freeze ClearShot.
                let projectExtension = DocumentPackage.fileExtension
                file = try await Task.detached(priority: .userInitiated) {
                    Result { () throws(APIError) in
                        try APIFiles.validate(needed.path, as: needed.kind, projectExtension: projectExtension)
                    }
                }.value.get()
            }
            if let given = checks.area {
                let resolved = try given.resolve(in: DisplayLayout.current(), mouse: NSEvent.mouseLocation)
                if resolved.wasClamped {
                    Log.api.info("\(label): the area is partly off its display; using \(resolved.rect) "
                        + "on \(resolved.display.name)")
                }
                area = resolved
            }
        } catch {
            // Only the HUD comes on screen, and it doesn't activate.
            await activation.yieldIfNeeded(since: received.receivedAt)
            fail(label, error.message)
            return
        }
        if !command.keepsActivation {
            await activation.yieldIfNeeded(since: received.receivedAt)
        }
        Log.api.info("Running \(label)")
        let notice = URLConsent.showsCaptureNotice(for: command, sender: received.sender, ownPID: getpid())
            ? URLConsent.captureNotice(sender: received.sender) : nil
        Task { [area, file] in
            URLCommandContext.$label.withValue(label) {
                // A ClearShot window, so captures leave it out; the capture's own HUD replaces it.
                if let notice {
                    coordinator.hud.show(notice, symbol: "camera.viewfinder", duration: .milliseconds(2500))
                }
                dispatch(command, area: area, file: file, label: label)
            }
        }
    }

    /// "capture-area from Raycast (com.raycast.macos, team …)", or "… from an unverified app": the command as given
    /// (shortened) and the sender as the prompt names it (`URLConsent.describe`, sanitised), for the log.
    private static func label(_ received: ReceivedURL) -> String {
        let command = APIRequest.shortened(APIRequest.commandName(of: received.url))
        return "\(command.isEmpty ? "A command with no name" : command) from \(URLConsent.describe(received.sender))"
    }
}
