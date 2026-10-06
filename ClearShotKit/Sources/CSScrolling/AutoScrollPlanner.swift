/// The closed loop behind Auto-Scroll: how far each step scrolls, judged by how far the page actually moved. Steps
/// start at 40% of the region's extent along the axis; a step that moved the page more than 60% shrinks the next so the
/// same movement would be 40%; a step with no verified match is scrolled back and halved (never below 10%). Auto-scroll
/// ends after five steps in a row without a move, stills and no-matches alike (only a move starts the count again):
/// five stills mean the end of the page, so the capture finishes; with a no-match among them, or after three no-matches
/// in a row, auto-scroll stops and the capture goes on by hand. Points along the axis.
public struct AutoScrollPlanner: Sendable {
    public enum Decision: Sendable, Equatable {
        /// Scroll this far toward the end of the page.
        case step(points: Int)
        /// Undo the step just taken (that far back); the next step is `stepPoints`.
        case scrollBack(points: Int)
        /// The page stopped moving: finish the capture.
        case finish
        /// Auto-scroll can't keep the stitch verified: stop scrolling, keep capturing.
        case stop
    }

    static let firstStepFraction = 0.4
    static let tooFarFraction = 0.6
    static let smallestStepFraction = 0.1
    static let stepsWithoutMovingToEnd = 5
    static let unmatchedStepsToStop = 3

    public private(set) var stepPoints: Int
    private let extent: Int
    private let smallestStep: Int
    /// Steps since the last move, stills and no-matches alike.
    private var stepsWithoutMoving = 0
    /// Whether any of those had no verified match.
    private var unmatchedSinceMoving = false
    /// No-matches in a row.
    private var unmatchedSteps = 0

    public init(regionExtentPoints: Int) {
        extent = max(1, regionExtentPoints)
        smallestStep = max(1, Int((Self.smallestStepFraction * Double(extent)).rounded()))
        stepPoints = max(smallestStep, Int((Self.firstStepFraction * Double(extent)).rounded()))
    }

    public var firstStep: Decision {
        .step(points: stepPoints)
    }

    /// The decision after a step of `stepPoints`, given how far the page moved (the accepted offsets since the step, in
    /// points); nil: no verified match after the step.
    public mutating func next(afterMoving movedPoints: Int?) -> Decision {
        guard let moved = movedPoints else {
            stepsWithoutMoving += 1
            unmatchedSinceMoving = true
            unmatchedSteps += 1
            if unmatchedSteps >= Self.unmatchedStepsToStop || stepsWithoutMoving >= Self.stepsWithoutMovingToEnd {
                return .stop
            }
            let taken = stepPoints
            stepPoints = max(smallestStep, stepPoints / 2)
            return .scrollBack(points: taken)
        }
        unmatchedSteps = 0
        guard moved > 0 else {
            stepsWithoutMoving += 1
            guard stepsWithoutMoving >= Self.stepsWithoutMovingToEnd else { return .step(points: stepPoints) }
            return unmatchedSinceMoving ? .stop : .finish
        }
        stepsWithoutMoving = 0
        unmatchedSinceMoving = false
        if Double(moved) > Self.tooFarFraction * Double(extent) {
            let scaled = Double(stepPoints) * Self.firstStepFraction * Double(extent) / Double(moved)
            stepPoints = max(smallestStep, Int(scaled.rounded()))
        }
        return .step(points: stepPoints)
    }
}
