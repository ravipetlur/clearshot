import Testing
@testable import CSScrolling

struct AutoScrollPlannerTests {
    @Test func theFirstStepIsFortyPercent() {
        let planner = AutoScrollPlanner(regionExtentPoints: 1000)
        #expect(planner.firstStep == .step(points: 400))
        #expect(planner.stepPoints == 400)
    }

    @Test func aStepThatMovedTooFarShrinksTheNextOne() {
        var planner = AutoScrollPlanner(regionExtentPoints: 1000)
        // 400 points of wheel moved the page 800: the next step is scaled so the same movement would be 400.
        #expect(planner.next(afterMoving: 800) == .step(points: 200))
        #expect(planner.stepPoints == 200)
        // Up to 60% of the extent counts as fine: the step stays.
        #expect(planner.next(afterMoving: 600) == .step(points: 200))
    }

    @Test func fiveStillStepsFinish() {
        var planner = AutoScrollPlanner(regionExtentPoints: 1000)
        for _ in 1...4 {
            #expect(planner.next(afterMoving: 0) == .step(points: 400))
        }
        #expect(planner.next(afterMoving: 0) == .finish)
    }

    @Test func aMoveResetsTheStillCount() {
        var planner = AutoScrollPlanner(regionExtentPoints: 1000)
        for _ in 1...4 {
            #expect(planner.next(afterMoving: 0) == .step(points: 400))
        }
        #expect(planner.next(afterMoving: 380) == .step(points: 400))
        for _ in 1...4 {
            #expect(planner.next(afterMoving: 0) == .step(points: 400))
        }
        #expect(planner.next(afterMoving: 0) == .finish)
    }

    @Test func fiveStepsWithoutMovingStopEvenWhenStillsAndNoMatchesAlternate() {
        // Only a move resets the count: stills and no-matches both count toward the end of auto-scroll. With a
        // no-match among them the end of the page isn't verified, so auto-scroll stops and the capture goes on by hand.
        var planner = AutoScrollPlanner(regionExtentPoints: 1000)
        #expect(planner.next(afterMoving: 0) == .step(points: 400))
        #expect(planner.next(afterMoving: nil) == .scrollBack(points: 400))
        #expect(planner.next(afterMoving: 0) == .step(points: 200))
        #expect(planner.next(afterMoving: nil) == .scrollBack(points: 200))
        #expect(planner.next(afterMoving: 0) == .stop)

        var startingWithNoMatch = AutoScrollPlanner(regionExtentPoints: 1000)
        #expect(startingWithNoMatch.next(afterMoving: nil) == .scrollBack(points: 400))
        #expect(startingWithNoMatch.next(afterMoving: 0) == .step(points: 200))
        #expect(startingWithNoMatch.next(afterMoving: nil) == .scrollBack(points: 200))
        #expect(startingWithNoMatch.next(afterMoving: 0) == .step(points: 100))
        #expect(startingWithNoMatch.next(afterMoving: nil) == .stop)

        // A move starts the count again.
        var interrupted = AutoScrollPlanner(regionExtentPoints: 1000)
        for moved: Int? in [0, nil, 0, nil] { _ = interrupted.next(afterMoving: moved) }
        #expect(interrupted.next(afterMoving: 50) == .step(points: 100))
        for _ in 1...4 { #expect(interrupted.next(afterMoving: 0) == .step(points: 100)) }
        #expect(interrupted.next(afterMoving: 0) == .finish)
    }

    @Test func noMatchScrollsBackAndHalves() {
        var planner = AutoScrollPlanner(regionExtentPoints: 1000)
        #expect(planner.next(afterMoving: nil) == .scrollBack(points: 400))
        #expect(planner.stepPoints == 200)
        #expect(planner.next(afterMoving: nil) == .scrollBack(points: 200))
        #expect(planner.stepPoints == 100)
    }

    @Test func threeNoMatchesInARowStop() {
        var planner = AutoScrollPlanner(regionExtentPoints: 1000)
        #expect(planner.next(afterMoving: nil) == .scrollBack(points: 400))
        #expect(planner.next(afterMoving: nil) == .scrollBack(points: 200))
        #expect(planner.next(afterMoving: nil) == .stop)

        // A verified step in between breaks the run.
        var interrupted = AutoScrollPlanner(regionExtentPoints: 1000)
        #expect(interrupted.next(afterMoving: nil) == .scrollBack(points: 400))
        #expect(interrupted.next(afterMoving: nil) == .scrollBack(points: 200))
        #expect(interrupted.next(afterMoving: 90) == .step(points: 100))
        #expect(interrupted.next(afterMoving: nil) == .scrollBack(points: 100))
    }

    @Test func theStepNeverDropsBelowTenPercent() {
        var planner = AutoScrollPlanner(regionExtentPoints: 1000)
        #expect(planner.next(afterMoving: nil) == .scrollBack(points: 400))
        #expect(planner.next(afterMoving: nil) == .scrollBack(points: 200))
        #expect(planner.next(afterMoving: 100) == .step(points: 100))
        #expect(planner.next(afterMoving: nil) == .scrollBack(points: 100))
        #expect(planner.stepPoints == 100)
        // Shrinking after a long movement stops at 10% too.
        var fast = AutoScrollPlanner(regionExtentPoints: 1000)
        #expect(fast.next(afterMoving: 990) == .step(points: 162))
        #expect(fast.next(afterMoving: 990) == .step(points: 100))
    }
}
