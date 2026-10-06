import CoreGraphics
import CSCapture
import Foundation

/// Crop & Resize mode's state: the pending crop and its ratio, and the area the canvas shows meanwhile, all in output
/// pixels.
public struct CropSession: Equatable, Sendable {
    public var rect: CGRect
    public var ratio: CropRatio
    public var viewport: CGRect
    /// The canvas the crop started from, kept in step with the document's. A crop still equal to it is untouched.
    public internal(set) var canvas: CGRect

    /// `canvas` is the canvas the crop started from; a session made without one starts from `rect`.
    public init(rect: CGRect, ratio: CropRatio, viewport: CGRect, canvas: CGRect? = nil) {
        self.rect = rect
        self.ratio = ratio
        self.viewport = viewport
        self.canvas = canvas ?? rect
    }

    /// The person hasn't cropped: the crop is the canvas. Leaving the mode then records nothing, and the crop follows the
    /// canvas when auto-expand grows it. A crop that has been dragged stands, wherever the canvas goes.
    public var isUntouched: Bool { rect == canvas }
}

/// The canvas and the picture: Crop & Resize, rotate and flip, resize, Revert to Original and the canvas fill. They are
/// canvas changes (`changeCanvas`): none of them auto-expands the canvas.
extension AnnotationEditor {
    // MARK: Crop & Resize

    /// The pending crop's fixed ratio (width ÷ height), if it has one.
    public var cropAspect: Double? {
        crop?.ratio.aspect(pictureSize: document.transform.outputSize)
    }

    /// Starts the mode on the current canvas. `tool` calls it on switching to `.crop`; `previous` is the tool to come back to.
    /// While a live change is open (a drag, a slider, a text edit) there is no session: the caller ends the edit first.
    func beginCrop(from previous: EditorTool) {
        toolBeforeCrop = previous
        guard !isInLiveChange else { return }
        crop = freshCropSession(ratio: .freeform)
    }

    /// Makes the session crop mode lacks, when switching to `.crop` happened under a live change (a text being typed, a drag,
    /// a slider) and so started none. Ending or cancelling the live change calls it, and so does the canvas once it has
    /// ended a text edit. Keeps the tool to come back to; does nothing outside crop mode, with a session already running, or
    /// while a live change is still open.
    public func ensureCropSession() {
        guard tool == .crop, crop == nil, !isInLiveChange else { return }
        crop = freshCropSession(ratio: .freeform)
    }

    private func freshCropSession(ratio: CropRatio) -> CropSession {
        let rect = document.canvasBounds
        return CropSession(rect: rect, ratio: ratio, viewport: CropGeometry.viewport(for: document, crop: rect), canvas: rect)
    }

    /// An object change has maybe grown the canvas (auto-expand) while a crop is pending: the session's starting canvas
    /// becomes the new one, and a crop that was still the canvas becomes it too, so leaving the mode doesn't cut the
    /// expansion away. A crop the person has dragged stands (it may cut through objects); the viewport grows to show it all.
    func syncCropSessionToCanvas() {
        guard var session = crop else { return }
        let canvas = document.canvasBounds
        guard canvas != session.canvas else { return }
        if session.isUntouched { session.rect = canvas }
        session.canvas = canvas
        session.viewport = viewport(growing: session.viewport, toHold: session.rect)
        crop = session
    }

    /// `viewport` grown to show what a crop at `rect` needs shown, but never past `AnnotationDocument.maximumSide` on a side:
    /// on an axis where the union would, the surroundings of `rect` alone stand.
    private func viewport(growing viewport: CGRect, toHold rect: CGRect) -> CGRect {
        let wanted = CropGeometry.viewport(for: document, crop: rect)
        var grown = viewport.union(wanted)
        let limit = AnnotationDocument.maximumSide
        if grown.width > limit { grown = CGRect(x: wanted.minX, y: grown.minY, width: wanted.width, height: grown.height) }
        if grown.height > limit { grown = CGRect(x: grown.minX, y: wanted.minY, width: grown.width, height: wanted.height) }
        return grown
    }

