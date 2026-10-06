import CoreGraphics
import CSCore
import Testing
@testable import CSCapture

/// Toggle fullscreen, as All-In-One's toolbar and a recording's Ready toolbar both use it.
struct FullscreenToggleTests {
    static let main = AdjustableSelectionTests.main
    static let portrait = AdjustableSelectionTests.portrait
    let area = CGRect(x: 100, y: 100, width: 400, height: 300)

    func selection(_ rect: CGRect, on display: DisplayInfo = Self.main) -> AdjustableSelection {
        var selection = AdjustableSelection(displays: [Self.main, Self.portrait])
        selection.setRect(rect, onDisplay: display.id)
        return selection
    }

    @Test func fillsTheDisplayAndBringsTheSelectionBack() {
        var toggle = FullscreenToggle()
        var selection = selection(area)
        toggle.toggle(&selection)
        #expect(selection.rect == Self.main.frame)
        #expect(selection.display == Self.main)
        toggle.toggle(&selection)
        #expect(selection.rect == area)
        // And again: the selection it brought back is saved anew.
        toggle.toggle(&selection)
        #expect(selection.rect == Self.main.frame)
        toggle.toggle(&selection)
        #expect(selection.rect == area)
    }

    @Test func aSelectionThatFillsItsDisplayWithNothingSavedStays() {
        var toggle = FullscreenToggle()
        var full = selection(Self.main.frame)
        toggle.toggle(&full)
        #expect(full.rect == Self.main.frame)

        // Nothing to fill without a selection, or while one is being dragged out.
        var none = AdjustableSelection(displays: [Self.main, Self.portrait])
        toggle.toggle(&none)
        #expect(none.rect == nil)
        var dragging = AdjustableSelection(displays: [Self.main, Self.portrait])
        dragging.mouseDown(at: CGPoint(x: 100, y: 100), modifiers: [])
        dragging.mouseDragged(to: CGPoint(x: 500, y: 400), modifiers: [])
        let beforeToggle = dragging.rect
        toggle.toggle(&dragging)
        #expect(dragging.rect == beforeToggle)
        #expect(dragging.phase == .dragging)
    }

    /// The saved selection comes back only on the display it was on.
    @Test func theSavedSelectionBelongsToItsDisplay() {
        var toggle = FullscreenToggle()
        var selection = selection(area)
        toggle.toggle(&selection)
        selection.setRect(Self.portrait.frame, onDisplay: Self.portrait.id)
        toggle.toggle(&selection)
        #expect(selection.rect == Self.portrait.frame)
        #expect(selection.display == Self.portrait)
    }
}
