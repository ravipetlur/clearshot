import CoreGraphics
import Foundation

/// Smart selection: ⌘-click selects the flat-colour region under the pointer, and Fit to Content (⌥A) moves the pixel
/// selection's edges in over the flat margin around what is in it. The work reads the cached `PicturePixels` and runs
/// off the main actor.
extension AnnotationEditor {
    /// How far a colour may differ from the reference and still count as flat, in the sampler's 0...255 channels.
    public nonisolated static let smartSelectionTolerance = 8
    /// The most pixels a ⌘-clicked region may have; a larger one selects nothing.
    public nonisolated static let smartSelectionMaxPixels = 8_000_000
    /// The largest area, in pixels, that a live preview of Fit to Content is worked out for while dragging.
    public static let fitPreviewMaxPixels = 1_000_000
    /// How long a notice stays up.
    static let pixelNoticeDuration = Duration.seconds(3)

    /// What a ⌘-click on the picture did.
    public enum FlatRegionResult: Equatable, Sendable {
        /// The region's bounds are now the pixel selection.
        case selected
        /// The region is over `smartSelectionMaxPixels`: nothing was selected, and a notice says so.
        case tooLarge
        /// The point is off the picture, or the picture can't be read, or it changed meanwhile.
        case nothing
    }

    /// Selects the bounds of the flat-colour region of the picture under `point` (base pixels).
    @discardableResult
    public func selectFlatRegion(at point: CGPoint) async -> FlatRegionResult {
        guard crop == nil, let pixels = await currentPicturePixels(), pixels.identity == document.picturePixelsIdentity else { return .nothing }
        let bounds = await Task.detached(priority: .userInitiated) {
            pixels.floodFillBounds(from: point, tolerance: Self.smartSelectionTolerance, maxPixels: Self.smartSelectionMaxPixels)
        }.value
        guard pixels.identity == document.picturePixelsIdentity else { return .nothing }
        guard let bounds else {
            // The fill only gives up for size inside the picture; outside it there was nothing to click.
            guard pixels.sampler.pixel(at: pixels.pixelPoint(fromBase: point)) != nil else { return .nothing }
            showPixelNotice("That region is too large to select (over 8 million pixels), so nothing is selected.")
            return .tooLarge
        }
        selectPixels(bounds)
        return .selected
    }

    /// Moves the pixel selection's `edges` in over the flat margin around its content (Edit › Fit Selection to Content).
    /// Returns whether the selection changed; it doesn't for a flat or already tight area.
    @discardableResult
    public func fitPixelSelectionToContent(edges: Set<RectEdge> = Set(RectEdge.allCases)) async -> Bool {
        guard let rect = pixelSelection, crop == nil, let pixels = await currentPicturePixels(),
              pixels.identity == document.picturePixelsIdentity else { return false }
        let fitted = await Task.detached(priority: .userInitiated) {
            pixels.fitBounds(of: rect, tolerance: Self.smartSelectionTolerance, edges: edges)
        }.value
        // Dropped if the selection or the picture moved on while it worked.
        guard pixelSelection == rect, pixels.identity == document.picturePixelsIdentity else { return false }
        selectPixels(fitted)
        return pixelSelection != rect
    }

    /// What `area` would fit to, for the preview outline while dragging a selection out; nil when the pixels aren't ready, the
    /// area is too large to measure within a frame (then no preview is drawn), or there is nothing to fit.
    public func fitPreview(of area: CGRect) -> CGRect? {
        guard let pixels = picturePixels, area.width * area.height <= Double(Self.fitPreviewMaxPixels) else { return nil }
        let fitted = pixels.fitBounds(of: area, tolerance: Self.smartSelectionTolerance)
        return fitted == area ? nil : fitted
    }

    /// Shows the outline `area` would fit to while it is dragged out, or clears it with nil.
    public func showFitPreview(of area: CGRect?) {
        fitPreviewOutline = area.flatMap { PixelSelection.clamped($0, in: document.baseSize) }.flatMap(fitPreview(of:))
    }

    /// Shows a short notice over the canvas for a few seconds.
    func showPixelNotice(_ text: String) {
        pixelNotice = text
        pixelNoticeTask?.cancel()
        pixelNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.pixelNoticeDuration) } catch { return }
            self?.pixelNotice = nil
        }
    }
}
