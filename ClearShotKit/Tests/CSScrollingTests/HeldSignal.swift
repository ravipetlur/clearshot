import Synchronization

/// What a test's estimator gives once the stitching queue is inside it, and the bounded wait for that.
///
/// The wait polls rather than suspending on a continuation: a continuation ignores cancellation, so a queue that never
/// reached the estimator would hang the whole suite, and a semaphore wait would block one of the few threads the other
/// tests of a loaded suite run on. A poll holds no thread, ends when its task is cancelled, and gives up at a timeout
/// that is far longer than a slow stitching queue takes to start.
final class HeldSignal: Sendable {
    private let given = Mutex(false)

    func give() {
        given.withLock { $0 = true }
    }

    /// True once the signal has been given; false when `timeout` passes first or the waiting task is cancelled. The
    /// signal is checked before the deadline and the cancellation, so one given in time is never reported missed.
    func wait(timeout: Duration = .seconds(300)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if given.withLock({ $0 }) { return true }
            if Task.isCancelled || ContinuousClock.now >= deadline { return false }
            // A cancelled sleep throws at once; the next turn of the loop sees the cancellation.
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
