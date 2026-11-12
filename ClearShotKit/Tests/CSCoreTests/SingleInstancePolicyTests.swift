import Testing
@testable import CSCore

struct SingleInstancePolicyTests {
    /// Another live copy is handed off to. A copy that has already exited is not: `make run` kills the old copy just
    /// before launching, and LaunchServices can still list it briefly. Alone, there is nothing to hand off to.
    @Test(arguments: [
        ([RunningInstance(pid: 10, isTerminated: false), RunningInstance(pid: 20, isTerminated: false)], Int32?(10)),
        ([RunningInstance(pid: 10, isTerminated: true), RunningInstance(pid: 20, isTerminated: false)], nil),
        ([RunningInstance(pid: 20, isTerminated: false)], nil),
    ])
    func handsOffOnlyToAnotherLiveCopy(running: [RunningInstance], expected: Int32?) {
        #expect(SingleInstancePolicy.instanceToHandOffTo(running: running, currentPID: 20)?.pid == expected)
    }
}
