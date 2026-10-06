import AppKit
import CSCore
import CSScrolling

/// Auto-Scroll's hands: moves the cursor into the region, then scrolls the page under it step by step with continuous
/// scroll events at the region's centre, letting `AutoScrollPlanner` judge each step by how far the stitched page moved
/// (`AutoScrollStep`: once it settles). It pauses while the person has the pointer outside the region (that is how they
/// reach Done; nothing is ever posted with the pointer outside, where it would scroll something else) and ends when the
/// planner says the page stopped (`.finish`) or the stitch can't keep up (`.stop`). Stopping, for any reason, puts the
/// cursor back where it was.
final class AutoScrollDriver {
    private let axis: ScrollAxis
    /// AppKit global points.
    private let region: CGRect
    /// Where the events go, in CG global points: the region's centre.
    private let target: CGPoint
    private let layout: DisplayLayout
    private let pixelsPerPoint: Double
    private var planner: AutoScrollPlanner
    /// The step being taken; nil between steps.
    private var step: AutoScrollStep?
    private var task: Task<Void, Never>?
    /// The cursor as auto-scroll began (CG global points), to put back.
    private var savedCursor: CGPoint?
    private var isPaused = false
    private var isStopped = false

    /// Auto-scroll of `region` (AppKit global points) along `axis`.
    init(axis: ScrollAxis, region: CGRect, layout: DisplayLayout) {
        self.axis = axis
        self.region = region
        self.layout = layout
        target = layout.cgPoint(fromAppKit: CGPoint(x: region.midX, y: region.midY))
        pixelsPerPoint = Double(layout.display(bestMatching: region)?.scale ?? layout.main.scale)
        planner = AutoScrollPlanner(regionExtentPoints: Int((axis == .vertical ? region.height : region.width).rounded()))
    }

    /// Saves the cursor, moves it to the region's centre and starts scrolling. `onDecision` hears how auto-scroll ended:
    /// `.finish` (the page stopped moving: finish the capture) or `.stop` (go on by hand); the cursor is back by then.
    func start(onDecision: @escaping (AutoScrollPlanner.Decision) -> Void) {
        guard task == nil, !isStopped else { return }
        // From AppKit's position rather than `ScrollEventPoster.cursorLocationCG()`, which says (0, 0) when it fails.
        savedCursor = layout.cgPoint(fromAppKit: NSEvent.mouseLocation)
        ScrollEventPoster.warpCursor(toCG: target)
        task = Task { [weak self] in
            guard let decision = await self?.drive() else { return }
            self?.stop()
            onDecision(decision)
        }
    }

    /// A frame of the region was stitched.
    func noteUpdate(_ update: StitchUpdate) {
        step?.note(update, at: .now)
    }

    /// Holds the next scroll while the pointer is outside the region.
    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    /// Stops scrolling and puts the cursor back. Does nothing a second time.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        task?.cancel()
        task = nil
        step = nil
        if let savedCursor { ScrollEventPoster.warpCursor(toCG: savedCursor) }
        savedCursor = nil
    }

    // MARK: Private

    /// Takes the planner's steps until it says `.finish` or `.stop`; nil once stopped from outside.
    private func drive() async -> AutoScrollPlanner.Decision? {
        var decision = planner.firstStep
        while true {
            switch decision {
            case .step(let points):
                guard let step = await scroll(by: points) else { return nil }
                decision = planner.next(afterMoving: step.movedPoints(pixelsPerPoint: pixelsPerPoint))
            case .scrollBack(let points):
                // Undo the step; what the page does meanwhile counts for nothing. The planner has the next step ready.
                guard await scroll(by: -points) != nil else { return nil }
                decision = .step(points: planner.stepPoints)
            case .finish, .stop:
                return decision
            }
        }
    }

    /// Scrolls `points` toward the end of the page (negative: back), once auto-scroll isn't paused and the pointer is in
    /// the region, and waits for the page to settle. Returns what the step did; nil once stopped.
    private func scroll(by points: Int) async -> AutoScrollStep? {
        // Checked again here, with nothing awaited before the post: the cursor watch's pause can be up to 100 ms late, and
        // a scroll goes to whatever is under the pointer.
        while !Task.isCancelled, isPaused || !NSMouseInRect(NSEvent.mouseLocation, region, false) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled else { return nil }
        step = AutoScrollStep(startedAt: .now)
        ScrollEventPoster.post(axis: axis, points: Int32(clamping: points), atCG: target)
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
            guard let step else { return nil }
            if step.isSettled(at: .now) {
                self.step = nil
                return step
            }
        }
        return nil
    }
}
