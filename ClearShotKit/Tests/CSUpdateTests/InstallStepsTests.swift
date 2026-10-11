import Foundation
import Synchronization
import Testing
import CSUpdate

// MARK: - The fake world

/// What the fake steps are called, in the order a clean install calls them.
enum Call: String, CaseIterable, Hashable, Sendable {
    case download, checksum, gatekeeperImage, mount, appIdentity, appSignature, gatekeeperApp
    case writable, openImage, stageAndReplace, removeBackup, detach, cleanup, waitUntilQuiet, relaunch

    /// The steps that check the release, in order: a failure at one stops the ones after it.
    static let verification: [Call] = [.download, .checksum, .gatekeeperImage, .mount, .appIdentity, .appSignature, .gatekeeperApp]
}

/// Lets one task wait until another says go.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// The steps of an install, faked: each records that it was called (and with what), may run a behaviour of the test's
/// (suspend, cancel the task, change the flow), and may then fail as the test says.
final class World: Sendable {
    struct Script: Sendable {
        var failures: [Call: any Error] = [:]
        var behaviors: [Call: @Sendable () async throws -> Void] = [:]
        var writable = true
        var relaunches = true
    }

    private struct Recorded {
        var calls: [Call] = []
        var arguments: [Call: URL] = [:]
        var notes: [String] = []
        /// `Task.isCancelled`, as the detach and cleanup steps saw it.
        var cleanupSawCancellation: [Bool] = []
        /// The flow's state at each cleanup, when the world watches a flow.
        var flowAtCleanup: [InstallFlow.State] = []
    }

    let script: Script
    private let watching: FlowBox?
    let image = URL(filePath: "/work/ClearShot-1.2.0.dmg")
    let checksumFile = URL(filePath: "/work/ClearShot-1.2.0.dmg.sha256")
    let volume = URL(filePath: "/work/ClearShot")
    let app = URL(filePath: "/work/ClearShot/ClearShot.app")
    let backup = URL(filePath: "/Applications/ClearShot-1.1.0.app")
    private let recorded = Mutex(Recorded())

    init(_ script: Script = Script(), watching: FlowBox? = nil) {
        self.script = script
        self.watching = watching
    }

    var calls: [Call] { recorded.withLock { $0.calls } }
    var notes: [String] { recorded.withLock { $0.notes } }
    var cleanupSawCancellation: [Bool] { recorded.withLock { $0.cleanupSawCancellation } }
    var flowAtCleanup: [InstallFlow.State] { recorded.withLock { $0.flowAtCleanup } }
    func argument(of call: Call) -> URL? { recorded.withLock { $0.arguments[call] } }

    /// Records the call, runs the test's behaviour for it, then fails if the test says so.
    private func enter(_ call: Call, _ url: URL? = nil) async throws {
        recorded.withLock {
            $0.calls.append(call)
            if let url { $0.arguments[call] = url }
        }
        if let behavior = script.behaviors[call] { try await behavior() }
        if let failure = script.failures[call] { throw failure }
    }

    func steps() -> InstallSteps {
        InstallSteps(
            download: { [self] progress in
                try await enter(.download)
                progress(0.5)
                progress(1)
                return InstallSteps.Files(image: image, checksum: checksumFile)
            },
            checksum: { [self] files in
                try await enter(.checksum, files.image)
            },
            gatekeeperImage: { [self] image in
                try await enter(.gatekeeperImage, image)
            },
            mount: { [self] image in
                try await enter(.mount, image)
                return volume
            },
            appIdentity: { [self] volume in
                try await enter(.appIdentity, volume)
                return app
            },
            appSignature: { [self] app in
                try await enter(.appSignature, app)
            },
            gatekeeperApp: { [self] app in
                try await enter(.gatekeeperApp, app)
            },
            destinationIsWritable: { [self] in
                recorded.withLock { $0.calls.append(.writable) }
                return script.writable
            },
            openImage: { [self] volume in
                try? await enter(.openImage, volume)
            },
            stageAndReplace: { [self] app in
                try await enter(.stageAndReplace, app)
                return backup
            },
            removeBackup: { [self] backup in
                try await enter(.removeBackup, backup)
            },
            detach: { [self] volume in
                recorded.withLock { $0.cleanupSawCancellation.append(Task.isCancelled) }
                try? await enter(.detach, volume)
            },
            cleanup: { [self] in
                let state = watching?.state
                recorded.withLock {
                    $0.cleanupSawCancellation.append(Task.isCancelled)
                    if let state { $0.flowAtCleanup.append(state) }
                }
                try? await enter(.cleanup)
            },
            waitUntilQuiet: { [self] in
                try? await enter(.waitUntilQuiet)
            },
            relaunch: { [self] in
                recorded.withLock { $0.calls.append(.relaunch) }
                return script.relaunches
            },
            note: { [self] text in
                recorded.withLock { $0.notes.append(text) }
            })
    }
}

