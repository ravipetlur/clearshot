import Testing
@testable import CSScrolling

struct ScrollingControlStateTests {
    @Test func startStopStartsFromReadyFinishesWhileCapturingAndIgnoresSelecting() {
        var state = ScrollingControlState(phase: .ready)
        #expect(state.startStop() == .start)
        #expect(state.phase == .capturing)
        #expect(state.startStop() == .finish)
        #expect(state.phase == .finishing)
        // Finishing, selecting (no region yet) and no session at all: nothing happens.
        for phase: ScrollingControlState.Phase in [.finishing, .selecting, .none] {
            var other = ScrollingControlState(phase: phase)
            #expect(other.startStop() == .none)
            #expect(other.phase == phase)
        }
        #expect(ScrollingControlState().phase == .none)
    }
}
