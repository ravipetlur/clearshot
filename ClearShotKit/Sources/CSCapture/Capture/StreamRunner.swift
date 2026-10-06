import CoreGraphics
import CSCore
import Foundation
import ScreenCaptureKit
import Synchronization

/// A stream's life, kept under its runner's lock: it starts at most once, never after it stopped, and delivers events
/// only until it stops.
struct StreamLifecycle {
    private(set) var hasStarted = false
    /// `stop` began, or the stream ended by itself.
    private(set) var hasStopped = false

    /// Whether `start` may go ahead: true at most once, and never after `stop`.
    mutating func claimStart() -> Bool {
        guard !hasStarted, !hasStopped else { return false }
        hasStarted = true
        return true
    }

    mutating func stop() {
        hasStopped = true
    }
}

/// The run-once life of one ScreenCaptureKit stream, shared by `RegionStream` and `ScreenRecordingStream`: it starts at
/// most once and never after `stop`; `stop` stops whatever started, even a stream still starting; and the owner's
/// events go out only under its lock while the stream hasn't stopped, so none slips out once `stop` begins.
///
/// `State` is the owner's own state, kept under the same lock (the recording stream's clock and last sample time).
final class StreamRunner<State>: @unchecked Sendable {
    private let name: String
    private let log: AppLogger
    private let lifecycle = Mutex(StreamLifecycle())
    /// The running stream; only touched while holding `lifecycle`.
    private var stream: SCStream?
    /// Only touched while holding `lifecycle`.
    private var state: State

    /// `name` starts the log lines ("Region stream").
    init(name: String, log: AppLogger, state: State) {
        self.name = name
        self.log = log
        self.state = state
    }

    /// `stop` began, or the stream ended by itself.
    var hasStopped: Bool {
        lifecycle.withLock { $0.hasStopped }
    }

    /// Reads or changes the owner's state under the lock.
    func withState<Result: Sendable>(_ body: (inout State) -> Result) -> Result {
        lifecycle.withLock { _ in body(&state) }
    }

    /// Runs `body` under the lock unless the stream has stopped: how events reach the owner's handlers. With `ending`
    /// the stream is marked stopped at the same moment, so nothing follows.
    func deliver(ending: Bool = false, _ body: (inout State) -> Void) {
        lifecycle.withLock { lifecycle in
            guard !lifecycle.hasStopped else { return }
            if ending {
                lifecycle.stop()
            }
            body(&state)
        }
    }

    /// Starts once: checks Screen Recording permission, fetches every window (on screen or not), finds the display, has
    /// `makeStream` build the stream (its filter, configuration and outputs), starts it, then lets `started` note it in
    /// the state. A second call, or one after `stop`, does nothing. Fetch and start errors go through `mapError`.
    func start<Failure: Error>(display displayID: UInt32, permissionDenied: Failure, displayNotFound: Failure,
                               mapError: (any Error) -> Failure,
                               makeStream: (SCShareableContent, SCDisplay) throws -> SCStream,
                               started: (SCStream, inout State) -> Void = { _, _ in }) async throws(Failure) {
        guard lifecycle.withLock({ $0.claimStart() }) else { return }
        guard CGPreflightScreenCaptureAccess() else { throw permissionDenied }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw mapError(error)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw displayNotFound }
        let startedStream: SCStream
        do {
            startedStream = try makeStream(content, display)
            try await startedStream.startCapture()
        } catch {
            throw mapError(error)
        }
        let stoppedMeanwhile = lifecycle.withLock { lifecycle -> Bool in
            started(startedStream, &state)
            if !lifecycle.hasStopped {
                stream = startedStream
            }
            return lifecycle.hasStopped
        }
        // `stop` ran while this was starting, so it found no stream to stop (or the stream already ended): stop it now.
        if stoppedMeanwhile {
            try? await startedStream.stopCapture()
        }
    }

    /// The stream while it runs (started and not stopped).
    func runningStream() -> SCStream? {
        var running: SCStream?
        lifecycle.withLock { lifecycle in
            running = lifecycle.hasStopped ? nil : stream
        }
        return running
    }

    /// Marks the stream stopped and waits until ScreenCaptureKit has stopped it. Events still in flight are dropped.
    func stop() async {
        var running: SCStream?
        lifecycle.withLock { lifecycle in
            lifecycle.stop()
            running = stream
            stream = nil
        }
        guard let running else { return }
        do {
            try await running.stopCapture()
        } catch {
            // Expected after the stream ended by itself.
            log.debug("\(name): stopCapture failed: \(error.localizedDescription)")
        }
    }
}

/// Runs async updates one at a time, in the order they were asked for: each waits for the one before it to finish.
final class SerialUpdates: Sendable {
    /// The latest update, which the next one waits for.
    private let last = Mutex<Task<Void, Never>?>(nil)

    /// Returns once `update` has run, after every update asked for before it.
    func run(_ update: @escaping @Sendable () async -> Void) async {
        let next = last.withLock { last -> Task<Void, Never> in
            let previous = last
            let next = Task {
                await previous?.value
                await update()
            }
            last = next
            return next
        }
        await next.value
    }
}