/// An `InstallFlow` as the update center holds it: the sequencer's events go in tagged with their attempt, and the
/// person's choices (Cancel, Try Again, a new check) go in untagged.
final class FlowBox: Sendable {
    private struct Inner {
        var flow = InstallFlow()
        var attempted: [InstallFlow.Event] = []
        var accepted: [InstallFlow.Event] = []
    }

    private let inner = Mutex(Inner())

    var flow: InstallFlow { inner.withLock { $0.flow } }
    var state: InstallFlow.State { inner.withLock { $0.flow.state } }
    /// Every event the sequencer sent, taken or not.
    var attempted: [InstallFlow.Event] { inner.withLock { $0.attempted } }
    /// The events the flow took.
    var accepted: [InstallFlow.Event] { inner.withLock { $0.accepted } }

    /// A check that found the release, then the person's choice to install it: the first attempt.
    func begin(_ release: ReleaseInfo) -> InstallAttempt {
        inner.withLock { inner in
            _ = inner.flow.handle(.checkStarted)
            _ = inner.flow.handle(.updateFound(release))
            _ = inner.flow.handle(.downloadStarted)
            return inner.flow.attempt!
        }
    }

    /// The person's choice, or a check's result.
    @discardableResult
    func choose(_ event: InstallFlow.Event) -> Bool {
        inner.withLock { $0.flow.handle(event) }
    }

    /// The new attempt after the person cancelled, tried again and chose to install.
    func beginAgain() -> InstallAttempt {
        inner.withLock { inner in
            _ = inner.flow.handle(.retry)
            _ = inner.flow.handle(.downloadStarted)
            return inner.flow.attempt!
        }
    }

    func sink(_ attempt: InstallAttempt) -> InstallSteps.Report {
        { [self] event in
            inner.withLock { inner in
                inner.attempted.append(event)
                let taken = inner.flow.handle(event, from: attempt)
                if taken { inner.accepted.append(event) }
                return taken
            }
        }
    }
}

private struct SomeError: Error, Equatable {}

// MARK: - The sequencer

struct InstallStepsTests {
    let release = InstallFlowTests.release

    struct Run {
        let world: World
        let box: FlowBox
        let outcome: InstallOutcome
    }

    func run(_ script: World.Script = World.Script()) async -> Run {
        let world = World(script)
        let box = FlowBox()
        let attempt = box.begin(release)
        let outcome = await world.steps().run(report: box.sink(attempt))
        return Run(world: world, box: box, outcome: outcome)
    }

    /// The calls a run makes when `call` is the last step it gets to, with the image detached if it had mounted, then
    /// cleaned. A step that throws didn't finish: a mount that fails or is cancelled leaves nothing to detach by name.
    func callsWhenStoppedAt(_ call: Call, finished: Bool = false) -> [Call] {
        let index = Call.verification.firstIndex(of: call)!
        let mountIndex = Call.verification.firstIndex(of: .mount)!
        let mounted = finished ? index >= mountIndex : index > mountIndex
        return Array(Call.verification[...index]) + (mounted ? [.detach] : []) + [.cleanup]
    }

    // MARK: A clean run

