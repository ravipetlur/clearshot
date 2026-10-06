import Testing
@testable import CSCore

struct SingleInstancePolicyTests {
    @Test func handsOffToAnotherLiveCopy() {
        let running = [RunningInstance(pid: 10, isTerminated: false), RunningInstance(pid: 20, isTerminated: false)]
        #expect(SingleInstancePolicy.instanceToHandOffTo(running: running, currentPID: 20)?.pid == 10)
    }

    @Test func ignoresACopyThatHasAlreadyExited() {
        // `make run` kills the old copy just before launching; LaunchServices can still list it briefly.
        let running = [RunningInstance(pid: 10, isTerminated: true), RunningInstance(pid: 20, isTerminated: false)]
        #expect(SingleInstancePolicy.instanceToHandOffTo(running: running, currentPID: 20) == nil)
    }

    @Test func aloneMeansNoHandOff() {
        #expect(SingleInstancePolicy.instanceToHandOffTo(running: [RunningInstance(pid: 20, isTerminated: false)], currentPID: 20) == nil)
    }
}
