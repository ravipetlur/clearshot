import CoreGraphics
import Testing
@testable import CSScrolling

/// These only build events and read their fields. Never post one from a test: it would scroll the user's apps.
struct ScrollEventPosterTests {
    let centre = CGPoint(x: -900, y: 1310)

    @Test func aVerticalStepIsAContinuousPixelScrollThatRevealsContentBelow() throws {
        let event = try #require(ScrollEventPoster.makeEvent(axis: .vertical, points: 120, atCG: centre))
        #expect(event.type == .scrollWheel)
        #expect(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
        // Negative is "scroll down": the content moves up and what was below comes into view.
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -120)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0)
    }

    @Test func aHorizontalStepUsesTheSecondWheel() throws {
        let event = try #require(ScrollEventPoster.makeEvent(axis: .horizontal, points: 120, atCG: centre))
        #expect(event.type == .scrollWheel)
        #expect(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -120)

        // A step back (negative points) reverses the sign.
        let back = try #require(ScrollEventPoster.makeEvent(axis: .horizontal, points: -40, atCG: centre))
        #expect(back.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 40)
    }

    @Test func theEventCarriesTheRegionCentre() throws {
        let event = try #require(ScrollEventPoster.makeEvent(axis: .vertical, points: 120, atCG: centre))
        #expect(event.location == centre)
    }
}