    @Test func aCleanRunInstallsAndRelaunches() async {
        let run = await run()
        #expect(run.outcome == .installed(backupNotRemoved: false))
        #expect(run.world.calls == [
            .download, .checksum, .gatekeeperImage, .mount, .appIdentity, .appSignature, .gatekeeperApp,
            .writable, .stageAndReplace, .removeBackup, .detach, .cleanup, .waitUntilQuiet, .relaunch,
        ])
    }

    /// The image is detached and the temporary files removed before the relaunch, which ends the process.
    @Test func theImageIsDetachedAndCleanedBeforeTheRelaunch() async {
        let run = await run()
        let calls = run.world.calls
        #expect(calls.last == .relaunch)
        #expect(calls.firstIndex(of: .detach)! < calls.firstIndex(of: .relaunch)!)
        #expect(calls.firstIndex(of: .cleanup)! < calls.firstIndex(of: .relaunch)!)
        #expect(calls.firstIndex(of: .removeBackup)! < calls.firstIndex(of: .detach)!)
    }

    @Test func eachStepIsReportedToTheFlowInOrder() async {
        let run = await run()
        #expect(run.box.accepted == [
            .downloadProgress(0.5), .downloadProgress(1), .downloadFinished,
            .stepPassed(.checksum), .stepPassed(.gatekeeperImage), .stepPassed(.mount),
            .stepPassed(.appIdentity), .stepPassed(.appSignature), .installStarted,
        ])
        #expect(run.box.attempted == run.box.accepted)
        #expect(run.box.state == .installing)
    }

    @Test func whatOneStepMakesTheNextGets() async {
        let run = await run()
        let world = run.world
        #expect(world.argument(of: .checksum) == world.image)
        #expect(world.argument(of: .gatekeeperImage) == world.image)
        #expect(world.argument(of: .mount) == world.image)
        #expect(world.argument(of: .appIdentity) == world.volume)
        #expect(world.argument(of: .appSignature) == world.app)
        #expect(world.argument(of: .gatekeeperApp) == world.app)
        #expect(world.argument(of: .stageAndReplace) == world.app)
        #expect(world.argument(of: .removeBackup) == world.backup)
        #expect(world.argument(of: .detach) == world.volume)
    }

    // MARK: A failure stops everything after it

    static let failures: [(Call, UpdateFailure)] = [
        (.download, .sizeMismatch), (.checksum, .checksumMismatch), (.gatekeeperImage, .imageRejected),
        (.mount, .mountFailed), (.appIdentity, .appIdentifierMismatch), (.appSignature, .signerMismatch),
        (.gatekeeperApp, .appRejected),
    ]

    @Test(arguments: failures)
    func aFailureStopsTheLaterStepsAndCleansUp(call: Call, failure: UpdateFailure) async {
        var script = World.Script()
        script.failures[call] = failure
        let run = await run(script)
        #expect(run.outcome == .failed(failure))
        #expect(run.world.calls == callsWhenStoppedAt(call))
        #expect(run.box.state == .failed(failure))
        #expect(run.box.flow.attempt == nil)
        // Said in the log, with the step's failure.
        #expect(run.world.notes.contains { $0.contains(String(describing: failure)) })
    }

    /// The flow isn't `failed` until the cleanup is done, so a Try Again can't meet a half-cleaned attempt.
    @Test(arguments: failures)
    func aFailureIsReportedOnlyAfterTheCleanup(call: Call, failure: UpdateFailure) async {
        var script = World.Script()
        script.failures[call] = failure
        let box = FlowBox()
        let world = World(script, watching: box)
        let attempt = box.begin(release)
        _ = await world.steps().run(report: box.sink(attempt))
        #expect(world.flowAtCleanup.count == 1)
        for state in world.flowAtCleanup {
            if case .failed = state { Issue.record("the flow was already failed at the cleanup: \(state)") }
        }
        #expect(box.state == .failed(failure))
    }

    static let defaults: [(Call, UpdateFailure)] = [
        (.download, .downloadFailed), (.checksum, .checksumMismatch), (.gatekeeperImage, .imageRejected),
        (.mount, .mountFailed), (.appIdentity, .appMissing), (.appSignature, .signatureInvalid),
        (.gatekeeperApp, .appRejected),
    ]

    /// An error that isn't an `UpdateFailure` stops the run with its step's own failure.
    @Test(arguments: defaults)
    func anUnknownErrorIsTheStepsOwnFailure(call: Call, failure: UpdateFailure) async {
        var script = World.Script()
        script.failures[call] = SomeError()
        let run = await run(script)
        #expect(run.outcome == .failed(failure))
        #expect(run.world.calls == callsWhenStoppedAt(call))
    }

    // MARK: Cancelling

    /// The person cancels while a step runs: the task is cancelled, the flow is cancelled by the center, and the step
    /// ends with a cancellation. Everything is cleaned up, no failure is reported, and nothing runs after.
    @Test(arguments: Call.verification)
    func cancellingWhileAStepRunsCleansUp(call: Call) async {
        let entered = Gate()
        var script = World.Script()
        script.behaviors[call] = {
            await entered.open()
            try await Task.sleep(for: .seconds(60))
        }
        let world = World(script)
        let box = FlowBox()
        let attempt = box.begin(release)
        let task = Task { await world.steps().run(report: box.sink(attempt)) }
        await entered.wait()
        task.cancel()
        box.choose(.cancel)
        let outcome = await task.value
        #expect(outcome == .cancelled)
        #expect(world.calls == callsWhenStoppedAt(call))
        #expect(box.state == .cancelled)
        #expect(!box.attempted.contains { if case .failure = $0 { true } else { false } })
    }

    /// A cancel that arrives while a step runs, and that the step doesn't notice: it is noticed before the next one.
    @Test(arguments: Call.verification)
    func aCancelIsNoticedBetweenSteps(call: Call) async {
        var script = World.Script()
        script.behaviors[call] = { withUnsafeCurrentTask { $0?.cancel() } }
        let world = World(script)
        let box = FlowBox()
        let attempt = box.begin(release)
        let task = Task { await world.steps().run(report: box.sink(attempt)) }
        let outcome = await task.value
        #expect(outcome == .cancelled)
        // The step that was running finished, so the image it mounted is detached.
        #expect(world.calls == callsWhenStoppedAt(call, finished: true))
    }

    /// Cleanup runs even though the task was cancelled: a cancelled task would otherwise end the very `diskutil` that
    /// ejects the image.
    @Test func cleanupIsNotCancelledWithTheTask() async {
        let entered = Gate()
        var script = World.Script()
        script.behaviors[.appSignature] = {
            await entered.open()
            try await Task.sleep(for: .seconds(60))
        }
        let world = World(script)
        let box = FlowBox()
        let attempt = box.begin(release)
        let task = Task { await world.steps().run(report: box.sink(attempt)) }
        await entered.wait()
        task.cancel()
        _ = await task.value
        #expect(world.calls.suffix(2) == [.detach, .cleanup])
        #expect(world.cleanupSawCancellation == [false, false])
    }

    /// What URLSession says when a download task is cancelled counts as a cancel, not a failure.
    @Test func aURLErrorThatIsCancelledIsACancellation() async {
        var script = World.Script()
        script.failures[.download] = URLError(.cancelled)
        let run = await run(script)
        #expect(run.outcome == .cancelled)
        #expect(run.world.calls == [.download, .cleanup])
        #expect(!run.box.attempted.contains { if case .failure = $0 { true } else { false } })
        #expect(run.box.state == .downloading(progress: 0))
    }

    @Test func theSameErrorAsAnNSErrorIsACancellationToo() async {
        var script = World.Script()
        script.failures[.download] = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        let run = await run(script)
        #expect(run.outcome == .cancelled)
        #expect(!run.box.attempted.contains { if case .failure = $0 { true } else { false } })
    }

    @Test func aSwiftCancellationErrorIsACancellation() async {
        var script = World.Script()
        script.failures[.checksum] = CancellationError()
        let run = await run(script)
        #expect(run.outcome == .cancelled)
        #expect(run.world.calls == [.download, .checksum, .cleanup])
    }

    /// Any other URL error is a failed download.
    @Test func otherURLErrorsAreAFailedDownload() async {
        var script = World.Script()
        script.failures[.download] = URLError(.notConnectedToInternet)
        let run = await run(script)
        #expect(run.outcome == .failed(.downloadFailed))
    }

    /// A step that fails because it was cancelled (its process ended, say) reports its own error: it is still a cancel.
    @Test func aFailureThatComesWithACancelIsACancel() async {
        var script = World.Script()
        script.behaviors[.checksum] = { withUnsafeCurrentTask { $0?.cancel() } }
        script.failures[.checksum] = UpdateFailure.checksumMismatch
        let task = Task { await run(script) }
        let run = await task.value
        #expect(run.outcome == .cancelled)
        #expect(!run.box.attempted.contains { if case .failure = $0 { true } else { false } })
    }

    // MARK: Late results from an old attempt

    /// Attempt one is cancelled, and the person starts attempt two. Attempt one's download then fails, late. The failure
    /// must not touch attempt two, and attempt one cleans up and stops.
    @Test func aLateFailureFromAnOldAttemptIsIgnored() async {
        let release = release
        let gate = Gate()
        let entered = Gate()
        var script = World.Script()
        script.behaviors[.download] = {
            await entered.open()
            await gate.wait()
        }
        script.failures[.download] = UpdateFailure.downloadFailed
        let world = World(script)
        let box = FlowBox()
        let first = box.begin(release)
        let task = Task { await world.steps().run(report: box.sink(first)) }
        await entered.wait()
        // The person cancels (the center cancels the task and the flow), goes back to the offer and installs again.
        task.cancel()
        box.choose(.cancel)
        let second = box.beginAgain()
        #expect(second != first)
        await gate.open()
        let outcome = await task.value
        #expect(outcome == .cancelled)
        #expect(world.calls == [.download, .cleanup])
        // The failure was sent, was rejected, and attempt two is as it was.
        #expect(box.state == .downloading(progress: 0))
        #expect(box.flow.attempt == second)
    }

    /// The same, when the old attempt doesn't know it was cancelled (its task wasn't): the flow's answer stops it.
    @Test func aLateFailureTheTaskNeverSawIsStillIgnored() async {
        let gate = Gate()
        let entered = Gate()
        var script = World.Script()
        script.behaviors[.download] = {
            await entered.open()
            await gate.wait()
        }
        script.failures[.download] = UpdateFailure.downloadFailed
        let world = World(script)
        let box = FlowBox()
        let first = box.begin(release)
        let task = Task { await world.steps().run(report: box.sink(first)) }
        await entered.wait()
        box.choose(.cancel)
        let second = box.beginAgain()
        await gate.open()
        let outcome = await task.value
        #expect(outcome == .cancelled)
        #expect(box.attempted.contains(.failure(.downloadFailed)))
        #expect(!box.accepted.contains(.failure(.downloadFailed)))
        #expect(box.state == .downloading(progress: 0))
        #expect(box.flow.attempt == second)
    }

    /// A check the person started after cancelling is not touched by the old attempt's failure either.
    @Test func aLateFailureFromACancelledAttemptCannotReachACheck() async {
        let gate = Gate()
        let entered = Gate()
        var script = World.Script()
        script.behaviors[.checksum] = {
            await entered.open()
            await gate.wait()
        }
        script.failures[.checksum] = UpdateFailure.checksumMismatch
        let world = World(script)
        let box = FlowBox()
        let first = box.begin(release)
        let task = Task { await world.steps().run(report: box.sink(first)) }
        await entered.wait()
        task.cancel()
        box.choose(.cancel)
        box.choose(.retry)
        box.choose(.checkStarted)
        #expect(box.state == .checking)
        await gate.open()
        let outcome = await task.value
        #expect(outcome == .cancelled)
        #expect(box.state == .checking)
        #expect(world.calls == [.download, .checksum, .cleanup])
    }

    /// Cancelled just as a step finished: the flow turns the report down, and the run stops there.
    @Test func aReportTheFlowRejectsStopsTheRun() async {
        let box = FlowBox()
        var script = World.Script()
        // The person's Cancel lands in the flow while the checksum step runs, before the task hears of it.
        script.behaviors[.checksum] = { [box] in box.choose(.cancel) }
        let world = World(script)
        let attempt = box.begin(release)
        let outcome = await world.steps().run(report: box.sink(attempt))
        #expect(outcome == .cancelled)
        #expect(world.calls == [.download, .checksum, .cleanup])
        #expect(box.state == .cancelled)
    }

    /// The gate on installing: a Cancel that reached the flow first means `installStarted` is turned down, and nothing is
    /// replaced. This closes the race between the check for cancellation and the start of the install.
    @Test func aCancelledFlowNeverLetsTheInstallStart() async {
        var script = World.Script()
        let box = FlowBox()
        script.behaviors[.gatekeeperApp] = { [box] in box.choose(.cancel) }
        let world = World(script)
        let attempt = box.begin(release)
        let outcome = await world.steps().run(report: box.sink(attempt))
        #expect(outcome == .cancelled)
        #expect(!world.calls.contains(.stageAndReplace))
        #expect(!world.calls.contains(.removeBackup))
        #expect(!world.calls.contains(.relaunch))
        #expect(world.calls.suffix(2) == [.detach, .cleanup])
        #expect(box.attempted.last == .installStarted)
        #expect(!box.accepted.contains(.installStarted))
    }

    // MARK: Not writable: the hand-off

    @Test func aFolderThatIsNotWritableHandsTheImageOver() async {
        var script = World.Script()
        script.writable = false
        let run = await run(script)
        let world = run.world
        #expect(run.outcome == .handedOff(volume: world.volume))
        #expect(world.calls == [
            .download, .checksum, .gatekeeperImage, .mount, .appIdentity, .appSignature, .gatekeeperApp,
            .writable, .openImage,
        ])
        #expect(world.argument(of: .openImage) == world.volume)
        // It is left mounted, with its files in place: nothing is detached or cleaned up.
        #expect(!world.calls.contains(.detach))
        #expect(!world.calls.contains(.cleanup))
        #expect(!world.calls.contains(.stageAndReplace))
        #expect(!world.calls.contains(.relaunch))
        #expect(run.box.state == .handedOff(release))
        #expect(run.box.accepted.last == .handOff)
        #expect(!run.box.accepted.contains(.installStarted))
    }

    /// A Cancel that reached the flow first turns the hand-off down: the image isn't opened for a cancelled attempt, and
    /// is detached.
    @Test func aCancelledFlowNeverGetsAHandOff() async {
        let box = FlowBox()
        var script = World.Script()
        script.writable = false
        script.behaviors[.gatekeeperApp] = { [box] in box.choose(.cancel) }
        let world = World(script)
        let attempt = box.begin(release)
        let outcome = await world.steps().run(report: box.sink(attempt))
        #expect(outcome == .cancelled)
        #expect(!world.calls.contains(.openImage))
        #expect(world.calls.suffix(2) == [.detach, .cleanup])
    }

    // MARK: After the point of no return

    /// The old copy couldn't be deleted. The new app is in place, so the install completes (`backupNotRemoved`), and
    /// says so in the log only.
    @Test func aRemovalFailureAfterTheReplaceStillCompletes() async {
        var script = World.Script()
        script.failures[.removeBackup] = SomeError()
        let run = await run(script)
        #expect(run.outcome == .installed(backupNotRemoved: true))
        #expect(run.world.calls.suffix(5) == [.removeBackup, .detach, .cleanup, .waitUntilQuiet, .relaunch])
        #expect(run.world.notes.contains { $0.contains(InstallSteps.backupNotRemovedNote) })
        // The flow never saw a failure.
        #expect(run.box.state == .installing)
        #expect(!run.box.attempted.contains { if case .failure = $0 { true } else { false } })
    }

    /// The swap failed before anything was replaced: the current version is still installed, and everything is cleaned.
    @Test func aFailedReplaceFailsWithInstallFailedAndCleansUp() async {
        var script = World.Script()
        script.failures[.stageAndReplace] = SomeError()
        let run = await run(script)
        #expect(run.outcome == .failed(.installFailed))
        #expect(run.world.calls.suffix(3) == [.stageAndReplace, .detach, .cleanup])
        #expect(!run.world.calls.contains(.removeBackup))
        #expect(!run.world.calls.contains(.relaunch))
        #expect(run.box.state == .failed(.installFailed))
    }

    @Test(arguments: [UpdateFailure.installFailed, .appNotRestored])
    func aFailureThrownByTheInstallIsKept(failure: UpdateFailure) async {
        var script = World.Script()
        script.failures[.stageAndReplace] = failure
        let run = await run(script)
        #expect(run.outcome == .failed(failure))
        #expect(run.box.state == .failed(failure))
    }

    /// The note for a backup that stays beside the app is a plain sentence, and says what to expect.
    @Test func theBackupNoteSaysTheOldCopyWasLeftBesideTheApp() {
        #expect(InstallSteps.backupNotRemovedNote.contains("deleted"))
        #expect(InstallSteps.backupNotRemovedNote.contains("beside the app"))
        #expect(!InstallSteps.backupNotRemovedNote.contains("Trash"))
    }

    /// The app is replaced but couldn't be started again: that says the app was updated, not that nothing changed.
    @Test func aRelaunchThatFailsSaysTheAppWasUpdated() async {
        var script = World.Script()
        script.relaunches = false
        let run = await run(script)
        #expect(run.outcome == .failed(.relaunchFailed))
        #expect(run.box.state == .failed(.relaunchFailed))
        // Cleaned up first, then the relaunch was tried.
        #expect(run.world.calls.suffix(4) == [.detach, .cleanup, .waitUntilQuiet, .relaunch])
    }

    // MARK: The relaunch waits for a capture

    /// A capture, selection or recording started after Install was clicked is finished before the relaunch ends the
    /// process: the wait is the step before the relaunch, and the relaunch isn't started while it is going on.
    @Test func theRelaunchWaitsUntilNothingIsUnderWay() async {
        let waiting = Gate()
        let quiet = Gate()
        var script = World.Script()
        script.behaviors[.waitUntilQuiet] = {
            await waiting.open()
            await quiet.wait()
        }
        let world = World(script)
        let box = FlowBox()
        let attempt = box.begin(release)
        let task = Task { await world.steps().run(report: box.sink(attempt)) }
        await waiting.wait()
        // Give a relaunch that wrongly didn't wait every chance to happen.
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(world.calls.last == .waitUntilQuiet)
        #expect(!world.calls.contains(.relaunch))
        await quiet.open()
        let outcome = await task.value
        #expect(outcome == .installed(backupNotRemoved: false))
        #expect(world.calls.suffix(2) == [.waitUntilQuiet, .relaunch])
    }

    /// The image is ejected and the temporary files removed before the wait, which can take as long as a recording: the
    /// image isn't left mounted for it.
    @Test func theImageIsDetachedBeforeTheWait() async {
        let run = await run()
        let calls = run.world.calls
        let wait = calls.firstIndex(of: .waitUntilQuiet)
        #expect(wait != nil)
        for earlier in [Call.removeBackup, .detach, .cleanup] {
            let index = calls.firstIndex(of: earlier)
            #expect(index != nil && wait != nil && index! < wait!, "\(earlier)")
        }
    }

    /// Only an install that relaunches waits: a failure, a cancel or a hand-off never does.
    @Test(arguments: Call.verification)
    func aRunThatStopsEarlyNeverWaits(call: Call) async {
        var script = World.Script()
        script.failures[call] = UpdateFailure.imageRejected
        let run = await run(script)
        #expect(!run.world.calls.contains(.waitUntilQuiet))
    }

    @Test func aHandOffNeverWaits() async {
        var script = World.Script()
        script.writable = false
        let run = await run(script)
        #expect(!run.world.calls.contains(.waitUntilQuiet))
    }

    @Test func aFailedSwapNeverWaits() async {
        var script = World.Script()
        script.failures[.stageAndReplace] = UpdateFailure.installFailed
        let run = await run(script)
        #expect(!run.world.calls.contains(.waitUntilQuiet))
    }

    /// Deleting the old copy failing doesn't skip the wait: the new app is in place and is relaunched, after it.
    @Test func aRemovalFailureStillWaitsBeforeTheRelaunch() async {
        var script = World.Script()
        script.failures[.removeBackup] = SomeError()
        let run = await run(script)
        #expect(run.world.calls.suffix(2) == [.waitUntilQuiet, .relaunch])
    }

    /// Past `installStarted` the install can't be cancelled: a cancelled task doesn't stop it halfway.
    @Test func theInstallIsNotCancelledOncePastThePointOfNoReturn() async {
        var script = World.Script()
        script.behaviors[.stageAndReplace] = { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { await run(script) }
        let run = await task.value
        #expect(run.outcome == .installed(backupNotRemoved: false))
        #expect(run.world.calls.suffix(5) == [.removeBackup, .detach, .cleanup, .waitUntilQuiet, .relaunch])
    }

    @Test func aFailureAfterTheInstallStartedIsReportedFromInstalling() async {
        var script = World.Script()
        script.failures[.stageAndReplace] = SomeError()
        let run = await run(script)
        #expect(run.box.attempted.contains(.installStarted))
        #expect(run.box.accepted.last == .failure(.installFailed))
    }
}
