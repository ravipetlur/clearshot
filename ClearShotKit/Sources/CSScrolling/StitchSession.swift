import CoreGraphics
import CSCore
import Dispatch
import Synchronization

/// Runs a `Stitcher` on a private serial queue for a live capture. Frames can be submitted from any thread; at most
/// one waits while a frame is being stitched (a newer one replaces it), so slow stitching never builds a backlog. After
/// each frame, `onUpdate` gets the update and, when the frame was accepted, a copy of the live preview. The update's
/// trace says how many frames were replaced unseen before it and how long it took.
public final class StitchSession: @unchecked Sendable {
    /// Frames waiting to be stitched, shared between `submit` and the queue.
    private struct Inbox {
        var waiting: StitchFrame?
        /// Frames replaced while waiting since the last one taken.
        var replaced = 0
        var draining = false
        var closed = false
        var cancelled = false
    }

    private let queue = DispatchQueue(label: CSCore.identifier("stitching"), qos: .userInitiated)
    private let inbox = Mutex(Inbox())
    private let onUpdate: @Sendable (StitchUpdate, CGImage?) -> Void
    /// Only touched on `queue`; nil once cancelled or finished.
    private var stitcher: Stitcher?

    /// `previewSide` is the preview's size across the axis in pixels (less for narrower frames: it is never scaled up).
    /// `onUpdate` is called on the session's queue.
    public init(stitcher: Stitcher, previewSide: Int,
                onUpdate: @escaping @Sendable (StitchUpdate, CGImage?) -> Void) {
        var stitcher = stitcher
        stitcher.showPreview(side: previewSide)
        self.stitcher = stitcher
        self.onUpdate = onUpdate
    }

    /// Queues `frame`, replacing one still waiting. Ignored after `finish` or `cancel`.
    public func submit(_ frame: StitchFrame) {
        let startDraining = inbox.withLock { inbox -> Bool in
            guard !inbox.closed else { return false }
            if inbox.waiting != nil { inbox.replaced += 1 }
            inbox.waiting = frame
            guard !inbox.draining else { return false }
            inbox.draining = true
            return true
        }
        if startDraining {
            queue.async { self.drain() }
        }
    }

    /// The capture, once the frames already submitted are stitched; nil when none was accepted, or after `cancel`.
    public func finish() async -> CGImage? {
        inbox.withLock { $0.closed = true }
        return await withCheckedContinuation { (done: CheckedContinuation<CGImage?, Never>) in
            queue.async {
                self.drain()
                let image = self.isCancelled ? nil : self.stitcher?.compose()
                self.stitcher = nil
                done.resume(returning: image)
            }
        }
    }

    /// Drops the waiting frame and everything stitched; later frames are ignored and `finish` gives nil.
    public func cancel() {
        inbox.withLock { inbox in
            inbox.closed = true
            inbox.cancelled = true
            inbox.waiting = nil
        }
        queue.async { self.stitcher = nil }
    }

    private var isCancelled: Bool {
        inbox.withLock { $0.cancelled }
    }

    /// Stitches waiting frames until none is left. On the queue.
    private func drain() {
        while let (frame, skipped) = nextFrame() {
            let start = ContinuousClock.now
            guard var update = stitcher?.add(frame) else { continue }
            let preview = update.accepted ? stitcher?.previewImage() : nil
            guard !isCancelled else { continue }
            let elapsed = start.duration(to: .now).components
            update.trace?.milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            update.trace?.framesSkipped = skipped
            onUpdate(update, preview)
        }
    }

    /// The waiting frame and how many were replaced before it.
    private func nextFrame() -> (StitchFrame, skipped: Int)? {
        inbox.withLock { inbox -> (StitchFrame, skipped: Int)? in
            guard let frame = inbox.waiting else {
                inbox.draining = false
                return nil
            }
            defer {
                inbox.waiting = nil
                inbox.replaced = 0
            }
            return (frame, inbox.replaced)
        }
    }
}
