import Testing
@testable import CSCore

struct GenerationCounterTests {
    @Test func onlyTheLatestGenerationIsCurrent() {
        // The HUD's fade-out for message 1 must not hide message 2 shown during that fade.
        var counter = GenerationCounter()
        let first = counter.next()
        let second = counter.next()
        #expect(!counter.isCurrent(first))
        #expect(counter.isCurrent(second))
    }
}
