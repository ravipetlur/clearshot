import AppKit
import CSCapture
import CSCore

/// Capture Text: an area or a window picked as for Capture Area, whose text goes to the clipboard. It makes no history
/// item, runs no after-capture action and leaves Capture Previous Area's area alone.
extension CaptureFlow {
    /// `keepLineBreaks` nil follows the Keep line breaks setting (Capture Text); Capture Text With and Without Line Breaks
    /// pass true and false.
    func captureText(keepLineBreaks: Bool?) async {
        await run {
            guard let picked = try await self.selectImage() else { return }
            await self.presentText(picked.image, keepLineBreaks: keepLineBreaks)
        }
    }

    /// A URL's `capture-text` with an area (AppKit global points, clamped to `display`): read at once with no overlay.
    func captureText(at rect: CGRect, on display: DisplayInfo, keepLineBreaks: Bool?) async {
        await run {
            let layout = DisplayLayout.current()
            let image = try await self.service.captureArea(layout.localRect(rect, in: display), on: display,
                                                           rules: self.exclusionRules(), showsCursor: false)
            await self.presentText(image, keepLineBreaks: keepLineBreaks)
        }
    }
}
