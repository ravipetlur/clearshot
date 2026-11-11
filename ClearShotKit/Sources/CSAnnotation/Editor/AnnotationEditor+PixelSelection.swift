import CoreGraphics

/// The pixel-area selection: the edits behind the editor's keys, in whole base pixels, clamped to the picture.
extension AnnotationEditor {
    /// The base image's size, which a pixel selection stays inside.
    private var pictureBounds: CGSize { document.baseSize }

    /// Selects a pixel area (fitted to the picture, on whole pixels), or clears the selection with nil or an area outside
    /// the picture. Selecting pixels deselects objects. Not an undo step: it is a view of the picture, like the zoom.
    public func selectPixels(_ rect: CGRect?) {
        guard let rect, crop == nil, let fitted = PixelSelection.clamped(rect, in: pictureBounds) else {
            pixelSelection = nil
            return
        }
        selection = []
        pixelSelection = fitted
    }

    public func clearPixelSelection() {
        pixelSelection = nil
    }

    /// The pixel selection's size, as "120 × 80" for the badge on the canvas.
    public var pixelSelectionSizeText: String? {
        pixelSelection.map { "\(Int($0.width)) × \(Int($0.height))" }
    }

    /// Arrow keys: moves the selection by `delta` pixels in the directions shown on screen. Returns whether there was one.
    @discardableResult
    public func nudgePixelSelection(by delta: CGVector) -> Bool {
        guard let rect = pixelSelection else { return false }
        let scale = document.pixelScale
        pixelSelection = PixelSelection.nudged(rect, by: baseVector(fromPoints: CGVector(dx: delta.dx / scale, dy: delta.dy / scale)),
                                               in: pictureBounds)
        return true
    }

    /// ⌘-arrow keys: moves the right and bottom edges by `delta` pixels (in the picture's own axes).
    @discardableResult
    public func resizePixelSelection(by delta: CGVector) -> Bool {
        guard let rect = pixelSelection else { return false }
        pixelSelection = PixelSelection.resized(rect, by: delta, in: pictureBounds)
        return true
    }

    /// `[` and `]`: every side out by `amount` pixels (negative: in).
    @discardableResult
    public func growPixelSelection(by amount: Double) -> Bool {
        guard let rect = pixelSelection else { return false }
        pixelSelection = PixelSelection.grown(rect, by: amount, in: pictureBounds)
        return true
    }
}
