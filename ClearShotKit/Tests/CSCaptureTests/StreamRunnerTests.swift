import Synchronization
import Testing
@testable import CSCapture

/// The shared stream plumbing, without ScreenCaptureKit: event delivery around a stop, and serial updates.
struct StreamRunnerTests {
    @Test func eventsStopWhenTheStreamStops() async {
        let runner = StreamRunner(name: "Test stream", log: .init(category: "tests", sink: nil), state: 0)
        runner.deliver { $0 += 1 }
        await runner.stop()
        runner.deliver { $0 += 1 }
        #expect(runner.hasStopped)
        #expect(runner.withState { $0 } == 1)
        #expect(runner.runningStream() == nil)
    }

    @Test func anEndingEventIsTheLast() {
        let runner = StreamRunner(name: "Test stream", log: .init(category: "tests", sink: nil), state: [String]())
        runner.deliver { $0.append("frame") }
        runner.deliver(ending: true) { $0.append("stopped") }
        runner.deliver { $0.append("late frame") }
        runner.deliver(ending: true) { $0.append("stopped again") }
        #expect(runner.withState { $0 } == ["frame", "stopped"])
    }

    /// A pause and a quick resume: the resume waits for the slow pause, so the stream ends at the resume's rate.
    @Test func updatesRunOneAtATimeInTheOrderAsked() async {
        let updates = SerialUpdates()
        let log = Mutex<[String]>([])
        let first = Task {
            await updates.run {
                log.withLock { $0.append("pause begins") }
                try? await Task.sleep(for: .milliseconds(100))
                log.withLock { $0.append("pause ends") }
            }
        }
        while log.withLock({ $0.isEmpty }) {
            await Task.yield()
        }
        await updates.run {
            log.withLock { $0.append("resume") }
        }
        await first.value
        #expect(log.withLock { $0 } == ["pause begins", "pause ends", "resume"])
    }
}