    /// Starts the pending crop over from the document's canvas, keeping its ratio: after undo or redo, and Revert to Original.
    func resetCropSession() {
        guard let session = crop else { return }
        crop = freshCropSession(ratio: session.ratio)
    }

    /// Moves the pending crop (a handle drag or a move), limited by `CropGeometry.clamped`. `final` is the end of a drag:
    /// the viewport then grows if the crop has come near its edge, so the next drag can reach further out.
    public func updateCrop(_ rect: CGRect, final: Bool = false) {
        guard var session = crop else { return }
        session.rect = CropGeometry.clamped(rect)
        if final {
            let margin = max(session.viewport.width, session.viewport.height) * 0.05
            if !session.viewport.insetBy(dx: margin, dy: margin).contains(session.rect) {
                session.viewport = viewport(growing: session.viewport, toHold: session.rect)
            }
        }
        crop = session
    }

    /// Picks a ratio. A fixed one reshapes the pending crop to it about its centre.
    public func setCropRatio(_ ratio: CropRatio) {
        guard var session = crop else { return }
        session.ratio = ratio
        if let aspect = ratio.aspect(pictureSize: document.transform.outputSize) {
            session.rect = CropGeometry.conformed(session.rect, aspect: aspect)
        }
        crop = session
    }

    /// Return or Apply: the pending crop becomes the canvas as one undo step, and the tool from before the mode comes back.
    /// Ignored while a live change is open.
    public func applyCrop() {
        guard !isInLiveChange else { return }
        commitCrop()
        if tool == .crop { tool = toolBeforeCrop }
    }

    /// Esc or Cancel: the canvas stays as it was, and the tool from before the mode comes back.
    public func cancelCrop() {
        crop = nil
        if tool == .crop { tool = toolBeforeCrop }
    }

    /// Ends the session, writing its crop. A crop of exactly the picture clears `canvasRect`; one that changes nothing
    /// records nothing, and neither does one the person never touched, whatever the canvas it started from (fractions of a
    /// pixel, under the minimum crop). Ignored while a live change is open: the session stays.
    func commitCrop() {
        guard let session = crop, !isInLiveChange else { return }
        crop = nil
        guard !session.isUntouched else { return }
        let rect = CropGeometry.clamped(session.rect)
        let canvas: CGRect? = rect == document.pictureBounds ? nil : rect
        guard canvas != document.canvasRect else { return }
        changeCanvas("Crop") { $0.canvasRect = canvas }
    }

    // MARK: Rotate, flip, resize, revert

    public func rotateLeft() { applyImageOp(.rotateLeft, actionName: "Rotate Left") }
    public func rotateRight() { applyImageOp(.rotateRight, actionName: "Rotate Right") }
    public func flipHorizontally() { applyImageOp(.flipHorizontal, actionName: "Flip Horizontal") }
    public func flipVertically() { applyImageOp(.flipVertical, actionName: "Flip Vertical") }

    /// The largest output size Resize can give: the one for which the picture's share of it stays within
    /// `AnnotationDocument.maximumOutputSide` on each axis. That is the output limit itself while the output (the
    /// canvas, or the background's frame) is at least the picture, and less on a crop of it, since the whole picture
    /// scales with the output. Whole pixels.
    public var resizeLimit: CGSize {
        let limit = AnnotationDocument.maximumOutputSide
        let canvas = outputBounds.size, picture = document.transform.outputSize
        func side(canvas: Double, picture: Double) -> Double {
            guard canvas.isFinite, picture.isFinite, canvas > 0, picture > 0 else { return limit }
            return min(limit, max(1, (limit * canvas / picture).rounded(.down)))
        }
        return CGSize(width: side(canvas: canvas.width, picture: picture.width),
                      height: side(canvas: canvas.height, picture: picture.height))
    }

    /// `width` × `height` as Resize will take them: each within 1…16 383, then, if that is more than `resizeLimit`, both
    /// scaled down together so the requested proportions hold.
    private func resizeRequest(width: Int, height: Int) -> CGSize {
        let width = Double(ImageResize.clamped(width)), height = Double(ImageResize.clamped(height))
        let limit = resizeLimit
        guard width > limit.width || height > limit.height else { return CGSize(width: width, height: height) }
        let factor = min(limit.width / width, limit.height / height)
        return CGSize(width: min(limit.width, max(1, (width * factor).rounded())),
                      height: min(limit.height, max(1, (height * factor).rounded())))
    }

