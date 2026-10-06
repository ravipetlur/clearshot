import CSCore
import Foundation
import Synchronization

/// What running a shortcut came to.
public enum ShortcutOutcome: Sendable, Equatable {
    case ran
    /// No shortcut has that name.
    case missing
    /// It couldn't run, or it failed: what the command said.
    case failed(String)
}

/// Runs the user's Shortcuts and lists them. ClearShot's runner is `SystemShortcutRunner`; tests use a fake and never
/// run the real command.
public protocol ShortcutRunning: Sendable {
    /// Runs the shortcut named `name`, off the caller's actor (it takes seconds when Focus changes).
    @concurrent func run(_ name: String) async -> ShortcutOutcome
    /// The names of every shortcut, or nil when they can't be listed.
    @concurrent func names() async -> [String]?
}

/// The `shortcuts` command (`/usr/bin/shortcuts run` and `list`), with a 10 s limit on each run. Measured: a name that
/// doesn't exist is reported in 0.15 s with "Couldn't find shortcut".
public struct SystemShortcutRunner: ShortcutRunning {
    static let executable = URL(filePath: "/usr/bin/shortcuts")
    /// A run or a list still going after this is stopped and counts as failed.
    public static let timeout: Duration = .seconds(10)

    public init() {}

    @concurrent public func run(_ name: String) async -> ShortcutOutcome {
        switch await Self.execute(["run", name]) {
        case let .finished(status, output, errors):
            return Self.outcome(status: status, output: errors + output)
        case .failed(let reason):
            return .failed(reason)
        }
    }

    @concurrent public func names() async -> [String]? {
        guard case let .finished(status, output, _) = await Self.execute(["list"]), status == 0 else { return nil }
        return output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// What a run that exited with `status`, having printed `output`, came to: "Couldn't find shortcut" is a missing one
    /// whatever the status (never measured for a missing name), else 0 ran, anything else failed with what it printed.
    static func outcome(status: Int32, output: String) -> ShortcutOutcome {
        let normalized = output.replacingOccurrences(of: "’", with: "'")
        if normalized.localizedCaseInsensitiveContains("couldn't find shortcut") { return .missing }
        guard status != 0 else { return .ran }
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? "The shortcuts command exited with status \(status)." : message)
    }

    // MARK: Private

    private enum Execution: Sendable {
        case finished(status: Int32, output: String, errors: String)
        case failed(String)
    }

    /// The command's output, read on these threads: reading blocks until the command closes it.
    private static let readQueue = DispatchQueue(label: CSCore.identifier("shortcuts"), attributes: .concurrent)

    /// What the command's two pipes held and whether its result has been handed over, from whichever thread gets there.
    private final class Collected: Sendable {
        let output = Mutex(Data())
        let errors = Mutex(Data())
        let continuation: Mutex<CheckedContinuation<Execution, Never>?>

        init(_ continuation: CheckedContinuation<Execution, Never>) {
            self.continuation = Mutex(continuation)
        }

        /// Hands `execution` over the first time; later calls do nothing.
        func finish(_ execution: Execution) {
            continuation.withLock { continuation in
                continuation?.resume(returning: execution)
                continuation = nil
            }
        }
    }

    /// Runs the command with `arguments` and returns its status and output, or why it gave none: it couldn't start, or
    /// it was still running after `timeout` (it is then stopped).
    private static func execute(_ arguments: [String]) async -> Execution {
        await withCheckedContinuation { continuation in
            let collected = Collected(continuation)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            let reads = DispatchGroup()
            readQueue.async(group: reads) {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                collected.output.withLock { $0 = data }
            }
            readQueue.async(group: reads) {
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                collected.errors.withLock { $0 = data }
            }
            process.terminationHandler = { process in
                let status = process.terminationStatus
                reads.notify(queue: readQueue) {
                    let output = String(decoding: collected.output.withLock { $0 }, as: UTF8.self)
                    let errors = String(decoding: collected.errors.withLock { $0 }, as: UTF8.self)
                    collected.finish(.finished(status: status, output: output, errors: errors))
                }
            }
            do {
                try process.run()
            } catch {
                // Nothing will write to the pipes: closing them ends the reads.
                try? output.fileHandleForWriting.close()
                try? errors.fileHandleForWriting.close()
                collected.finish(.failed("The shortcuts command couldn't run: \(error.localizedDescription)"))
                return
            }
            readQueue.asyncAfter(deadline: .now() + .seconds(Int(timeout.components.seconds))) {
                guard process.isRunning else { return }
                Log.recording.error("shortcuts \(arguments.first ?? "") didn't finish within \(timeout); stopping it")
                process.terminate()
                collected.finish(.failed("The shortcuts command didn't finish in time."))
            }
        }
    }
}

/// The two Shortcuts that switch Do Not Disturb: macOS has no public way to set Focus, so the user makes two shortcuts,
/// each a single Set Focus action, and ClearShot runs them by name.
public enum FocusShortcuts {
    public static let onName = "ClearShot Focus On"
    public static let offName = "ClearShot Focus Off"

    /// Whether each shortcut is among `names`, matched exactly.
    public static func areInstalled(in names: [String]) -> (on: Bool, off: Bool) {
        (names.contains(onName), names.contains(offName))
    }

    /// Settings' check: which of the two exist, from `runner`'s list, or nil when it can't be read. It only lists;
    /// it never runs a shortcut.
    public static func check(using runner: any ShortcutRunning) async -> (on: Bool, off: Bool)? {
        await runner.names().map(areInstalled(in:))
    }
}

/// Focus over one recording: On runs at most once, during the countdown; Off runs only after On succeeded, exactly
/// once, on whichever ending comes, even one that comes while On is still running; the journal says Focus is on only
/// between a successful On and its Off, so a launch after a crash turns it off again.
public struct FocusSessionState: Sendable, Equatable {
    /// What to do once On has finished.
    public enum Action: Sendable, Equatable {
        case none
        /// Write `focusTurnedOn` into the journal.
        case recordInJournal
        /// The session already ended: run Off now.
        case turnOff
    }

    private enum Step: Sendable, Equatable {
        case notStarted, turningOn, on, unavailable, off
    }

    private var step = Step.notStarted
    private var hasEnded = false

    public init() {}

    /// On is about to run: true the first time, while the session hasn't ended.
    public mutating func beginTurningOn() -> Bool {
        guard step == .notStarted, !hasEnded else { return false }
        step = .turningOn
        return true
    }

    /// On finished; `succeeded` when the shortcut ran.
    public mutating func turnOnFinished(succeeded: Bool) -> Action {
        guard step == .turningOn else { return .none }
        guard succeeded else {
            step = .unavailable
            return .none
        }
        if hasEnded {
            step = .off
            return .turnOff
        }
        step = .on
        return .recordInJournal
    }

    /// The session ended, however it ended: true when Off should run now (On succeeded and Off hasn't run).
    public mutating func sessionEnded() -> Bool {
        hasEnded = true
        guard step == .on else { return false }
        step = .off
        return true
    }

    /// Focus is on because of this session and Off hasn't run.
    public var journalSaysOn: Bool {
        step == .on
    }
}
