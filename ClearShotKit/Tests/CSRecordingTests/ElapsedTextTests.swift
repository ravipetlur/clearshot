import Testing
@testable import CSRecording

struct ElapsedTextTests {
    @Test func formatsMinutesSecondsAndHours() {
        #expect(ElapsedText.string(seconds: 0) == "0:00")
        #expect(ElapsedText.string(seconds: 7) == "0:07")
        #expect(ElapsedText.string(seconds: 7.9) == "0:07")
        #expect(ElapsedText.string(seconds: 754) == "12:34")
        #expect(ElapsedText.string(seconds: 3599) == "59:59")
        #expect(ElapsedText.string(seconds: 3723) == "1:02:03")
        #expect(ElapsedText.string(seconds: -3) == "0:00")
    }
}