    /// Resize: the output (`outputBounds`: the canvas, or the background's frame) to `width` × `height` pixels, each
    /// clamped to 1…16 383 and to `resizeLimit`. The picture takes its share of that
    /// (`AnnotationDocument.imageOp(for:itemScale:outputSize:)`), and the annotations scale with it and stay editable.
    /// Without a background an explicit canvas ends up exactly that size, on whole pixels, so the export is the size
    /// asked for. With one the padding and inset scale too but round to whole pixels, so an explicit canvas is pinned
    /// to its own share of the request instead, and the frame lands within a pixel or two of it. A resize to the
    /// current size records nothing.
    public func resizeImage(width: Int, height: Int) {
        let size = resizeRequest(width: width, height: height)
        let output = outputBounds.size
        guard size != output,
              case .resize(let pictureWidth, let pictureHeight) = document.imageOp(
                  for: .resize(width: Int(size.width), height: Int(size.height)), itemScale: 1, outputSize: output)
        else { return }
        var canvasSize = size
        if document.background != nil {
            let canvas = document.canvasBounds.size
            canvasSize = CGSize(width: max(1, (canvas.width * size.width / max(output.width, 1)).rounded()),
                                height: max(1, (canvas.height * size.height / max(output.height, 1)).rounded()))
        }
        applyImageOp(.resize(width: ImageResize.clamped(pictureWidth), height: ImageResize.clamped(pictureHeight)),
                     actionName: "Resize Image", canvasSize: canvasSize)
    }

    /// One image operation as one undo step. An explicit canvas moves with the picture (`applying`), and so does a crop
    /// being edited, unless it is the untouched canvas, which it follows. `canvasSize`, for Resize, pins an explicit canvas
    /// to exactly that size on whole pixels (its origin rounded), which the scaling of the picture leaves a fraction off.
    /// Ignored while a live change is open.
    func applyImageOp(_ op: ImageOp, actionName: String, canvasSize: CGSize? = nil) {
        guard !isInLiveChange else { return }
        let before = document.transform
        let wasUntouched = crop?.isUntouched ?? false
        changeCanvas(actionName) { document in
            document = document.applying(op)
            if let canvasSize, let canvas = document.canvasRect {
                document.canvasRect = CGRect(x: canvas.minX.rounded(), y: canvas.minY.rounded(),
                                             width: canvasSize.width, height: canvasSize.height)
            }
        }
        guard var session = crop else { return }
        session.canvas = document.canvasBounds
        if wasUntouched {
            session.rect = session.canvas
        } else {
            let map = before.inverse.concatenating(document.transform.transform)
            session.rect = CropGeometry.clamped(session.rect.applying(map))
        }
        session.viewport = CropGeometry.viewport(for: document, crop: session.rect)
        crop = session
    }

    /// Revert to Original: no image operations, no crop or expansion, Auto fill. The objects stay. One undo step;
    /// nothing happens when there is nothing to revert, or while a live change is open.
    public func revertToOriginal() {
        guard document.canRevertToOriginal, !isInLiveChange else { return }
        changeCanvas("Revert to Original") { $0 = $0.revertedToOriginal() }
        resetCropSession()
    }

    // MARK: Canvas fill

    /// What fills the canvas outside the picture. `coalescing` for a stream of colors (the color panel's wheel, the
    /// opacity slider), so it is one undo step. Ignored while a live change is open.
    public func setCanvasFill(_ fill: CanvasFill, coalescing: Bool = false) {
        guard !isInLiveChange else { return }
        changeCanvas("Change Background", coalescing: coalescing) { $0.canvasFill = fill }
    }

    /// The custom fill color, or white when the fill isn't a color (where choosing Color starts).
    public var canvasFillColor: RGBAColor {
        if case .color(let color) = document.canvasFill { color } else { .white }
    }
}
